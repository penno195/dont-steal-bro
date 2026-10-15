--!strict
-- Covers P6-8's first-round tips (OnboardingLogic) and the Steal or
-- Share explainer (DecisionLogic.explainerRows). The overlay itself is
-- reviewed on device (docs/onboarding.md).

local DecisionLogic = require("../src/client/UI/DecisionLogic")
local OnboardingLogic = require("../src/client/UI/OnboardingLogic")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

describe("OnboardingLogic copy", function()
	it("keeps every tip short enough for two lines on a phone", function()
		for _, tip in OnboardingLogic.TIPS do
			expect(#tip.title <= 30):toBe(true)
			expect(#tip.body <= 90):toBe(true)
		end
	end)

	it("gives every tip a reading time between 4 and 9 seconds", function()
		for _, tip in OnboardingLogic.TIPS do
			local s = OnboardingLogic.readSeconds(tip)
			expect(s >= 4 and s <= 9):toBe(true)
		end
	end)
end)

describe("OnboardingLogic queue", function()
	it("shows one tip at a time, in order, each once", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.trigger(s, "powerUp")
		expect(s.showing):toBe("race")
		OnboardingLogic.dismiss(s)
		expect(s.showing):toBe("powerUp")
		OnboardingLogic.dismiss(s)
		OnboardingLogic.trigger(s, "powerUp")
		expect(s.showing):toBe(nil)
	end)

	it("never queues the same tip twice", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.trigger(s, "hit")
		OnboardingLogic.trigger(s, "hit")
		OnboardingLogic.trigger(s, "race")
		expect(#s.queue):toBe(1)
	end)

	it("ignores a tip for another stage", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "choose")
		expect(s.showing):toBe(nil)
	end)

	it("drops a stale race tip when the Studio starts", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.trigger(s, "hit")
		OnboardingLogic.enterStage(s, "Studio")
		expect(s.showing):toBe(nil)
		expect(#s.queue):toBe(0)
		OnboardingLogic.trigger(s, "finale")
		expect(s.showing):toBe("finale")
	end)

	it("counts the loop taught after the race and either finale path", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Race")
		OnboardingLogic.trigger(s, "race")
		OnboardingLogic.dismiss(s)
		expect(OnboardingLogic.loopTaught(s)):toBe(false)
		OnboardingLogic.enterStage(s, "Studio")
		OnboardingLogic.trigger(s, "missed")
		OnboardingLogic.dismiss(s)
		expect(OnboardingLogic.loopTaught(s)):toBe(true)
	end)

	it("doesn't count a player who joined after the race", function()
		local s = OnboardingLogic.new()
		OnboardingLogic.enterStage(s, "Studio")
		OnboardingLogic.trigger(s, "finale")
		OnboardingLogic.dismiss(s)
		OnboardingLogic.trigger(s, "choose")
		OnboardingLogic.dismiss(s)
		expect(OnboardingLogic.loopTaught(s)):toBe(false)
	end)
end)

describe("OnboardingLogic hub intro", function()
	local function ctx(overrides: { [string]: any }): OnboardingLogic.IntroContext
		local c: { [string]: any } = {
			isHub = true,
			settingsLoaded = true,
			introSeen = false,
			roundState = nil,
			loading = false,
			menuOpen = false,
			queued = false,
		}
		for k, v in overrides do
			c[k] = v
		end
		return c :: any
	end

	it("opens on the welcome, with Skip, and ends on Play lit", function()
		local steps = OnboardingLogic.HUB_STEPS
		expect(steps[1].id):toBe("welcome")
		expect(steps[1].kind):toBe("card")
		expect(steps[1].skip):toBe(true)
		local last = steps[#steps]
		expect(last.id):toBe("play")
		expect(last.kind):toBe("spotlight")
		expect(last.target):toBe("play")
	end)

	it("keeps every hub step inside the tip limits, ids unique", function()
		local seen = {}
		for i, step in OnboardingLogic.HUB_STEPS do
			expect(seen[step.id]):toBe(nil)
			seen[step.id] = true
			expect(#step.title <= 30):toBe(true)
			-- Over 90 gets a third line on its card.
			expect(#step.body <= 120):toBe(true)
			expect(typeof(step.picture)):toBe("number")
			-- A spotlight always names what it lights; only the welcome skips.
			expect(step.kind ~= "spotlight" or step.target ~= nil):toBe(true)
			expect(step.skip == nil or i == 1):toBe(true)
		end
	end)

	it("runs the practice area, then the Locker, between the welcome and Play", function()
		local order = {}
		for _, step in OnboardingLogic.HUB_STEPS do
			table.insert(order, step.id)
		end
		expect(table.concat(order, ",")):toBe("welcome,rivals,aim,station,task,locker,gift,loadout,close,play")
		-- "aim" directly follows "rivals": with no pickup both are skipped.
		expect(OnboardingLogic.HUB_STEPS[2].waitFor):toBe("pickup")
		expect(OnboardingLogic.HUB_STEPS[3].waitFor):toBe("use")
		-- Only the Locker's card asks for the gift.
		for _, step in OnboardingLogic.HUB_STEPS do
			expect(step.gift == true):toBe(step.id == "gift")
		end
	end)

	it("ends each Locker spotlight on what it asks for", function()
		local base = { lockerOpen = false, giftStock = 1, giftLoaded = false, loadoutFull = false, queued = false }
		local function with(overrides: { [string]: any }): any
			local f = table.clone(base) :: any
			for k, v in overrides do
				f[k] = v
			end
			return f
		end
		local done = OnboardingLogic.spotlightDone
		expect(done("locker", base)):toBe(false)
		expect(done("locker", with({ lockerOpen = true }))):toBe(true)
		expect(done("gift", with({ lockerOpen = true }))):toBe(false)
		expect(done("gift", with({ lockerOpen = true, giftLoaded = true }))):toBe(true)
		expect(done("close", with({ lockerOpen = true }))):toBe(false)
		expect(done("close", base)):toBe(true)
		expect(done("play", base)):toBe(false)
		expect(done("play", with({ queued = true }))):toBe(true)
	end)

	it("never strands the player on a gift they can't load", function()
		local f = { lockerOpen = true, giftStock = 0, giftLoaded = false, loadoutFull = false, queued = false }
		expect(OnboardingLogic.spotlightDone("gift", f)):toBe(true)
		f.giftStock = 2
		f.loadoutFull = true
		expect(OnboardingLogic.spotlightDone("gift", f)):toBe(true)
	end)

	it("points back at the Locker button while the Locker is shut", function()
		local f = { lockerOpen = false, giftStock = 1, giftLoaded = false, loadoutFull = false, queued = false }
		expect(OnboardingLogic.spotlightAim("gift", f)):toBe("locker")
		expect(OnboardingLogic.spotlightAim("close", f)):toBe("close")
		f.lockerOpen = true
		expect(OnboardingLogic.spotlightAim("gift", f)):toBe("gift")
	end)

	it("waits on what each practice step asks for", function()
		local none = { holdsAimed = false, used = false, opened = false, solved = false }
		local function with(key: string): any
			local f = table.clone(none) :: any
			f[key] = true
			return f
		end
		expect(OnboardingLogic.hubWaitDone("pickup", none)):toBe(false)
		expect(OnboardingLogic.hubWaitDone("pickup", with("holdsAimed"))):toBe(true)
		expect(OnboardingLogic.hubWaitDone("use", with("holdsAimed"))):toBe(false)
		expect(OnboardingLogic.hubWaitDone("use", with("used"))):toBe(true)
		expect(OnboardingLogic.hubWaitDone("station", with("opened"))):toBe(true)
		-- Solving it means they got there.
		expect(OnboardingLogic.hubWaitDone("station", with("solved"))):toBe(true)
		expect(OnboardingLogic.hubWaitDone("solve", with("opened"))):toBe(false)
		expect(OnboardingLogic.hubWaitDone("solve", with("solved"))):toBe(true)
		expect(OnboardingLogic.hubWaitDone(nil, none)):toBe(true)
	end)

	it("is due for a new player idle in the Hub", function()
		expect(OnboardingLogic.introDue(ctx({}))):toBe(true)
		expect(OnboardingLogic.introDue(ctx({ roundState = "WaitingForPlayers" }))):toBe(true)
	end)

	it("waits out everything that would put it in the way", function()
		expect(OnboardingLogic.introDue(ctx({ isHub = false }))):toBe(false)
		expect(OnboardingLogic.introDue(ctx({ settingsLoaded = false }))):toBe(false)
		expect(OnboardingLogic.introDue(ctx({ introSeen = true }))):toBe(false)
		expect(OnboardingLogic.introDue(ctx({ roundState = "Race" }))):toBe(false)
		expect(OnboardingLogic.introDue(ctx({ loading = true }))):toBe(false)
		expect(OnboardingLogic.introDue(ctx({ menuOpen = true }))):toBe(false)
		expect(OnboardingLogic.introDue(ctx({ queued = true }))):toBe(false)
	end)
end)

describe("OnboardingLogic guided-round steps", function()
	local function current(steps): string?
		local step = OnboardingLogic.currentStep(steps)
		return if step then step.id else nil
	end

	it("has the owner's five steps, in order, inside the tip limits", function()
		local ids = {}
		for _, step in OnboardingLogic.STEPS do
			table.insert(ids, step.id)
			expect(#step.title <= 30):toBe(true)
			expect(#step.body <= 90):toBe(true)
		end
		expect(table.concat(ids, "|")):toBe("station|task|grab|use|finish")
	end)

	it("walks the steps in order, then shows nothing", function()
		local steps = OnboardingLogic.newSteps()
		expect(current(steps)):toBe("station")
		for _, id in { "station", "task", "grab", "use" } :: { any } do
			OnboardingLogic.completeStep(steps, id)
		end
		expect(current(steps)):toBe("finish")
		OnboardingLogic.completeStep(steps, "finish")
		expect(current(steps)):toBe(nil)
	end)

	it("skips a step the player already did out of order", function()
		local steps = OnboardingLogic.newSteps()
		OnboardingLogic.completeStep(steps, "grab")
		expect(current(steps)):toBe("station")
		OnboardingLogic.completeStep(steps, "task")
		expect(current(steps)):toBe("use")
	end)

	it("counts a use as having grabbed one", function()
		local steps = OnboardingLogic.newSteps()
		OnboardingLogic.completeStep(steps, "task")
		OnboardingLogic.completeStep(steps, "use")
		expect(current(steps)):toBe("finish")
	end)
end)

describe("DecisionLogic.explainerRows", function()
	it("reads the three-seat table the way payoff-table.md does", function()
		local rows = DecisionLogic.explainerRows(3)
		expect(#rows):toBe(4)
		expect(rows[1].detail):toBe("Everyone gets a SMALL prize.")
		expect(rows[2].detail):toBe("The stealer gets the BIG prize. The sharers get nothing.")
		expect(rows[3].detail):toBe("The one who shared gets a MEDIUM prize. The stealers get nothing.")
		expect(rows[4].detail):toBe("Everyone gets nothing.")
	end)

	it("names every prize prizeFor gives, for every table size", function()
		for seats = 1, 3 do
			for _, row in DecisionLogic.explainerRows(seats) do
				local stealers = row.stealers
				local expected: { string } = {}
				if stealers > 0 then
					table.insert(expected, DecisionLogic.prizeFor("Steal", stealers - 1, seats))
				end
				if stealers < seats then
					table.insert(expected, DecisionLogic.prizeFor("Share", stealers, seats))
				end
				for _, prize in expected do
					local word = if prize == "Nothing" then "nothing" else DecisionLogic.PRIZE_LABEL[prize :: any]
					expect(string.find(row.detail, word, 1, true) ~= nil):toBe(true)
				end
			end
		end
	end)

	it("backs up the one-line lesson: a steal only pays when it's the only one", function()
		for seats = 2, 3 do
			for othersStealing = 1, seats - 1 do
				expect(DecisionLogic.prizeFor("Steal", othersStealing, seats)):toBe("Nothing")
			end
			expect(DecisionLogic.prizeFor("Steal", 0, seats)):toBe("Big")
		end
	end)
end)
