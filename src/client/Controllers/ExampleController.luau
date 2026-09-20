--!strict
-- Demonstrates the Loader pattern (src/shared/Loader.luau). Delete this
-- once a real controller (e.g. InputController) exists to demonstrate it
-- instead - it exists only to prove the loader end to end.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require(ReplicatedStorage.Shared.Loader)

local ExampleController: Loader.Controller = {
	name = "ExampleController",
	dependencies = {},
}

function ExampleController:init()
	self.startedAt = os.clock()
end

function ExampleController:start()
	print(string.format("ExampleController: alive %.3fs after init", os.clock() - self.startedAt))
end

return ExampleController
