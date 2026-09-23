--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The round results screen (P6-6). Mounted by MenuController on entering
-- Results, once the Decision Studio screen has been dismissed
-- (DecisionStudioController.isActive), so the two never overlap.
--
-- DATA, and how far each is trusted (ResultsLogic's header):
--   - recap: RoundRecap, PER-REQUEST in effect - the server targets it
--     at this player once, on entering Results. Authoritative.
--   - tally: counted by MenuController from broadcasts it already got
--     this round (TaskQualificationResult, its own PowerUpUseResult).
--     Display-only.
--
-- SEQUENCING. One card per ResultsLogic beat, revealed on its clock, and
-- the streak last after a held pause. A tap anywhere shows everything
-- at once. Reduced motion keeps the same order and timing and only
-- drops the slide-in (ResultsLogic.beats says why).
--
-- The recap can arrive a moment after the screen opens. Until then the
-- streak card is a "confirming" placeholder; if it never comes
-- (RECAP_WAIT), the card says so plainly instead of spinning forever.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local ResultsLogic = require(script.Parent.Parent.ResultsLogic)
local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local MenuShell = require(script.Parent.MenuShell)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local cleanup = vide.cleanup
local effect = vide.effect
local indexes = vide.indexes

local Env = C.Env

local CARD_H = 64
local STREAK_H = 112
local SLIDE = 24
local RECAP_WAIT = 6

export type Store = {
	recap: () -> ResultsLogic.Recap?,
	tally: () -> ResultsLogic.RaceTally,
	close: () -> (),
	now: (() -> number)?, -- clock override for a preview; default os.clock
}

type CardStyle = { icon: string, color: string }

local STREAK_STYLE: { [string]: CardStyle } = {
	Up = { icon = "flame", color = "success" },
	Held = { icon = "lock", color = "warning" },
	Died = { icon = "down", color = "danger" },
	None = { icon = "info", color = "inkMuted" },
}

local LABELS: { [string]: string } = {
	Placement = "Placement",
	Tasks = "Tasks completed",
	PowerUps = "Power-ups used",
	Finale = "Decision Studio",
	Rewards = "Bounty",
}

local ICONS: { [string]: string } = {
	Placement = "trophy",
	Tasks = "check",
	PowerUps = "bolt",
	Finale = "star",
	Rewards = "gem",
}

-- Slides up and fades in when `shown` turns true; just appears under
-- reduced motion.
local function reveal(shown: () -> boolean, height: number, order: number, children: { any }): Frame
	local target = derive(function()
		return if shown() then 0 else 1
	end)
	local t = Env.animate(target, Theme.motion.slow)
	return create("Frame")({
		Name = "Beat" .. order,
		LayoutOrder = order,
		Size = UDim2.fromOffset(MenuShell.INNER, height),
		BackgroundTransparency = 1,
		Visible = shown,
		create("CanvasGroup")({
			Name = "Card",
			Size = UDim2.fromScale(1, 1),
			Position = function()
				return UDim2.fromOffset(0, t() * SLIDE)
			end,
			GroupTransparency = t,
			BackgroundColor3 = Theme.color.surface,
			Base.corner(Theme.radius.md),
			create("UIPadding")({
				PaddingLeft = UDim.new(0, Theme.spacing.md),
				PaddingRight = UDim.new(0, Theme.spacing.md),
			}),
			children :: any, -- Vide takes a nested array of children
		}),
	}) :: Frame
end

local function statCard(id: string, value: () -> string, shown: () -> boolean, order: number): Frame
	local icon = C.Icons.view(ICONS[id], 28, Theme.color.inkMuted)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Position = UDim2.fromScale(0, 0.5)
	return reveal(shown, CARD_H, order, {
		icon,
		Base.text("caption", {
			Name = "Label",
			Position = UDim2.fromOffset(40, Theme.spacing.sm),
			Size = UDim2.new(1, -40, 0, Theme.type.caption.size + Theme.spacing.xs),
			Text = LABELS[id],
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Base.text("title", {
			Name = "Value",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 40, 1, -Theme.spacing.sm),
			Size = UDim2.new(1, -40, 0, Theme.type.title.size + Theme.spacing.xs),
			Text = value,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = true,
		}),
	})
end

local function streakCard(store: Store, timedOut: () -> boolean, shown: () -> boolean, order: number): Frame
	local change = derive(function(): ResultsLogic.StreakChange?
		local recap = store.recap()
		return if recap then ResultsLogic.streakChange(recap) else nil
	end)
	local style = derive(function(): CardStyle
		local c = change()
		return STREAK_STYLE[if c then c.kind else "None"]
	end)
	local headline = derive(function(): string
		local c = change()
		if c then
			return ResultsLogic.streakHeadline(c)
		end
		return if timedOut() then "Couldn't load your streak" else "Confirming your streak"
	end)
	local note = derive(function(): string
		local c = change()
		if c then
			if c.note then
				return c.note
			end
			return if c.newBest
				then "Your best ever."
				elseif c.kind == "Died" then "Back to zero. Next round starts a new one."
				else ""
		end
		return if timedOut() then "It's saved on the server. It'll show next time you open your profile." else ""
	end)

	-- The icon changes with the kind as well as the colour, so the card
	-- reads the same in greyscale: one of each, only the current shown.
	local icons = {}
	for kind, s in STREAK_STYLE do
		local icon = C.Icons.view(s.icon, 36, Theme.color[s.color])
		icon.Position = UDim2.fromOffset(0, Theme.spacing.md)
		icon.Visible = false
		effect(function()
			local c = change()
			icon.Visible = (if c then c.kind else "None") == kind
		end)
		table.insert(icons, icon)
	end

	return reveal(shown, STREAK_H, order, {
		create("Frame")({
			Name = "Accent",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -Theme.spacing.md, 0.5, 0),
			Size = UDim2.new(0, 6, 1, 0),
			BackgroundColor3 = function()
				return Theme.color[style().color]
			end,
			BorderSizePixel = 0,
		}),
		icons,
		Base.text("headline", {
			Name = "Headline",
			Position = UDim2.fromOffset(48, Theme.spacing.sm),
			Size = UDim2.new(1, -48, 0, Theme.type.headline.size + Theme.spacing.xs),
			Text = headline,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Base.text("body", {
			Name = "Note",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, 0, 1, -Theme.spacing.sm),
			Size = UDim2.new(1, 0, 0, 2 * Theme.type.body.size + Theme.spacing.xs),
			Text = note,
			TextColor3 = Theme.color.inkMuted,
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
	})
end

local function body(store: Store, height: () -> number): { Instance }
	local clock = store.now or os.clock
	local openedAt = clock()
	local elapsed = source(0)
	local skipped = source(false)
	local hb = RunService.Heartbeat:Connect(function()
		-- Quarter-second steps: beats are 0.6s apart, and Vide only
		-- propagates a value that changed, so this re-runs the reveal
		-- derive four times a second rather than every frame.
		elapsed(math.floor((clock() - openedAt) * 4) / 4)
	end)
	cleanup(function()
		hb:Disconnect()
	end)

	local timedOut = derive(function()
		return elapsed() >= RECAP_WAIT
	end)

	-- Without a recap yet, a racer's streak beat is still scheduled - as
	-- a placeholder - so the sequence doesn't reshuffle when it arrives,
	-- and says so if it never does. A spectator has no streak beat.
	local beats = derive(function(): { ResultsLogic.Beat }
		local recap = store.recap()
		local list = ResultsLogic.beats(recap)
		if recap == nil and store.tally().placement ~= nil then
			table.insert(
				list,
				{ id = "Streak", at = list[#list].at + ResultsLogic.BEAT_GAP + ResultsLogic.STREAK_PAUSE }
			)
		end
		return list
	end)
	local shownCount = derive(function()
		return ResultsLogic.revealedCount(beats(), elapsed(), skipped())
	end)
	local function isShown(id: ResultsLogic.BeatId): () -> boolean
		return function()
			local list = beats()
			for i = 1, math.min(shownCount(), #list) do
				if list[i].id == id then
					return true
				end
			end
			return false
		end
	end
	local streakDue = derive(function()
		local list = beats()
		for _, beat in list do
			if beat.id == "Streak" then
				return true
			end
		end
		return false
	end)

	local tally = store.tally
	local finale = derive(function(): string
		local recap = store.recap()
		return (if recap then ResultsLogic.finaleLine(recap.reason) else nil) or ""
	end)
	local reward = derive(function(): string
		local recap = store.recap()
		local bounty = recap and recap.bounty
		return if bounty then string.format("Tier %d, carried into your next finale", bounty.streakTier) else ""
	end)

	local cards = create("ScrollingFrame")({
		Name = "Recap",
		Size = function()
			return UDim2.fromOffset(MenuShell.INNER, height())
		end,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		statCard("Placement", function()
			local t = tally()
			return ResultsLogic.placementText(t.placement, t.fieldSize)
		end, isShown("Placement"), 1),
		statCard("Tasks", function()
			return tostring(tally().tasksCompleted)
		end, isShown("Tasks"), 2),
		statCard("PowerUps", function()
			return tostring(tally().powerUpsUsed)
		end, isShown("PowerUps"), 3),
		statCard("Finale", finale, isShown("Finale"), 4),
		statCard("Rewards", reward, isShown("Rewards"), 5),
		indexes(
			derive(function()
				return if streakDue() then { true } else {}
			end),
			function()
				return streakCard(store, timedOut, isShown("Streak"), 6)
			end
		) :: any,
	}) :: ScrollingFrame

	-- Touching the recap at all - a tap, or starting a scroll - shows it
	-- all now. On the list's own InputBegan, because a ScrollingFrame
	-- sinks input and a button under it would never hear the tap.
	cards.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			skipped(true)
		end
	end)

	return { cards }
end

local Results = {}

function Results.mount(controller: any, store: Store): () -> ()
	return MenuShell.mount(controller, {
		name = "ResultsScreen",
		title = "Round over",
		closeLabel = "Continue",
		onClose = store.close,
		body = function(height)
			return body(store, height)
		end,
	})
end

return Results
