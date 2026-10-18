--!strict
-- Sends this client's uncaught script errors to the server, which logs
-- them as Telemetry's ScriptError event (Side: Client), so a UI or task
-- view that breaks on players' phones shows up in the dashboard instead
-- of only in their F9 console.
--
-- Only the trace goes up, never the message: messages can hold names.
-- The server keeps just "Module line N" from its first frame
-- (TelemetryLogic.errorOrigin). Each origin is sent once per session,
-- and at most MAX_REPORTS in all, so an error in a render loop costs
-- one remote call, not sixty a second.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScriptContext = game:GetService("ScriptContext")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Net = require(ReplicatedStorage.Shared.Net)

local MAX_REPORTS = 10
local MAX_TRACE = 300 -- Net's ClientErrorReport limit

local sent: { [string]: true } = {}
local count = 0

local function report(_message: string, trace: string, origin: Instance?)
	if count >= MAX_REPORTS then
		return
	end
	local firstLine = string.match(trace, "^[^\n]*") or ""
	if firstLine == "" then
		-- No trace (a dead thread, say): name the script instead.
		firstLine = if origin then origin.Name .. ":0" else "unknown:0"
	end
	firstLine = string.sub(firstLine, 1, MAX_TRACE)
	if sent[firstLine] then
		return
	end
	sent[firstLine] = true
	count += 1
	Net.fireServer("ClientErrorReport", { trace = firstLine })
end

local ErrorReportController: Loader.Controller = {
	name = "ErrorReportController",
}

function ErrorReportController:start()
	ScriptContext.Error:Connect(report)
end

return ErrorReportController
