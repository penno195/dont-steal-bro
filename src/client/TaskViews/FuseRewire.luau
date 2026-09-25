--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of P2-6's Drag reference task (tasks-catalogue.md #7,
-- `fuse-rewire`) - see src/server/TaskHandlers/FuseRewire.luau for the
-- server half. Built on UI/TaskViewBase like CodePlayback.luau: the
-- shell owns the window, close, timer and status line; this file owns
-- the sockets, the fuses and what a drop looks like.
--
-- Input is InputAdapters.Drag: drag a fuse onto a socket, or tap a fuse
-- then a socket (gamepad/keyboard pick-then-place works the same way).
-- A drop only SENDS the pair. The mapping is server-private; the
-- handler's feedback says whether that one pair was right, and only
-- then does the fuse move into its socket. A wrong pair flashes the
-- socket and the fuse stays in the tray, "no penalty" as specified.
--
-- Right and wrong are never colour alone: a wired socket shows a check
-- and the fuse's number, a rejected one flashes a cross.
--
-- Layout: sockets on top (drop targets, read at a glance), fuses in the
-- bottom row where a one-handed thumb picks them up.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Env = require(script.Parent.Parent.UI.Components.Env)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local InputAdapters = require(script.Parent.Parent.UI.InputAdapters)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local source = vide.source

type Challenge = {
	fuseIds: { string },
	slotIds: { string },
}

type Feedback = {
	accepted: boolean,
	fuseId: string,
	slotId: string,
}

-- 4 x 64 plus gaps fits a 360-point portrait sheet inside its margins.
local CELL = 64
local GAP = Theme.spacing.md
local REJECT_SECONDS = 0.4

-- Per-attempt feedback handlers, keyed by the attempt's ctx: onProgress
-- is spec-level but the sources it updates are built per attempt.
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

local function numberOf(id: string): string
	return id:match("%d+") or id
end

local function row(name: string, children: { Instance }, anchorY: number): Frame
	local frame = create("Frame")({
		Name = name,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, anchorY),
		Position = UDim2.fromScale(0.5, anchorY),
		Size = UDim2.fromOffset(4 * CELL + 3 * GAP, CELL),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, GAP),
		}),
	}) :: Frame
	for _, child in children do
		child.Parent = frame
	end
	return frame
end

return TaskViewBase.define({
	taskId = "fuse-rewire",
	title = "Fuse Rewire",

	build = function(ctx)
		local challenge = ctx.challenge :: Challenge
		-- fuseId -> slotId, only for pairs the server accepted.
		local placed: Base.Source<{ [string]: string }> & (({ [string]: string }) -> { [string]: string }) =
			source({}) :: any
		local rejected: Base.Source<string?> & ((string?) -> string?) = source(nil) :: any
		local rejectSerial = 0

		local function fuseIn(slotId: string): string?
			for fuseId, s in placed() do
				if s == slotId then
					return fuseId
				end
			end
			return nil
		end

		-- Mirrors the Drag adapter's `held`. The adapter needs the buttons,
		-- so it's created after them; visuals bind to this proxy instead.
		local held: Base.Source<string?> & ((string?) -> string?) = source(nil) :: any

		local sockets: { [string]: GuiButton } = {}
		local socketList: { Instance } = {}
		for i, slotId in challenge.slotIds do
			local letter = string.char(64 + i)
			local button = Base.interactive({
				name = slotId,
				size = Vector2.new(CELL, CELL),
				layoutOrder = i,
				order = 10 + i,
				radius = Theme.radius.md,
				onActivate = function() end, -- Drag listens for Activated itself
				visual = function()
					return {
						create("Frame")({
							Name = "Surface",
							Size = UDim2.fromScale(1, 1),
							BackgroundColor3 = Env.animate(function(): Color3
								return if fuseIn(slotId) ~= nil
									then Theme.color.success
									elseif rejected() == slotId then Theme.color.danger
									else Theme.color.surface
							end, Theme.motion.fast),
							Base.corner(Theme.radius.md),
							create("UIStroke")({
								ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
								Color = Theme.color.line,
								Thickness = 2,
							}),
							Base.text("headline", {
								Size = UDim2.fromScale(1, 1),
								Text = function()
									local fuseId = fuseIn(slotId)
									return if fuseId then numberOf(fuseId) else letter
								end,
								TextColor3 = function()
									return if fuseIn(slotId) ~= nil or rejected() == slotId
										then Theme.color.inkOnLight
										else Theme.color.inkMuted
								end,
							}),
							-- Corner badge: the non-colour half of right/wrong.
							create("Frame")({
								Name = "Badge",
								BackgroundTransparency = 1,
								AnchorPoint = Vector2.new(1, 0),
								Position = UDim2.new(1, -2, 0, 2),
								Size = UDim2.fromOffset(20, 20),
								vide.show(function()
									return fuseIn(slotId) ~= nil
								end, function()
									return Icons.view("check", 18, Theme.color.inkOnLight)
								end) :: any,
								vide.show(function()
									return rejected() == slotId
								end, function()
									return Icons.view("close", 18, Theme.color.inkOnLight)
								end) :: any,
							}),
						}),
					}
				end,
			})
			sockets[slotId] = button
			table.insert(socketList, button)
		end

		local fuses: { [string]: GuiButton } = {}
		local fuseList: { Instance } = {}
		for i, fuseId in challenge.fuseIds do
			local button = Base.interactive({
				name = fuseId,
				size = Vector2.new(CELL, CELL),
				layoutOrder = i,
				order = i,
				radius = Theme.radius.md,
				onActivate = function() end, -- Drag listens for Activated itself
				visual = function()
					return {
						create("Frame")({
							Name = "Surface",
							Size = UDim2.fromScale(1, 1),
							BackgroundColor3 = function()
								return if held() == fuseId then Theme.color.primary else Theme.color.surfaceRaised
							end,
							Base.corner(Theme.radius.md),
							create("UIStroke")({
								ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
								Color = Theme.color.focus,
								-- Thicker ring on the held fuse: the pick is shape, not just fill.
								Thickness = function()
									return if held() == fuseId then 3 else 0
								end,
							}),
							Base.text("headline", {
								Size = UDim2.fromScale(1, 1),
								Text = numberOf(fuseId),
								TextColor3 = function()
									return if held() == fuseId then Theme.color.onPrimary else Theme.color.ink
								end,
							}),
						}),
					}
				end,
			})
			-- A wired fuse leaves the tray (its number shows in the socket).
			-- The empty holder keeps its place so the others don't shift
			-- under a thumb mid-reach.
			vide.effect(function()
				button.Visible = placed()[fuseId] == nil
			end)
			local holder = create("Frame")({
				Name = fuseId .. "Holder",
				BackgroundTransparency = 1,
				LayoutOrder = i,
				Size = UDim2.fromOffset(CELL, CELL),
			})
			button.AnchorPoint = Vector2.new(0.5, 0.5)
			button.Position = UDim2.fromScale(0.5, 0.5)
			button.Parent = holder
			fuses[fuseId] = button
			table.insert(fuseList, holder)
		end

		local socketRow = row("Sockets", socketList, 0)
		local fuseRow = row("Fuses", fuseList, 1)

		local drag = InputAdapters.Drag({
			items = fuses,
			targets = sockets,
			area = ctx.area,
			onDrop = function(fuseId: string, slotId: string)
				if placed()[fuseId] ~= nil or fuseIn(slotId) ~= nil then
					return
				end
				ctx.submit("FuseDropSubmit", { fuseId = fuseId, slotId = slotId })
			end,
		})
		vide.effect(function()
			held(drag.held())
		end)

		handlers[ctx] = function(feedback: Feedback)
			if feedback.accepted then
				local nextPlaced = table.clone(placed())
				nextPlaced[feedback.fuseId] = feedback.slotId
				placed(nextPlaced)
				local count = 0
				for _ in nextPlaced do
					count += 1
				end
				ctx.setStatus(string.format("%d of %d wired", count, #challenge.slotIds), "Active")
				ctx.cue("Good")
			else
				rejectSerial += 1
				local mine = rejectSerial
				rejected(feedback.slotId)
				task.delay(REJECT_SECONDS, function()
					if mine == rejectSerial then
						rejected(nil)
					end
				end)
				ctx.setStatus("Wrong socket, try another")
				ctx.cue("Bad")
			end
		end

		ctx.setStatus(
			if Env.inputMode() == Enum.PreferredInput.Touch
				then "Drag, or tap a fuse then a socket"
				else "Drag each fuse to a socket"
		)

		local ghost = create("Frame")({
			Name = "DragGhost",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(CELL, CELL),
			BackgroundColor3 = Theme.color.primary,
			BackgroundTransparency = 0.15,
			ZIndex = 10,
			Visible = function()
				return drag.ghost() ~= nil
			end,
			Position = function()
				return drag.ghost() or UDim2.new()
			end,
			Base.corner(Theme.radius.md),
			Base.text("headline", {
				Size = UDim2.fromScale(1, 1),
				ZIndex = 11,
				Text = function()
					local id = drag.held()
					return if id then numberOf(id) else ""
				end,
				TextColor3 = Theme.color.onPrimary,
			}),
		}) :: Frame

		return { socketRow :: Instance, fuseRow :: Instance, ghost :: Instance }
	end,

	-- Feedback-less results are the shell's default "Keep going".
	onProgress = function(ctx, feedback)
		local handle = handlers[ctx]
		if handle ~= nil and type(feedback) == "table" then
			handle(feedback :: Feedback)
		else
			ctx.setStatus("Keep going", "Active")
		end
	end,
})
