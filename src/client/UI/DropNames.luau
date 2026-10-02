--!strict
-- A win drop's display name, from the power-up and cosmetic registries
-- (PayoutLogic.NameOf). One lookup for the Decision Studio's reveal and
-- the results screen, so the two name a drop the same way.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cosmetics = require(ReplicatedStorage.Shared.Config.Cosmetics)
local PowerUps = require(ReplicatedStorage.Shared.Config.PowerUps)

local names: { [string]: { [string]: string } } = { PowerUp = {}, Cosmetic = {} }
for _, entry in PowerUps do
	names.PowerUp[entry.def.id] = entry.def.displayName
end
for _, entry in Cosmetics do
	names.Cosmetic[entry.def.id] = entry.def.displayName
end

return function(kind: string, id: string): string?
	local byId = names[kind]
	return if byId then byId[id] else nil
end
