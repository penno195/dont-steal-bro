--!strict
-- Practice parties (design-decisions.md Q7, the "practice matches and
-- parties" case). Invite someone on this hub server, they accept, and
-- the leader's Practice queue takes the whole party into one match.
-- Ranked stays solo: MatchmakingService refuses a ranked join from
-- anyone in a party, which is what keeps Q7 condition 2 ("matchmaking
-- is fully random") true for every match with a streak at stake.
--
-- The rules live in PartyLogic.luau (tested headlessly). This file
-- moves them in and out of remotes. A party lives and dies on one hub
-- server; nothing is stored. A practice match sends everyone home in
-- one teleport, so they land together and can simply party up again.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Loader = require(ReplicatedStorage.Shared.Loader)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Net = require(ReplicatedStorage.Shared.Net)
local PartyLogic = require(ServerScriptService.Server.PartyLogic)

local config: PartyLogic.Config = {
	maxSize = GameConfig.matchmaking.groupSize,
	inviteTtlSeconds = GameConfig.matchmaking.partyInviteTtlSeconds,
}

local state = PartyLogic.new()

-- One fixed line per refusal, so nothing a client sends reaches the screen.
local INVITE_NOTICES: { [string]: string } = {
	Self = "You can't invite yourself.",
	NotLeader = "Only your party leader can invite players.",
	Full = "Your party is full.",
	AlreadyInParty = "They're already in a party.",
	AlreadyInYourParty = "They're already in your party.",
}

local RESPOND_NOTICES: { [string]: string } = {
	Expired = "That invite has expired.",
	Gone = "That party isn't open any more.",
	Full = "That party is full.",
}

local function now(): number
	return os.clock()
end

local function matchmaking(): any
	return Loader.get("MatchmakingService")
end

local function push(player: Player, notice: string?)
	local party = PartyLogic.partyFor(state, player.UserId)
	local invite: PartyLogic.Invite? = state.invites[player.UserId]
	if invite ~= nil and now() > invite.expiresAt then
		state.invites[player.UserId] = nil
		invite = nil
	end
	Net.fireClient("PartyState", player, {
		leaderId = if party then party.leader else nil,
		memberIds = if party then table.clone(party.members) else {},
		inviteFromId = if invite then invite.from else nil,
		notice = notice,
	})
end

-- Everyone whose party just changed: a queued practice party is no
-- longer the party that queued, so its queue is cancelled for all of
-- them (MatchmakingService says why), and everyone gets their new state.
local function changed(userIds: { number }, notice: string?)
	local players: { Player } = {}
	for _, userId in userIds do
		local player = Players:GetPlayerByUserId(userId)
		if player ~= nil then
			table.insert(players, player)
		end
	end
	matchmaking().cancelPractice(players, "Your party changed. Press Practice to queue again.")
	for _, player in players do
		push(player, notice)
	end
end

local function onInvite(player: Player, payload: any)
	if not matchmaking().isActive() then
		return
	end
	local target = Players:GetPlayerByUserId(payload.targetId)
	if target == nil then
		push(player, "That player isn't on this server.")
		return
	end
	local result = PartyLogic.invite(state, player.UserId, target.UserId, now(), config)
	if result ~= "Sent" then
		push(player, INVITE_NOTICES[result])
		return
	end
	push(player, "Invite sent.")
	push(target)
end

local function onRespond(player: Player, payload: any)
	local invite = state.invites[player.UserId]
	local from = if invite then Players:GetPlayerByUserId(invite.from) else nil
	local result, affected = PartyLogic.respond(state, player.UserId, payload.accept == true, now(), config)
	if result == "Joined" then
		changed(affected, nil)
	elseif result == "Declined" then
		push(player)
		if from ~= nil then
			push(from, "Your invite was declined.")
		end
	else
		push(player, RESPOND_NOTICES[result])
	end
end

local function onLeave(player: Player, _payload: any)
	local affected = PartyLogic.leave(state, player.UserId)
	if #affected > 0 then
		changed(affected, nil)
	end
end

local PartyService: Loader.Service = {
	name = "PartyService",
	dependencies = { "NetGuard", "MatchmakingService" },

	-- Everyone who travels with `player` (their party, or just them).
	membersOf = function(player: Player): { number }
		return PartyLogic.membersOf(state, player.UserId)
	end,

	isLeader = function(player: Player): boolean
		return PartyLogic.isLeader(state, player.UserId)
	end,

	-- The practice queue's unit key: the party's id, or the player's own.
	unitOf = function(userId: number): string
		return state.partyOf[userId] or tostring(userId)
	end,
}

function PartyService:init()
	local NetGuard = Loader.get("NetGuard") :: any
	NetGuard.on("PartyInviteIntent", onInvite)
	NetGuard.on("PartyRespondIntent", onRespond)
	NetGuard.on("PartyLeaveIntent", onLeave)

	Players.PlayerRemoving:Connect(function(player: Player)
		local affected = PartyLogic.removePlayer(state, player.UserId)
		local remaining: { number } = {}
		for _, userId in affected do
			if userId ~= player.UserId then
				table.insert(remaining, userId)
			end
		end
		if #remaining > 0 then
			changed(remaining, "A party member left the server.")
		end
	end)
end

return PartyService
