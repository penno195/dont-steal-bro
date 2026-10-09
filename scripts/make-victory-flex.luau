--!strict
-- Writes the Victory Flex emote (next-stages step 10) as a KeyframeSequence
-- to assets/cosmetics/VictoryFlex.rbxm, for the Animation Editor to load
-- and publish. Run: lune run scripts/make-victory-flex
--
-- Poses are R15 joint offsets: upper arms out to horizontal, forearms
-- curled up and in (a double-biceps flex), torso leaning back a touch.

local fs = require("@lune/fs")
local roblox = require("@lune/roblox")
local Instance = roblox.Instance
local CFrame = roblox.CFrame
local Enum = roblox.Enum

local r = math.rad

local function frame(t: number, shoulder: number, elbow: number, lean: number, headTilt: number, bounce: boolean?)
	local kf = Instance.new("Keyframe")
	kf.Time = t
	local function pose(name: string, cf: any, parent: any)
		local p = Instance.new("Pose")
		p.Name = name
		p.CFrame = cf or CFrame.identity
		p.EasingStyle = if bounce then Enum.PoseEasingStyle.Bounce else Enum.PoseEasingStyle.Cubic
		p.EasingDirection = Enum.PoseEasingDirection.Out
		p.Parent = parent
		return p
	end
	local root = pose("HumanoidRootPart", nil, kf)
	local lower = pose("LowerTorso", nil, root)
	local upper = pose("UpperTorso", CFrame.Angles(r(-lean), 0, 0), lower)
	pose("Head", CFrame.Angles(r(headTilt), 0, 0), upper)
	local ru = pose("RightUpperArm", CFrame.Angles(0, 0, r(shoulder)), upper)
	pose("RightLowerArm", CFrame.Angles(0, 0, r(elbow)), ru)
	local lu = pose("LeftUpperArm", CFrame.Angles(0, 0, r(-shoulder)), upper)
	pose("LeftLowerArm", CFrame.Angles(0, 0, r(-elbow)), lu)
	return kf
end

local seq = Instance.new("KeyframeSequence")
seq.Name = "VictoryFlex"
seq.Loop = false
seq.Priority = Enum.AnimationPriority.Action
frame(0, 0, 0, 0, 0).Parent = seq
frame(0.3, 90, 105, 6, 8).Parent = seq
frame(0.7, 90, 120, 10, 12, true).Parent = seq
frame(1.0, 90, 100, 6, 8).Parent = seq
frame(1.3, 90, 125, 12, 14, true).Parent = seq
frame(1.8, 90, 115, 8, 10).Parent = seq
frame(2.2, 0, 0, 0, 0).Parent = seq

fs.writeFile("assets/cosmetics/VictoryFlex.rbxm", roblox.serializeModel({ seq }))
print("wrote assets/cosmetics/VictoryFlex.rbxm")
