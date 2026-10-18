--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The hub's community notice board (owner, 2026-10-18): a board by the
-- store plinths, the HubCommunityBoard part (hub-spec.md), that reads
-- FREE, a picture of the community reward and JOIN. Before it, the
-- reward was only on the Locker's Style tab, which few players open.
--
-- Tapping it (a ClickDetector, or its ProximityPrompt for keyboard and
-- gamepad) opens MenuController's community pop-up with Roblox's join
-- prompt over it;
-- the grant is still the server's (CommunityRewardCheck). Once the
-- player owns the reward, or with the reward switched off, the board
-- reads "Thanks for joining" instead and does nothing.
--
-- The board's face is drawn on the part's Front face. WHEN: hub servers
-- only; the part may stream in and out.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local derive = vide.derive
local effect = vide.effect

local TAG = "HubCommunityBoard"
local PIXELS_PER_STUD = 40
local MAX_DISTANCE = 80
local PROMPT_DISTANCE = 10
local CLICK_DISTANCE = 40
local GOLD = Color3.fromRGB(240, 196, 80)
local BACKING = Color3.fromRGB(236, 228, 210)

local rewardPicture: number? = nil
for _, entry in Cosmetics do
	if entry.def.id == GameConfig.community.rewardCosmeticId then
		rewardPicture = entry.def.previewIconAssetId
	end
end

local mounted: { [Instance]: () -> () } = {}

local function menu(): any
	return Loader.get("MenuController")
end

local function label(props: { [any]: any })
	local base = {
		BackgroundTransparency = 1,
		TextScaled = true,
		FontFace = Theme.type.title.font,
		TextColor3 = Theme.color.ink,
		TextStrokeTransparency = 0.3,
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
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	mounted[part] = vide.root(function()
		local offered = derive(function(): boolean
			return menu().communityOffered()
		end)

		local gui = create("SurfaceGui")({
			Name = "CommunityBoard",
			Adornee = part,
			Face = Enum.NormalId.Front,
			SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
			PixelsPerStud = PIXELS_PER_STUD,
			MaxDistance = MAX_DISTANCE,
			LightInfluence = 0,
			ResetOnSpawn = false,
			create("Frame")({
				Name = "Face",
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				label({
					Name = "Free",
					Position = UDim2.fromScale(0.05, 0.03),
					Size = UDim2.fromScale(0.9, 0.2),
					TextColor3 = GOLD,
					Text = function()
						return if offered() then "FREE" else "THANKS FOR JOINING"
					end,
				}),
				-- A pale disc behind the picture: the pack is black and gold,
				-- which vanishes on the dark board.
				create("Frame")({
					Name = "Backing",
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.fromScale(0.5, 0.25),
					Size = UDim2.fromScale(0.48, 0.48),
					BackgroundColor3 = BACKING,
					create("UIAspectRatioConstraint")({ AspectRatio = 1 }),
					create("UICorner")({ CornerRadius = UDim.new(0.5, 0) }),
					create("ImageLabel")({
						Name = "Picture",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromScale(0.85, 0.85),
						BackgroundTransparency = 1,
						ScaleType = Enum.ScaleType.Fit,
						Image = if rewardPicture then "rbxassetid://" .. rewardPicture else "",
					}),
				}),
				create("Frame")({
					Name = "Join",
					AnchorPoint = Vector2.new(0.5, 0),
					Position = UDim2.fromScale(0.5, 0.77),
					Size = UDim2.fromScale(0.6, 0.18),
					BackgroundColor3 = Theme.color.primary,
					Visible = offered,
					create("UICorner")({ CornerRadius = UDim.new(0.3, 0) }),
					label({
						Size = UDim2.fromScale(1, 1),
						Text = "JOIN",
						TextColor3 = Theme.color.onPrimary,
						TextStrokeTransparency = 1,
					}),
				}),
				label({
					Name = "Owned",
					Position = UDim2.fromScale(0.05, 0.77),
					Size = UDim2.fromScale(0.9, 0.14),
					FontFace = Theme.type.label.font,
					TextColor3 = Theme.color.inkMuted,
					Visible = function()
						return not offered()
					end,
					Text = "It's in your Locker",
				}),
			}),
			Parent = playerGui,
		}) :: SurfaceGui

		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "CommunityBoardPrompt"
		prompt.ActionText = "Join"
		prompt.ObjectText = "Free backpack"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = PROMPT_DISTANCE
		prompt.RequiresLineOfSight = false
		prompt.Parent = part
		effect(function()
			prompt.Enabled = offered()
		end)
		-- A tap or click on the board itself: a ClickDetector raycasts
		-- from the pointer, so it works on touch and shows the hand cursor.
		local clicker = Instance.new("ClickDetector")
		clicker.Name = "CommunityBoardClick"
		clicker.Parent = part
		effect(function()
			-- No hand cursor once there's nothing to join.
			clicker.MaxActivationDistance = if offered() then CLICK_DISTANCE else 0
		end)
		local function activate()
			if offered() then
				menu().openCommunityJoin()
			end
		end
		local triggered = prompt.Triggered:Connect(activate)
		local clicked = clicker.MouseClick:Connect(activate)

		vide.cleanup(function()
			triggered:Disconnect()
			clicked:Disconnect()
			clicker:Destroy()
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

local CommunityBoardController: Loader.Controller = {
	name = "CommunityBoardController",
	dependencies = { "MenuController" },
}

function CommunityBoardController:start()
	if not menu().isHubServer() then
		return
	end
	for _, part in CollectionService:GetTagged(TAG) do
		mount(part)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(mount)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(unmount)
end

return CommunityBoardController
