--!strict
-- Covers AnnounceLogic.luau: tidying and capping the text, the per-staff
-- cooldown, the cross-server message (size, parsing, staleness, repeats)
-- and the banner's queue and hold time (staff-tools.md step 6).
-- AnnounceService and AnnouncementController touch TextService,
-- MessagingService and the screen, so they're exercised in Studio.

local TestRunner = require("./TestRunner")
local AnnounceLogic = require("../src/shared/AnnounceLogic")

local describe, it, expect = TestRunner.describe, TestRunner.it, TestRunner.expect

local function message(text: string): AnnounceLogic.Message
	return { id = "11111111-2222-3333-4444-555555555555", text = text, from = "Corvus", sentAt = 1000 }
end

describe("AnnounceLogic.clean", function()
	it("tidies newlines, tabs and runs of spaces, and trims the ends", function()
		expect(AnnounceLogic.clean("  Double\ncoins\t\tthis   hour!  ")):toBe("Double coins this hour!")
	end)

	it("refuses nothing, only spaces, and non-strings", function()
		for _, text in { "", "   ", "\n\t", 42, nil :: any } do
			local cleaned, why = AnnounceLogic.clean(text)
			expect(cleaned):toBe(nil)
			expect(why):toBe("Type a message")
		end
	end)

	it("counts characters, not bytes, against the cap", function()
		local atCap = string.rep("é", AnnounceLogic.MAX_CHARS) -- 2 bytes each
		expect(AnnounceLogic.clean(atCap)):toBe(atCap)
		local cleaned, why = AnnounceLogic.clean(atCap .. "x")
		expect(cleaned):toBe(nil)
		expect(why):toBe(
			string.format("Keep it to %d characters (it's %d)", AnnounceLogic.MAX_CHARS, AnnounceLogic.MAX_CHARS + 1)
		)
	end)

	it("refuses broken UTF-8", function()
		local cleaned, why = AnnounceLogic.clean("hi \255")
		expect(cleaned):toBe(nil)
		expect(why ~= nil):toBe(true)
	end)

	it("lets the most characters in fit under Net's byte cap", function()
		expect(AnnounceLogic.MAX_BYTES):toBe(480) -- Net.luau StaffAnnounceIntent maxLength, copied
		expect(#string.rep("😀", AnnounceLogic.MAX_CHARS) <= AnnounceLogic.MAX_BYTES):toBe(true)
	end)
end)

describe("AnnounceLogic.counter", function()
	it("shows typed / cap and flags going over", function()
		local line, over = AnnounceLogic.counter("hello")
		expect(line):toBe(string.format("5/%d", AnnounceLogic.MAX_CHARS))
		expect(over):toBe(false)
		local _, longOver = AnnounceLogic.counter(string.rep("a", AnnounceLogic.MAX_CHARS + 1))
		expect(longOver):toBe(true)
	end)
end)

describe("AnnounceLogic.isFilteredOut", function()
	it("is true only when the filter left nothing but hashes", function()
		expect(AnnounceLogic.isFilteredOut("#### ###")):toBe(true)
		expect(AnnounceLogic.isFilteredOut("")):toBe(true)
		expect(AnnounceLogic.isFilteredOut("hello ####")):toBe(false)
	end)
end)

describe("AnnounceLogic.checkCooldown", function()
	it("lets a first announcement through", function()
		expect(AnnounceLogic.checkCooldown(nil, 100, 10)):toBe(true)
	end)

	it("holds the next one until the cooldown is up, saying how long", function()
		local ok, wait = AnnounceLogic.checkCooldown(100, 103, 10)
		expect(ok):toBe(false)
		expect(wait):toBe(7)
		expect(AnnounceLogic.checkCooldown(100, 110, 10)):toBe(true)
	end)

	it("never blocks with a zero cooldown", function()
		expect(AnnounceLogic.checkCooldown(100, 100, 0)):toBe(true)
	end)
end)

describe("AnnounceLogic message size", function()
	it("fits a full-length message, worst-case characters and all", function()
		local worst = string.rep("😀", AnnounceLogic.MAX_CHARS)
		expect(AnnounceLogic.fits(message(worst))):toBe(true)
	end)

	it("counts quotes and backslashes twice, as JSON escapes them", function()
		local plain = AnnounceLogic.encodedSize(message("aa"))
		expect(AnnounceLogic.encodedSize(message('""'))):toBe(plain + 2)
		expect(AnnounceLogic.encodedSize(message("\\\\"))):toBe(plain + 2)
	end)

	it("refuses one over MessagingService's limit", function()
		expect(AnnounceLogic.fits(message(string.rep('"', 500)))):toBe(false)
	end)
end)

describe("AnnounceLogic.parse", function()
	it("takes a well-formed message", function()
		local parsed = AnnounceLogic.parse(message("Hi all")) :: AnnounceLogic.Message
		expect(parsed.text):toBe("Hi all")
		expect(parsed.from):toBe("Corvus")
		expect(parsed.sentAt):toBe(1000)
	end)

	it("drops junk off the topic", function()
		local good = message("Hi all") :: any
		for _, change in
			{
				function(m)
					m.id = nil
				end,
				function(m)
					m.text = ""
				end,
				function(m)
					m.text = string.rep("a", AnnounceLogic.MAX_BYTES + 1)
				end,
				function(m)
					m.from = 7
				end,
				function(m)
					m.sentAt = "now"
				end,
				function(m)
					m.sentAt = 0 / 0
				end,
			} :: { (any) -> () }
		do
			local bad = table.clone(good)
			change(bad)
			expect(AnnounceLogic.parse(bad)):toBe(nil)
		end
		expect(AnnounceLogic.parse("Hi")):toBe(nil)
		expect(AnnounceLogic.parse(nil)):toBe(nil)
	end)
end)

describe("AnnounceLogic.isStale", function()
	it("drops one that arrives too late, keeps one from a clock a little ahead", function()
		expect(AnnounceLogic.isStale(1000, 1000 + AnnounceLogic.MAX_AGE_SECONDS)):toBe(false)
		expect(AnnounceLogic.isStale(1000, 1001 + AnnounceLogic.MAX_AGE_SECONDS)):toBe(true)
		expect(AnnounceLogic.isStale(1005, 1000)):toBe(false)
	end)
end)

describe("AnnounceLogic.remember", function()
	it("shows an id once, so a server's own publish isn't shown twice", function()
		local seen = AnnounceLogic.newSeen()
		expect(AnnounceLogic.remember(seen, "a")):toBe(true)
		expect(AnnounceLogic.remember(seen, "a")):toBe(false)
		expect(AnnounceLogic.remember(seen, "b")):toBe(true)
	end)

	it("forgets the oldest past the cap", function()
		local seen = AnnounceLogic.newSeen()
		for i = 1, AnnounceLogic.SEEN_CAP + 1 do
			AnnounceLogic.remember(seen, tostring(i))
		end
		expect(#seen.order):toBe(AnnounceLogic.SEEN_CAP)
		expect(AnnounceLogic.remember(seen, "1")):toBe(true)
		expect(AnnounceLogic.remember(seen, tostring(AnnounceLogic.SEEN_CAP + 1))):toBe(false)
	end)
end)

describe("AnnounceLogic banner", function()
	it("reads a payload, refusing a malformed one", function()
		local banner = AnnounceLogic.readBanner({ text = "Hi", from = "Corvus" }) :: AnnounceLogic.Banner
		expect(banner.text):toBe("Hi")
		expect(banner.from):toBe("Corvus")
		expect(AnnounceLogic.readBanner({ text = "Hi" })):toBe(nil)
		expect(AnnounceLogic.readBanner({ text = "", from = "Corvus" })):toBe(nil)
		expect(AnnounceLogic.readBanner(5)):toBe(nil)
	end)

	it("takes the longest display name in any script (20 characters, 80 bytes)", function()
		local name = string.rep("😀", 20)
		expect(AnnounceLogic.readBanner({ text = "Hi", from = name }) ~= nil):toBe(true)
		local m = message("Hi") :: any
		m.from = name
		expect(AnnounceLogic.parse(m) ~= nil):toBe(true)
	end)

	it("holds for the reading time, within the bounds", function()
		expect(AnnounceLogic.holdSeconds("Hi", 4, 10)):toBe(4)
		expect(AnnounceLogic.holdSeconds(string.rep("a", 90), 4, 10)):toBe(7.5)
		expect(AnnounceLogic.holdSeconds(string.rep("a", 120), 4, 6)):toBe(6)
	end)

	it("keeps the newest few waiting, dropping the oldest", function()
		local queue = {}
		for i = 1, AnnounceLogic.QUEUE_CAP + 2 do
			AnnounceLogic.enqueue(queue, { text = tostring(i), from = "Corvus" })
		end
		expect(#queue):toBe(AnnounceLogic.QUEUE_CAP)
		expect(queue[1].text):toBe("3")
		expect(queue[#queue].text):toBe(tostring(AnnounceLogic.QUEUE_CAP + 2))
	end)
end)

describe("AnnounceLogic.appendAudit", function()
	it("adds the entry, keeps the newest `cap` and drops junk", function()
		local entry = { at = 1, staffUserId = 7, typed = "hi", shown = "hi", reachedEveryServer = true }
		local log = AnnounceLogic.appendAudit({ "junk", entry }, entry, 1)
		expect(#log):toBe(1)
		expect(#AnnounceLogic.appendAudit(nil, entry, 5)):toBe(1)
	end)
end)
