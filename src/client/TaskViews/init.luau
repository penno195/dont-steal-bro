--!strict
-- Auto-collects every sibling task-view module, keyed by its own
-- declared `taskId` - the client-side twin of src/server/TaskHandlers/
-- init.luau, same reasoning: "one registry entry" means dropping one
-- more file next to this one (Ground Rule 2), and TaskStationController
-- needs O(1) lookup by the taskId a TaskChallenge payload names.
--
-- Types.luau (the shared TaskView contract, not a view itself) is
-- skipped by name - everything else under this folder is assumed to be
-- a real view module.

local Types = require(script.Types)

local views: { [string]: Types.TaskView } = {}

for _, child in script:GetChildren() do
	if not child:IsA("ModuleScript") or child.Name == "Types" then
		continue
	end

	local view = (require(child) :: any) :: Types.TaskView
	if views[view.taskId] ~= nil then
		error(string.format("TaskViews: duplicate taskId %q (at least one is %s)", view.taskId, child:GetFullName()), 0)
	end
	views[view.taskId] = view
end

return views
