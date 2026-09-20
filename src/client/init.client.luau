--!strict
-- Client entry point. Boots every Controller in src/client/Controllers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require(ReplicatedStorage.Shared.Loader)

Loader.start(script.Controllers)
