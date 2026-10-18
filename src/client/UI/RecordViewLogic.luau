--!strict
-- The pure half of the Hub's "Your record" panel (payoff-loop step 7;
-- design-decisions.md Q5's betrayal applied case): reading StoreState's
-- `record` and what the panel says. No Roblox API, no requires; tested
-- under Lune (tests/RecordViewLogic.spec).
--
-- The server sends `record` on the Hub only, to its owner
-- (StoreService.recordCard), so a match server never shows it.

local RecordViewLogic = {}

-- StoreState.record: your own lifetime Studio choices.
export type Record = { steals: number, shares: number, betrayed: number }

local function isCount(value: any): boolean
	return type(value) == "number" and value == value and value >= 0
end

-- A record, checked for shape. nil (off the Hub, or malformed) hides
-- the launcher's button.
function RecordViewLogic.parse(value: any): Record?
	if
		type(value) ~= "table"
		or not isCount(value.steals)
		or not isCount(value.shares)
		or not isCount(value.betrayed)
	then
		return nil
	end
	return { steals = value.steals, shares = value.shares, betrayed = value.betrayed }
end

RecordViewLogic.TITLE = "Your record"
RecordViewLogic.BUTTON_LABEL = "Your record"

-- The panel's body. The robbed line says what it counts, since "robbed"
-- has a narrow meaning here: you shared and a lone stealer took it all.
function RecordViewLogic.body(record: Record): string
	if record.steals + record.shares <= 0 then
		return "No Studio choices yet.\nReach the Decision Studio to start your record."
	end
	local robbed = if record.betrayed > 0
		then string.format("Robbed: %d× (you shared, a lone stealer took it all)", record.betrayed)
		else "Never robbed yet."
	return string.format("Shared: %d\nStole: %d\n%s", record.shares, record.steals, robbed)
end

return RecordViewLogic
