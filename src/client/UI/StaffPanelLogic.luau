--!strict
-- The staff panel's rules (staff-tools.md step 4; design-decisions.md
-- "Applied case: staff tools"), kept free of Roblox calls so they're
-- tested headlessly (tests/StaffPanelLogic.spec.luau). MenuController
-- owns the data, Screens/StaffPanel draws it.
--
-- The panel is a convenience, not a gate: StaffService checks the
-- sender against liveOps.adminUserIds and re-checks every field
-- (StaffGrantLogic), whatever this lets through. What it does decide is
-- that the panel only ever sends a StaffGrantIntent the server would
-- take, so a refusal means something changed (the player left), not
-- that the panel built a bad payload.
--
-- Names only, never a streak or a title (Q7 condition 1).

local StaffPanelLogic = {}

-- StaffGrantLogic.GIFT_KINDS, copied (a client module can't require a
-- server one, the same reason Net.luau copies it) - change all three
-- together.
export type Kind = "Currency" | "Cosmetic" | "NavigationRound" | "UnlimitedNavigation" | "StreakSave"

export type KindDef = {
	kind: Kind,
	label: string,
	icon: string, -- Components/Icons
	takesAmount: boolean,
	presets: { number }, -- quick-pick amounts, empty when no amount
}

StaffPanelLogic.KINDS = {
	{ kind = "Currency", label = "Coins", icon = "coin", takesAmount = true, presets = { 100, 500, 1000 } },
	{ kind = "Cosmetic", label = "Cosmetic", icon = "gem", takesAmount = false, presets = {} },
	{
		kind = "NavigationRound",
		label = "Navigation rounds",
		icon = "arrow",
		takesAmount = true,
		presets = { 1, 5, 10 },
	},
	{ kind = "UnlimitedNavigation", label = "Unlimited Navigation", icon = "arrow", takesAmount = false, presets = {} },
	{ kind = "StreakSave", label = "Streak Saves", icon = "shield", takesAmount = true, presets = { 1, 3, 5 } },
} :: { KindDef }

-- StaffGrantLogic.MAX_AMOUNT: a ceiling on the number (it has to stay an
-- exact integer in a DataStore), not a cap. Staff gifts have no caps.
StaffPanelLogic.MAX_AMOUNT = 2147483647

local byKind: { [string]: KindDef } = {}
for _, def in StaffPanelLogic.KINDS do
	byKind[def.kind] = def
end

function StaffPanelLogic.kindDef(kind: string): KindDef?
	return byKind[kind]
end

-- Whether to show the panel's launcher button at all. The list is the
-- shared GameConfig's, so any client can read it; the server's check is
-- the one that counts.
function StaffPanelLogic.isStaff(userId: number, adminUserIds: { number }): boolean
	return table.find(adminUserIds, userId) ~= nil
end

-- ===== the form ============================================================

export type Selection = {
	target: "Player" | "Server",
	userId: number?, -- the chosen player, for a Player target
	kind: Kind,
	amountText: string, -- what's in the amount box
	cosmeticId: string?,
}

-- The amount box's text as a whole number of at least 1, or nil.
-- Commas and spaces are allowed ("10,000").
function StaffPanelLogic.parseAmount(text: string): number?
	local digits = string.gsub(text, "[%s,]", "")
	if string.match(digits, "^%d+$") == nil then
		return nil
	end
	local n = tonumber(digits)
	if n == nil or n < 1 or n > StaffPanelLogic.MAX_AMOUNT then
		return nil
	end
	return n
end

-- The StaffGrantIntent to send for a selection, or what's missing.
-- `inServer` is the user ids in this server right now. Fields a kind
-- doesn't use are left out, as StaffGrantLogic.checkGift insists.
function StaffPanelLogic.payload(selection: Selection, inServer: { number }): ({ [string]: any }?, string?)
	local out: { [string]: any } = { target = selection.target, kind = selection.kind }
	if selection.target == "Player" then
		if selection.userId == nil or table.find(inServer, selection.userId) == nil then
			return nil, "Pick a player"
		end
		out.targetUserId = selection.userId
	elseif #inServer == 0 then
		return nil, "Nobody is in this server"
	end

	local def = byKind[selection.kind]
	if def == nil then
		return nil, "Pick an item"
	end
	if def.takesAmount then
		local amount = StaffPanelLogic.parseAmount(selection.amountText)
		if amount == nil then
			return nil, "Enter an amount of at least 1"
		end
		out.amount = amount
	end
	if selection.kind == "Cosmetic" then
		if selection.cosmeticId == nil then
			return nil, "Pick a cosmetic"
		end
		out.cosmeticId = selection.cosmeticId
	end
	return out, nil
end

local function counted(n: number, one: string, many: string): string
	return string.format("%d %s", n, if n == 1 then one else many)
end

-- What the Give button will do, in words: "500 coins to Penno",
-- "1 Streak Save to everyone here (6)". For a payload `payload` built.
function StaffPanelLogic.summary(
	payload: { [string]: any },
	playerName: (number) -> string,
	cosmeticName: (string) -> string,
	serverCount: number
): string
	local kind = payload.kind
	local amount = payload.amount or 1
	local what
	if kind == "Currency" then
		what = counted(amount, "coin", "coins")
	elseif kind == "Cosmetic" then
		what = cosmeticName(payload.cosmeticId or "?")
	elseif kind == "NavigationRound" then
		what = counted(amount, "Navigation round", "Navigation rounds")
	elseif kind == "UnlimitedNavigation" then
		what = "Unlimited Navigation"
	else
		what = counted(amount, "Streak Save", "Streak Saves")
	end
	local who = if payload.target == "Server"
		then string.format("everyone here (%d)", serverCount)
		else playerName(payload.targetUserId)
	return what .. " to " .. who
end

-- ===== lists ===============================================================

export type PlayerEntry = {
	userId: number,
	displayName: string,
	name: string,
}

-- "Display (@name)", or just the display name when they're the same.
function StaffPanelLogic.playerLabel(entry: PlayerEntry): string
	if entry.displayName == entry.name then
		return entry.displayName
	end
	return string.format("%s (@%s)", entry.displayName, entry.name)
end

local function byLower(a: string, b: string, tieA: string, tieB: string): boolean
	local la, lb = string.lower(a), string.lower(b)
	if la ~= lb then
		return la < lb
	end
	return tieA < tieB
end

-- By display name, case-insensitive (username breaks ties). A copy.
function StaffPanelLogic.sortPlayers(players: { PlayerEntry }): { PlayerEntry }
	local out = table.clone(players)
	table.sort(out, function(a, b)
		return byLower(a.displayName, b.displayName, a.name, b.name)
	end)
	return out
end

export type CosmeticEntry = {
	id: string,
	name: string,
	category: string,
}

-- By category, then name, case-insensitive (id breaks ties). A copy.
function StaffPanelLogic.sortCosmetics(cosmetics: { CosmeticEntry }): { CosmeticEntry }
	local out = table.clone(cosmetics)
	table.sort(out, function(a, b)
		if a.category ~= b.category then
			return a.category < b.category
		end
		return byLower(a.name, b.name, a.id, b.id)
	end)
	return out
end

-- ===== the reply ===========================================================

export type Result = {
	ok: boolean,
	message: string,
}

-- A StaffGrantResult payload, or nil if it's malformed. The server's
-- message is lower case mid-sentence ("gave 5 coins to 1 player"), so
-- it's capitalised for a line of its own.
function StaffPanelLogic.readResult(payload: any): Result?
	if type(payload) ~= "table" or type(payload.ok) ~= "boolean" or type(payload.message) ~= "string" then
		return nil
	end
	local message = payload.message
	return {
		ok = payload.ok,
		message = string.upper(string.sub(message, 1, 1)) .. string.sub(message, 2),
	}
end

return StaffPanelLogic
