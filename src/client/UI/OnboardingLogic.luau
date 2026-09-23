--!strict
-- First-round tips (P6-8, docs/onboarding.md): the copy and the queue
-- that decides which one shows. No Roblox API, so tests/Onboarding.spec
-- runs it headlessly; OnboardingController feeds it round events and
-- draws whatever it says is showing.
--
-- THE SHAPE: no tutorial level and no wall of text. A new player is
-- dropped straight into a real round, and a tip appears the first time
-- something happens to them: the race starts, they pick up a power-up,
-- they get hit, they make (or miss) the finale. So each tip explains
-- the thing already on their screen. By the Choose phase they've seen
-- the whole loop: race, grief, top 3, Steal or Share. That's four tips,
-- inside the first 60 seconds of play that matter.
--
-- RULES: one tip at a time, each at most once, and a tip only while
-- its own part of the round is live. A power-up tip that's still
-- queued when the race ends is dropped, never shown in the Studio.

local OnboardingLogic = {}

export type Stage = "Race" | "Studio" | "Results"
export type TipId = "race" | "powerUp" | "hit" | "line" | "finale" | "missed" | "negotiate" | "choose" | "streak"

export type Tip = {
	id: TipId,
	stage: Stage,
	title: string,
	body: string,
	-- An extra button on the tip. "explainer" opens How it works.
	action: "explainer"?,
}

-- The copy. A Roblox player's register: short, second person, a bit of
-- attitude, never "Great job!". Titles under 30 characters and bodies
-- under 90, so a tip is two short lines on a phone
-- (tests/Onboarding.spec checks both limits).
local TIPS: { Tip } = {
	{
		id = "race",
		stage = "Race",
		title = "Race to finish your tasks",
		body = "Follow the arrow to each station. Top 3 make the finale.",
	},
	{
		id = "powerUp",
		stage = "Race",
		title = "You got a power-up",
		body = "Hit the power-up button to mess with a rival. Or save it.",
	},
	{
		id = "hit",
		stage = "Race",
		title = "Someone got you",
		body = "It wears off soon. Your turn next time you grab a power-up.",
	},
	{
		id = "line",
		stage = "Race",
		title = "Only the top 3 go through",
		body = "Your place and the gap to 3rd are at the top. Keep moving.",
	},
	{
		id = "finale",
		stage = "Studio",
		title = "You made the finale",
		body = "You and 2 others each pick Steal or Share. In secret.",
	},
	{
		id = "missed",
		stage = "Studio",
		title = "Not this time",
		body = "Only the top 3 play the finale. Watch how it goes down.",
	},
	{
		id = "negotiate",
		stage = "Studio",
		title = "Talk it out",
		body = "Make deals, make promises. Nobody has to keep them.",
		action = "explainer",
	},
	{
		id = "choose",
		stage = "Studio",
		title = "Pick in secret",
		body = "Hold Steal or Share. Nobody sees it until everyone's in.",
		action = "explainer",
	},
	{
		id = "streak",
		stage = "Results",
		title = "That's your streak",
		body = "Win and it goes up. Lose once and it's back to 0.",
	},
}

local BY_ID: { [string]: Tip } = {}
for _, tip in TIPS do
	BY_ID[tip.id] = table.freeze(tip)
end
OnboardingLogic.TIPS = table.freeze(TIPS)

function OnboardingLogic.tip(id: string): Tip
	return BY_ID[id]
end

-- How long a tip stays up before it leaves on its own: about 3 words a
-- second (a slow young reader) plus 2 seconds to notice it, and never
-- under 4 or over 9, so a tip doesn't outstay the moment it's about.
function OnboardingLogic.readSeconds(tip: Tip): number
	local words = 0
	for _ in string.gmatch(tip.title .. " " .. tip.body, "%S+") do
		words += 1
	end
	return math.clamp(words / 3 + 2, 4, 9)
end

export type State = {
	stage: string?, -- a Stage; plain string because literals widen once stored
	seen: { [string]: boolean },
	queue: { string },
	showing: string?, -- a TipId
}

function OnboardingLogic.new(): State
	return { stage = nil, seen = {}, queue = {}, showing = nil }
end

local function advance(state: State)
	if state.showing ~= nil then
		return
	end
	while #state.queue > 0 do
		local id = table.remove(state.queue, 1) :: string
		if BY_ID[id].stage == state.stage then
			state.showing = id
			return
		end
	end
end

-- The round moved on. Anything queued or showing for an earlier stage
-- is dropped: that moment has passed. The one showing isn't marked seen,
-- but the moment it was about won't come round again this round anyway.
function OnboardingLogic.enterStage(state: State, stage: string?)
	state.stage = stage
	if state.showing ~= nil and BY_ID[state.showing].stage ~= stage then
		state.showing = nil
	end
	local kept: { string } = {}
	for _, id in state.queue do
		if BY_ID[id].stage == stage then
			table.insert(kept, id)
		end
	end
	state.queue = kept
	advance(state)
end

-- Something happened that a tip explains. Ignored if the tip was seen,
-- is already queued or showing, or belongs to another stage.
function OnboardingLogic.trigger(state: State, id: TipId)
	local tip = BY_ID[id]
	if tip == nil or tip.stage ~= state.stage or state.seen[id] or state.showing == id then
		return
	end
	if table.find(state.queue, id) ~= nil then
		return
	end
	table.insert(state.queue, id)
	advance(state)
end

-- The showing tip was closed or timed out. Only this marks it seen.
function OnboardingLogic.dismiss(state: State)
	if state.showing ~= nil then
		state.seen[state.showing] = true
		state.showing = nil
	end
	advance(state)
end

-- True once the player has been taught the whole loop: the race, then
-- either the Studio or seeing they missed it. That's when the tips turn
-- themselves off. A player who joined mid-round and skipped the race
-- tip keeps them for their next full round.
function OnboardingLogic.loopTaught(state: State): boolean
	return state.seen.race == true and (state.seen.choose == true or state.seen.missed == true)
end

return OnboardingLogic
