--!strict
-- What a daily or weekly board placement pays (design-decisions.md Q1's
-- 2026-09-30 revision, applied 2026-10-02; rewards-roadmap.md step 4).
--
-- Pure: no Roblox API, so tests/LeaderboardPayoutLogic.spec.luau runs it
-- headlessly. Self-contained on purpose - no requires of sibling files -
-- for the same reason RewardLogic and StoreLogic are.
--
-- A payout travels as a ProfileStore message (ProfileStore:MessageAsync),
-- because the winner is usually offline when their period ends. This
-- module builds that message on the sending server and re-checks it on
-- the receiving one: the message sat in a DataStore in between, so the
-- receiver treats it as data to validate, not as a trusted value.

local LeaderboardPayoutLogic = {}

-- The `type` field every payout message carries. DataService routes
-- profile messages by it, so a future message kind gets its own name.
LeaderboardPayoutLogic.MESSAGE_TYPE = "LeaderboardPayout"

-- One band of places: every rank from the previous band's maxRank + 1 up
-- to this maxRank pays the same. Bands are listed in ascending maxRank,
-- which ConfigValidator enforces.
export type PayoutBand = {
	maxRank: number,
	currency: number,
	-- A limited cosmetic for this band. Cosmetic only, per Q8: no band
	-- can name a power-up, because the field can only hold a cosmetic id.
	cosmeticId: string?,
}

-- Keyed by period kind ("Daily", "Weekly"). A kind with no entry pays
-- nothing; the all-time board is deliberately absent (user decision).
export type PayoutTable = { [string]: { PayoutBand } }

export type PayoutMessage = {
	type: string,
	kind: string,
	periodKey: string,
	rank: number,
	currency: number,
	cosmeticId: string?,
}

-- Structurally StoreLogic.Grant, so it goes straight into
-- StoreLogic.applyGrants - the one grant path purchases and wins share.
export type Grant = {
	kind: "Currency" | "Cosmetic",
	amount: number?,
	cosmeticId: string?,
}

local function isPositiveInteger(value: any): boolean
	return type(value) == "number" and value >= 1 and value == math.floor(value)
end

local function isNonNegativeInteger(value: any): boolean
	return type(value) == "number" and value >= 0 and value == math.floor(value)
end

local function isNonEmptyString(value: any): boolean
	return type(value) == "string" and #value > 0
end

-- The band `rank` falls in, or nil when that rank is unpaid.
function LeaderboardPayoutLogic.bandFor(bands: { PayoutBand }?, rank: number): PayoutBand?
	if bands == nil or rank < 1 then
		return nil
	end
	for _, band in bands do
		if rank <= band.maxRank then
			return band
		end
	end
	return nil
end

-- How many places a kind pays: the last band's maxRank, or 0.
function LeaderboardPayoutLogic.paidPlaces(bands: { PayoutBand }?): number
	if bands == nil or #bands == 0 then
		return 0
	end
	return bands[#bands].maxRank
end

-- The message for one placement, or nil when it pays nothing.
function LeaderboardPayoutLogic.messageFor(
	payouts: PayoutTable,
	kind: string,
	periodKey: string,
	rank: number
): PayoutMessage?
	local band = LeaderboardPayoutLogic.bandFor(payouts[kind], rank)
	if band == nil then
		return nil
	end
	if band.currency <= 0 and band.cosmeticId == nil then
		return nil
	end
	return {
		type = LeaderboardPayoutLogic.MESSAGE_TYPE,
		kind = kind,
		periodKey = periodKey,
		rank = rank,
		currency = band.currency,
		cosmeticId = band.cosmeticId,
	}
end

-- Re-checks a message read back out of a profile. Returns nil for
-- anything malformed, which the receiver logs and drops.
function LeaderboardPayoutLogic.parseMessage(raw: any): PayoutMessage?
	if type(raw) ~= "table" or raw.type ~= LeaderboardPayoutLogic.MESSAGE_TYPE then
		return nil
	end
	if not isNonEmptyString(raw.kind) or not isNonEmptyString(raw.periodKey) then
		return nil
	end
	if not isPositiveInteger(raw.rank) or not isNonNegativeInteger(raw.currency) then
		return nil
	end
	if raw.cosmeticId ~= nil and not isNonEmptyString(raw.cosmeticId) then
		return nil
	end
	return {
		type = raw.type,
		kind = raw.kind,
		periodKey = raw.periodKey,
		rank = raw.rank,
		currency = raw.currency,
		cosmeticId = raw.cosmeticId,
	}
end

function LeaderboardPayoutLogic.grantsFor(message: PayoutMessage): { Grant }
	local grants: { Grant } = {}
	if message.currency > 0 then
		table.insert(grants, { kind = "Currency", amount = message.currency })
	end
	if message.cosmeticId ~= nil then
		table.insert(grants, { kind = "Cosmetic", cosmeticId = message.cosmeticId })
	end
	return grants
end

-- One audit line per applied grant, in the same spirit as
-- ProgressionLogic.formatRewardAudit.
function LeaderboardPayoutLogic.formatAudit(playerName: string, message: PayoutMessage, change: string): string
	return string.format(
		"LeaderboardPayout: %s %s %s rank %d - %s",
		playerName,
		message.kind,
		message.periodKey,
		message.rank,
		change
	)
end

return LeaderboardPayoutLogic
