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

local Workspace = game:GetService("Workspace")

local Types = {}

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

-- Shared by any view whose interaction (drag, precise tapping) would
-- otherwise fight with the default camera-rotate gesture on the same
-- touch input - P2-6's own requirement: "camera input frozen while the
-- view is open." Scriptable hands the camera fully to script control
-- (so the default rotate-on-drag behavior stops responding) without
-- moving it - leaving CurrentCamera.CFrame exactly where it was is what
-- "frozen," not "hidden" or "reset," actually means here. Custom hands
-- it back to the default player camera script. A view calls freezeCamera
-- from show() and unfreezeCamera from both onResult's success branch and
-- hide() - see PressureValve.luau/FuseRewire.luau.
function Types.freezeCamera()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Scriptable
	end
end

function Types.unfreezeCamera()
	local camera = Workspace.CurrentCamera
	if camera ~= nil then
		camera.CameraType = Enum.CameraType.Custom
	end
end

return Types
