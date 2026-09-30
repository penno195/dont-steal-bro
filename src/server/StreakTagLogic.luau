--!strict
-- The rules behind the streak counter over a player's head in the Hub
-- (StreakTagService), kept Roblox-free so they're tested headlessly.
--
-- WHY HUB ONLY: design-decisions.md Q7 condition 1 - a streak is never
-- visible to other players during a live round, "hub and post-match
-- leaderboard only". A match server's pre-round lobby is NOT the hub: the
-- people standing in it are the ones you're about to race, which is the
-- exact targeting the rule exists to prevent. So the counter exists on
-- the Hub server and nowhere else, and a match server never sends one.

local StreakTagLogic = {}

export type Row = { racerId: number, streak: number, flairId: string? }

-- Is this server the Hub? Mirrors QueueController.isHubServer: with the
-- hub place unpublished (id 0), only a Studio session with a Workspace.Hub
-- counts, so a live match server with an unset id never shows streaks.
function StreakTagLogic.isHub(placeId: number, hubPlaceId: number, isStudio: boolean, hasHubFolder: boolean): boolean
	if hubPlaceId == 0 then
		return isStudio and hasHubFolder
	end
	return placeId == hubPlaceId
end

-- The tags to broadcast: one per racer with a live streak. A streak of 0
-- has no counter - and so no flair either, since flair only dresses the
-- counter. Anything malformed is dropped rather than drawn wrong.
function StreakTagLogic.tags(rows: { Row }): { Row }
	local out: { Row } = {}
	for _, row in rows do
		local streak = row.streak
		if streak >= 1 and streak == math.floor(streak) then
			table.insert(out, { racerId = row.racerId, streak = streak, flairId = row.flairId })
		end
	end
	return out
end

return StreakTagLogic
