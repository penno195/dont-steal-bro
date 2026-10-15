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
		body = "It's in your slots, bottom right. Use it on a rival, or save it.",
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

-- THE HUB STEPS (tutorial v2, docs/onboarding.md "Tutorial v2"). On a
-- player's first visit to the Hub, in order: the welcome card, the
-- practice area (a power-up to grab and fire, then the task station),
-- then (seam 3) the inventory, ending on "press Play" with only Play
-- lit. The welcome and Play copy is the owner's (2026-10-15,
-- design-decisions.md "the tutorial, second version"); the practice
-- area's is Claude's draft.
--
--   kind "card"       a pop-up on a dimmed screen. `skip` adds the Skip
--                     that ends the whole tutorial (the welcome only).
--                     With `waitFor`, the step then stays up in the
--                     corner card until the player has done it.
--   kind "spotlight"  the screen dims except `target`, ringed, with the
--                     title and body in a caption card beside it. The
--                     step ends when the player uses the target.
--
-- `picture` is a Studio screenshot (0 = none yet).
export type HubStepId = "welcome" | "rivals" | "aim" | "station" | "task" | "play"
export type HubTarget = "play"
-- What a card waits for (hubWaitDone): holding an Aimed item (the
-- personal pickup), a power-up used, standing at the practice station,
-- and its task solved.
export type HubWait = "pickup" | "use" | "station" | "solve"
export type HubStep = {
	id: HubStepId,
	kind: "card" | "spotlight",
	title: string,
	body: string,
	picture: number,
	skip: boolean?,
	target: HubTarget?,
	waitFor: HubWait?,
}

local HUB_STEPS: { HubStep } = {
	{
		id = "welcome",
		kind = "card",
		title = "Welcome to Don't Steal Bro!",
		body = "Where your fate is decided by your own conscience!",
		picture = 130263615284046,
		skip = true,
	},
	{
		id = "rivals",
		kind = "card",
		title = "Mess with rivals",
		body = "Grab the glowing power-up in the practice area. Only you can see it.",
		picture = 0,
		waitFor = "pickup",
	},
	{
		id = "aim",
		kind = "card",
		title = "Aim and fire",
		body = "Drag from its slot (or hold click) to aim at a dummy. Let go to fire!",
		picture = 0,
		waitFor = "use",
	},
	{
		id = "station",
		kind = "card",
		title = "Task station",
		body = "Matches are a race through tasks. Head to the station under the beam of light.",
		picture = 0,
		waitFor = "station",
	},
	{
		id = "task",
		kind = "card",
		title = "Do the task",
		body = "Open the station and complete the task.",
		picture = 0,
		waitFor = "solve",
	},
	{
		id = "play",
		kind = "spotlight",
		title = "Into a match!",
		body = "Let's get straight into a match, press Play.",
		picture = 0,
		target = "play",
	},
}
for _, step in HUB_STEPS do
	table.freeze(step)
end
OnboardingLogic.HUB_STEPS = table.freeze(HUB_STEPS)

OnboardingLogic.HUB_BUTTONS = table.freeze({
	next = "Next",
	skip = "Skip",
})

-- Has the player done what a card waits for? `facts` is what the Hub
-- has seen since that step began (HubIntroController keeps it), except
-- holdsAimed and atStation, which are how things stand right now.
export type HubFacts = {
	holdsAimed: boolean,
	used: boolean,
	atStation: boolean,
	solved: boolean,
}

function OnboardingLogic.hubWaitDone(wait: HubWait?, facts: HubFacts): boolean
	if wait == "pickup" then
		return facts.holdsAimed
	elseif wait == "use" then
		return facts.used
	elseif wait == "station" then
		return facts.atStation or facts.solved
	elseif wait == "solve" then
		return facts.solved
	end
	return true
end

-- Whether the intro should open now. Only in the Hub, only between
-- rounds (nil or WaitingForPlayers), never over the loading screen,
-- an open menu or a queue the player is already in, and only once the
-- saved settings say they haven't seen it.
export type IntroContext = {
	isHub: boolean,
	settingsLoaded: boolean,
	introSeen: boolean,
	roundState: string?,
	loading: boolean,
	menuOpen: boolean,
	queued: boolean,
}

function OnboardingLogic.introDue(c: IntroContext): boolean
	return c.isHub
		and c.settingsLoaded
		and not c.introSeen
		and (c.roundState == nil or c.roundState == "WaitingForPlayers")
		and not c.loading
		and not c.menuOpen
		and not c.queued
end

-- THE GUIDED ROUND'S STEPS (tutorial seam 4, docs/onboarding.md). In
-- the tutorial round one step prompt is up at a time, and it stays up
-- until the player has done it. Copy picked by the owner 2026-10-15.
-- Each step is a fact about the round that, once true, stays true, and
-- the prompt is the first fact in order not yet true. So a player who
-- grabs a power-up on the way to their first station skips "Grab a
-- power-up" when they get there.
--
-- Each step opens as a pop-up on a dimmed, frozen screen first (owner,
-- 2026-10-15), with `picture`: a Studio screenshot of what to look for
-- (0 = none yet, the pop-up just has the text).
export type StepId = "station" | "task" | "grab" | "use" | "finish"
export type Step = { id: StepId, title: string, body: string, picture: number }

local STEPS: { Step } = {
	{
		id = "station",
		title = "Head to a station",
		body = "Follow the arrow to your first task.",
		picture = 72834010784044,
	},
	{ id = "task", title = "Do the task", body = "Finish the mini-game to tick it off.", picture = 110568131773173 },
	{
		id = "grab",
		title = "Grab a power-up",
		body = "Run through one of the glowing orbs.",
		picture = 103735767545857,
	},
	{
		id = "use",
		title = "Use it on a bot",
		body = "Tap the power-up button. It hits the nearest rival.",
		picture = 77015988624200,
	},
	{
		id = "finish",
		title = "Finish your tasks",
		body = "Top 3 make the finale. Follow the arrow.",
		picture = 114091474180130,
	},
}
OnboardingLogic.STEPS = table.freeze(STEPS)

export type Steps = { [string]: boolean }

function OnboardingLogic.newSteps(): Steps
	return {}
end

-- Marks a step done. Doing a task means the player reached a station,
-- and using a power-up means they had one, so those latch too.
function OnboardingLogic.completeStep(steps: Steps, id: StepId)
	steps[id] = true
	if id == "task" then
		steps.station = true
	elseif id == "use" then
		steps.grab = true
	end
end

-- The prompt to show, or nil once every step is done.
function OnboardingLogic.currentStep(steps: Steps): Step?
	for _, step in OnboardingLogic.STEPS do
		if not steps[step.id] then
			return step
		end
	end
	return nil
end

-- True once the player has been taught the whole loop: the race, then
-- either the Studio or seeing they missed it. That's when the tips turn
-- themselves off. A player who joined mid-round and skipped the race
-- tip keeps them for their next full round.
function OnboardingLogic.loopTaught(state: State): boolean
	return state.seen.race == true and (state.seen.choose == true or state.seen.missed == true)
end

return OnboardingLogic
