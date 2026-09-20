--!strict
-- Demonstrates the Loader pattern (src/shared/Loader.luau). Delete this
-- once a real service (e.g. RoundService) exists to demonstrate it
-- instead - it exists only to prove the loader end to end.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require(ReplicatedStorage.Shared.Loader)

local ExampleService: Loader.Service = {
	name = "ExampleService",
	dependencies = {},
}

function ExampleService:init()
	-- Safe here: grab a reference to another module. Not safe here: call
	-- a method on it - it may not have run its own init() yet.
	self.startedAt = os.clock()
end

function ExampleService:start()
	-- Safe here: every module has finished init(), so calling into
	-- another module's public methods (via Loader.get) is now fine.
	print(string.format("ExampleService: alive %.3fs after init", os.clock() - self.startedAt))
end

return ExampleService
