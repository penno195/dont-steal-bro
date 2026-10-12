--!strict
-- Draws the live themed event (staff-tools.md step 5). EventService sets
-- the ReplicatedStorage attribute LiveEventId in Hub servers only, so
-- this shows in the lobby and nowhere else (owner, 2026-10-12). Each
-- event's look is its own module in src/client/EventViews/, named by
-- EventDef.view: `start()` builds it and returns the function that takes
-- it all down again. The music is AudioController's job.
--
-- Presentation only: nothing here reaches the server (Ground Rule 1).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Loader)
local Events = require(ReplicatedStorage.Shared.Config.Events)

type View = { start: () -> () -> () }

local viewsFolder = script.Parent.Parent:WaitForChild("EventViews")

local shownId: string? = nil
local stopShown: (() -> ())? = nil

local function viewFor(id: string): View?
	for _, entry in Events do
		if entry.def.id ~= id then
			continue
		end
		local module = viewsFolder:FindFirstChild(entry.def.view)
		if module == nil or not module:IsA("ModuleScript") then
			warn("EventController: no EventViews module named " .. entry.def.view)
			return nil
		end
		return (require :: any)(module) :: View
	end
	return nil
end

local function sync()
	local raw = ReplicatedStorage:GetAttribute("LiveEventId")
	local id = if type(raw) == "string" then raw else nil
	if id == shownId then
		return
	end
	if stopShown ~= nil then
		local stop = stopShown
		stopShown = nil
		local ok, err = pcall(stop :: any)
		if not ok then
			warn("EventController: tearing down " .. tostring(shownId) .. " failed: " .. tostring(err))
		end
	end
	shownId = id
	if id == nil then
		return
	end
	local view = viewFor(id)
	if view == nil then
		return
	end
	local ok, result = pcall(view.start)
	if ok then
		stopShown = result
	else
		warn("EventController: starting " .. id .. " failed: " .. tostring(result))
	end
end

local EventController: Loader.Controller = {
	name = "EventController",
}

function EventController:start()
	ReplicatedStorage:GetAttributeChangedSignal("LiveEventId"):Connect(sync)
	sync()
end

return EventController
