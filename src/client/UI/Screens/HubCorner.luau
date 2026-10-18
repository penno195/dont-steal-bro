--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The Hub's top-right column (Hub menu pass, 2026-10-18; mockup
-- docs/ui-art-pass/hub-menu.html): the level pill, the week's playtime
-- row under it (always shown while the free pass is still to earn), the
-- daily challenges drop-down the pill opens, and the launcher's buttons
-- under all that. While the drop-down is open it takes the buttons'
-- place: pushed down, they'd run into the jump button.
--
-- Display only. The full challenges panel (with its Swap buttons) is
-- still MenuController's modal; the drop-down's "Swap" opens it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local DailyChallengeViewLogic = require(script.Parent.Parent.DailyChallengeViewLogic)
local Icons = require(script.Parent.Parent.Components.Icons)
local SeasonTrackLogic = require(script.Parent.Parent.SeasonTrackLogic)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive
local indexes = vide.indexes
local source = vide.source

type State = DailyChallengeViewLogic.State
type Slot = DailyChallengeViewLogic.Slot

export type Props = {
	width: number, -- the column's width, reference px
	visible: () -> boolean, -- the Hub's pill row is showing
	level: () -> number?, -- nil until StoreState arrives
	fraction: () -> number,
	playtime: () -> SeasonTrackLogic.PlaytimeView?,
	challenges: () -> State?,
	receivedAt: () -> number, -- os.clock() when `challenges` arrived
	openChallenges: () -> (), -- the full panel, with the swaps
	buttons: Instance, -- the launcher row, shown while the drop-down is shut
}

local PAD = Theme.spacing.sm
local ICON = Theme.spacing.xl
local BAR = Theme.spacing.xs + Theme.spacing.xxs

local function bar(fraction: () -> number, gradient: ColorSequence, order: number): Frame
	return create("Frame")({
		Name = "Track",
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, BAR),
		BackgroundColor3 = Theme.color.background,
		Base.corner(Theme.radius.pill),
		create("Frame")({
			Name = "Fill",
			BackgroundColor3 = Color3.new(1, 1, 1),
			Size = function()
				return UDim2.fromScale(math.clamp(fraction(), 0, 1), 1)
			end,
			Visible = function()
				return fraction() > 0.001
			end,
			Base.corner(Theme.radius.pill),
			create("UIGradient")({ Color = gradient }),
		}),
	}) :: Frame
end

local function panel(name: string, order: number, rim: Color3, children: { any }): Frame
	local props: { [any]: any } = {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Base.STAGE_BACKGROUND,
		Base.corner(Theme.radius.md),
		Base.stage({ rim = rim, outline = PAD }),
		create("UIPadding")({
			PaddingTop = UDim.new(0, PAD),
			PaddingBottom = UDim.new(0, PAD),
			PaddingLeft = UDim.new(0, PAD),
			PaddingRight = UDim.new(0, PAD),
		}),
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

-- Icon on the left, a label over a bar in the middle, a note on the right.
local function row(
	order: number,
	icon: GuiObject,
	label: () -> string,
	labelColor: () -> Color3,
	fraction: () -> number,
	gradient: ColorSequence,
	note: () -> string
): Frame
	local NOTE_W = 64
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	return create("Frame")({
		Name = "Row" .. order,
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, ICON),
		BackgroundTransparency = 1,
		icon,
		create("Frame")({
			Name = "Middle",
			Position = UDim2.fromOffset(ICON + Theme.spacing.xs, 0),
			Size = UDim2.new(1, -(ICON + Theme.spacing.xs + NOTE_W), 1, 0),
			BackgroundTransparency = 1,
			create("UIListLayout")({
				Padding = UDim.new(0, Theme.spacing.xxs),
				VerticalAlignment = Enum.VerticalAlignment.Center,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			Base.text("caption", {
				Name = "Label",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, Theme.type.caption.size),
				Text = label,
				TextColor3 = labelColor,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			bar(fraction, gradient, 2),
		}),
		Base.text("caption", {
			Name = "Note",
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.fromScale(1, 0.5),
			Size = UDim2.fromOffset(NOTE_W - Theme.spacing.xs, Theme.type.caption.size),
			Text = note,
			TextColor3 = Theme.color.rim,
			TextXAlignment = Enum.TextXAlignment.Right,
		}),
	}) :: Frame
end

local GOLD = ColorSequence.new(Theme.fill.primary.top, Theme.fill.primary.bottom)
local GREEN = ColorSequence.new(Theme.fill.share.top, Theme.color.success)

local function challengeRow(slot: () -> Slot, index: number): Frame
	local icon = create("Frame")({
		Name = "Icon",
		Size = UDim2.fromOffset(ICON, ICON),
		BackgroundTransparency = 1,
		Icons.view("check-badge", ICON, Theme.color.ink),
	}) :: Frame
	local mark = icon:FindFirstChild("Icon") :: ImageLabel
	local tasks = Icons.view("hub-tasks", ICON, Theme.color.ink)
	tasks.Parent = icon
	vide.effect(function()
		mark.Visible = slot().done
		tasks.Visible = not slot().done
	end)
	return row(
		index,
		icon,
		function()
			return slot().label
		end,
		function()
			return if slot().done then Theme.color.inkMuted else Theme.color.ink
		end,
		function()
			local s = slot()
			return if s.done then 1 else math.min(s.progress, s.target) / math.max(s.target, 1)
		end,
		GREEN,
		function()
			local s = slot()
			return if s.done then "Done" else DailyChallengeViewLogic.rewardText(s.coins, 0)
		end
	)
end

local HubCorner = {}

function HubCorner.column(props: Props): Frame
	local open = source(false)
	local hasList = derive(function()
		local s = props.challenges()
		return s ~= nil and #s.slots > 0
	end)
	-- A list that goes away (a server hop, the reset) shuts the drop-down.
	vide.effect(function()
		if not hasList() then
			open(false)
		end
	end)

	local badge = C.LevelBadge({
		width = props.width,
		level = function()
			return props.level() or 1
		end,
		fraction = props.fraction,
		caption = function()
			return DailyChallengeViewLogic.levelCaption(props.challenges())
		end,
		open = open,
		onActivate = function()
			if hasList() then
				open(not open())
			end
		end,
	})
	badge.LayoutOrder = 1
	vide.effect(function()
		badge.Visible = props.visible() and props.level() ~= nil
	end)

	local playtime = panel("Playtime", 2, Theme.color.rim, {
		row(
			1,
			Icons.view("hub-playtime", ICON, Theme.color.ink),
			function()
				return "Free Season Pass"
			end,
			function()
				return Theme.color.ink
			end,
			function()
				local view = props.playtime()
				return if view then view.fraction else 0
			end,
			GOLD,
			function()
				local view = props.playtime()
				return if view then view.short else ""
			end
		),
	})
	vide.effect(function()
		playtime.Visible = props.visible() and props.playtime() ~= nil
	end)

	-- The countdown ticks only while the drop-down is open.
	local now = source(os.clock())
	vide.effect(function()
		if not open() then
			return
		end
		local ticking = true
		task.spawn(function()
			while ticking do
				now(os.clock())
				task.wait(1)
			end
		end)
		vide.cleanup(function()
			ticking = false
		end)
	end)
	local slots = derive(function(): { Slot }
		local s = props.challenges()
		return if s then s.slots else {}
	end)
	local function stateText(f: (State) -> string): () -> string
		return function()
			local s = props.challenges()
			return if s then f(s) else ""
		end
	end
	local swapW = Theme.spacing.xxxl + Theme.spacing.md
	local drop = panel("Challenges", 3, Theme.color.line, {
		Base.text("caption", {
			Name = "Head",
			LayoutOrder = 0,
			Size = UDim2.new(1, 0, 0, Theme.type.caption.size),
			Text = function()
				local s = props.challenges()
				if s == nil then
					return ""
				end
				return DailyChallengeViewLogic.resetText(
					DailyChallengeViewLogic.secondsLeft(s, now() - props.receivedAt())
				)
			end,
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		indexes(slots, challengeRow) :: any,
		create("Frame")({
			Name = "Foot",
			LayoutOrder = 100,
			Size = UDim2.new(1, 0, 0, Theme.touch.iconButton),
			BackgroundTransparency = 1,
			Base.text("caption", {
				Name = "Bonus",
				Size = UDim2.new(1, -(swapW + Theme.spacing.xs), 1, 0),
				Text = stateText(DailyChallengeViewLogic.bonusLine),
				TextColor3 = Theme.color.rim,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			C.Button({
				label = DailyChallengeViewLogic.REROLL_LABEL,
				variant = "secondary",
				compact = true,
				width = swapW,
				anchorPoint = Vector2.new(1, 0.5),
				position = UDim2.fromScale(1, 0.5),
				onActivate = function()
					open(false)
					props.openChallenges()
				end,
			}) :: any,
		}),
	})
	vide.effect(function()
		drop.Visible = props.visible() and open()
	end)

	local buttons = props.buttons :: GuiObject
	buttons.LayoutOrder = 4
	vide.effect(function()
		buttons.Visible = not (props.visible() and open())
	end)

	return create("Frame")({
		Name = "HubColumn",
		Size = UDim2.fromOffset(props.width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
		}),
		badge,
		playtime,
		drop,
		buttons,
	}) :: Frame
end

return HubCorner
