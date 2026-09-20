--!strict
-- Server entry point. Boots every Service in src/server/Services.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Loader = require(ReplicatedStorage.Shared.Loader)

Loader.start(script.Services)
