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

local InputLock = require(script.Parent.Parent.UI.InputLock)

local Types = {}

-- Handed to show() by TaskStationController (P6-4). `close` abandons
-- the attempt: it hides this view (via hide) and tells the server
-- (TaskAbort). Safe to call more than once, and a no-op once the
-- attempt has ended some other way.
export type Session = {
	attempt: number,
	close: () -> (),
}

export type TaskView = {
	taskId: string,

	-- The server sent a TaskChallenge for this taskId - build/open the
	-- UI and render `challenge` (whatever shape that task's own handler
	-- chose to send). `session` is how the view ends its own attempt
	-- (the close button) - see Session below.
	show: (stationId: string, challenge: any, session: Session) -> (),

	-- The server responded to a submission this view itself fired. Must
	-- handle being called again for the SAME attempt after a fail (the
	-- UI stays open, ready for another submission) - only a `success`
	-- result ends the attempt. `feedback` is the handler's optional
	-- per-submission detail (its own shape, e.g. Fuse Rewire's accepted
	-- pair) - see the server's TaskHandlers/Types.luau TaskFeedback.
	onResult: (stationId: string, success: boolean, feedback: any?) -> (),

	-- The attempt ended for any OTHER reason before success - walked
	-- away, a new interaction started elsewhere, disconnecting. Tears
	-- down whatever `show` created. Must be safe to call even if `show`
	-- was never called for this stationId (a no-op).
	hide: (stationId: string) -> (),
}

-- Kept for the views not yet on TaskViewBase (PressureValve, FuseRewire;
-- see docs/task-views.md "Migrating"). Both now go through UI/InputLock,
-- which also freezes character input and restores the camera to what it
-- was rather than forcing Custom - see its header. A view built on
-- TaskViewBase never calls these: the base locks and unlocks for it.
local LEGACY_TOKEN = table.freeze({})

function Types.freezeCamera()
	InputLock.acquire(LEGACY_TOKEN)
end

function Types.unfreezeCamera()
	InputLock.release(LEGACY_TOKEN)
end

return Types
