--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The Hub's daily challenges panel (payoff-loop step 8c): today's rows,
-- each with its progress bar, reward and Swap button, then the swaps
-- left, the all-done bonus and the countdown to the UTC reset. Built as
-- Modal `content`; MenuController owns the state, the reroll intent and
-- the modal. The wording is DailyChallengeViewLogic's.
--
-- Display only: progress, payouts and the reroll are all the server's
-- (DailyChallengeService). Swap only sends a slot number.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local DailyChallengeViewLogic = require(script.Parent.Parent.DailyChallengeViewLogic)
local Theme = require(script.Parent.Parent.Theme)

local cleanup = vide.cleanup
local create = vide.create
local derive = vide.derive
local indexes = vide.indexes
local source = vide.source

type State = DailyChallengeViewLogic.State
type Slot = DailyChallengeViewLogic.Slot

export type Props = {
	state: () -> State?,
	-- os.clock() when `state` arrived, for the countdown.
	receivedAt: () -> number,
	-- A swap is in flight: every Swap button waits.
	rerolling: () -> boolean,
	onReroll: (slot: number) -> (),
}

local SWAP_W = 80
local WIDTH = C.Modal.CONTENT_WIDTH - Theme.spacing.sm

local function line(style: string, text: string | () -> string, order: number, color: Color3?): TextLabel
	return Base.text(style, {
		Name = "Line" .. order,
		LayoutOrder = order,
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Text = text,
		TextColor3 = color,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
end

local function row(props: Props, slot: () -> Slot, index: number): Frame
	local bar = C.ProgressBar({
		-- A percentage, not progress/target: a swap or the day's reset
		-- changes the slot's target under the same row.
		value = function()
			local s = slot()
			return if s.done then 100 else 100 * math.min(s.progress, s.target) / math.max(s.target, 1)
		end,
		max = 100,
		label = function()
			return DailyChallengeViewLogic.rewardText(slot().coins, slot().xp)
		end,
		valueText = function()
			return DailyChallengeViewLogic.progressText(slot())
		end,
		width = WIDTH - SWAP_W - Theme.spacing.sm,
	})
	local swap = C.Button({
		label = DailyChallengeViewLogic.REROLL_LABEL,
		variant = "secondary",
		compact = true,
		width = SWAP_W,
		loading = props.rerolling,
		disabled = function()
			local state = props.state()
			return state == nil or not DailyChallengeViewLogic.canReroll(state, slot())
		end,
		onActivate = function()
			props.onReroll(index)
		end,
		anchorPoint = Vector2.new(1, 1),
		position = UDim2.fromScale(1, 1),
	})
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.fromScale(0, 1)
	return create("Frame")({
		Name = "Challenge" .. index,
		LayoutOrder = index,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Base.text("label", {
			Name = "Label",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(WIDTH, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Text = function()
				return slot().label
			end,
			TextColor3 = function()
				return if slot().done then Theme.color.success else Theme.color.ink
			end,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		create("Frame")({
			Name = "Bar",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(WIDTH, Theme.touch.iconButton),
			bar :: Instance,
			swap :: Instance,
		}),
	}) :: Frame
end

local DailyChallenges = {}

function DailyChallenges.content(props: Props): ScrollingFrame
	-- The countdown: a second's tick while the panel is open.
	local now = source(os.clock())
	local ticking = true
	task.spawn(function()
		while ticking do
			task.wait(1)
			if ticking then
				now(os.clock())
			end
		end
	end)
	cleanup(function()
		ticking = false
	end)

	local slots = derive(function(): { Slot }
		local state = props.state()
		return if state then state.slots else {}
	end)
	local function stateLine(f: (State) -> string): () -> string
		return function()
			local state = props.state()
			return if state then f(state) else ""
		end
	end

	local body = create("Frame")({
		Name = "Challenges",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		indexes(slots, function(slot: () -> Slot, index: number)
			return row(props, slot, index)
		end) :: any,
		line("caption", stateLine(DailyChallengeViewLogic.rerollLine), 20, Theme.color.inkMuted),
		line("label", stateLine(DailyChallengeViewLogic.bonusLine), 21, Theme.color.rim),
		line("caption", function()
			local state = props.state()
			if state == nil then
				return ""
			end
			local left = DailyChallengeViewLogic.secondsLeft(state, now() - props.receivedAt())
			return DailyChallengeViewLogic.resetText(left)
		end, 22, Theme.color.inkMuted),
	})

	-- Modal.open fits the height to the screen, then it scrolls: three
	-- rows are taller than a landscape phone has room for.
	return create("ScrollingFrame")({
		Name = "ChallengesScroll",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 4,
		body,
	}) :: ScrollingFrame
end

return DailyChallenges
