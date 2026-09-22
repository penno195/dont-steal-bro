--!strict
-- Cosmetics (P4-6): applying what the store already tracks ownership and
-- equip state for (P4-5) onto real characters - skins, trails, and the
-- Decision Studio podium flourish - plus the victory emote playback hook.
-- The registry is config (src/shared/Config/Cosmetics/), the
-- slot/category rules are pure (src/server/CosmeticLogic.luau, tested
-- headlessly in tests/CosmeticLogic.spec.luau), and this file is what
-- reads real profiles and touches real Instances.
--
-- ===== OWNERSHIP IS NEVER TRUSTED HERE, IT'S RE-DECIDED UPSTREAM ========
--
-- Every equip request already passed StoreService.handleEquipIntent's
-- ownership checks (StoreLogic.canEquipCosmetic against the cached list,
-- then DataService.setEquippedCosmetic against the profile itself)
-- before this file ever sees it. What P4-5 could NOT check is whether
-- the slot a client named actually matches the item's category - it was
-- written before this registry existed, so `canEquip` below (backed by
-- CosmeticLogic.canApply) is the missing gate, called from
-- StoreService.handleEquipIntent BEFORE the profile write, not just
-- applied defensively here at render time. Without it, a client could
-- ask to equip a Skin into the "trail" slot and StoreLogic's
-- ownership-only check would wave it through.
--
-- ===== WHY "Emote" HAS NOTHING TO APPLY ON SPAWN =========================
--
-- Every other category is worn continuously; an emote is a one-shot
-- animation triggered at a moment (a win, a podium reveal) that lives in
-- a later, UI-facing task. `playEquippedEmote` is the hook that moment
-- calls into - loading and playing the equipped emote's Animation - and
-- deliberately nothing calls it yet. That's not a gap: there's nothing
-- to keep "applied" for an emote between one victory and the next.
--
-- ===== INSTANCE-COUNT COST (docs/perf-budget.md) ========================
--
-- perf-budget.md caps "active particle emitters" at under 25
-- simultaneously emitting. A Trail isn't a ParticleEmitter, but it's the
-- same rendering cost class, so the arithmetic is worth doing rather
-- than assuming it's fine: gdd.md's round is 6 racers, each wearing at
-- most one trail, so a full lobby of trails is 6 Instances - nowhere
-- near the budget. Podium is rarer still: map-kit-spec.md fixes exactly
-- 3 StudioPodiumSlots, so at most 3 podium flourishes are ever live at
-- once, and only during the Decision Studio phase. Nothing here needs a
-- rate limit or a pool; the game's own roster caps already are one.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Participants = require(ServerScriptService.Server.Participants)
local CosmeticLogic = require(ServerScriptService.Server.CosmeticLogic)

local catalogue: { CosmeticLogic.CosmeticDef } = {}
for _, entry in Cosmetics do
	table.insert(catalogue, entry.def :: any)
end

-- Every Instance this service creates carries this attribute, so removal
-- can tell "mine, safe to touch" apart from an Instance a player's own
-- avatar legitimately brought with them (a real Shirt, say) without
-- keeping a second side-table of Instance identities to go stale.
local OWNED_ATTRIBUTE = "DSBCosmetic"

local function hexToColor3(hex: string): Color3
	local r = tonumber(string.sub(hex, 2, 3), 16) or 255
	local g = tonumber(string.sub(hex, 4, 5), 16) or 255
	local b = tonumber(string.sub(hex, 6, 7), 16) or 255
	return Color3.fromRGB(r, g, b)
end

-- ===== Skin: Shirt/Pants override, with clean restoration =================
--
-- Captured the first time this service overrides a character's own
-- outfit, so unequipping restores exactly what the player was wearing
-- rather than leaving them naked or leaving a stray empty Shirt/Pants
-- behind. Keyed by the character Model, never the Player, so a mid-round
-- respawn - a brand new Model - starts from ITS OWN real outfit, never a
-- stale capture from the character that just died.
type SkinRestore = { shirtTemplate: string?, pantsTemplate: string? }
local skinRestoreFor: { [Model]: SkinRestore } = {}

local function removeSkin(character: Model)
	local restore = skinRestoreFor[character]
	skinRestoreFor[character] = nil

	local shirt = character:FindFirstChildOfClass("Shirt")
	if shirt ~= nil and shirt:GetAttribute(OWNED_ATTRIBUTE) == true then
		if restore ~= nil and restore.shirtTemplate ~= nil then
			shirt.ShirtTemplate = restore.shirtTemplate
			shirt:SetAttribute(OWNED_ATTRIBUTE, nil)
		else
			shirt:Destroy()
		end
	end

	local pants = character:FindFirstChildOfClass("Pants")
	if pants ~= nil and pants:GetAttribute(OWNED_ATTRIBUTE) == true then
		if restore ~= nil and restore.pantsTemplate ~= nil then
			pants.PantsTemplate = restore.pantsTemplate
			pants:SetAttribute(OWNED_ATTRIBUTE, nil)
		else
			pants:Destroy()
		end
	end
end

local function applySkin(character: Model, def: CosmeticLogic.CosmeticDef)
	-- Clears any cosmetic skin already worn (an equip CHANGE, not just a
	-- first equip) before recapturing "original," so restore never
	-- captures our own previous override as if it were the player's.
	removeSkin(character)

	local shirt = character:FindFirstChildOfClass("Shirt")
	local originalShirtTemplate: string? = nil
	if shirt == nil then
		shirt = Instance.new("Shirt")
		shirt.Parent = character
	else
		originalShirtTemplate = shirt.ShirtTemplate
	end
	shirt:SetAttribute(OWNED_ATTRIBUTE, true)
	shirt.ShirtTemplate = string.format("rbxassetid://%d", def.shirtAssetId :: number)

	local pants = character:FindFirstChildOfClass("Pants")
	local originalPantsTemplate: string? = nil
	if pants == nil then
		pants = Instance.new("Pants")
		pants.Parent = character
	else
		originalPantsTemplate = pants.PantsTemplate
	end
	pants:SetAttribute(OWNED_ATTRIBUTE, true)
	pants.PantsTemplate = string.format("rbxassetid://%d", def.pantsAssetId :: number)

	skinRestoreFor[character] = { shirtTemplate = originalShirtTemplate, pantsTemplate = originalPantsTemplate }
end

-- ===== Trail: our own Instances, always safe to just destroy ==============

local function removeTrail(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart == nil then
		return
	end
	for _, name in { "DSBCosmeticTrail", "DSBCosmeticTrailA", "DSBCosmeticTrailB" } do
		local existing = rootPart:FindFirstChild(name)
		if existing ~= nil then
			existing:Destroy()
		end
	end
end

local function applyTrail(character: Model, def: CosmeticLogic.CosmeticDef)
	removeTrail(character)

	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if rootPart == nil then
		return
	end

	local attachmentA = Instance.new("Attachment")
	attachmentA.Name = "DSBCosmeticTrailA"
	attachmentA.Position = Vector3.new(0, 1, 0)
	attachmentA.Parent = rootPart

	local attachmentB = Instance.new("Attachment")
	attachmentB.Name = "DSBCosmeticTrailB"
	attachmentB.Position = Vector3.new(0, -1.5, 0)
	attachmentB.Parent = rootPart

	local trail = Instance.new("Trail")
	trail.Name = "DSBCosmeticTrail"
	trail.Attachment0 = attachmentA
	trail.Attachment1 = attachmentB
	trail.Texture = string.format("rbxassetid://%d", def.trailTextureAssetId :: number)
	trail.Color = ColorSequence.new(hexToColor3(def.trailColorHex :: string))
	trail.Lifetime = def.trailLifetime :: number
	trail:SetAttribute(OWNED_ATTRIBUTE, true)
	trail.Parent = rootPart
end

-- ===== Podium: gated on the Decision Studio round state, not equip ========

local function removePodium(character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if rootPart == nil then
		return
	end
	local existing = rootPart:FindFirstChild("DSBCosmeticPodium")
	if existing ~= nil then
		existing:Destroy()
	end
end

local function applyPodium(character: Model, def: CosmeticLogic.CosmeticDef)
	removePodium(character)

	local rootPart = character:WaitForChild("HumanoidRootPart", 5)
	if rootPart == nil then
		return
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "DSBCosmeticPodium"
	emitter.Texture = string.format("rbxassetid://%d", def.podiumTextureAssetId :: number)
	emitter.Color = ColorSequence.new(hexToColor3(def.podiumColorHex :: string))
	-- Fixed, low rate rather than a config knob (see this file's header
	-- note on instance-count cost) - "how sparkly" is not something a
	-- content file should be able to trade against the perf budget.
	emitter.Rate = 6
	emitter.Lifetime = NumberRange.new(1, 1.5)
	emitter:SetAttribute(OWNED_ATTRIBUTE, true)
	emitter.Parent = rootPart
end

-- ===== equip-time application ==============================================

-- The category/slot gate StoreService.handleEquipIntent calls BEFORE
-- writing anything to the profile - see this file's header for why P4-5
-- alone can't provide it.
local function canEquip(slot: string, itemId: string?): (boolean, string?)
	return CosmeticLogic.canApply(catalogue, slot, itemId)
end

-- Applies (or clears) skin and trail from a player's currently equipped
-- state onto their live character. Called on every spawn and after every
-- successful equip change - Emote has nothing to apply (see header);
-- Podium is refreshed separately, gated on round state, by
-- refreshAllPodiums below.
local function refreshFor(player: Player)
	local character = player.Character
	if character == nil then
		return
	end
	local DataService = Loader.get("DataService") :: any
	local equipped = DataService.getEquipped(player) :: { [string]: string }

	local skinId = equipped[CosmeticLogic.slotFor("Skin") :: string]
	local skinDef = CosmeticLogic.findById(catalogue, skinId)
	if skinDef ~= nil and skinDef.category == "Skin" and skinDef.enabled then
		applySkin(character, skinDef)
	else
		removeSkin(character)
	end

	local trailId = equipped[CosmeticLogic.slotFor("Trail") :: string]
	local trailDef = CosmeticLogic.findById(catalogue, trailId)
	if trailDef ~= nil and trailDef.category == "Trail" and trailDef.enabled then
		applyTrail(character, trailDef)
	else
		removeTrail(character)
	end
end

-- ===== the victory emote hook ==============================================

-- Plays this player's equipped Emote once, if they have one enabled.
-- Never called from this file - it's the seam a later results/podium
-- task triggers at the moment a win actually happens. Returns whether
-- anything played, so that caller can decide what to do if not.
local function playEquippedEmote(player: Player): boolean
	local DataService = Loader.get("DataService") :: any
	local equipped = DataService.getEquipped(player) :: { [string]: string }
	local itemId = equipped[CosmeticLogic.slotFor("Emote") :: string]
	local def = CosmeticLogic.findById(catalogue, itemId)
	if def == nil or def.category ~= "Emote" or not def.enabled then
		return false
	end

	local character = player.Character
	if character == nil then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil then
		return false
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator == nil then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animation = Instance.new("Animation")
	animation.AnimationId = string.format("rbxassetid://%d", def.animationAssetId :: number)
	local track = animator:LoadAnimation(animation)
	track:Play()
	return true
end

-- ===== Decision Studio podium, keyed to the live finale roster =============
--
-- Only humans get one: NPCs have no profile for DataService.getEquipped
-- to read (Participants.humans()/`.player` is the one legitimate branch
-- on "is this a bot" - see Participants.luau's own header).
local function refreshAllPodiums()
	local DecisionService = Loader.get("DecisionService") :: any
	local DataService = Loader.get("DataService") :: any
	local qualifierIds = DecisionService.getQualifierIds() :: { number }

	for _, racerId in qualifierIds do
		local participant = Participants.get(racerId)
		if participant == nil or participant.player == nil or participant.character == nil then
			continue
		end

		local equipped = DataService.getEquipped(participant.player :: Player) :: { [string]: string }
		local itemId = equipped[CosmeticLogic.slotFor("Podium") :: string]
		local def = CosmeticLogic.findById(catalogue, itemId)
		if def ~= nil and def.category == "Podium" and def.enabled then
			applyPodium(participant.character :: Model, def)
		end
	end
end

local function clearAllPodiums()
	local DecisionService = Loader.get("DecisionService") :: any
	local qualifierIds = DecisionService.getQualifierIds() :: { number }
	for _, racerId in qualifierIds do
		local participant = Participants.get(racerId)
		if participant ~= nil and participant.character ~= nil then
			removePodium(participant.character :: Model)
		end
	end
end

-- ===== service ==============================================================

local CosmeticService: Loader.Service = {
	name = "CosmeticService",
	dependencies = { "ConfigValidator", "DataService", "RoundService", "ParticipantService" },

	canEquip = canEquip,
	refreshFor = refreshFor,
	playEquippedEmote = playEquippedEmote,
}

function CosmeticService:init()
	local RoundService = Loader.get("RoundService") :: any

	Players.PlayerAdded:Connect(function(player: Player)
		player.CharacterAdded:Connect(function()
			refreshFor(player)
		end)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		local character = player.Character
		if character ~= nil then
			skinRestoreFor[character] = nil
		end
	end)

	RoundService.onEnter("DecisionStudio", refreshAllPodiums)
	RoundService.onExit("DecisionStudio", clearAllPodiums)
end

return CosmeticService
