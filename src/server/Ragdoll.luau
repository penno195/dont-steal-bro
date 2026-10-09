--!strict
-- Ragdolls a rig and stands it back up: the "Ragdoll" victim look
-- (Push/Trip). StatusEffects calls `set` whenever a racer's look
-- changes; nothing here decides WHEN, and nothing here changes what the
-- effect does - WalkSpeed 0 is still the lock, so a client that refuses
-- to flop gains nothing.
--
-- WHY THE SERVER SWAPS THE JOINTS: joint changes made on a client never
-- replicate, so a client-only ragdoll flops on one screen and slides
-- stiffly on the other five. Done here, every client sees the same
-- limbs. The rig's OWNER still has to stop its Humanoid fighting the
-- flop - a player's client does that from the look broadcast
-- (EffectLabelController); for a bot the server is the owner, so it's
-- done here.
--
-- Every Motor6D except Root and Neck becomes a limited ball socket.
-- Root keeps the body on its HumanoidRootPart, so the rig falls over
-- as one and can't drop through the floor; Neck stays because a broken
-- neck kills a Humanoid that RequiresNeck.

local KEEP: { [string]: boolean } = { Root = true, RootJoint = true, Neck = true }

type Saved = {
	motors: { Motor6D },
	added: { Instance },
	collide: { [BasePart]: boolean },
	gone: RBXScriptConnection?,
}

-- STRONG keys; a rig destroyed mid-ragdoll (respawn, round end) drops
-- out through its Destroying signal. Not weak keys: an Instance's Lua
-- handle can be collected while the Instance lives on, so a weak entry
-- could vanish mid-ragdoll and leave a long-lived rig (a practice dummy)
-- limp for good, its joints never restored (VictimLookController had
-- the same bug with the ice block, 2026-10-09).
local saved: { [Model]: Saved } = {}

local Ragdoll = {}

local function ragdoll(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid == nil or humanoid.Health <= 0 then
		return
	end
	local entry: Saved = { motors = {}, added = {}, collide = {} }
	for _, motor in character:GetDescendants() do
		if not motor:IsA("Motor6D") or KEEP[motor.Name] or not motor.Enabled then
			continue
		end
		local part0, part1 = motor.Part0, motor.Part1
		if part0 == nil or part1 == nil then
			continue
		end
		local a0 = Instance.new("Attachment")
		a0.Name = "RagdollA0"
		a0.CFrame = motor.C0
		a0.Parent = part0
		local a1 = Instance.new("Attachment")
		a1.Name = "RagdollA1"
		a1.CFrame = motor.C1
		a1.Parent = part1
		local socket = Instance.new("BallSocketConstraint")
		socket.Name = "RagdollSocket"
		socket.Attachment0 = a0
		socket.Attachment1 = a1
		socket.LimitsEnabled = true
		socket.UpperAngle = 60
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = -45
		socket.TwistUpperAngle = 45
		socket.Parent = part1
		-- Joined limbs overlap at the joint; without this they shove
		-- each other apart and the rig jitters.
		local apart = Instance.new("NoCollisionConstraint")
		apart.Name = "RagdollNoCollide"
		apart.Part0 = part0
		apart.Part1 = part1
		apart.Parent = part1
		table.insert(entry.added, a0)
		table.insert(entry.added, a1)
		table.insert(entry.added, socket)
		table.insert(entry.added, apart)
		motor.Enabled = false
		table.insert(entry.motors, motor)
		-- Limbs that don't collide fall through the floor once loose.
		if entry.collide[part1] == nil then
			entry.collide[part1] = part1.CanCollide
			part1.CanCollide = true
		end
	end
	entry.gone = character.Destroying:Once(function()
		saved[character] = nil
	end)
	saved[character] = entry
	-- The bot case: the server owns the rig, so it owns the state too.
	local root = character:FindFirstChild("HumanoidRootPart")
	if root ~= nil and root:IsA("BasePart") and not root.Anchored and root:GetNetworkOwner() == nil then
		humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end
end

local function standUp(character: Model)
	local entry = saved[character]
	saved[character] = nil
	if entry == nil then
		return
	end
	if entry.gone ~= nil then
		entry.gone:Disconnect()
	end
	for _, instance in entry.added do
		instance:Destroy()
	end
	for _, motor in entry.motors do
		if motor.Parent ~= nil then
			motor.Enabled = true
		end
	end
	for part, collide in entry.collide do
		if part.Parent ~= nil then
			part.CanCollide = collide
		end
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")
	if
		humanoid ~= nil
		and humanoid.Health > 0
		and root ~= nil
		and root:IsA("BasePart")
		and not root.Anchored
		and root:GetNetworkOwner() == nil
	then
		humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

-- The server's own record - MovementWatch trusts this, not the
-- client-owned Humanoid state.
function Ragdoll.isRagdolled(character: Model): boolean
	return saved[character] ~= nil
end

-- Idempotent: ragdolling a ragdolled rig, or standing up a standing
-- one, does nothing.
function Ragdoll.set(character: Model, on: boolean)
	if on and saved[character] == nil then
		ragdoll(character)
	elseif not on then
		standUp(character)
	end
end

return Ragdoll
