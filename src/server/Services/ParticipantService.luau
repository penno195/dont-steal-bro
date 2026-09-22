--!strict
-- Keeps Participants.luau's roster in step with the real server (P3-5):
-- every human who joins is registered, every human who leaves is
-- removed, and each one's live Character is kept current as they spawn
-- and respawn.
--
-- WHY IT'S ITS OWN SERVICE: three services (TaskService, PowerUpService,
-- StatusEffects) read the roster, and any of them could have owned the
-- PlayerAdded hook that fills it - but then the other two would depend
-- on an arbitrary one of their peers for something none of them owns
-- conceptually, and whichever was picked could never be disabled
-- without silently emptying the roster for the rest. Sixty lines with
-- no dependencies of its own is the cheaper answer.
--
-- NPCs are NOT registered here - NPCService registers its own, because
-- it's the thing that creates and destroys them. This service is only
-- the human half; Participants.luau is where the two halves meet.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Participants = require(ServerScriptService.Server.Participants)

local function trackCharacter(player: Player)
	player.CharacterAdded:Connect(function(character: Model)
		Participants.setCharacter(player.UserId, character)
	end)
	player.CharacterRemoving:Connect(function()
		-- Explicitly nil rather than left stale: every consumer already
		-- handles a characterless racer, but none of them handle a
		-- reference to a character that's being torn down, and a
		-- distance read against one returns a plausible-looking number
		-- from wherever it happened to die.
		Participants.setCharacter(player.UserId, nil)
	end)

	-- A player who already has a Character by the time this runs (a
	-- Studio playtest, where the local player spawns before the server
	-- script has finished booting) would otherwise never get one
	-- recorded until their first respawn.
	if player.Character ~= nil then
		Participants.setCharacter(player.UserId, player.Character)
	end
end

local function addPlayer(player: Player)
	if Participants.get(player.UserId) ~= nil then
		return
	end

	Participants.register({
		id = player.UserId,
		displayName = player.DisplayName,
		isNPC = false,
		player = player,
		character = player.Character,
	})
	trackCharacter(player)
end

local ParticipantService: Loader.Service = {
	name = "ParticipantService",
	dependencies = {},
}

function ParticipantService:init()
	-- PlayerAdded can already have fired for someone by the time a
	-- server script boots, so the existing roster is swept first - the
	-- standard Roblox join-race pattern, and it matters more here than
	-- usual because a human missed by this sweep is a human every
	-- roster-driven service treats as absent for the whole round.
	for _, player in Players:GetPlayers() do
		addPlayer(player)
	end

	Players.PlayerAdded:Connect(addPlayer)

	Players.PlayerRemoving:Connect(function(player: Player)
		Participants.unregister(player.UserId)
	end)
end

return ParticipantService
