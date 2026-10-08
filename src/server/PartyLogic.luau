--!strict
-- Practice parties (design-decisions.md Q7, the "practice matches and
-- parties" case). The pure half: who is in which party, who has been
-- invited, and what an invite, an answer or a departure does to that.
-- PartyService.luau owns the remotes and the Players events and calls
-- these; tests/PartyLogic.spec.luau covers them headlessly.
--
-- A party lives on one hub server and only ever queues for PRACTICE.
-- Ranked stays solo (Q7 condition 2), and MatchmakingService refuses a
-- ranked join from anyone in a party. Nothing here reads or carries a
-- streak (Q7 condition 1): a party is user ids and nothing else.
--
-- Everything is keyed by userId, and every function mutates `state` in
-- place and returns a result code, so the service can turn a refusal
-- into one fixed message.

local PartyLogic = {}

export type Config = {
	maxSize: number, -- one match: GameConfig.matchmaking.groupSize
	inviteTtlSeconds: number,
}

export type Party = {
	id: string,
	leader: number,
	members: { number }, -- leader first, then join order
}

export type Invite = {
	from: number,
	expiresAt: number,
}

export type State = {
	parties: { [string]: Party },
	partyOf: { [number]: string },
	-- One pending invite per invitee: a newer one replaces it, so a
	-- player can never be buried under a stack of prompts.
	invites: { [number]: Invite },
	nextId: number,
}

export type InviteResult = "Sent" | "Self" | "NotLeader" | "Full" | "AlreadyInParty" | "AlreadyInYourParty"

export type RespondResult = "Joined" | "Declined" | "NoInvite" | "Expired" | "Gone" | "Full"

function PartyLogic.new(): State
	return { parties = {}, partyOf = {}, invites = {}, nextId = 0 }
end

function PartyLogic.partyFor(state: State, userId: number): Party?
	local id = state.partyOf[userId]
	return if id ~= nil then state.parties[id] else nil
end

-- Everyone who travels with `userId`: their party, or just themselves.
function PartyLogic.membersOf(state: State, userId: number): { number }
	local party = PartyLogic.partyFor(state, userId)
	return if party ~= nil then table.clone(party.members) else { userId }
end

function PartyLogic.isLeader(state: State, userId: number): boolean
	local party = PartyLogic.partyFor(state, userId)
	return party == nil or party.leader == userId
end

-- A solo player may invite (their party forms when someone accepts).
-- In a party, only the leader may, so a party can't grow behind the
-- leader's back.
function PartyLogic.invite(state: State, from: number, to: number, now: number, config: Config): InviteResult
	if from == to then
		return "Self"
	end
	local party = PartyLogic.partyFor(state, from)
	if party ~= nil then
		if party.leader ~= from then
			return "NotLeader"
		end
		if table.find(party.members, to) ~= nil then
			return "AlreadyInYourParty"
		end
		if #party.members >= config.maxSize then
			return "Full"
		end
	end
	if state.partyOf[to] ~= nil then
		return "AlreadyInParty"
	end
	state.invites[to] = { from = from, expiresAt = now + config.inviteTtlSeconds }
	return "Sent"
end

-- Removes `userId` from their party. A leader who leaves hands the
-- party to the longest-standing member; a party left with one member
-- dissolves. Returns the user ids whose party changed (including
-- `userId`), so the service can update them and cancel their queue.
function PartyLogic.leave(state: State, userId: number): { number }
	local party = PartyLogic.partyFor(state, userId)
	if party == nil then
		return {}
	end
	local affected = table.clone(party.members)
	local index = table.find(party.members, userId)
	if index ~= nil then
		table.remove(party.members, index)
	end
	state.partyOf[userId] = nil
	if #party.members <= 1 then
		for _, member in party.members do
			state.partyOf[member] = nil
		end
		state.parties[party.id] = nil
	elseif party.leader == userId then
		party.leader = party.members[1]
	end
	return affected
end

-- The invitee's answer. Declining (or an expired invite) clears it.
-- Accepting from inside another party leaves that one first: the
-- answer is the player's own choice of who to play with.
-- Returns the result and the user ids whose party changed.
function PartyLogic.respond(
	state: State,
	to: number,
	accept: boolean,
	now: number,
	config: Config
): (RespondResult, { number })
	local invite = state.invites[to]
	if invite == nil then
		return "NoInvite", {}
	end
	state.invites[to] = nil
	if now > invite.expiresAt then
		return "Expired", {}
	end
	if not accept then
		return "Declined", {}
	end

	local from = invite.from
	local party = PartyLogic.partyFor(state, from)
	-- The inviter may have joined someone else's party since, or no
	-- longer lead their own.
	if party ~= nil and party.leader ~= from then
		return "Gone", {}
	end
	if party ~= nil and #party.members >= config.maxSize then
		return "Full", {}
	end

	local affected = PartyLogic.leave(state, to)
	if party == nil then
		state.nextId += 1
		local id = "party-" .. tostring(state.nextId)
		local fresh: Party = { id = id, leader = from, members = { from } }
		state.parties[id] = fresh
		state.partyOf[from] = id
		party = fresh
	end
	local joined = party :: Party
	table.insert(joined.members, to)
	state.partyOf[to] = joined.id
	for _, member in joined.members do
		if table.find(affected, member) == nil then
			table.insert(affected, member)
		end
	end
	return "Joined", affected
end

-- A player left the server: their party and any invite to or from them.
function PartyLogic.removePlayer(state: State, userId: number): { number }
	state.invites[userId] = nil
	for invitee, invite in state.invites do
		if invite.from == userId then
			state.invites[invitee] = nil
		end
	end
	return PartyLogic.leave(state, userId)
end

return PartyLogic
