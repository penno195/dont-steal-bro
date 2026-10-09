--!strict
-- Practice parties, the client half (design-decisions.md Q7, the
-- "practice matches and parties" case): what the queue card offers a
-- player in or out of a party, when the invite prompt is up, and what
-- each row of the party panel lets them do. No Roblox API, so
-- tests/PartyViewLogic.spec runs it headlessly; PartyController feeds
-- it PartyState payloads and QueueController reads `queueButtons`.
--
-- THE SERVER DECIDES (Ground Rule 1). Everything here only chooses what
-- to show: a button hidden here is also refused by PartyService or
-- MatchmakingService, with its own notice.
--
-- RANKED IS SOLO. A party plays Practice only, so a player in one sees
-- no ranked Play button, and only the leader sees Practice: the
-- leader's tap queues the whole party.
--
-- NOTHING BUT USER IDS. PartyState never carries a streak or title
-- (Q7 condition 1), and nor does anything built from it here.

local PartyViewLogic = {}

export type State = {
	leaderId: number?,
	memberIds: { number },
	inviteFromId: number?,
	-- os.clock() the current invite arrived; the server's TTL runs from
	-- about then, and it never pushes the expiry, so the prompt times
	-- itself out (`inviteOpen`).
	inviteAt: number?,
}

export type QueueButtons = {
	-- The Play button. On a private server every queue is practice, so
	-- this is the only one there.
	play: boolean,
	practice: boolean,
	-- Why a button is missing, for the card's status line.
	note: string?,
}

-- "Invite": tap to send. "Sent": waiting on their answer. nil: nothing
-- to do with this player (already in the party, or not ours to invite).
export type RowAction = "Invite" | "Sent"

function PartyViewLogic.new(): State
	return { leaderId = nil, memberIds = {}, inviteFromId = nil, inviteAt = nil }
end

-- Any non-zero whole number: Studio's local test players are -1, -2...
local function userId(value: any): number?
	if type(value) == "number" and value ~= 0 and math.abs(value) < math.huge and value % 1 == 0 then
		return value
	end
	return nil
end

-- Folds one PartyState payload in, and returns the notice it carries
-- (if any) for a toast. Anything malformed leaves the state unchanged.
function PartyViewLogic.apply(state: State, payload: any, now: number): (State, string?)
	if type(payload) ~= "table" or type(payload.memberIds) ~= "table" then
		return state, nil
	end
	local members: { number } = {}
	for _, value in payload.memberIds do
		local id = userId(value)
		if id ~= nil then
			table.insert(members, id)
		end
	end
	local inviteFrom = userId(payload.inviteFromId)
	local nextState: State = {
		leaderId = userId(payload.leaderId),
		memberIds = members,
		inviteFromId = inviteFrom,
		-- A repeat of the same invite (any other push) keeps its clock.
		inviteAt = if inviteFrom == nil then nil elseif inviteFrom == state.inviteFromId then state.inviteAt else now,
	}
	local notice = if type(payload.notice) == "string" and payload.notice ~= "" then payload.notice else nil
	return nextState, notice
end

function PartyViewLogic.inParty(state: State): boolean
	return #state.memberIds > 1
end

function PartyViewLogic.isMember(state: State, id: number): boolean
	return table.find(state.memberIds, id) ~= nil
end

-- Solo counts as leading: nobody else can start your queue for you.
function PartyViewLogic.leads(state: State, me: number): boolean
	return not PartyViewLogic.inParty(state) or state.leaderId == me
end

function PartyViewLogic.queueButtons(state: State, me: number, practiceServer: boolean): QueueButtons
	if not PartyViewLogic.leads(state, me) then
		return { play = false, practice = false, note = "Your party leader starts the practice queue." }
	end
	if practiceServer then
		return { play = true, practice = false, note = nil }
	end
	if PartyViewLogic.inParty(state) then
		return { play = false, practice = true, note = "Parties play Practice only." }
	end
	return { play = true, practice = true, note = nil }
end

-- Whether the invite prompt should be up.
function PartyViewLogic.inviteOpen(state: State, now: number, ttlSeconds: number): boolean
	return state.inviteFromId ~= nil and state.inviteAt ~= nil and now - state.inviteAt < ttlSeconds
end

-- `sentAt`: when this client last invited `target`, if it has.
function PartyViewLogic.rowAction(
	state: State,
	me: number,
	target: number,
	maxSize: number,
	sentAt: number?,
	now: number,
	ttlSeconds: number
): RowAction?
	if target == me or PartyViewLogic.isMember(state, target) or not PartyViewLogic.leads(state, me) then
		return nil
	end
	if #state.memberIds >= maxSize then
		return nil
	end
	if sentAt ~= nil and now - sentAt < ttlSeconds then
		return "Sent"
	end
	return "Invite"
end

-- "Party", or "Party 3/6" once there is one.
function PartyViewLogic.title(state: State, maxSize: number): string
	if not PartyViewLogic.inParty(state) then
		return "Party"
	end
	return string.format("Party %d/%d", #state.memberIds, maxSize)
end

return PartyViewLogic
