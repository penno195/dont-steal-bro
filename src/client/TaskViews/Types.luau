--!strict
-- The client-side half of P2-5's task framework contract - mirrors
-- src/server/TaskHandlers/Types.luau's shape on purpose (show ~ start,
-- onResult ~ validate's feedback, hide ~ cleanup), so a task author
-- reads the same three-beat lifecycle on both sides instead of two
-- unrelated interfaces. TaskStationController.luau is this side's
-- dispatcher, exactly as TaskHandlerService.luau is the server's.
--
-- A view OWNS its own remote-firing: it fires whatever per-task/per-verb
-- submission remote its own minigame needs directly (see CodePlayback.
-- luau firing KeypadDigitSubmit) - the controller never needs to know
-- what that shape is, only which view to dispatch to by taskId.

export type TaskView = {
	taskId: string,

	-- The server sent a TaskChallenge for this taskId - build/open the
	-- UI and render `challenge` (whatever shape that task's own handler
	-- chose to send).
	show: (stationId: string, challenge: any) -> (),

	-- The server responded to a submission this view itself fired. Must
	-- handle being called again for the SAME attempt after a fail (the
	-- UI stays open, ready for another submission) - only a `success`
	-- result ends the attempt.
	onResult: (stationId: string, success: boolean) -> (),

	-- The attempt ended for any OTHER reason before success - walked
	-- away, a new interaction started elsewhere, disconnecting. Tears
	-- down whatever `show` created. Must be safe to call even if `show`
	-- was never called for this stationId (a no-op).
	hide: (stationId: string) -> (),
}

return {}
