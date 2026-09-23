--!strict
-- Client half of P5-3's map vote: draws the board VoteService sends
-- and sends taps back as MapVoteIntent. Every decision (the ballot, who
-- voted for what, when it locks, who won, how a tie broke) is made on
-- the server; this file only displays it, so a compromised client can
-- change what it personally sees and nothing else. docs/voting.md §"The
-- board" is the spec this implements.
--
-- LAYOUT, FOR ONE THUMB IN PORTRAIT: a bottom sheet over a dimmed
-- screen. The ballot is at most 4 full-width cards stacked vertically,
-- each one big tap target in the lower half of the screen. No camera,
-- no scrolling, no second thumb. Each card: thumbnail, map name, live
-- count, and the avatars of whoever voted for it.
--
-- THE REVEAL: an outright winner gets a gold border and "WINNER". A tie
-- the server broke at random gets a visibly different treatment: a
-- "TIE - PICKED AT RANDOM" banner, and a highlight that cycles over
-- ONLY the tied cards, slowing down before it lands on the winner. The
-- server has already picked it; the roulette just shows players that
-- the pick was among the tied maps and was random, not rigged. The
-- server holds the board open for revealSeconds, which is what the
-- roulette's timing is sized to.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local Maps = require(ReplicatedStorage.Shared.Config.Maps)

local localPlayer = Players.LocalPlayer

local COLORS = {
	dim = Color3.fromRGB(0, 0, 0),
	sheet = Color3.fromRGB(28, 30, 38),
	card = Color3.fromRGB(44, 47, 58),
	text = Color3.fromRGB(240, 240, 245),
	muted = Color3.fromRGB(165, 168, 180),
	mine = Color3.fromRGB(80, 170, 255), -- the card you voted for
	winner = Color3.fromRGB(255, 200, 60),
	tie = Color3.fromRGB(190, 110, 255), -- the random tie-break, never gold
	warning = Color3.fromRGB(255, 120, 90),
}

local CARD_HEIGHT = 88
local AVATAR_SIZE = 26
local MAX_AVATARS = 6

type Card = {
	button: TextButton,
	stroke: UIStroke,
	count: TextLabel,
	avatars: Frame,
	tag: TextLabel,
}

type Board = {
	gui: ScreenGui,
	groupId: string,
	title: TextLabel,
	timer: TextLabel,
	banner: TextLabel,
	cards: { [string]: Card },
	order: { string },
	revealed: boolean,
}

local board: Board? = nil
local avatarCache: { [number]: string } = {}

local function mapDef(mapId: string): { displayName: string, thumbnailAssetId: string }?
	for _, entry in Maps do
		if entry.def.id == mapId then
			return entry.def
		end
	end
	return nil
end

local function assetUri(id: string): string
	return if string.find(id, "://", 1, true) then id else "rbxassetid://" .. id
end

-- Head shots are fetched once per user and cached; the card shows a
-- blank circle until the fetch lands, then the next update fills it.
local function avatarFor(userId: number): string
	local cached = avatarCache[userId]
	if cached ~= nil then
		return cached
	end
	avatarCache[userId] = ""
	task.spawn(function()
		local ok, content = pcall(function(): string
			return (Players:GetUserThumbnailAsync(userId, Enum.ThumbnailType.HeadShot, Enum.ThumbnailSize.Size48x48))
		end)
		if ok then
			avatarCache[userId] = content
		end
	end)
	return ""
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamBold
	text.TextColor3 = COLORS.text
	text.TextScaled = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	for key, value in props do
		(text :: any)[key] = value
	end
	text.Parent = parent
	return text
end

local function corner(parent: Instance, radius: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = parent
end

local function buildCard(list: Frame, mapId: string, index: number): Card
	local def = mapDef(mapId)
	local button = Instance.new("TextButton")
	button.Name = mapId
	button.LayoutOrder = index
	button.Size = UDim2.new(1, 0, 0, CARD_HEIGHT)
	button.BackgroundColor3 = COLORS.card
	button.AutoButtonColor = true
	button.Text = ""
	corner(button, 12)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Transparency = 1
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = button

	local thumb = Instance.new("ImageLabel")
	thumb.Size = UDim2.fromOffset(CARD_HEIGHT - 16, CARD_HEIGHT - 16)
	thumb.Position = UDim2.fromOffset(8, 8)
	thumb.BackgroundColor3 = COLORS.sheet
	thumb.ScaleType = Enum.ScaleType.Crop
	thumb.Image = if def then assetUri(def.thumbnailAssetId) else ""
	corner(thumb, 8)
	thumb.Parent = button

	local left = CARD_HEIGHT + 4
	label(button, {
		Text = if def then def.displayName else mapId,
		Size = UDim2.new(1, -left - 70, 0, 28),
		Position = UDim2.fromOffset(left, 10),
	})
	local tag = label(button, {
		Text = "",
		Size = UDim2.new(1, -left - 70, 0, 16),
		Position = UDim2.fromOffset(left, 40),
		TextColor3 = COLORS.muted,
	})
	local count = label(button, {
		Text = "0",
		Size = UDim2.fromOffset(56, 40),
		Position = UDim2.new(1, -64, 0.5, -20),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local avatars = Instance.new("Frame")
	avatars.BackgroundTransparency = 1
	avatars.Size = UDim2.new(1, -left - 70, 0, AVATAR_SIZE)
	avatars.Position = UDim2.new(0, left, 1, -AVATAR_SIZE - 8)
	local row = Instance.new("UIListLayout")
	row.FillDirection = Enum.FillDirection.Horizontal
	row.Padding = UDim.new(0, 4)
	row.Parent = avatars
	avatars.Parent = button

	button.Activated:Connect(function()
		local current = board
		if current == nil or current.revealed then
			return
		end
		Net.fireServer("MapVoteIntent", { mapId = mapId })
	end)

	button.Parent = list
	return { button = button, stroke = stroke, count = count, avatars = avatars, tag = tag }
end

local function buildBoard(state: any): Board
	local gui = Instance.new("ScreenGui")
	gui.Name = "MapVoteBoard"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20

	local dim = Instance.new("Frame")
	dim.Size = UDim2.fromScale(1, 1)
	dim.BackgroundColor3 = COLORS.dim
	dim.BackgroundTransparency = 0.45
	dim.Parent = gui

	local count = #state.cards
	local sheetHeight = 96 + count * (CARD_HEIGHT + 10) + 24
	local sheet = Instance.new("Frame")
	sheet.AnchorPoint = Vector2.new(0.5, 1)
	sheet.Position = UDim2.fromScale(0.5, 1)
	sheet.Size = UDim2.new(1, 0, 0, sheetHeight)
	sheet.BackgroundColor3 = COLORS.sheet
	corner(sheet, 20)
	local maxWidth = Instance.new("UISizeConstraint")
	maxWidth.MaxSize = Vector2.new(520, math.huge)
	maxWidth.Parent = sheet
	sheet.Parent = gui

	local title = label(sheet, {
		Text = "Vote for the map",
		Size = UDim2.new(1, -120, 0, 30),
		Position = UDim2.fromOffset(16, 16),
	})
	local timer = label(sheet, {
		Text = "",
		Size = UDim2.fromOffset(88, 30),
		Position = UDim2.new(1, -104, 0, 16),
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local banner = label(sheet, {
		Text = "Tap a map. You can change your vote until time runs out.",
		Font = Enum.Font.Gotham,
		TextColor3 = COLORS.muted,
		Size = UDim2.new(1, -32, 0, 20),
		Position = UDim2.fromOffset(16, 56),
	})

	local list = Instance.new("Frame")
	list.BackgroundTransparency = 1
	list.Position = UDim2.fromOffset(16, 88)
	list.Size = UDim2.new(1, -32, 1, -100)
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	list.Parent = sheet

	local cards: { [string]: Card } = {}
	local order: { string } = {}
	for index, card in state.cards do
		cards[card.mapId] = buildCard(list, card.mapId, index)
		table.insert(order, card.mapId)
	end

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return {
		gui = gui,
		groupId = state.groupId,
		title = title,
		timer = timer,
		banner = banner,
		cards = cards,
		order = order,
		revealed = false,
	}
end

local function setHighlight(card: Card, color: Color3?)
	card.stroke.Transparency = if color then 0 else 1
	if color then
		card.stroke.Color = color
	end
end

local function renderVotes(current: Board, state: any)
	for _, entry in state.cards do
		local card = current.cards[entry.mapId]
		if card == nil then
			continue
		end
		card.count.Text = tostring(entry.votes)
		for _, child in card.avatars:GetChildren() do
			if child:IsA("ImageLabel") then
				child:Destroy()
			end
		end
		for i, userId in entry.voters do
			if i > MAX_AVATARS then
				break
			end
			local avatar = Instance.new("ImageLabel")
			avatar.Size = UDim2.fromOffset(AVATAR_SIZE, AVATAR_SIZE)
			avatar.BackgroundColor3 = COLORS.sheet
			avatar.Image = avatarFor(userId)
			corner(avatar, AVATAR_SIZE // 2)
			avatar.Parent = card.avatars
		end
		if not current.revealed then
			setHighlight(card, if state.myVote == entry.mapId then COLORS.mine else nil)
			card.tag.Text = if state.myVote == entry.mapId then "Your vote" else ""
		end
	end
end

-- Cycles a highlight over the tied cards only, slowing down, and
-- lands on the winner the server already chose. About 2s, inside the
-- server's revealSeconds.
local function playTieRoulette(current: Board, tied: { string }, winner: string)
	local steps = 12
	local winnerIndex = table.find(tied, winner) or 1
	-- Start so the last step lands exactly on the winner.
	local startIndex = ((winnerIndex - steps) % #tied) + 1
	for step = 0, steps - 1 do
		if board ~= current then
			return
		end
		local mapId = tied[((startIndex - 1 + step) % #tied) + 1]
		for _, id in tied do
			setHighlight(current.cards[id], if id == mapId then COLORS.tie else nil)
		end
		task.wait(0.05 + step * 0.02)
	end
end

local function reveal(current: Board, state: any)
	current.revealed = true
	current.timer.Text = ""
	for _, card in current.cards do
		card.button.AutoButtonColor = false
		card.tag.Text = ""
		setHighlight(card, nil)
	end

	local winnerCard = current.cards[state.winner]
	local def = mapDef(state.winner or "")
	local name = if def then def.displayName elseif state.winner then state.winner else "a random map"

	if state.fallback then
		current.title.Text = "Heading to " .. name
		current.banner.TextColor3 = COLORS.warning
		current.banner.Text = "We couldn't count the votes this time, so the map was picked for you."
	elseif state.randomTieBreak then
		current.title.Text = "It's a tie!"
		current.banner.TextColor3 = COLORS.tie
		current.banner.Text = "🎲 TIE - PICKED AT RANDOM between the tied maps"
		for _, id in state.tied do
			local card = current.cards[id]
			if card then
				card.tag.Text = "Tied"
				card.tag.TextColor3 = COLORS.tie
			end
		end
		playTieRoulette(current, state.tied, state.winner)
	else
		current.title.Text = name .. " wins!"
		current.banner.Text = "Most votes wins."
	end

	if board ~= current or winnerCard == nil then
		return
	end
	local finalColor = if state.randomTieBreak then COLORS.tie else COLORS.winner
	setHighlight(winnerCard, finalColor)
	winnerCard.tag.Text = if state.randomTieBreak then "🎲 Random pick" else "WINNER"
	winnerCard.tag.TextColor3 = finalColor
	TweenService:Create(winnerCard.button, TweenInfo.new(0.25, Enum.EasingStyle.Back), {
		BackgroundColor3 = finalColor:Lerp(COLORS.card, 0.7),
	}):Play()
end

local function close()
	if board ~= nil then
		board.gui:Destroy()
		board = nil
	end
end

local function onState(state: any)
	if type(state) ~= "table" then
		return
	end
	if state.closed then
		close()
		return
	end
	if type(state.cards) ~= "table" then
		return
	end
	local current = board
	if current == nil or current.groupId ~= state.groupId then
		close()
		current = buildBoard(state)
		board = current
	end
	local live = current :: Board
	renderVotes(live, state)
	if state.locked then
		if not live.revealed then
			task.spawn(reveal, live, state)
		end
	else
		live.timer.Text = tostring(state.secondsLeft) .. "s"
	end
end

local VoteBoardController: Loader.Controller = {
	name = "VoteBoardController",
	dependencies = {},
}

function VoteBoardController:init()
	Net.onClientEvent("MapVoteState", onState)
end

return VoteBoardController
