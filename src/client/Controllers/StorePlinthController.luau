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
-- A SPINNING MODEL: an item with a `plinthModel` (a Meshy mesh) gets it
-- turning slowly over the plinth, and the billboard drops the picture
-- and floats higher with just the name and price (owner's call,
-- 2026-10-10). Client-only and never collides; Reduce Motion holds it
-- still.
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
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local Env = require(script.Parent.Parent.UI.Components.Env)
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
-- The model's centre over the plinth's top, its turn and bob, and how
-- high the name-and-price board floats once a model takes the picture's
-- place.
local MODEL_LIFT = 2.6
local MODEL_SPIN = math.rad(50) -- per second
local MODEL_BOB = 0.25 -- studs, up and down
local MODEL_BOB_PERIOD = 3 -- seconds
local TEXT_BOARD_H = 1.9
local TEXT_BOARD_LIFT = 5.6

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

type PlinthModel = { meshAssetId: number, textureAssetId: number, scale: number, rotation: { number }? }

-- The spinning model: a non-colliding Part with a SpecialMesh (the same
-- route as wearables: MeshPart.MeshId can't be set from a script).
-- Returns its cleanup.
local function spinModel(plinth: BasePart, model: PlinthModel): () -> ()
	local part = Instance.new("Part")
	part.Name = "StorePlinthModel"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.one
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.FileMesh
	mesh.MeshId = "rbxassetid://" .. model.meshAssetId
	mesh.TextureId = "rbxassetid://" .. model.textureAssetId
	mesh.Scale = Vector3.one * model.scale
	mesh.Parent = part

	local r = model.rotation or { 0, 0, 0 }
	local facing = CFrame.Angles(math.rad(r[1]), math.rad(r[2]), math.rad(r[3]))
	local function place(t: number)
		local still = Env.reducedMotion()
		local bob = if still then 0 else math.sin(t * 2 * math.pi / MODEL_BOB_PERIOD) * MODEL_BOB
		local spin = if still then 0 else t * MODEL_SPIN
		local top = plinth.Position + Vector3.new(0, plinth.Size.Y / 2 + MODEL_LIFT + bob, 0)
		part.CFrame = CFrame.new(top) * CFrame.Angles(0, spin, 0) * facing
	end
	place(0)
	part.Parent = workspace

	local started = os.clock()
	local stepped = RunService.Heartbeat:Connect(function()
		place(os.clock() - started)
	end)
	return function()
		stepped:Disconnect()
		part:Destroy()
	end
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
		local model = derive(function(): PlinthModel?
			local i = item()
			return if i then i.plinthModel else nil
		end)
		effect(function()
			local m = model()
			if m ~= nil then
				vide.cleanup(spinModel(part :: BasePart, m))
			end
		end)
		-- Name and price take the whole board once the model replaces the
		-- picture: a row's scale with the picture, or without it.
		local function row(withPicture: number, textOnly: number): number
			return if model() then textOnly else withPicture
		end

		local gui = create("BillboardGui")({
			Name = "StorePlinth" .. slot,
			Adornee = part,
			Size = function()
				return UDim2.fromScale(BOARD_W, if model() then TEXT_BOARD_H else BOARD_H)
			end,
			StudsOffsetWorldSpace = function()
				return Vector3.new(0, part.Size.Y / 2 + (if model() then TEXT_BOARD_LIFT else BOARD_LIFT), 0)
			end,
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
				Visible = function()
					return model() == nil
				end,
				Image = function()
					local i = item()
					return if i and i.imageAssetId ~= 0 then "rbxassetid://" .. i.imageAssetId else ""
				end,
			}),
			textLabel({
				Name = "Name",
				Position = function()
					return UDim2.fromScale(0, row(0.6, 0))
				end,
				Size = function()
					return UDim2.fromScale(1, row(0.18, 0.47))
				end,
				FontFace = Theme.type.title.font,
				TextStrokeTransparency = 0.4,
				Text = function()
					local i = item()
					return if i then i.displayName else ""
				end,
			}),
			textLabel({
				Name = "Price",
				Position = function()
					return UDim2.fromScale(0, row(0.8, 0.53))
				end,
				Size = function()
					return UDim2.fromScale(1, row(0.2, 0.47))
				end,
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
