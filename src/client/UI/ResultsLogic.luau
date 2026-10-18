--!strict
-- The pure half of the results screen (P6-6): what the round did to
-- this player, and the order the recap reveals it in - with the streak
-- change landing last. No Roblox API, no requires; tested under Lune
-- (tests/MenuScreens.spec).
--
-- Two sources, and they're trusted differently:
--   * RoundRecap (server, targeted, on entering Results): reason,
--     streak before/after, win reward, streak credit, finale guess and
--     streak shields. Authoritative.
--   * RaceTally (counted by the client from broadcasts it already got:
--     TaskProgress, TaskQualificationResult, its own PowerUpUseResult).
--     Display-only - a modified client lying to itself about how many
--     power-ups it used changes nothing anywhere else.

local ResultsLogic = {}

-- The server's win reward (ProgressionService's RoundRecap), already
-- granted by the time this arrives. The same shape as
-- PayoutLogic.Payout, which words it.
export type RecapReward = {
	currency: number,
	rung: number,
	drop: { kind: string, id: string, rarity: string, duplicate: boolean }?,
	dropAmount: number?,
}

-- One end of the XP bar: LevelLogic.Progress, worked out by the server.
export type LevelProgress = {
	level: number,
	xpIntoLevel: number,
	xpForNext: number, -- 0 at the max level
}

-- What the round paid toward the account level (payoff-loop step 1c;
-- ProgressionService's levelPayload). Already granted on arrival.
export type RecapLevel = {
	xpGained: number,
	before: LevelProgress,
	after: LevelProgress,
	placeCurrency: number,
	levelUpCurrency: number,
	cosmetics: { string }, -- level cosmetics unlocked this round
}

-- This player's finale guess (payoff-loop step 2c; GuessService's
-- recapFor). `correct` is only ever true when one finalist walked out
-- alone; `shieldEarned` is false in a practice match, which judges the
-- guess but grants nothing.
export type RecapGuess = {
	targetId: number,
	correct: boolean,
	shieldEarned: boolean,
}

-- The daily challenges this round finished (payoff-loop step 8c;
-- ProgressionService's challengesPayload). Already granted on arrival;
-- the XP is inside the level beat's xpGained too.
export type RecapChallenges = {
	completed: { string }, -- labels, slot order; never empty
	coins: number,
	xp: number,
	allDone: boolean, -- finished the whole list (bonus included above)
}

export type Recap = {
	roundId: string,
	reason: string, -- ProgressionLogic.ReasonCode
	streakBefore: number,
	streakAfter: number,
	bestStreakBefore: number,
	bestStreakAfter: number,
	reward: RecapReward?, -- what this win paid; nil on a loss
	-- A practice match on a private server (design-decisions.md Q7):
	-- nothing was at stake, so the streak never moved.
	practice: boolean?,
	-- XP, level and place coins. Every round has one (Q1, "a payoff
	-- for every round") except a practice match or a failed write.
	level: RecapLevel?,
	-- Payoff-loop step 2: a streak shield took this round's loss, so the
	-- streak stayed where it was.
	shieldSpent: boolean?,
	guess: RecapGuess?, -- nil when they placed no guess
	streakShields: number?, -- shields held now, after this round
	challenges: RecapChallenges?, -- nil when the round finished none
}

export type RaceTally = {
	placement: number?, -- nil if they never appeared in a standings broadcast
	fieldSize: number,
	tasksCompleted: number,
	powerUpsUsed: number,
}

local WIN_REASONS: { [string]: boolean } = {
	QualifiedWin = true,
	StudioWinSoleStealer = true,
	StudioWinLoneSharer = true,
	StudioWinAllShare = true,
}

function ResultsLogic.isWin(reason: string): boolean
	return WIN_REASONS[reason] == true
end

-- ===== the finale line ======================================================

-- nil when the player never reached the Studio - the screen then leaves
-- the finale beat out entirely rather than showing "didn't qualify"
-- twice (placement already says it).
function ResultsLogic.finaleLine(reason: string): string?
	if reason == "StudioWinSoleStealer" then
		return "You stole it - and got away with it."
	elseif reason == "StudioWinLoneSharer" then
		return "You shared, and it paid off."
	elseif reason == "StudioWinAllShare" then
		return "Everyone shared. Everyone won."
	elseif reason == "QualifiedWin" then
		return "Last finalist standing - the win is yours."
	elseif reason == "StudioLoss" then
		return "The Studio didn't go your way."
	elseif reason == "ForfeitDisconnect" then
		return "You left the Studio, which counts as a loss."
	end
	return nil
end

-- ===== the streak change ===================================================

export type StreakKind =
	"Up" -- a win: every win adds to the streak (design-decisions.md Q5)
	| "Died" -- a loss that ended a streak worth naming
	| "None" -- a loss from zero: nothing was lost
	| "Practice" -- a practice match: nothing was at stake, win or lose
	| "Shielded" -- a loss a streak shield took, so the streak stayed

export type StreakChange = {
	kind: StreakKind,
	before: number,
	after: number,
	newBest: boolean,
}

function ResultsLogic.streakChange(recap: Recap): StreakChange
	local kind: StreakKind
	if recap.practice == true then
		kind = "Practice"
	elseif recap.shieldSpent == true then
		kind = "Shielded"
	elseif recap.streakAfter > recap.streakBefore then
		kind = "Up"
	elseif recap.streakBefore > 0 then
		kind = "Died"
	else
		kind = "None"
	end
	return {
		kind = kind,
		before = recap.streakBefore,
		after = recap.streakAfter,
		newBest = recap.bestStreakAfter > recap.bestStreakBefore,
	}
end

-- The one-line headline for the streak beat. A dead streak is named as
-- a number, plainly - P6-5's rule for the Studio result applies here
-- too: without cruelty, but without softening.
function ResultsLogic.streakHeadline(change: StreakChange): string
	if change.kind == "Up" then
		return if change.newBest
			then string.format("Streak %d - a new best", change.after)
			else string.format("Streak %d", change.after)
	elseif change.kind == "Died" then
		return string.format("Your %d-win streak ends here", change.before)
	elseif change.kind == "Practice" then
		return if change.before > 0
			then string.format("Practice match - your %d-win streak is safe", change.before)
			else "Practice match - nothing at stake"
	elseif change.kind == "Shielded" then
		return string.format("Your %d-win streak is safe", change.after)
	end
	return "No streak on the line this time"
end

-- ===== sequencing ===========================================================

export type BeatId =
	"Placement"
	| "Tasks"
	| "PowerUps"
	| "Finale"
	| "Rewards"
	| "Drop"
	| "Guess"
	| "Level"
	| "Challenges"
	| "Streak"

export type Beat = { id: BeatId, at: number }

-- Seconds between beats, and the extra held breath before the streak.
-- The pause is the point: the streak is the thing the whole metagame is
-- about, so it gets a beat of silence to itself.
ResultsLogic.BEAT_GAP = 0.6
ResultsLogic.STREAK_PAUSE = 0.9

-- The recap's beats in order, each with its start time from when the
-- screen opens. The streak is always last - P6-6's one sequencing rule.
-- Finale appears only for someone who reached the Studio, Rewards only
-- for a win that paid something, Drop only when that win also dropped
-- an item (its own card, for its icon), Guess when they placed a finale
-- guess (payoff-loop step 2c), Level when the round paid XP
-- (payoff-loop step 1c), Streak only when there is a
-- recap at all (a spectator has no streak change this round).
--
-- Reduced motion keeps the SAME order and timing. Reduced motion is
-- about movement (the screen swaps slides for plain appearance), not
-- pacing, and collapsing the sequence would take away the one moment of
-- suspense the screen has for the players who most need it calm.
function ResultsLogic.beats(recap: Recap?): { Beat }
	local ids: { BeatId } = { "Placement", "Tasks", "PowerUps" }
	if recap ~= nil then
		if ResultsLogic.finaleLine(recap.reason) ~= nil then
			table.insert(ids, "Finale")
		end
		local reward = recap.reward
		if reward ~= nil and ResultsLogic.isWin(recap.reason) then
			table.insert(ids, "Rewards")
			if reward.drop ~= nil then
				table.insert(ids, "Drop")
			end
		end
		if recap.guess ~= nil then
			table.insert(ids, "Guess")
		end
		if recap.level ~= nil then
			table.insert(ids, "Level")
		end
		if recap.challenges ~= nil then
			table.insert(ids, "Challenges")
		end
		table.insert(ids, "Streak")
	end

	local out: { Beat } = {}
	local t = 0
	for i, id in ids do
		if id == "Streak" then
			t += ResultsLogic.STREAK_PAUSE
		end
		table.insert(out, { id = id :: BeatId, at = t })
		if i < #ids then
			t += ResultsLogic.BEAT_GAP
		end
	end
	return out
end

-- How many beats are showing at `elapsed` seconds in. `skipped` (a tap
-- on the recap) shows everything at once - the pacing is for the first
-- watch, not a wait a player has to sit through every round.
function ResultsLogic.revealedCount(beats: { Beat }, elapsed: number, skipped: boolean): number
	if skipped then
		return #beats
	end
	local n = 0
	for _, beat in beats do
		if beat.at <= elapsed then
			n += 1
		end
	end
	return n
end

-- ===== the level beat (payoff-loop step 1c) ================================

-- How full the XP bar is, 0..1. The max level shows a full bar.
function ResultsLogic.levelFraction(progress: LevelProgress): number
	if progress.xpForNext <= 0 then
		return 1
	end
	return math.clamp(progress.xpIntoLevel / progress.xpForNext, 0, 1)
end

-- The bar's right-hand label: "120/400 XP", or "MAX" at the cap.
function ResultsLogic.levelXpText(progress: LevelProgress): string
	if progress.xpForNext <= 0 then
		return "MAX"
	end
	return string.format("%d/%d XP", progress.xpIntoLevel, progress.xpForNext)
end

function ResultsLogic.levelsGained(level: RecapLevel): number
	return math.max(0, level.after.level - level.before.level)
end

function ResultsLogic.levelHeadline(level: RecapLevel): string
	if ResultsLogic.levelsGained(level) > 0 then
		return string.format("Level up! Level %d", level.after.level)
	end
	return string.format("Level %d", level.after.level)
end

-- "+85 XP  +35 coins". Place and level-up coins are one grant, so
-- they're one number here.
function ResultsLogic.levelGains(level: RecapLevel): string
	local coins = level.placeCurrency + level.levelUpCurrency
	if coins > 0 then
		return string.format("+%d XP  +%d coins", level.xpGained, coins)
	end
	return string.format("+%d XP", level.xpGained)
end

-- Where the bar starts filling from: this round's start in the same
-- level, or empty if the round crossed into a new one.
function ResultsLogic.levelStartFraction(level: RecapLevel): number
	if ResultsLogic.levelsGained(level) > 0 then
		return 0
	end
	return ResultsLogic.levelFraction(level.before)
end

-- A recap's level, checked for shape: the remote is trusted, but a
-- malformed one should drop the beat, not error the screen.
local function isProgress(value: any): boolean
	return type(value) == "table"
		and type(value.level) == "number"
		and type(value.xpIntoLevel) == "number"
		and type(value.xpForNext) == "number"
end

function ResultsLogic.parseLevel(value: any): RecapLevel?
	if
		type(value) ~= "table"
		or type(value.xpGained) ~= "number"
		or not isProgress(value.before)
		or not isProgress(value.after)
		or type(value.placeCurrency) ~= "number"
		or type(value.levelUpCurrency) ~= "number"
	then
		return nil
	end
	local cosmetics: { string } = {}
	if type(value.cosmetics) == "table" then
		for _, id in value.cosmetics do
			if type(id) == "string" then
				table.insert(cosmetics, id)
			end
		end
	end
	return {
		xpGained = value.xpGained,
		before = value.before,
		after = value.after,
		placeCurrency = value.placeCurrency,
		levelUpCurrency = value.levelUpCurrency,
		cosmetics = cosmetics,
	}
end

-- ===== the guess beat and shields (payoff-loop step 2c) =====================

-- The guess card's headline. Only a guess that earned a shield promises
-- one: a practice match judges it but pays nothing.
function ResultsLogic.guessHeadline(guess: RecapGuess, practice: boolean?): string
	if not guess.correct then
		return "No shield this time"
	elseif guess.shieldEarned then
		return "You called it: +1 shield"
	elseif practice == true then
		return "You called it (practice: no shield)"
	end
	return "You called it"
end

-- The guess card's label: who they picked.
function ResultsLogic.guessLabel(guess: RecapGuess, nameOf: ((id: number) -> string?)?): string
	local name = if nameOf then nameOf(guess.targetId) else nil
	return if name then string.format("Your guess: %s", name) else "Your guess"
end

-- "2 streak shields held", for the player's own screens only (Q7
-- condition 1). nil when they hold none.
function ResultsLogic.shieldsLine(count: number?): string?
	if count == nil or count <= 0 then
		return nil
	end
	return if count == 1 then "1 streak shield held" else string.format("%d streak shields held", count)
end

-- A recap's guess, checked for shape, like parseLevel.
function ResultsLogic.parseGuess(value: any): RecapGuess?
	if
		type(value) ~= "table"
		or type(value.targetId) ~= "number"
		or type(value.correct) ~= "boolean"
		or type(value.shieldEarned) ~= "boolean"
	then
		return nil
	end
	return { targetId = value.targetId, correct = value.correct, shieldEarned = value.shieldEarned }
end

-- A recap's challenges, checked for shape, like parseLevel. nil when
-- none finished, so the beat is skipped.
function ResultsLogic.parseChallenges(value: any): RecapChallenges?
	if
		type(value) ~= "table"
		or type(value.completed) ~= "table"
		or type(value.coins) ~= "number"
		or type(value.xp) ~= "number"
		or type(value.allDone) ~= "boolean"
	then
		return nil
	end
	local completed: { string } = {}
	for _, label in value.completed do
		if type(label) == "string" then
			table.insert(completed, label)
		end
	end
	if #completed == 0 then
		return nil
	end
	return { completed = completed, coins = value.coins, xp = value.xp, allDone = value.allDone }
end

-- The challenge beat's caption: the one it finished by name, or a count.
function ResultsLogic.challengesLabel(c: RecapChallenges): string
	if c.allDone then
		return "All daily challenges done!"
	elseif #c.completed == 1 then
		return "Challenge done: " .. c.completed[1]
	end
	return string.format("%d daily challenges done", #c.completed)
end

-- The challenge beat's value: what they paid.
function ResultsLogic.challengesGains(c: RecapChallenges): string
	local parts = {}
	if c.coins > 0 then
		table.insert(parts, string.format("+%d coins", c.coins))
	end
	if c.xp > 0 then
		table.insert(parts, string.format("+%d XP", c.xp))
	end
	return if #parts > 0 then table.concat(parts, "  ") else "Done"
end

-- A shield count, or nil when it isn't a sane one.
function ResultsLogic.parseShields(value: any): number?
	if type(value) ~= "number" or value ~= value or value < 0 then
		return nil
	end
	return math.floor(value)
end

-- "3rd of 6", with the ordinal done properly (11th/12th/13th).
function ResultsLogic.placementText(placement: number?, fieldSize: number): string
	if placement == nil then
		return "Unplaced"
	end
	local suffix = "th"
	local mod100 = placement % 100
	if mod100 < 11 or mod100 > 13 then
		local mod10 = placement % 10
		suffix = if mod10 == 1 then "st" elseif mod10 == 2 then "nd" elseif mod10 == 3 then "rd" else "th"
	end
	return string.format("%d%s of %d", placement, suffix, fieldSize)
end

return ResultsLogic
