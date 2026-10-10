--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The hub's three store plinths: the HubStorePodium parts (hub-spec.md),
-- each with a `Slot` (1-3) showing the store item config features there
-- (StoreItemDef.featuredSlot) while it's on sale (design-decisions.md
-- Q1, "the featured plinths").
--
-- WHAT A PLINTH SHOWS: a billboard over it with the item's picture,
-- name and price. A Robux item shows what Roblox really charges, with
-- the config's "was" price struck through and a SALE tag only if that
-- live price is lower; MenuController.priceOf works that out, the same
-- as the store's cards. An empty slot shows nothing.
--
-- OPENING THE STORE: a ProximityPrompt, one tap (owner's call,
-- 2026-10-10: walking past three plinths must not pop menus open). It
-- opens the hub store on that item; buying still goes through the
-- store's panel and StoreService.
--
-- WHEN: hub servers only. The parts may stream in and out; each mounts
-- when it arrives and unmounts when it leaves.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local StoreScreenLogic = require(script.Parent.Parent.UI.StoreScreenLogic)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local derive = vide.derive
local effect = vide.effect

local TAG = "HubStorePodium"
-- The billboard, in studs, and how far over the plinth's top it floats.
local BOARD_W = 6
local BOARD_H = 4.5
local BOARD_LIFT = 3
local BOARD_MAX_DISTANCE = 90
local PROMPT_DISTANCE = 10

local mounted: { [Instance]: () -> () } = {}

local function menu(): any
	return Loader.get("MenuController")
end

local function textLabel(props: { [any]: any })
	local base = {
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = Theme.type.body.font,
		TextColor3 = Theme.color.ink,
	}
	for key, value in props do
		base[key] = value
	end
	return create("TextLabel")(base)
end

local function mount(part: Instance)
	if not part:IsA("BasePart") or mounted[part] ~= nil then
		return
	end
	local slot = part:GetAttribute("Slot")
	if type(slot) ~= "number" then
		warn(string.format("StorePlinthController: %s has no Slot attribute", part:GetFullName()))
		return
	end

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	mounted[part] = vide.root(function()
		local item = derive(function(): StoreScreenLogic.Item?
			return menu().featured()[slot]
		end)
		local price = derive(function(): StoreScreenLogic.Price?
			local i = item()
			return if i then menu().priceOf(i) else nil
		end)

		local gui = create("BillboardGui")({
			Name = "StorePlinth" .. slot,
			Adornee = part,
			Size = UDim2.fromScale(BOARD_W, BOARD_H),
			StudsOffsetWorldSpace = Vector3.new(0, part.Size.Y / 2 + BOARD_LIFT, 0),
			MaxDistance = BOARD_MAX_DISTANCE,
			LightInfluence = 0,
			ResetOnSpawn = false,
			Enabled = function()
				return item() ~= nil
			end,
			create("ImageLabel")({
				Name = "Image",
				Size = UDim2.fromScale(1, 0.58),
				BackgroundTransparency = 1,
				ScaleType = Enum.ScaleType.Fit,
				Image = function()
					local i = item()
					return if i and i.imageAssetId ~= 0 then "rbxassetid://" .. i.imageAssetId else ""
				end,
			}),
			textLabel({
				Name = "Name",
				Position = UDim2.fromScale(0, 0.6),
				Size = UDim2.fromScale(1, 0.18),
				FontFace = Theme.type.title.font,
				TextStrokeTransparency = 0.4,
				Text = function()
					local i = item()
					return if i then i.displayName else ""
				end,
			}),
			textLabel({
				Name = "Price",
				Position = UDim2.fromScale(0, 0.8),
				Size = UDim2.fromScale(1, 0.2),
				FontFace = Theme.type.label.font,
				TextColor3 = Theme.color.primary,
				TextStrokeTransparency = 0.4,
				RichText = true,
				Text = function()
					local i, p = item(), price()
					if i == nil or p == nil then
						return ""
					end
					local text = StoreScreenLogic.priceRich(i, p)
					if p.was == nil then
						return text
					end
					return string.format('<font color="#%s">SALE</font>  %s', Theme.color.warning:ToHex(), text)
				end,
			}),
			Parent = playerGui,
		}) :: BillboardGui

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "StorePlinthPrompt"
		prompt.ActionText = "View"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Parent = part
		effect(function()
			local i = item()
			prompt.Enabled = i ~= nil
			prompt.ObjectText = if i then i.displayName else ""
		end)
		local triggered = prompt.Triggered:Connect(function()
			local i = item()
			if i ~= nil then
				menu().openStoreOn(i.key)
			end
		end)

		vide.cleanup(function()
			triggered:Disconnect()
			prompt:Destroy()
			gui:Destroy()
		end)
	end)
end

local function unmount(part: Instance)
	local destroy = mounted[part]
	if destroy ~= nil then
		mounted[part] = nil
		destroy()
	end
end

local StorePlinthController: Loader.Controller = {
	name = "StorePlinthController",
	dependencies = { "MenuController" },
}

function StorePlinthController:start()
	if not menu().isHubServer() then
		return
	end
	for _, part in CollectionService:GetTagged(TAG) do
		mount(part)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(mount)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unmount)
end

return StorePlinthController
