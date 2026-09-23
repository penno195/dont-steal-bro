--!strict
-- Gamepad focus on screen open and close (P6-8). Every interactive
-- element already carries a SelectionOrder (Base.interactive's `order`),
-- but order only matters once something HAS focus: without a
-- SelectedObject a controller player has to find Roblox's UI-select
-- button before the D-pad does anything. So each screen enters focus
-- on its first element when it opens, and hands focus back to whatever
-- had it when it closes.
--
-- Touch and mouse players are left alone: a selection ring appearing
-- on a phone is noise, and on a PC it steals Enter.

local GuiService = game:GetService("GuiService")

local UIScaleController = require(script.Parent.Parent.Controllers.UIScaleController)

local Focus = {}

-- The visible, selectable descendant of `root` with the lowest
-- SelectionOrder - where a D-pad user expects to start.
function Focus.firstSelectable(root: Instance): GuiObject?
	local best: GuiObject? = nil
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") and d.Selectable and d.Visible then
			if best == nil or d.SelectionOrder < (best :: GuiObject).SelectionOrder then
				best = d
			end
		end
	end
	return best
end

local function focusInto(root: Instance)
	if UIScaleController.getInputMode() ~= Enum.PreferredInput.Gamepad then
		return
	end
	local current = GuiService.SelectedObject
	if current ~= nil and current:IsDescendantOf(root) then
		return
	end
	GuiService.SelectedObject = Focus.firstSelectable(root)
end

-- Call when `root` opens. Focuses its first element on a gamepad
-- (deferred a frame, so a screen built in the same call has its
-- children), and again if the player picks up a controller while it's
-- open. Returns the exit: call it on close to restore the previous
-- selection.
function Focus.enter(root: Instance): () -> ()
	local previous = GuiService.SelectedObject
	local open = true
	task.defer(function()
		if open then
			focusInto(root)
		end
	end)
	local stopWatching = UIScaleController.observeInputMode(function()
		if open then
			focusInto(root)
		end
	end)

	return function()
		if not open then
			return
		end
		open = false
		stopWatching()
		local current = GuiService.SelectedObject
		if previous ~= nil and previous:IsDescendantOf(game) then
			GuiService.SelectedObject = previous
		elseif current ~= nil and (current:IsDescendantOf(root) or not current:IsDescendantOf(game)) then
			GuiService.SelectedObject = nil
		end
	end
end

return Focus
