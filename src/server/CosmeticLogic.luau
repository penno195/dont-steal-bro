--!strict
-- The cosmetics system's rules (P4-6), as arithmetic: which equip slot a
-- category lives in, whether a slot and an item's category actually
-- match, and looking an item up by id. CosmeticService.luau is the
-- Roblox-touching wrapper that reads real profiles and applies real
-- Instances to real characters.
--
-- ===== WHY SLOT-MATCHING IS CHECKED HERE, NOT JUST IN THE SCHEMA ========
--
-- DataService.setEquippedCosmetic and StoreLogic.canEquipCosmetic (P4-5)
-- both take `slot` as an arbitrary client-chosen string - neither one
-- knows what a "Trail" is, on purpose, because P4-5 was written before
-- the cosmetics registry existed. That leaves one gap open: a client
-- that owns a trail could ask to equip it into the "skin" slot, and
-- nothing upstream of CosmeticService would refuse it. `matchesSlot`
-- closes that gap - see CosmeticService's own equip handler for where
-- it's enforced.

local CosmeticLogic = {}

-- Structurally identical to Validate.CosmeticDef, duplicated rather than
-- required for the reason TitleLogic.TitleDef's header gives: a Roblox
-- Instance-path require would make this module unloadable under Lune,
-- and Luau's structural typing means a real CosmeticDef satisfies this
-- with no cast at the call site.
export type CosmeticDef = {
	id: string,
	category: "Skin"
		| "Trail"
		| "Emote"
		| "Podium"
		| "Reveal"
		| "Projectile"
		| "StreakFlair"
		| "Nameplate"
		| "CallingCard"
		| "Hat"
		| "BackItem",
	displayName: string,
	description: string,
	rarity: "Common" | "Uncommon" | "Rare",
	sortOrder: number,
	enabled: boolean,
	shirtAssetId: number?,
	pantsAssetId: number?,
	trailTextureAssetId: number?,
	trailColorHex: string?,
	trailLifetime: number?,
	animationAssetId: number?,
	podiumTextureAssetId: number?,
	podiumColorHex: string?,
	revealTextureAssetId: number?,
	revealSoundAssetId: number?,
	projectileMeshAssetId: number?,
	explosionTextureAssetId: number?,
	flairTextureAssetId: number?,
	flairColorHex: string?,
	nameplateFrameAssetId: number?,
	nameplateColorHex: string?,
	cardImageAssetId: number?,
	wearMeshAssetId: number?,
	wearTextureAssetId: number?,
	wearScale: number?,
	wearOffset: { number }?,
	wearRotation: { number }?,
	previewIconAssetId: number?,
}

-- One canonical slot name per category - the single place that mapping
-- is written, so a category and its slot can never drift apart the way
-- two independently-typed strings could.
local SLOT_FOR_CATEGORY: { [string]: string } = {
	Skin = "skin",
	Trail = "trail",
	Emote = "emote",
	Podium = "podium",
	Reveal = "reveal",
	Projectile = "projectile",
	StreakFlair = "streakFlair",
	Nameplate = "nameplate",
	CallingCard = "callingCard",
	Hat = "hat",
	BackItem = "backItem",
}

-- Where each wearable sits: the character attachment its Accessory
-- welds to (on both R6 and R15 rigs), and the Roblox AccessoryType of
-- the player's own items it hides while worn.
local WEAR_SPOT: { [string]: { attachment: string, accessoryType: string } } = {
	Hat = { attachment = "HatAttachment", accessoryType = "Hat" },
	BackItem = { attachment = "BodyBackAttachment", accessoryType = "Back" },
}

function CosmeticLogic.wearAttachmentFor(category: string): string?
	local spot = WEAR_SPOT[category]
	return if spot ~= nil then spot.attachment else nil
end

-- Whether one of the player's own accessories clashes with a worn
-- `category` item and should be hidden: same AccessoryType, or (older
-- items left as "Unknown") welded at the same attachment. Takes the
-- Enum item's Name and the Handle's Attachment names as plain strings,
-- so it stays testable without Roblox.
function CosmeticLogic.clashesWith(category: string, accessoryType: string, attachmentNames: { string }): boolean
	local spot = WEAR_SPOT[category]
	if spot == nil then
		return false
	end
	return accessoryType == spot.accessoryType or table.find(attachmentNames, spot.attachment) ~= nil
end

function CosmeticLogic.slotFor(category: string): string?
	return SLOT_FOR_CATEGORY[category]
end

-- Whether a client-chosen slot string is the one this category actually
-- lives in. An unrecognised category matches nothing.
function CosmeticLogic.matchesSlot(category: string, slot: string): boolean
	return SLOT_FOR_CATEGORY[category] == slot
end

function CosmeticLogic.findById(cosmetics: { CosmeticDef }, id: string?): CosmeticDef?
	if id == nil then
		return nil
	end
	for _, def in cosmetics do
		if def.id == id then
			return def
		end
	end
	return nil
end

-- What a player is wearing in `category`'s slot, or nil. A stale id - an
-- item since removed, disabled, or of another category - reads as
-- nothing equipped rather than as something half-drawn.
function CosmeticLogic.equippedIn(
	cosmetics: { CosmeticDef },
	equipped: { [string]: string },
	category: string
): CosmeticDef?
	local slot = SLOT_FOR_CATEGORY[category]
	if slot == nil then
		return nil
	end
	local def = CosmeticLogic.findById(cosmetics, equipped[slot])
	if def == nil or def.category ~= category or not def.enabled then
		return nil
	end
	return def
end

-- The one check CosmeticService needs before applying anything: the
-- item exists, is enabled (has a real asset), and belongs in the slot
-- the request named. Ownership itself is DataService's job, exactly the
-- defence-in-depth split StoreLogic.canEquipCosmetic and TitleLogic.
-- canEquip already use - this is the category-aware check layered on
-- top of P4-5's ownership-only one.
function CosmeticLogic.canApply(cosmetics: { CosmeticDef }, slot: string, itemId: string?): (boolean, string?)
	if itemId == nil then
		return true, nil -- unequipping is always allowed
	end
	local def = CosmeticLogic.findById(cosmetics, itemId)
	if def == nil then
		return false, string.format("%q is not a registered cosmetic", itemId)
	end
	if not def.enabled then
		return false, string.format("%q has no Roblox asset yet", itemId)
	end
	if not CosmeticLogic.matchesSlot(def.category, slot) then
		return false, string.format("%q is a %s, not a %s", itemId, def.category, slot)
	end
	return true, nil
end

return CosmeticLogic
