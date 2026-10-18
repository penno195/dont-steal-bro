--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The level-up pop-up (owner, 2026-10-18): the claim pop-up with an XP
-- bar on top that fills, tick by tick, from where the player stood to
-- where they are now. Each full bar is a level-up beat: the level number
-- pops, the LevelUp sting plays and the bar empties. The reward cards
-- (level-up coins, any level cosmetic) bounce in once the bar is done.
-- The tutorial reward ends on it, to show a new player the XP system;
-- a round that levels up shows it too.
--
-- LevelUpLogic works out the segments and timings; this only plays
-- them. Sounds go out through `cue`, since UI modules don't reach
-- controllers. Under reduced motion the bar jumps to its end and the
-- sting plays once.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local ClaimPopup = require(script.Parent.ClaimPopup)
local LevelUpLogic = require(script.Parent.Parent.LevelUpLogic)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

-- Structurally ResultsLogic.RecapLevel's bar ends and XP.
export type Level = {
	xpGained: number,
	before: LevelUpLogic.Progress,
	after: LevelUpLogic.Progress,
}

local LEVEL_ROW = Theme.type.headline.size + Theme.spacing.xs
local TRACK = 20
local RIM = 3
local CAPTION_ROW = Theme.type.label.size + Theme.spacing.xxs
local GAP = Theme.spacing.sm
local HEIGHT = LEVEL_ROW + GAP + TRACK + 2 * RIM + GAP + CAPTION_ROW
-- The modal's own grow-in, before the bar starts to move.
local START_DELAY = 0.4
local POP_SCALE = 1.4 -- the level number's size at the top of its pop

local LevelUpPopup = {}

local function levelText(level: number): string
	return string.format("LEVEL %d", level)
end

-- "x/y XP" for a level whose cost is known (the two ends); "" between.
local function countText(level: Level, shownLevel: number, fraction: number): string
	local ends = if shownLevel == level.after.level
		then level.after
		elseif shownLevel == level.before.level then level.before
		else nil
	if ends == nil or ends.xpForNext <= 0 then
		return ""
	end
	return string.format("%d/%d XP", math.floor(fraction * ends.xpForNext + 0.5), ends.xpForNext)
end

-- The bar and its labels, already playing (from START_DELAY on).
local function header(level: Level, cue: (string) -> ()): GuiObject
	local segments = LevelUpLogic.segments(level.before, level.after)
	local first = segments[1]
	local fillSeconds = LevelUpLogic.fillSeconds(segments)

	local pop = create("UIScale")({ Scale = 1 })
	local levelLabel = Base.text("headline", {
		Name = "Level",
		Size = UDim2.new(1, 0, 0, LEVEL_ROW),
		Text = levelText(first.level),
		TextColor3 = Theme.fill.primary.top,
		pop,
	})
	local fill = create("Frame")({
		Name = "Fill",
		BackgroundColor3 = Color3.new(1, 1, 1),
		Size = UDim2.fromScale(first.from, 1),
		Base.corner(Theme.radius.pill),
		create("UIGradient")({ Color = ColorSequence.new(Theme.fill.primary.top, Theme.color.brand) }),
		create("Frame")({
			Name = "Gloss",
			Position = UDim2.fromOffset(Theme.spacing.xs, Theme.spacing.xxs),
			Size = UDim2.new(1, -Theme.spacing.sm, 0.35, 0),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BackgroundTransparency = 0.55,
			Base.corner(Theme.radius.pill),
		}),
	})
	local gained = Base.text("label", {
		Name = "Gained",
		Size = UDim2.new(0.5, 0, 0, CAPTION_ROW),
		Text = "+0 XP",
		TextColor3 = Theme.color.success,
		TextXAlignment = Enum.TextXAlignment.Left,
	})
	local count = Base.text("label", {
		Name = "Count",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 0, CAPTION_ROW),
		Text = countText(level, first.level, first.from),
		TextColor3 = Theme.color.inkMuted,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local root = create("Frame")({
		Name = "XpBar",
		Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, HEIGHT),
		BackgroundTransparency = 1,
		levelLabel,
		create("Frame")({
			Name = "Track",
			Position = UDim2.fromOffset(RIM, LEVEL_ROW + GAP + RIM),
			Size = UDim2.new(1, -2 * RIM, 0, TRACK),
			BackgroundColor3 = Theme.color.background,
			ClipsDescendants = true,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Theme.color.rim,
				Thickness = RIM,
			}),
			fill,
		}),
		create("Frame")({
			Name = "Captions",
			Position = UDim2.fromOffset(0, LEVEL_ROW + GAP + TRACK + 2 * RIM + GAP),
			Size = UDim2.new(1, 0, 0, CAPTION_ROW),
			BackgroundTransparency = 1,
			gained,
			count,
		}),
	})

	local function alive(): boolean
		return root:IsDescendantOf(game)
	end

	local function levelUp(nextLevel: number)
		cue("LevelUp")
		levelLabel.Text = levelText(nextLevel)
		pop.Scale = POP_SCALE
		TweenService:Create(
			pop,
			TweenInfo.new(C.Env.duration(0.45), Enum.EasingStyle.Back, Enum.EasingDirection.Out),
			{ Scale = 1 }
		):Play()
	end

	task.spawn(function()
		task.wait(C.Env.duration(START_DELAY))
		local last = segments[#segments]
		-- Reduced motion: straight to the end, one sting if it levelled.
		if C.Env.duration(1) == 0 then
			if not alive() then
				return
			end
			fill.Size = UDim2.fromScale(last.to, 1)
			gained.Text = string.format("+%d XP", level.xpGained)
			count.Text = countText(level, last.level, last.to)
			if last.level ~= first.level then
				levelUp(last.level)
			end
			return
		end
		local filled = 0 -- fill seconds already played, for the XP counter
		for index, part in segments do
			if not alive() then
				return
			end
			fill.Size = UDim2.fromScale(part.from, 1)
			levelLabel.Text = levelText(part.level)
			if part.seconds > 0 then
				TweenService:Create(
					fill,
					TweenInfo.new(part.seconds, Enum.EasingStyle.Linear),
					{ Size = UDim2.fromScale(part.to, 1) }
				):Play()
				local started = os.clock()
				while os.clock() - started < part.seconds do
					if not alive() then
						return
					end
					local elapsed = os.clock() - started
					gained.Text =
						string.format("+%d XP", LevelUpLogic.xpShown(level.xpGained, filled + elapsed, fillSeconds))
					count.Text = countText(level, part.level, fill.Size.X.Scale)
					cue("XpFill")
					task.wait(LevelUpLogic.TICK_SECONDS)
				end
				filled += part.seconds
				fill.Size = UDim2.fromScale(part.to, 1)
			end
			gained.Text = string.format("+%d XP", LevelUpLogic.xpShown(level.xpGained, filled, fillSeconds))
			count.Text = countText(level, part.level, part.to)
			local following = segments[index + 1]
			if part.levelsUp and following ~= nil then
				levelUp(following.level)
				count.Text = countText(level, following.level, following.from)
				task.wait(LevelUpLogic.LEVEL_BEAT_SECONDS)
			end
		end
	end)

	return root
end

-- How long after it appears the bar is done, for the cards' entrance.
local function popDelay(level: Level): number
	return C.Env.duration(START_DELAY + LevelUpLogic.totalSeconds(LevelUpLogic.segments(level.before, level.after)))
end

-- Opens it now; returns `close`. `rewards` are the level-up's cards
-- (may be empty: the bar alone still says it). `cue` plays a sound.
function LevelUpPopup.show(
	level: Level,
	rewards: { ClaimPopup.Reward },
	title: string,
	body: string?,
	cue: (string) -> ()
): () -> ()
	return ClaimPopup.show(rewards, title, body, {
		header = function()
			return header(level, cue)
		end,
		popDelay = popDelay(level),
	})
end

-- Queues it behind any other pop-up (PopupQueue), like ClaimPopup.open.
function LevelUpPopup.open(
	level: Level,
	rewards: { ClaimPopup.Reward },
	title: string,
	body: string?,
	cue: (string) -> ()
): () -> ()
	return ClaimPopup.open(rewards, title, body, {
		header = function()
			return header(level, cue)
		end,
		popDelay = popDelay(level),
	})
end

return LevelUpPopup
