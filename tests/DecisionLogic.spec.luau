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
	local PRIZE_BY_TAG: { [string]: DecisionLogic.Prize } =
		{ SoleStealer = "Big", LoneSharer = "Medium", AllShare = "Small" }

	for seats = 1, 3 do
		it(string.format("matches every combination with %d seat(s)", seats), function()
			for mask = 0, 2 ^ seats - 1 do
				local finalists: { Outcomes.FinalistInput } = {}
				for i = 1, seats do
					local steals = math.floor(mask / 2 ^ (i - 1)) % 2 == 1
					table.insert(finalists, { playerId = i, choice = if steals then "Steal" else "Share" })
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
							expected = PRIZE_BY_TAG[winner.outcomeTag]
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
				-- bountyVU is a field from a pre-2c server, kept here to
				-- prove parseReveal copies only what it knows.
				winners = { { playerId = 1, outcomeTag = "SoleStealer", bountyVU = 20 } },
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

	it("copies only winner ids, dropping any field it doesn't know", function()
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

describe("DecisionLogic.reputationSplit", function()
	it("says nothing damning about a first-timer (or an NPC)", function()
		expect(DecisionLogic.reputationSplit(nil)):toBe(nil)
		expect(DecisionLogic.reputationSplit({ steals = 0, shares = 0 })):toBe(nil)
	end)

	it("splits into two rounded percentages that add to 100", function()
		local s = DecisionLogic.reputationSplit({ steals = 8, shares = 5 }) :: DecisionLogic.ReputationSplit
		expect(s.steal):toBe(62)
		expect(s.share):toBe(38)
		local third = DecisionLogic.reputationSplit({ steals = 1, shares = 2 }) :: DecisionLogic.ReputationSplit
		expect(third.steal + third.share):toBe(100)
		local all = DecisionLogic.reputationSplit({ steals = 1, shares = 0 }) :: DecisionLogic.ReputationSplit
		expect(all.steal):toBe(100)
		expect(all.share):toBe(0)
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

describe("DecisionLogic.rewardTiles", function()
	it("lists every prize the table can pay, best first, then nothing", function()
		local tiles = DecisionLogic.rewardTiles(3)
		expect(#tiles):toBe(4)
		expect(tiles[1].prize):toBe("Big")
		expect(tiles[1].how):toBe("You steal, both share")
		expect(tiles[2].prize):toBe("Medium")
		expect(tiles[2].how):toBe("You share, both steal")
		expect(tiles[3].prize):toBe("Small")
		expect(tiles[4].prize):toBe("Nothing")
	end)

	it("drops a prize the seat count can't reach", function()
		-- Two seats: there is no lone sharer between two thieves.
		local tiles = DecisionLogic.rewardTiles(2)
		expect(#tiles):toBe(3)
		expect(tiles[1].prize):toBe("Big")
		expect(tiles[2].prize):toBe("Small")
		expect(DecisionLogic.rewardTiles(1)[1].prize):toBe("Small")
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

	it("brings each card up face down, then turns it", function()
		local before = DecisionLogic.revealStep(t.lead - t.suspense - 0.01, 3)
		expect(before.current):toBe(0)
		local down = DecisionLogic.revealStep(t.lead - t.suspense, 3)
		expect(down.current):toBe(1)
		expect(down.faceUp):toBe(false)
		local up = DecisionLogic.revealStep(t.lead, 3)
		expect(up.current):toBe(1)
		expect(up.faceUp):toBe(true)
		local second = DecisionLogic.revealStep(t.lead + t.cardGap - t.suspense, 3)
		expect(second.current):toBe(2)
		expect(second.faceUp):toBe(false)
		expect(second.cardsShown):toBe(1)
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

describe("DecisionLogic.revealOrder", function()
	local seats = { 10, 20, 30 }

	it("shows your own card first, then the one who chose the opposite", function()
		local order = DecisionLogic.revealOrder(seats, { [10] = "Share", [20] = "Share", [30] = "Steal" }, 20)
		expect(order[1]):toBe(20)
		expect(order[2]):toBe(30)
		expect(order[3]):toBe(10)
	end)

	it("keeps seat order for the rest when nobody went the other way", function()
		local order = DecisionLogic.revealOrder(seats, { [10] = "Steal", [20] = "Steal", [30] = "Steal" }, 30)
		expect(order[1]):toBe(30)
		expect(order[2]):toBe(10)
		expect(order[3]):toBe(20)
	end)

	it("gives a spectator seat order", function()
		local order = DecisionLogic.revealOrder(seats, { [10] = "Steal", [20] = "Share", [30] = "Steal" }, 99)
		expect(order[1]):toBe(10)
		expect(order[2]):toBe(20)
		expect(order[3]):toBe(30)
	end)
end)

describe("DecisionLogic.cardTurnAt", function()
	it("lands on the beat revealStep turns each card", function()
		for index = 1, 3 do
			local at = DecisionLogic.cardTurnAt(index)
			expect(DecisionLogic.revealStep(at, 3).cardsShown):toBe(index)
			expect(DecisionLogic.revealStep(at - 0.01, 3).cardsShown):toBe(index - 1)
		end
	end)
end)

describe("DecisionLogic.parseRevealCosmetics", function()
	it("keys each finalist's cosmetic by id, NPC ids included", function()
		local out = DecisionLogic.parseRevealCosmetics({
			{ playerId = 10, cosmeticId = "reveal-vault-door" },
			{ playerId = "20", cosmeticId = "reveal-other" },
		})
		expect(out[10]):toBe("reveal-vault-door")
		expect(out[20]):toBe("reveal-other")
	end)

	it("drops malformed entries and non-tables", function()
		local out = DecisionLogic.parseRevealCosmetics({
			{ playerId = 1.5, cosmeticId = "x" },
			{ playerId = 30 },
			"junk",
		})
		expect(next(out)):toBe(nil)
		expect(next(DecisionLogic.parseRevealCosmetics(nil))):toBe(nil)
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

describe("DecisionLogic.keyboardLift", function()
	local usable = { x = 0, y = 0, width = 400, height = 800 }

	it("keeps the plain margin with no keyboard, or one below the screen", function()
		expect(DecisionLogic.keyboardLift(nil, usable, 16, 0.6)):toBe(16)
		expect(DecisionLogic.keyboardLift(800, usable, 16, 0.6)):toBe(16)
	end)

	it("lifts the stack clear of the keyboard's top edge", function()
		expect(DecisionLogic.keyboardLift(450, usable, 16, 0.6)):toBe(366)
		expect(DecisionLogic.keyboardLift(795, usable, 16, 0.6)):toBe(21)
	end)

	it("caps the lift so the stack stays on screen", function()
		expect(DecisionLogic.keyboardLift(100, usable, 16, 0.6)):toBe(480)
	end)
end)

describe("DecisionLogic.waitingNotice", function()
	local ids = { 1, 2, 3 }

	it("counts the finalists still reading", function()
		expect(DecisionLogic.waitingNotice(true, ids, { [1] = true }, {})):toBe("Waiting for 2 more players…")
		expect(DecisionLogic.waitingNotice(true, ids, { [1] = true, [2] = true }, {})):toBe(
			"Waiting for 1 more player…"
		)
	end)

	it("never waits on a seat that left", function()
		expect(DecisionLogic.waitingNotice(true, ids, { [1] = true, [2] = true }, { [3] = true })):toBe(
			"Everyone's ready. Starting…"
		)
	end)

	it("tells a spectator who they're waiting on", function()
		expect(DecisionLogic.waitingNotice(false, ids, {}, {})):toBe("Waiting for the finalists…")
	end)
end)
