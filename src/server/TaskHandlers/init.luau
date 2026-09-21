--!strict
-- Auto-collects every sibling task-handler module, keyed by its own
-- declared `taskId` - "one registry entry" (the "how to add a task"
-- doc's own phrase, docs/how-to-add-a-task.md) means dropping one more
-- file next to this one; nothing here changes (Ground Rule 2). Rojo's
-- init.luau convention turns this folder itself into the ModuleScript
-- returned here, with every sibling file as its child - the same
-- pattern as src/shared/Config/Tasks/init.luau, just keyed by taskId
-- instead of returning a flat list, since TaskHandlerService needs O(1)
-- lookup by the task id a station's AcceptedTaskIds attribute names.
--
-- Types.luau (the shared TaskHandler/TaskContext contract, not a
-- handler itself) is skipped by name - everything else under this
-- folder is assumed to be a real handler module.

local Types = require(script.Types)

local handlers: { [string]: Types.TaskHandler<any, any, any> } = {}

for _, child in script:GetChildren() do
	if not child:IsA("ModuleScript") or child.Name == "Types" then
		continue
	end

	local handler = (require(child) :: any) :: Types.TaskHandler<any, any, any>
	if handlers[handler.taskId] ~= nil then
		error(
			string.format("TaskHandlers: duplicate taskId %q (at least one is %s)", handler.taskId, child:GetFullName()),
			0
		)
	end
	handlers[handler.taskId] = handler
end

return handlers
