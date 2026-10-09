--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- Practice parties, the client half (design-decisions.md Q7, the
-- "practice matches and parties" case; PartyService is the server's).
-- Three pieces, all Hub only:
--
--   THE PANEL (openPanel, from the queue card's Party button): who's in
--   your party, everyone else on this server with an Invite button, and
--   Leave party. Rows show a headshot and display name only - never a
--   title or streak (Q7 condition 1 covers indirect tells too).
--
--   THE INVITE PROMPT: a modal with Accept / Decline whenever an invite
--   waits on this player, closed when they answer, when the server
--   says it's gone, or when its TTL runs out (the server never pushes
--   an expiry, so the prompt times itself out).
--
--   NOTICES: PartyState's one-line notice ("Invite sent.") as a toast.
--
-- The rules - which buttons, which rows - live in UI/PartyViewLogic
-- (pure, tested). QueueController reads `state` for the card's buttons.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local C = require(script.Parent.Parent.UI.Components)
local Base = require(script.Parent.Parent.UI.Components.Base)
local PartyViewLogic = require(script.Parent.Parent.UI.PartyViewLogic)
local Theme = require(script.Parent.Parent.UI.Theme)
local MenuController = require(script.Parent.MenuController)

local create = vide.create
local show = vide.show
local source = vide.source
local values = vide.values

local TTL = GameConfig.matchmaking.partyInviteTtlSeconds
local MAX_SIZE = GameConfig.matchmaking.groupSize
local TICK = 1
local INVITE_WIDTH = 88 -- reference px, the row's Invite / Sent button
local CONTENT_WIDTH = C.Modal.CONTENT_WIDTH

local me = Players.LocalPlayer.UserId

local state = source(PartyViewLogic.new())
-- Everyone else on this server, by display name.
local others = source({} :: { number })
-- userId -> os.clock() of this client's last invite to them.
local sentAt = source({} :: { [number]: number })
-- Ticks once a second, so "Sent" turns back into "Invite" on time.
local clock = source(os.clock())

local closePanel: (() -> ())? = nil
local closeInvite: (() -> ())? = nil
local inviteShownFrom: number? = nil

local function displayName(userId: number): string
	local player = Players:GetPlayerByUserId(userId)
	return if player then player.DisplayName else "Player"
end

local function refreshOthers()
	local ids: { number } = {}
	for _, player in Players:GetPlayers() do
		if player.UserId ~= me then
			table.insert(ids, player.UserId)
		end
	end
	table.sort(ids, function(a, b)
		return displayName(a):lower() < displayName(b):lower()
	end)
	others(ids)
end

-- ===== the panel ============================================================

local function hidePanel()
	if closePanel ~= nil then
		(closePanel :: () -> ())()
		closePanel = nil
	end
end

local function invite(userId: number)
	local sent = table.clone(sentAt())
	sent[userId] = os.clock()
	sentAt(sent)
	Net.fireServer("PartyInviteIntent", { targetId = userId })
end

local function sectionCaption(text: string | () -> string, order: number): Instance
	return Base.text("caption", {
		Name = "Caption",
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xs),
		Text = text,
		TextColor3 = Theme.color.inkMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

local function memberRow(userId: number, index: () -> number): Instance
	local row = C.PlayerRow({
		userId = userId,
		displayName = displayName(userId),
		trailing = function(): string
			return if state().leaderId == userId then "Leader" else ""
		end,
		isLocalPlayer = userId == me,
		width = CONTENT_WIDTH,
	})
	row.LayoutOrder = 10 + index()
	return row
end

local function otherRow(userId: number, index: () -> number): Instance
	local action = function(): PartyViewLogic.RowAction?
		return PartyViewLogic.rowAction(state(), me, userId, MAX_SIZE, sentAt()[userId], clock(), TTL)
	end
	local button = C.Button({
		label = function(): string
			return if action() == "Sent" then "Sent" else "Invite"
		end,
		variant = "secondary",
		compact = true,
		width = INVITE_WIDTH,
		disabled = function(): boolean
			return action() ~= "Invite"
		end,
		onActivate = function()
			if action() == "Invite" then
				invite(userId)
			end
		end,
	})
	-- Not ours to invite (a member's view, or a full party): no button.
	vide.effect(function()
		button.Visible = action() ~= nil
	end)
	local row = C.PlayerRow({
		userId = userId,
		displayName = displayName(userId),
		accessory = button,
		accessoryWidth = INVITE_WIDTH,
		width = CONTENT_WIDTH,
	})
	row.LayoutOrder = 100 + index()
	return row
end

local function panelContent(): Instance
	local members = function(): { number }
		return state().memberIds
	end
	local outside = function(): { number }
		local s = state()
		local ids: { number } = {}
		for _, userId in others() do
			if not PartyViewLogic.isMember(s, userId) then
				table.insert(ids, userId)
			end
		end
		return ids
	end
	local inParty = function(): boolean
		return PartyViewLogic.inParty(state())
	end
	local leads = function(): boolean
		return PartyViewLogic.leads(state(), me)
	end

	local body = create("Frame")({
		Name = "Body",
		Size = UDim2.fromOffset(CONTENT_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),

		show(inParty, function()
			return sectionCaption(function()
				return string.format("In your party (%d/%d)", #state().memberIds, MAX_SIZE)
			end, 1)
		end) :: any,
		values(members, memberRow) :: any,
		show(inParty, function()
			return C.Button({
				label = "Leave party",
				variant = "danger",
				width = CONTENT_WIDTH,
				onActivate = function()
					Net.fireServer("PartyLeaveIntent", {})
				end,
				layoutOrder = 50,
			})
		end) :: any,

		sectionCaption(function()
			if #outside() == 0 then
				return "Nobody else is on this server yet."
			end
			return if leads() then "On this server" else "Only your party leader can invite."
		end, 60),
		values(outside, otherRow) :: any,
	})

	return create("ScrollingFrame")({
		Name = "Players",
		-- Modal.open fits the height to the screen (fitToScreen).
		Size = UDim2.fromOffset(CONTENT_WIDTH, 0),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = Theme.spacing.xs,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.fromScale(0, 0),
		body,
	})
end

local function openPanel()
	if closePanel ~= nil or closeInvite ~= nil then
		return
	end
	refreshOthers()
	closePanel = C.Modal.open({
		title = "Party",
		body = "Play Practice together. Parties can't play ranked, and nothing is at stake in practice.",
		content = panelContent,
		actions = { { label = "Done", variant = "secondary", onActivate = hidePanel } },
		dismissible = true,
		onDismiss = hidePanel,
	})
end

-- ===== the invite prompt ====================================================

local function hideInvite()
	if closeInvite ~= nil then
		(closeInvite :: () -> ())()
		closeInvite = nil
	end
	inviteShownFrom = nil
end

local function respond(accept: boolean)
	Net.fireServer("PartyRespondIntent", { accept = accept })
	-- Answered: forget it here, so the tick doesn't reopen it before
	-- the server's PartyState lands.
	local s = table.clone(state())
	s.inviteFromId = nil
	s.inviteAt = nil
	state(s)
	hideInvite()
end

local function syncInvite()
	local s = state()
	if not PartyViewLogic.inviteOpen(s, os.clock(), TTL) then
		hideInvite()
		return
	end
	if closeInvite ~= nil and inviteShownFrom == s.inviteFromId then
		return
	end
	hideInvite()
	-- One modal at a time (Modal.luau): the invite outranks the panel.
	hidePanel()
	local from = s.inviteFromId :: number
	inviteShownFrom = from
	closeInvite = C.Modal.open({
		title = "Party invite",
		body = string.format(
			"%s invited you to their party. Parties play Practice only: no streak, coins or stats at stake.",
			displayName(from)
		),
		actions = {
			{
				label = "Join party",
				variant = "primary",
				onActivate = function()
					respond(true)
				end,
			},
			{
				label = "No thanks",
				variant = "secondary",
				onActivate = function()
					respond(false)
				end,
			},
		},
		dismissible = true,
		onDismiss = function()
			respond(false)
		end,
	})
end

-- ===== controller ===========================================================

local PartyController: Loader.Controller = {
	name = "PartyController",
	dependencies = { "UIScaleController", "MenuController" },

	-- Read by QueueController for the card's buttons.
	state = state,
	openPanel = openPanel,
}

function PartyController:init()
	if not MenuController.isHubServer() then
		return
	end
	Net.onClientEvent("PartyState", function(payload: any)
		local nextState, notice = PartyViewLogic.apply(state(), payload, os.clock())
		state(nextState)
		if notice ~= nil then
			C.Toast.show(notice, "info")
		end
		syncInvite()
	end)
end

function PartyController:start()
	if not MenuController.isHubServer() then
		return
	end
	refreshOthers()
	Players.PlayerAdded:Connect(refreshOthers)
	Players.PlayerRemoving:Connect(function(player: Player)
		local ids: { number } = {}
		for _, userId in others() do
			if userId ~= player.UserId then
				table.insert(ids, userId)
			end
		end
		others(ids)
	end)

	task.spawn(function()
		while true do
			task.wait(TICK)
			clock(os.clock())
			syncInvite()
		end
	end)
end

return PartyController
