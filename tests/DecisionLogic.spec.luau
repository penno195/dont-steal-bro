--!strict
-- Covers the pure half of the Decision Studio screen (P6-5). The screen
-- itself is reviewed on device through the DecisionStudio preview
-- (docs/decision-studio.md).

local DecisionLogic = require("../src/client/UI/DecisionLogic")
local Outcomes = require("../src/shared/Config/Outcomes")
local TestRunner = require("./TestRunner")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local HOLD = DecisionLogic.TIMING.holdSeconds

describe("DecisionLogic.prizeFor agrees with Outcomes.resolve", function()
	-- The always-visible payoff table is built from prizeFor. If it ever
	-- disagreed with the real resolver, a player would lose on a table
	-- that lied to them - so every combination, for every seat count,
	-- is checked against the resolver itself.
	local PRIZE_BY_VU: { [number]: DecisionLogic.Prize } = { [3] = "Big", [2] = "Medium", [1] = "Small" }

	for seats = 1, 3 do
		it(string.format("matches every combination with %d seat(s)", seats), function()
			for mask = 0, 2 ^ seats - 1 do
				local finalists: { Outcomes.FinalistInput } = {}
				for i = 1, seats do
					local steals = math.floor(mask / 2 ^ (i - 1)) % 2 == 1
					table.insert(finalists, {
						playerId = i,
						choice = if steals then "Steal" else "Share",
						soleStealerVU = 3,
						loneSharerVU = 2,
						allShareVU = 1,
					})
				end
				local result = Outcomes.resolve(finalists)
				for _, me in finalists do
					local othersStealing = 0
					for _, other in finalists do
						if other ~= me and other.choice == "Steal" then
							othersStealing += 1
						end
					end
					local expected: DecisionLogic.Prize = "Nothing"
					for _, winner in result.winners do
						if winner.playerId == me.playerId then
							expected = PRIZE_BY_VU[winner.bountyVU]
						end
					end
					expect(DecisionLogic.prizeFor(me.choice, othersStealing, seats)):toBe(expected)
					expect(DecisionLogic.prizeForBranch(result.branch, expected ~= "Nothing")):toBe(
						if expected == "Nothing" then "Nothing" else expected
					)
				end
			end
		end)
	end

	it("lays out one cell per 'what the others do'", function()
		local rows = DecisionLogic.payoffRows(3)
		expect(#rows):toBe(2)
		expect(rows[1].choice):toBe("Steal")
		expect(#rows[1].cells):toBe(3)
		expect(rows[1].cells[1].when):toBe("Both share")
		expect(rows[1].cells[1].prize):toBe("Big")
		expect(rows[2].cells[3].when):toBe("Both steal")
		expect(rows[2].cells[3].prize):toBe("Medium")
		expect(#DecisionLogic.payoffRows(2)[1].cells):toBe(2)
		expect(#DecisionLogic.payoffRows(1)[2].cells):toBe(1)
	end)
end)

describe("DecisionLogic.parseReveal", function()
	local function payload(choices: any): any
		return {
			choices = choices,
			outcome = {
				branch = "SoleSteal",
				winners = { { playerId = 1, bountyVU = 20 } },
				loserIds = { 2, -7 },
			},
			revealAt = 100,
		}
	end

	it("reads choices keyed by number or by string, NPC ids included", function()
		local r = DecisionLogic.parseReveal(payload({ ["1"] = "Steal", [2] = "Share", ["-7"] = "Share" }))
		assert(r ~= nil, "expected a reveal")
		expect(r.choices[1]):toBe("Steal")
		expect(r.choices[2]):toBe("Share")
		expect(r.choices[-7]):toBe("Share")
		expect(r.winnerIds[1]):toBe(1)
		expect(r.loserIds[2]):toBe(-7)
	end)

	it("never keeps a winner's bountyVU (a streak-tier tell)", function()
		local r = DecisionLogic.parseReveal(payload({ [1] = "Steal" })) :: any
		for _, value in r do
			if type(value) == "table" then
				for _, inner in value do
					expect(type(inner) == "table" and inner.bountyVU ~= nil):toBe(false)
				end
			end
		end
		expect(r.bountyVU):toBe(nil)
	end)

	it("drops anything that isn't Steal or Share, and rejects a malformed packet", function()
		local r = DecisionLogic.parseReveal(payload({ [1] = "Steal", [2] = "Maybe", ["x"] = "Share" }))
		assert(r ~= nil, "expected a reveal")
		expect(r.choices[2]):toBe(nil)
		expect(DecisionLogic.parseReveal({ choices = {} })):toBe(nil)
		expect(DecisionLogic.parseReveal(nil)):toBe(nil)
	end)
end)

describe("DecisionLogic.reputationLabel", function()
	it("says nothing damning about a first-timer (or an NPC)", function()
		expect(DecisionLogic.reputationLabel(nil)):toBe("No history yet")
		expect(DecisionLogic.reputationLabel({ steals = 0, shares = 0 })):toBe("No history yet")
	end)

	it("shows raw counts for a small sample and a percentage after", function()
		expect(DecisionLogic.reputationLabel({ steals = 1, shares = 0 })):toBe("Stole 1 of 1")
		expect(DecisionLogic.reputationLabel({ steals = 8, shares = 5 })):toBe("Steals 62% of 13")
	end)

	it("parses the participants list and ignores junk", function()
		local reps = DecisionLogic.parseReputation({
			{ playerId = 5, steals = 2, shares = 3 },
			{ playerId = "oops" },
			"nope",
		})
		expect(reps[5].steals):toBe(2)
		expect(DecisionLogic.parseReputation(nil)[5]):toBe(nil)
	end)
end)

describe("DecisionLogic hold-to-confirm", function()
	it("locks only after a full hold, exactly once", function()
		local c = DecisionLogic.press(DecisionLogic.OPEN, "Steal", 10)
		local locked
		c, locked = DecisionLogic.tick(c, 10 + HOLD / 2, HOLD)
		expect(locked):toBe(false)
		expect(DecisionLogic.holdFraction(c, 10 + HOLD / 2, HOLD)):toBeCloseTo(0.5)
		c, locked = DecisionLogic.tick(c, 10 + HOLD, HOLD)
		expect(locked):toBe(true)
		expect(c.state):toBe("Locked")
		expect(c.choice):toBe("Steal")
		c, locked = DecisionLogic.tick(c, 20, HOLD)
		expect(locked):toBe(false)
	end)

	it("cancels on an early release", function()
		local c = DecisionLogic.press(DecisionLogic.OPEN, "Share", 0)
		c = DecisionLogic.release(c, "Share")
		expect(c.state):toBe("Open")
		expect(DecisionLogic.holdFraction(c, 5, HOLD)):toBe(0)
	end)

	it("ignores a second thumb on the other button", function()
		local c = DecisionLogic.press(DecisionLogic.OPEN, "Share", 0)
		c = DecisionLogic.press(c, "Steal", 0.1)
		expect(c.choice):toBe("Share")
		c = DecisionLogic.release(c, "Steal") -- the stray thumb lifting
		expect(c.state):toBe("Holding")
	end)

	it("is final once locked", function()
		local c = DecisionLogic.press(DecisionLogic.OPEN, "Steal", 0)
		c = DecisionLogic.tick(c, HOLD, HOLD)
		c = DecisionLogic.release(c, "Steal")
		c = DecisionLogic.press(c, "Share", 5)
		expect(c.state):toBe("Locked")
		expect(c.choice):toBe("Steal")
	end)
end)

describe("DecisionLogic.stage", function()
	it("lets the reveal packet win over any phase", function()
		local r = DecisionLogic.parseReveal({
			choices = {},
			outcome = { branch = "AllShare", winners = {}, loserIds = {} },
			revealAt = 0,
		})
		expect(DecisionLogic.stage("Choose", r, false, true)):toBe("Reveal")
	end)

	it("moves a finalist to Locked once they commit, and a spectator straight there", function()
		expect(DecisionLogic.stage("Choose", nil, false, true)):toBe("Choose")
		expect(DecisionLogic.stage("Choose", nil, true, true)):toBe("Locked")
		expect(DecisionLogic.stage("Choose", nil, false, false)):toBe("Locked")
		expect(DecisionLogic.stage("Reveal", nil, true, true)):toBe("Locked")
		expect(DecisionLogic.stage(nil, nil, false, true)):toBe("Waiting")
	end)
end)

describe("DecisionLogic.revealStep", function()
	local t = DecisionLogic.TIMING

	it("holds every card back for the lead, then staggers them", function()
		expect(DecisionLogic.revealStep(-5, 3).cardsShown):toBe(0)
		expect(DecisionLogic.revealStep(t.lead - 0.01, 3).cardsShown):toBe(0)
		expect(DecisionLogic.revealStep(t.lead, 3).cardsShown):toBe(1)
		expect(DecisionLogic.revealStep(t.lead + t.cardGap, 3).cardsShown):toBe(2)
		expect(DecisionLogic.revealStep(t.lead + 10 * t.cardGap, 3).cardsShown):toBe(3)
	end)

	it("shows the outcome, then the result, and ends at revealLength", function()
		local length = DecisionLogic.revealLength(3)
		local outcomeAt = length - t.resultAfter
		expect(DecisionLogic.revealStep(outcomeAt - 0.01, 3).outcomeShown):toBe(false)
		expect(DecisionLogic.revealStep(outcomeAt, 3).outcomeShown):toBe(true)
		expect(DecisionLogic.revealStep(length - 0.01, 3).resultShown):toBe(false)
		expect(DecisionLogic.revealStep(length, 3).resultShown):toBe(true)
	end)

	it("depends on elapsed server time alone, so every client agrees", function()
		-- Two clients whose packets landed 0.4s apart still compute the
		-- same step at the same server time: revealStep takes no receive time.
		local a = DecisionLogic.revealStep(3.3, 3)
		local b = DecisionLogic.revealStep(3.3, 3)
		expect(a.cardsShown):toBe(b.cardsShown)
		expect(a.outcomeShown):toBe(b.outcomeShown)
	end)
end)

describe("DecisionLogic.resultCopy", function()
	local function reveal(branch: string, winners: { number }, losers: { number }): DecisionLogic.Reveal
		return {
			choices = {},
			branch = branch,
			winnerIds = winners,
			loserIds = losers,
			revealAt = 0,
		}
	end

	it("names the streak that just died, plainly", function()
		local copy = DecisionLogic.resultCopy(
			reveal("SoleSteal", { 2 }, { 1, 3 }),
			1,
			{ streakBefore = 7, streakAfter = 0, won = false }
		)
		expect(copy.headline):toBe("Betrayed")
		expect(copy.streak):toBe("Your 7-win streak ends here")
		expect(copy.tone):toBe("loss")
	end)

	it("gives the winner their prize and new streak", function()
		local copy = DecisionLogic.resultCopy(
			reveal("LoneShare", { 1 }, { 2, 3 }),
			1,
			{ streakBefore = 2, streakAfter = 3, won = true }
		)
		expect(copy.detail):toBe("MEDIUM bounty")
		expect(copy.streak):toBe("Streak 3")
	end)

	it("says so when the round carried no streak credit", function()
		local won = DecisionLogic.resultCopy(reveal("AllShare", { 1, 2, 3 }, {}), 1, {
			streakBefore = 4,
			streakAfter = 4,
			won = true,
		})
		expect(won.streak):toBe("No streak credit this round")
		local lost = DecisionLogic.resultCopy(reveal("AllSteal", {}, { 1, 2, 3 }), 1, {
			streakBefore = 4,
			streakAfter = 4,
			won = false,
		})
		expect(lost.streak):toBe("Streak 4 kept - no streak credit this round")
	end)

	it("shows a spectator the outcome and no streak", function()
		local copy = DecisionLogic.resultCopy(reveal("AllSteal", {}, { 1, 2, 3 }), 99, nil)
		expect(copy.headline):toBe("Nobody wins")
		expect(copy.streak):toBe(nil)
		expect(copy.tone):toBe("neutral")
	end)
end)

describe("DecisionLogic.chatInset", function()
	local usable = { x = 0, y = 40, width = 400, height = 800 }

	it("pushes content below a chat window at the top", function()
		expect(DecisionLogic.chatInset({ x = 0, y = 50, width = 300, height = 200 }, usable, 8, 0.45)):toBe(258)
	end)

	it("ignores a hidden or bottom-anchored window, and caps the push", function()
		expect(DecisionLogic.chatInset(nil, usable, 8, 0.45)):toBe(40)
		expect(DecisionLogic.chatInset({ x = 0, y = 50, width = 0, height = 0 }, usable, 8, 0.45)):toBe(40)
		expect(DecisionLogic.chatInset({ x = 0, y = 600, width = 300, height = 200 }, usable, 8, 0.45)):toBe(40)
		expect(DecisionLogic.chatInset({ x = 0, y = 50, width = 300, height = 600 }, usable, 8, 0.45)):toBe(400)
	end)
end)
