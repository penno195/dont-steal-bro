--!strict
-- Pays daily and weekly leaderboard placements (design-decisions.md Q1,
-- applied 2026-10-02; rewards-roadmap.md step 4). The amounts live in
-- GameConfig.leaderboard.payouts; the rules are in
-- LeaderboardPayoutLogic.luau, tested headlessly.
--
-- Two halves, because the winner is usually offline when their period
-- ends:
--
--   SEND - LeaderboardService fires its period reward hook once per paid
--   rank, on the one server that won the snapshot race. This turns the
--   rank into a payout message and queues it on the winner's profile
--   (DataService.sendProfileMessage, over ProfileStore:MessageAsync).
--
--   RECEIVE - whichever server next holds that profile's session gets
--   the message. DataService applies the grants and marks it processed
--   in one step; this side only says what the message pays, then logs
--   and pushes fresh store state.
--
-- The all-time board never pays (user decision), so it has no bands
-- and LeaderboardService never fires the hook for it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LeaderboardPayoutLogic = require(ServerScriptService.Server.LeaderboardPayoutLogic)

local payouts: LeaderboardPayoutLogic.PayoutTable = GameConfig.leaderboard.payouts :: any

-- Spawned per rank rather than run inline: MessageAsync retries with
-- backoff until it lands, and the rollover runs on the leaderboard's
-- poll thread, which must keep refreshing the boards meanwhile.
local function sendPayout(kind: string, periodKey: string, rank: number, userId: number, streak: number)
	local message = LeaderboardPayoutLogic.messageFor(payouts, kind, periodKey, rank)
	if message == nil then
		return
	end
	task.spawn(function()
		local DataService = Loader.get("DataService") :: any
		local sent = DataService.sendProfileMessage(userId, message)
		-- The snapshot in PeriodSnapshots_v1 is the durable record of who
		-- placed, so a failed send (only on server shutdown) can be
		-- re-sent by hand from it and this line.
		print(
			string.format(
				"LeaderboardPayout: %s %s %s rank %d to user %d (streak %d): %d coins%s",
				if sent then "queued" else "FAILED to queue",
				kind,
				periodKey,
				rank,
				userId,
				streak,
				message.currency,
				if message.cosmeticId ~= nil then " + " .. message.cosmeticId else ""
			)
		)
	end)
end

local LeaderboardPayoutService: Loader.Service = {
	name = "LeaderboardPayoutService",
	dependencies = { "DataService", "LeaderboardService", "StoreService" },
}

function LeaderboardPayoutService:init()
	local LeaderboardService = Loader.get("LeaderboardService") :: any
	LeaderboardService.setPeriodRewardHandler(sendPayout)

	local DataService = Loader.get("DataService") :: any
	DataService.routeProfileMessages(LeaderboardPayoutLogic.MESSAGE_TYPE, {
		resolve = function(_player: Player, raw: any)
			local message = LeaderboardPayoutLogic.parseMessage(raw)
			return if message ~= nil then LeaderboardPayoutLogic.grantsFor(message) else nil
		end,
		applied = function(player: Player, raw: any, changes: { string })
			local message = LeaderboardPayoutLogic.parseMessage(raw)
			if message == nil then
				return
			end
			for _, change in changes do
				print(LeaderboardPayoutLogic.formatAudit(player.Name, message, change))
			end
			if player.Parent == Players then
				(Loader.get("StoreService") :: any).pushState(player)
			end
		end,
	})
end

return LeaderboardPayoutService
