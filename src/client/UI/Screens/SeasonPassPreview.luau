--!strict
-- Device review for the store's Season tab (next-stages.md 1a): the real
-- Store screen on its Season tab, fed the first season's config and a
-- scripted fake StoreState instead of remotes, so the pass screen can be
-- screenshotted while no season is live. The UISeasonPassScene attribute
-- (1-4, default 2) picks the scene: pass not bought, pass items reached
-- but not bought, pass bought with rewards waiting, and the whole season
-- claimed. Claim taps work, the way the server would pay them
-- (SeasonLogic.claim), so the claimed look can be checked too.
--
-- Mounted by UIScaleController when ReplicatedStorage has the
-- UISeasonPassPreview attribute set. Debug only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local Season1 = require(ReplicatedStorage.Shared.Config.Seasons.Season1)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local ClaimPopup = require(script.Parent.ClaimPopup)
local SeasonPass = require(ReplicatedStorage.Shared.Config.Store.SeasonPass)
local SeasonTrackLogic = require(script.Parent.Parent.SeasonTrackLogic)
local StoreScreenLogic = require(script.Parent.Parent.StoreScreenLogic)
local Store = require(script.Parent.Store)

local source = vide.source

local SCENE_ATTRIBUTE = "UISeasonPassScene"
local DAY = 86400

type Scene = {
	passSeen: boolean,
	wins: number,
	freePaid: number,
	premiumPaid: number,
}

local SCENES: { Scene } = {
	{ passSeen = false, wins = 4, freePaid = 1, premiumPaid = 0 },
	{ passSeen = false, wins = 12, freePaid = 1, premiumPaid = 0 },
	{ passSeen = true, wins = 12, freePaid = 1, premiumPaid = 1 },
	{ passSeen = true, wins = 30, freePaid = 3, premiumPaid = 5 },
}

local function grantText(grant: StoreScreenLogic.Grant): string
	if grant.kind == "Currency" then
		return string.format("%d coins", grant.amount or 0)
	elseif grant.kind == "PowerUpStock" then
		return string.format("%dx %s", grant.amount or 1, grant.powerUpId or "?")
	elseif grant.kind == "Cosmetic" then
		return grant.cosmeticId or "?"
	end
	return grant.kind
end

-- The real items' pictures, as MenuController shows them.
local previewIcons: { [string]: number } = {}
for _, entry in Cosmetics do
	local id = entry.def.previewIconAssetId
	if id ~= nil and id > 0 then
		previewIcons[entry.def.id] = id
	end
end

local function grantImage(grant: SeasonTrackLogic.Grant): number?
	return if grant.kind == "Cosmetic" and grant.cosmeticId then previewIcons[grant.cosmeticId] else nil
end

local SeasonPassPreview = {}

function SeasonPassPreview.mount(controller: any): () -> ()
	local state = source(nil :: StoreScreenLogic.StoreState?)
	local def = Season1 :: any

	local function show(scene: Scene)
		state({
			currency = 1250,
			powerUpStock = {},
			loadout = {},
			ownedCosmetics = {},
			equipped = {},
			ownedPasses = {},
			loadoutSlots = 3,
			season = {
				id = def.id,
				secondsLeft = 22 * DAY,
				passSeen = scene.passSeen,
				freeWins = scene.wins,
				premiumWins = scene.wins,
				freePaid = scene.freePaid,
				premiumPaid = scene.premiumPaid,
			},
		})
	end

	local function pick()
		local n = ReplicatedStorage:GetAttribute(SCENE_ATTRIBUTE)
		show(SCENES[if type(n) == "number" and SCENES[n] then n else 2])
	end
	local sceneChanged = ReplicatedStorage:GetAttributeChangedSignal(SCENE_ATTRIBUTE):Connect(pick)
	pick()

	-- SeasonLogic.claim's rule on the fake state: a track pays up to
	-- `upTo` (all of it for Claim All) as far as the wins reach, premium
	-- only with the pass.
	local function claim(track: ("Free" | "Premium")?, upTo: number?)
		local s = state()
		local season = if s then table.clone(s.season :: any) else nil
		if s == nil or season == nil then
			return
		end
		local function settle(items: { any }, paid: number, unlocked: boolean): number
			if not unlocked then
				return paid
			end
			local limit = if track == nil then #items else upTo or 0
			while paid < math.min(limit, #items) and items[paid + 1].wins <= season.freeWins do
				paid += 1
			end
			return paid
		end
		if track == nil or track == "Free" then
			season.freePaid = settle(def.free, season.freePaid, true)
		end
		if track == nil or track == "Premium" then
			season.premiumPaid = settle(def.premium, season.premiumPaid, season.passSeen)
		end
		local after = table.clone(s)
		after.season = season
		-- The pop-up and its sound, as MenuController shows them for a
		-- real claim.
		local rewards = SeasonTrackLogic.claimedBetween(def, s.season :: any, season)
		if #rewards > 0 then
			local shown: { ClaimPopup.Reward } = {}
			for _, reward in rewards do
				table.insert(shown, {
					premium = reward.premium,
					text = grantText(reward.grant :: any),
					icon = SeasonTrackLogic.iconFor(reward.grant),
					image = grantImage(reward.grant),
				})
			end
			ClaimPopup.open(shown)
			-- Debug screen: reaches the controller directly, which shipping
			-- UI modules don't.
			Loader.get("AudioController").play("SeasonClaim")
		end
		state(after)
	end

	-- Shown as live whatever its `enabled` says: this is a preview.
	local pass: StoreScreenLogic.Item = table.clone(SeasonPass :: any)
	pass.enabled = true

	local unmount = Store.mount(controller, {
		items = { pass },
		initialCategory = "Season",
		rarityOf = function()
			return nil
		end,
		grantText = grantText,
		cosmeticName = function(id: string)
			return id
		end,
		state = state,
		flow = function()
			return StoreScreenLogic.idle()
		end,
		buy = function() end,
		dismiss = function() end,
		equip = function() end,
		seasonView = function(): SeasonTrackLogic.View?
			local s = state()
			if s == nil or s.season == nil then
				return nil
			end
			return SeasonTrackLogic.view(def, s.season :: any, grantText :: any, grantImage)
		end,
		passKeyOf = function()
			return def.passKey
		end,
		claim = claim,
		close = function()
			ReplicatedStorage:SetAttribute("UISeasonPassPreview", nil)
		end,
	})
	return function()
		sceneChanged:Disconnect()
		unmount()
	end
end

return SeasonPassPreview
