--!strict
-- Which participant ids are NPCs, for the client. Humans are keyed by
-- UserId; NPCs (race bots, hub training dummies) get ids from
-- Participants.allocateNPCId, counting down from FIRST_NPC_ID.
--
-- Not simply "negative": Studio's local Clients and Servers test gives
-- its players UserIds -1, -2, ..., which used to collide with the first
-- NPC ids, so test players were never registered (2026-10-03: no
-- pickups in a two-player hub test). Real UserIds are positive.
--
-- src/server/Participants.luau mirrors this constant (it stays free of
-- requires so Lune can load it); tests/Participants.spec.luau checks the
-- two agree.

local ParticipantIds = {}

ParticipantIds.FIRST_NPC_ID = -1000

function ParticipantIds.isNPC(id: number): boolean
	return id <= ParticipantIds.FIRST_NPC_ID
end

return ParticipantIds
