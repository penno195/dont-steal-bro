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
-- then the Locker (a free power-up to put in the loadout), ending on
-- "press Play" with only Play lit. Copy is the owner's (2026-10-15, design-decisions.md "the
-- tutorial, second version"; the practice area's cards, same day).
--
--   kind "card"       a pop-up on a dimmed screen. `skip` adds the Skip
--                     that ends the whole tutorial (the welcome only).
--                     With `waitFor`, the step then stays up in the
--                     corner card until the player has done it.
--   kind "spotlight"  the screen dims except `target`, ringed, with the
--                     title and body in a caption card beside it. The
--                     step ends when spotlightDone says so.
--
-- `gift` (the Locker's card) first asks the server for the free
-- power-up, and the card only shows if it was given just now.
--
-- `picture` is a Studio screenshot (0 = none yet).
export type HubStepId =
	"welcome"
	| "rivals"
	| "aim"
	| "station"
	| "task"
	| "locker"
	| "gift"
	| "loadout"
	| "close"
	| "play"
-- What a spotlight lights: the launcher's Locker button, the free
-- power-up's tile in the Locker, the Locker's close button, and Play.
export type HubTarget = "locker" | "gift" | "close" | "play"
-- What a card waits for (hubWaitDone): holding an Aimed item (the
-- personal pickup), a power-up fired, the practice station's task
-- opened, and that task solved.
export type HubWait = "pickup" | "use" | "station" | "solve"
export type HubStep = {
	id: HubStepId,
	kind: "card" | "spotlight",
	title: string,
	body: string,
	picture: number,
	skip: boolean?,
	gift: boolean?,
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
		body = "Grab the glowing power-up in the middle of the practice area.",
		picture = 0,
		waitFor = "pickup",
	},
	{
		id = "aim",
		kind = "card",
		title = "Aim and fire",
		body = "Drag from its slot (or left click) to aim at a dummy. Let's go fire!",
		picture = 0,
		waitFor = "use",
	},
	{
		id = "station",
		kind = "card",
		title = "Task station",
		body = "Matches are a race through tasks. Your stations have a beam of light. Find the station and start the task.",
		picture = 0,
		waitFor = "station",
	},
	{
		id = "task",
		kind = "card",
		title = "Do the task",
		body = "Complete the task to move on to the next or the final.",
		picture = 0,
		waitFor = "solve",
	},
	-- The Locker steps (seam 3). The gift card's body and the loadout
	-- caption are the owner's; the titles and the Locker and close
	-- captions are Claude's draft (2026-10-15), for the owner to tweak.
	{
		id = "locker",
		kind = "spotlight",
		title = "Your Locker",
		body = "Your power-ups live in the Locker. Open it!",
		picture = 0,
		target = "locker",
	},
	{
		id = "gift",
		kind = "card",
		title = "A free power-up!",
		body = "Here is a free power up to get you started!",
		picture = 0,
		gift = true,
	},
	{
		id = "loadout",
		kind = "spotlight",
		title = "Load it up",
		body = "Click to add to your load out for a match!",
		picture = 0,
		target = "gift",
	},
	{
		id = "close",
		kind = "spotlight",
		title = "All set",
		body = "Close the Locker to head back.",
		picture = 0,
		target = "close",
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
-- holdsAimed, which is how things stand right now.
export type HubFacts = {
	holdsAimed: boolean,
	used: boolean,
	opened: boolean,
	solved: boolean,
}

function OnboardingLogic.hubWaitDone(wait: HubWait?, facts: HubFacts): boolean
	if wait == "pickup" then
		return facts.holdsAimed
	elseif wait == "use" then
		return facts.used
	elseif wait == "station" then
		return facts.opened or facts.solved
	elseif wait == "solve" then
		return facts.solved
	end
	return true
end

-- How things stand for the spotlight steps, read live each check:
-- whether the Locker is open, the free power-up's stock and whether
-- it's in the loadout, whether the loadout is full, and whether the
-- player is in the queue.
export type SpotlightFacts = {
	lockerOpen: boolean,
	giftStock: number,
	giftLoaded: boolean,
	loadoutFull: boolean,
	queued: boolean,
}

-- Is a spotlight step done? The gift's step also ends when it can't be
-- done: none in stock (a replay after it was spent), or a full loadout
-- (a tap on the tile would do nothing), so the player is never stuck
-- behind a dim with nothing that works.
function OnboardingLogic.spotlightDone(target: HubTarget, f: SpotlightFacts): boolean
	if target == "locker" then
		return f.lockerOpen
	elseif target == "gift" then
		return f.giftLoaded or f.giftStock <= 0 or f.loadoutFull
	elseif target == "close" then
		return not f.lockerOpen
	end
	return f.queued
end

-- What to light right now. The gift's tile is inside the Locker, so a
-- player who shut it (Escape, gamepad B) is pointed back at the Locker
-- button rather than left with nothing lit.
function OnboardingLogic.spotlightAim(target: HubTarget, f: SpotlightFacts): HubTarget
	if target == "gift" and not f.lockerOpen then
		return "locker"
	end
	return target
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
-- fires their Freeze on the way to their first station skips "Use your
-- Freeze" when they get there.
--
-- Each step opens as a pop-up on a dimmed, frozen screen first (owner,
-- 2026-10-15), with `picture`: a Studio screenshot of what to look for
-- (0 = none yet, the pop-up just has the text).
--
-- Tutorial v2 (owner, 2026-10-15) dropped "Grab a power-up" and "Use it
-- on a bot" for "Use your Freeze": the loadout Freeze (or a round-only
-- one, TutorialService) must be fired at a bot. Its pop-up waits for
-- `gate` "botNear" (a bot in Freeze's reach, after the first task), and
-- with `holdUntilDone` the round stays frozen after "Got it" until it's
-- fired. Firing counts, whether it lands or not. Its copy is Claude's
-- draft.
export type StepId = "station" | "task" | "freeze" | "finish"
export type Step = {
	id: StepId,
	title: string,
	body: string,
	picture: number,
	gate: "botNear"?,
	holdUntilDone: boolean?,
}

local STEPS: { Step } = {
	{
		id = "station",
		title = "Head to a station",
		body = "Follow the arrow to your first task.",
		picture = 72834010784044,
	},
	{ id = "task", title = "Do the task", body = "Finish the mini-game to tick it off.", picture = 110568131773173 },
	{
		id = "freeze",
		title = "Use your Freeze",
		body = "A bot is close! Drag from your Freeze (or left click) to fire it at them.",
		picture = 0,
		gate = "botNear",
		holdUntilDone = true,
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
-- so that latches too.
function OnboardingLogic.completeStep(steps: Steps, id: StepId)
	steps[id] = true
	if id == "task" then
		steps.station = true
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

-- Is any bot within `reach` studs? A little short of the power-up's
-- real range, so the lock-on still finds them by the time the pop-up
-- is read.
function OnboardingLogic.botInReach(distances: { number }, reach: number): boolean
	for _, distance in distances do
		if distance <= reach then
			return true
		end
	end
	return false
end

-- THE STUDIO CARDS (tutorial v2): in the guided round, a finalist's
-- Negotiate and Choose each open with one of these as a pop-up. Bodies
-- are the owner's (2026-10-15); titles are Claude's draft. Like the
-- explainer, the Studio's timer is paused while one is up, and its
-- button glows after GameConfig.tutorial.explainerGlowSeconds.
export type StudioCard = { title: string, body: string }

OnboardingLogic.STUDIO_CARDS = table.freeze({
	Negotiate = table.freeze({
		title = "Talk it out",
		body = "This is where you can talk to the opponents to see if you trust them to share! Wait till the timer runs down.",
	}),
	Choose = table.freeze({
		title = "Steal or Share?",
		body = "Now you decide whether you are going to STEAL or SHARE! Press and hold your choice.",
	}),
}) :: { [string]: StudioCard }

-- True once the player has been taught the whole loop: the race, then
-- either the Studio or seeing they missed it. That's when the tips turn
-- themselves off. A player who joined mid-round and skipped the race
-- tip keeps them for their next full round.
function OnboardingLogic.loopTaught(state: State): boolean
	return state.seen.race == true and (state.seen.choose == true or state.seen.missed == true)
end

return OnboardingLogic
