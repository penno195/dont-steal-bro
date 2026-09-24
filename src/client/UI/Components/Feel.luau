--!strict
-- The UI half of the scale-punch (P8-3). FeelController drives one scale
-- value per channel (FeelLogic.CHANNEL); a screen opts an element in with
-- Feel.attach(element, "Tasks"). Kept out of FeelController so screens
-- never require a controller, the same split as Env.
--
-- The punch goes on the element's OWN UIScale, never a screen root's:
-- the root's UIScale belongs to UIScaleController, and punching a whole
-- screen would push its edges out of the safe area.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Feel = {}

type NumberSource = typeof(vide.source(1))

local channels: { [string]: NumberSource } = {}

local function channel(name: string): NumberSource
	local existing = channels[name]
	if existing ~= nil then
		return existing
	end
	local created = vide.source(1)
	channels[name] = created
	return created
end

function Feel.set(name: string, scale: number)
	channel(name)(scale)
end

-- A UIScale bound to the channel, to pass as a child in a create() call.
-- Must be called inside a Vide scope (a screen's mount).
function Feel.scale(name: string)
	local source = channel(name)
	return vide.create("UIScale")({
		Name = "FeelPunch",
		Scale = function()
			return source()
		end,
	})
end

-- The same, for an element that's already built (a component's return
-- value). One that already has a UIScale is left alone rather than
-- fought over.
function Feel.attach(element: GuiObject, name: string)
	if element:FindFirstChildOfClass("UIScale") ~= nil then
		return
	end
	Feel.scale(name).Parent = element
end

return Feel
