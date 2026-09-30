--!strict
-- Walk/run/idle animation for a bot's avatar rig. An avatar built by
-- Players:CreateHumanoidModelFromDescriptionAsync comes with the stock
-- "Animate" LocalScript, but a LocalScript only runs inside a player's
-- own character, so on a server-owned bot it never runs and the rig
-- slides around in its bind pose. This plays the same animations from
-- the server instead - tracks played on the server's Animator replicate
-- to every client.
--
-- The animation ids are read from that Animate script's own Animation
-- children (walk/WalkAnim, run/RunAnim, idle/Animation1) rather than
-- hard-coded, so whatever the platform ships as the default set is what
-- a bot uses - the same set a human with default animations has.

local NPCAnimator = {}

-- Humanoid.Running reports studs/s. Below this the bot is standing
-- still; above RUN_SPEED it has a sprint buff and switches to the run.
local MOVING_SPEED = 0.5
local RUN_SPEED = 17

local function animationFrom(animate: Instance, folderName: string, animationName: string): Animation?
	local folder = animate:FindFirstChild(folderName)
	local animation = if folder ~= nil then folder:FindFirstChild(animationName) else nil
	return if animation ~= nil and animation:IsA("Animation") then animation else nil
end

-- Starts animating `humanoid`'s rig. Removes the dead Animate script
-- either way. Returns false (and leaves the rig still) when the rig has
-- no Animate script or no Animator to play on - the fallback block rig.
function NPCAnimator.start(model: Model, humanoid: Humanoid): boolean
	local animate = model:FindFirstChild("Animate")
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animate == nil or animator == nil then
		return false
	end

	local walk = animationFrom(animate, "walk", "WalkAnim")
	local run = animationFrom(animate, "run", "RunAnim")
	local idle = animationFrom(animate, "idle", "Animation1")
	animate:Destroy()
	if walk == nil or idle == nil then
		return false
	end

	local walkTrack = animator:LoadAnimation(walk)
	local runTrack = if run ~= nil then animator:LoadAnimation(run) else walkTrack
	local idleTrack = animator:LoadAnimation(idle)
	walkTrack.Looped, runTrack.Looped, idleTrack.Looped = true, true, true
	idleTrack.Priority = Enum.AnimationPriority.Idle
	walkTrack.Priority = Enum.AnimationPriority.Movement
	runTrack.Priority = Enum.AnimationPriority.Movement

	local current: AnimationTrack? = nil
	local function switchTo(track: AnimationTrack)
		if current == track then
			return
		end
		if current ~= nil then
			current:Stop(0.2)
		end
		track:Play(0.2)
		current = track
	end

	switchTo(idleTrack)
	-- Tied to the Humanoid, so it goes when the rig is destroyed.
	humanoid.Running:Connect(function(speed: number)
		if speed < MOVING_SPEED then
			switchTo(idleTrack)
		elseif speed > RUN_SPEED then
			switchTo(runTrack)
		else
			switchTo(walkTrack)
		end
	end)
	return true
end

return NPCAnimator
