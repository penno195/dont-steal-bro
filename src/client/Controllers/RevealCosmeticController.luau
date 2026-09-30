--!strict
-- Draws the "Reveal" cosmetic: a one-shot burst on a finalist's podium
-- the instant their Steal/Share card turns face up.
--
-- WHEN: at DecisionLogic.cardTurnAt of that finalist's position in THIS
-- screen's revealOrder, because the order differs per screen (your own
-- card turns first). The burst and the card always land together, and
-- never before the choice is shown - a burst early would leak it.
--
-- COLOUR: the choice's own Steal/Share colour, never the item's. See
-- Validate.CosmeticDef's header: a reveal's colour already means
-- something, so the item only supplies the texture (and optionally a
-- sound).
--
-- SOUND: not played here. AudioController plays it IN PLACE OF that
-- card's RevealCard cue (soundsByCard below), through the SFX group, so
-- it replaces the default rather than doubling it and obeys the slider.
--
-- Purely visual and client-side. Which item each finalist wears comes in
-- DecisionReveal from the server, read from their own profile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Clock = require(ReplicatedStorage.Shared.Clock)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local DecisionLogic = require(script.Parent.Parent.UI.DecisionLogic)
local Theme = require(script.Parent.Parent.UI.Theme)

local selfId = game:GetService("Players").LocalPlayer.UserId

local BURST_NAME = "DSBRevealBurst"
local BURST_PARTICLES = 24
local BURST_SECONDS = 1.5 -- emitter lifetime; cleaned up after
-- A packet that lands this late past a card's turn still bursts; any
-- later and the moment has passed (same tolerance FeelController uses).
local LATE_TOLERANCE = 0.25

type RevealItem = { textureAssetId: number, soundAssetId: number? }

-- Reveal id -> what to draw. Enabled items only, so an unknown or
-- disabled id bursts nothing.
local revealDefs: { [string]: RevealItem } = {}
for _, entry in Cosmetics do
	local def = entry.def
	if def.category == "Reveal" and def.enabled then
		local sound = def.revealSoundAssetId
		revealDefs[def.id] = {
			textureAssetId = def.revealTextureAssetId :: number,
			soundAssetId = if sound ~= nil and sound > 0 then sound else nil,
		}
	end
end

-- Bumped on every round-state change out of the Studio, so a burst still
-- scheduled from a reveal that's over never fires into the next round.
local roundToken = 0

local function burst(racerId: number, item: RevealItem, isSteal: boolean)
	local nametags = Loader.get("NametagController") :: any
	local character = nametags.characterFor(racerId) :: Model?
	local root = if character ~= nil then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = BURST_NAME
	emitter.Texture = string.format("rbxassetid://%d", item.textureAssetId)
	emitter.Color = ColorSequence.new(if isSteal then Theme.color.steal else Theme.color.share)
	emitter.LightInfluence = 0
	emitter.Rate = 0 -- one-shot: only Emit below
	emitter.Lifetime = NumberRange.new(0.6, 1)
	emitter.Speed = NumberRange.new(6, 10)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Parent = root
	emitter:Emit(BURST_PARTICLES)

	task.delay(BURST_SECONDS, function()
		emitter:Destroy()
	end)
end

type Card = { index: number, racerId: number, item: RevealItem, isSteal: boolean }

-- Every card on THIS screen whose finalist wears an enabled Reveal item,
-- by its position in this screen's reveal order.
local function cardsFor(payload: any, reveal: DecisionLogic.Reveal): { Card }
	local cards: { Card } = {}
	local worn = DecisionLogic.parseRevealCosmetics(payload.revealCosmetics)
	if next(worn) == nil then
		return cards
	end
	local seatIds = (Loader.get("DecisionStudioController") :: any).getSeatIds() :: { number }
	for index, racerId in DecisionLogic.revealOrder(seatIds, reveal.choices, selfId) do
		local itemId = worn[racerId]
		local item = if itemId ~= nil then revealDefs[itemId] else nil
		local choice = reveal.choices[racerId]
		if item ~= nil and choice ~= nil then
			table.insert(cards, { index = index, racerId = racerId, item = item, isSteal = choice == "Steal" })
		end
	end
	return cards
end

local function onReveal(payload: any)
	local reveal = DecisionLogic.parseReveal(payload)
	if reveal == nil then
		return
	end
	local token = roundToken
	for _, card in cardsFor(payload, reveal) do
		local delay = reveal.revealAt + DecisionLogic.cardTurnAt(card.index) - Clock.now()
		if delay >= -LATE_TOLERANCE then
			task.delay(math.max(0, delay), function()
				if token == roundToken then
					burst(card.racerId, card.item, card.isSteal)
				end
			end)
		end
	end
end

local RevealCosmeticController: Loader.Controller = {
	name = "RevealCosmeticController",
	dependencies = { "NametagController", "DecisionStudioController" },

	-- Card position -> the Reveal item's own sound asset id, for
	-- AudioController to play in place of that card's RevealCard cue.
	-- Cards with no item, or an item with no sound, are absent.
	soundsByCard = function(payload: any, reveal: DecisionLogic.Reveal): { [number]: number }
		local out: { [number]: number } = {}
		for _, card in cardsFor(payload, reveal) do
			if card.item.soundAssetId ~= nil then
				out[card.index] = card.item.soundAssetId :: number
			end
		end
		return out
	end,
}

function RevealCosmeticController:init()
	Net.onClientEvent("RoundState", function(payload: any)
		local state = if type(payload) == "table" then payload.state else nil
		if state == "Loading" or state == "Cleanup" or state == "WaitingForPlayers" then
			roundToken += 1
		end
	end)
	Net.onClientEvent("DecisionReveal", onReveal)
end

return RevealCosmeticController
