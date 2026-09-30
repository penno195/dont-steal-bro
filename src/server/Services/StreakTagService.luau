--!strict
-- The win-streak counter over each player's head in the Hub, and the
-- StreakFlair cosmetic that dresses it. The rules are pure
-- (StreakTagLogic); this reads profiles and broadcasts StreakTagState.
--
-- HUB ONLY, enforced here: on any other server `active` is false and
-- nothing is ever sent, so a modified client in a match has no streak
-- to un-hide (Ground Rule 1, design-decisions.md Q7 condition 1). See
-- StreakTagLogic's header for why a match server's pre-round lobby
-- doesn't count as the hub.
--
-- Nothing changes a streak in the Hub - races happen on match servers -
-- so a broadcast on each profile load, leave and flair equip is enough.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local StreakTagLogic = require(ServerScriptService.Server.StreakTagLogic)

local active = false

local function broadcast()
	if not active then
		return
	end
	local DataService = Loader.get("DataService") :: any
	local CosmeticService = Loader.get("CosmeticService") :: any
	local rows: { StreakTagLogic.Row } = {}
	for _, player in Players:GetPlayers() do
		if DataService.isLoaded(player) then
			table.insert(rows, {
				racerId = player.UserId,
				streak = DataService.getStreak(player) :: number,
				flairId = CosmeticService.equippedIdFor(player, "StreakFlair") :: string?,
			})
		end
	end
	Net.fireAllClients("StreakTagState", { tags = StreakTagLogic.tags(rows) })
end

local StreakTagService: Loader.Service = {
	name = "StreakTagService",
	dependencies = { "DataService", "CosmeticService" },

	-- Called by StoreService after a StreakFlair equip. A no-op off the hub.
	broadcast = broadcast,
}

function StreakTagService:init()
	active = StreakTagLogic.isHub(
		game.PlaceId,
		GameConfig.matchmaking.hubPlaceId,
		RunService:IsStudio(),
		Workspace:FindFirstChild("Hub") ~= nil
	)
	if not active then
		return
	end

	local DataService = Loader.get("DataService") :: any
	DataService.onLoaded(function()
		broadcast()
	end)
	-- Deferred: the leaving player is still in GetPlayers() during
	-- PlayerRemoving, and their tag should go with them.
	Players.PlayerRemoving:Connect(function()
		task.defer(broadcast)
	end)
end

return StreakTagService
