--!strict
-- Generic auto-collector shared by every Config/<Category>/init.luau
-- registry (Maps, Tasks, PowerUps, Titles). Roblox-only - walks a real
-- Instance tree via `:GetChildren()`, so never required by the Lune
-- tests; ConfigValidator (Roblox-only itself) is what actually exercises
-- this. Adding a map/task/power-up/title means adding one sibling file
-- next to the category's init.luau - this is the "auto" half of that
-- promise (Ground Rule 2): nothing here needs editing when content is
-- added.

local Registry = {}

export type Entry<T> = { fileName: string, def: T }

-- `folder` is the registry's own `script` (a ModuleScript-turned-folder
-- via Rojo's init.luau convention) - every sibling ModuleScript under it
-- is one definition file. Returning the real Instance name (not the
-- def's own `id` field) as `fileName` is what lets ConfigValidator name
-- the actual broken file in an error, even if the file's `id` field
-- itself is the thing that's wrong.
function Registry.collect<T>(folder: Instance): { Entry<T> }
	local entries: { Entry<T> } = {}

	for _, child in folder:GetChildren() do
		if not child:IsA("ModuleScript") then
			continue
		end

		local def = (require(child) :: any) :: T
		table.insert(entries, { fileName = child.Name, def = def })
	end

	return entries
end

return Registry
