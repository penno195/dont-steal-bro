--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The hub's leaderboard wall: the three HubLeaderboardSurface parts
-- (hub-spec.md), one per `Period` ("Daily", "Weekly", "AllTime"), each
-- showing that board's top streaks. What a wall says lives in
-- UI/BoardLogic.wall (pure, tested); this file draws it.
--
-- DATA: the same broadcasts the menu's Leaderboards screen uses
-- (LeaderboardState, PeriodBoardState), sent from the server's cache on
-- join and every refresh. There is nothing to request.
--
-- WHERE: a SurfaceGui per part on its Front face, parented to PlayerGui
-- and adorned to the part, like QueueController's board, so this
-- viewer's own row can be highlighted. The parts may stream in and out;
-- each mounts when it arrives and unmounts when it leaves.
--
-- WHEN: hub servers only. Streaks are never shown on a match server
-- during a round (design-decisions.md Q7 condition 1), and a match
-- server has no wall anyway.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local vide = require(ReplicatedStorage.Packages.Vide)

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local BoardLogic = require(script.Parent.Parent.UI.BoardLogic)
local Theme = require(script.Parent.Parent.UI.Theme)

local source = vide.source
local create = vide.create
local indexes = vide.indexes

local TAG = "HubLeaderboardSurface"
local PIXELS_PER_STUD = 40
-- Fractions of the board's height.
local TITLE_H = 0.13
local FOOTER_H = 0.06
local ROW_GAP = 0.006

local selfId = Players.LocalPlayer.UserId
local boards = source({} :: { [string]: BoardLogic.Payload })
local mounted: { [Instance]: () -> () } = {}

local function isHubServer(): boolean
	local hubPlaceId = GameConfig.matchmaking.hubPlaceId
	if hubPlaceId == 0 then
		return RunService:IsStudio() and Workspace:FindFirstChild("Hub") ~= nil
	end
	return game.PlaceId == hubPlaceId
end

local function setBoard(tab: string, payload: any)
	if type(payload) ~= "table" or type(payload.entries) ~= "table" then
		return
	end
	local nextBoards = table.clone(boards())
	nextBoards[tab] = {
		entries = payload.entries,
		status = if type(payload.status) == "string" then payload.status else "Fresh",
		periodKey = payload.periodKey,
	}
	boards(nextBoards)
end

local function textLabel(props: { [any]: any })
	local base = {
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = Theme.type.body.font,
		TextColor3 = Theme.color.ink,
	}
	for key, value in props do
		base[key] = value
	end
	return create("TextLabel")(base)
end

local function row(item: () -> BoardLogic.WallRow, index: number)
	local rowH = (1 - TITLE_H - FOOTER_H) / BoardLogic.WALL_ROWS
	return create("Frame")({
		Name = "Row" .. index,
		Position = UDim2.fromScale(0.04, TITLE_H + (index - 1) * rowH),
		Size = UDim2.fromScale(0.92, rowH - ROW_GAP),
		BackgroundColor3 = function()
			return if item().isViewer then Theme.color.primary else Theme.color.surfaceRaised
		end,
		create("UICorner")({ CornerRadius = UDim.new(0.2, 0) }),
		textLabel({
			Name = "Rank",
			Position = UDim2.fromScale(0.03, 0.12),
			Size = UDim2.fromScale(0.15, 0.76),
			FontFace = Theme.type.label.font,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = function()
				return item().rank
			end,
		}),
		textLabel({
			Name = "Name",
			Position = UDim2.fromScale(0.19, 0.12),
			Size = UDim2.fromScale(0.6, 0.76),
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = function()
				return item().name
			end,
		}),
		textLabel({
			Name = "Streak",
			Position = UDim2.fromScale(0.8, 0.12),
			Size = UDim2.fromScale(0.17, 0.76),
			FontFace = Theme.type.label.font,
			TextXAlignment = Enum.TextXAlignment.Right,
			TextColor3 = function()
				return if item().isViewer then Theme.color.onPrimary else Theme.color.warning
			end,
			Text = function()
				return item().streak
			end,
		}),
	})
end

local function mount(part: Instance)
	if not part:IsA("BasePart") or mounted[part] ~= nil then
		return
	end
	local tab = part:GetAttribute("Period")
	if type(tab) ~= "string" or BoardLogic.wall(tab, nil, selfId) == nil then
		warn(string.format("HubBoardController: %s has no valid Period attribute", part:GetFullName()))
		return
	end

	-- The hub builder's placeholder label ("DAILY" etc) shares the Front
	-- face; hide it on this client so the two don't overlap.
	local placeholder = part:FindFirstChild("Display")
	if placeholder ~= nil and placeholder:IsA("SurfaceGui") then
		placeholder.Enabled = false
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	mounted[part] = vide.root(function()
		local function wall(): BoardLogic.Wall
			return BoardLogic.wall(tab, boards()[tab], selfId) :: BoardLogic.Wall
		end
		local function rows(): { BoardLogic.WallRow }
			return wall().rows
		end

		local gui = create("SurfaceGui")({
			Name = "LeaderboardWall" .. tab,
			Adornee = part,
			Face = Enum.NormalId.Front,
			SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
			PixelsPerStud = PIXELS_PER_STUD,
			LightInfluence = 0,
			ResetOnSpawn = false,
			create("Frame")({
				Name = "Board",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Theme.color.background,
				textLabel({
					Name = "Title",
					Position = UDim2.fromScale(0.04, 0.02),
					Size = UDim2.fromScale(0.92, TITLE_H - 0.04),
					FontFace = Theme.type.headline.font,
					Text = function()
						return wall().title
					end,
				}),
				indexes(rows, row),
				textLabel({
					Name = "Message",
					Position = UDim2.fromScale(0.08, 0.35),
					Size = UDim2.fromScale(0.84, 0.12),
					FontFace = Theme.type.title.font,
					Visible = function()
						return wall().message ~= nil
					end,
					Text = function()
						return wall().message or ""
					end,
				}),
				textLabel({
					Name = "Detail",
					Position = UDim2.fromScale(0.12, 0.5),
					Size = UDim2.fromScale(0.76, 0.08),
					TextColor3 = Theme.color.inkMuted,
					Visible = function()
						return wall().detail ~= nil
					end,
					Text = function()
						return wall().detail or ""
					end,
				}),
				-- Staleness: words, never a colour alone.
				textLabel({
					Name = "Stale",
					Position = UDim2.fromScale(0.04, 1 - FOOTER_H),
					Size = UDim2.fromScale(0.92, FOOTER_H - 0.01),
					TextColor3 = Theme.color.warning,
					Visible = function()
						return wall().stale
					end,
					Text = "⚠ Showing older results. Refreshing soon.",
				}),
			}),
			Parent = playerGui,
		}) :: SurfaceGui
		vide.cleanup(function()
			gui:Destroy()
		end)
	end)
end

local function unmount(part: Instance)
	local destroy = mounted[part]
	if destroy ~= nil then
		mounted[part] = nil
		destroy()
	end
end

local HubBoardController: Loader.Controller = {
	name = "HubBoardController",
	dependencies = {},
}

function HubBoardController:init()
	if not isHubServer() then
		return
	end
	Net.onClientEvent("LeaderboardState", function(payload: any)
		setBoard("AllTime", payload)
	end)
	Net.onClientEvent("PeriodBoardState", function(payload: any)
		if type(payload) == "table" and (payload.kind == "Daily" or payload.kind == "Weekly") then
			setBoard(payload.kind, payload)
		end
	end)
end

function HubBoardController:start()
	if not isHubServer() then
		return
	end
	for _, part in CollectionService:GetTagged(TAG) do
		mount(part)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(mount)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unmount)
end

return HubBoardController
