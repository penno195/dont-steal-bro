--!strict
-- Auto-collects every sibling task definition file. Add a 16th task by
-- adding one file next to this one - nothing here changes (Ground Rule
-- 2). Rojo's init.luau convention turns this folder itself into the
-- ModuleScript returned here, with every sibling file as its child.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Registry = require(ReplicatedStorage.Shared.Config.Registry)
local Validate = require(ReplicatedStorage.Shared.Config.Validate)

return Registry.collect(script) :: { Registry.Entry<Validate.TaskDef> }
