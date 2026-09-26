--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The client half of P2-6's Drag reference task (tasks-catalogue.md #7,
-- `fuse-rewire`) - see src/server/TaskHandlers/FuseRewire.luau for the
-- server half. Built on UI/TaskViewBase like CodePlayback.luau: the
-- shell owns the window, close, timer and status line; this file owns
-- the sockets, the fuses and what a drop looks like.
--
-- The match is visible: each fuse and its socket show the same amperage
-- (and colour stripe). Either row can be picked first - drag a fuse onto
-- a socket or a socket onto a fuse, or tap one then the other. The held
-- piece lights red; hovering it over a piece on the other row flashes
-- green if the amps match and red if not; a drop only SENDS the pair,
-- and the socket turns solid green once the server accepts it.
--
-- Right and wrong are never colour alone: amps are printed on every
-- piece, a wired socket shows a check, a rejected one a cross.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.UI.Components.Base)
local Icons = require(script.Parent.Parent.UI.Components.Icons)
local InputAdapters = require(script.Parent.Parent.UI.InputAdapters)
local TaskViewBase = require(script.Parent.Parent.UI.TaskViewBase)
local Theme = require(script.Parent.Parent.UI.Theme)

local create = vide.create
local source = vide.source

type Challenge = {
	fuseIds: { string },
	slotIds: { string },
	fuseAmps: { [string]: number },
	slotAmps: { [string]: number },
}

type Feedback = {
	accepted: boolean,
	fuseId: string,
	slotId: string,
}

type Kind = "fuse" | "slot"

-- 4 x 64 plus gaps fits a 360-point portrait sheet inside its margins.
local CELL = 64
local GAP = Theme.spacing.md
local STRIPE = 8
local REJECT_SECONDS = 0.4
local BLINK_HZ = 6

-- Stripe per rating, kept clear of the red/green feedback fills. The
-- printed amps are the real cue; the stripe just speeds up the scan.
local AMP_COLORS: { [number]: Color3 } = {
	[5] = Color3.fromHex("#C8A27A"),
	[10] = Color3.fromHex("#4F8CF0"),
	[15] = Color3.fromHex("#FFC53D"),
	[20] = Color3.fromHex("#A77BF3"),
	[25] = Color3.fromHex("#E6E9EF"),
	[30] = Color3.fromHex("#F28FD0"),
}

-- Per-attempt feedback handlers, keyed by the attempt's ctx: onProgress
-- is spec-level but the sources it updates are built per attempt.
local handlers: { [any]: (Feedback) -> () } = setmetatable({}, { __mode = "k" }) :: any

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

		local kinds: { [string]: Kind } = {}
		local amps: { [string]: number } = {}
		for _, id in challenge.fuseIds do
			kinds[id] = "fuse"
			amps[id] = challenge.fuseAmps[id]
		end
		for _, id in challenge.slotIds do
			kinds[id] = "slot"
			amps[id] = challenge.slotAmps[id]
		end

		local function fuseIn(slotId: string): string?
			for fuseId, s in placed() do
				if s == slotId then
					return fuseId
				end
			end
			return nil
		end

		local function isPlaced(id: string): boolean
			return if kinds[id] == "fuse" then placed()[id] ~= nil else fuseIn(id) ~= nil
		end

		local function ampText(id: string?): string
			local a = if id ~= nil then amps[id] else nil
			return if a ~= nil then string.format("%dA", a) else ""
		end

		-- Mirror the Drag adapter's sources. The adapter needs the buttons,
		-- so it's created after them; visuals bind to these proxies.
		local held: Base.Source<string?> & ((string?) -> string?) = source(nil) :: any
		local hovered: Base.Source<string?> & ((string?) -> string?) = source(nil) :: any

		local blink: Base.Source<boolean> & ((boolean) -> boolean) = source(true) :: any
		local blinkConn = RunService.Heartbeat:Connect(function()
			local on = (os.clock() * BLINK_HZ) % 2 < 1
			if on ~= blink() then
				blink(on)
			end
		end)
		vide.cleanup(function()
			blinkConn:Disconnect()
		end)

		-- The hovered piece's hint: nil when nothing's hovered or it's the
		-- same row as the held piece (not somewhere it could go).
		local function hoverMatch(id: string): boolean?
			local h = held()
			if h == nil or hovered() ~= id or kinds[h] == kinds[id] or isPlaced(id) then
				return nil
			end
			return amps[h] == amps[id]
		end

		local function fill(id: string, idle: Color3): Color3
			if kinds[id] == "slot" and isPlaced(id) then
				return Theme.color.success
			elseif held() == id then
				return Theme.color.danger
			end
			local match = hoverMatch(id)
			if match ~= nil then
				return if not blink() then idle elseif match then Theme.color.success else Theme.color.danger
			elseif rejected() == id then
				return Theme.color.danger
			end
			return idle
		end

		local function isLit(id: string): boolean
			return fill(id, Theme.color.surface) ~= Theme.color.surface
		end

		local buttons: { [string]: GuiButton } = {}

		local function cell(id: string, index: number, idle: Color3): GuiButton
			local button = Base.interactive({
				name = id,
				size = Vector2.new(CELL, CELL),
				layoutOrder = index,
				order = (if kinds[id] == "slot" then 10 else 0) + index,
				radius = Theme.radius.md,
				onActivate = function() end, -- Drag listens for Activated itself
				visual = function()
					return {
						create("Frame")({
							Name = "Surface",
							Size = UDim2.fromScale(1, 1),
							BackgroundColor3 = function()
								return fill(id, idle)
							end,
							Base.corner(Theme.radius.md),
							create("UIStroke")({
								ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
								Color = function()
									return if held() == id then Theme.color.focus else Theme.color.line
								end,
								-- Thicker ring on the held piece: the pick is shape, not just fill.
								Thickness = function()
									return if held() == id then 3 else 2
								end,
							}),
							create("Frame")({
								Name = "Stripe",
								BorderSizePixel = 0,
								Size = UDim2.new(1, 0, 0, STRIPE),
								BackgroundColor3 = AMP_COLORS[amps[id]] or Theme.color.line,
								Base.corner(Theme.radius.md),
							}),
							Base.text("title", {
								Position = UDim2.fromOffset(0, STRIPE),
								Size = UDim2.new(1, 0, 1, -STRIPE),
								Text = ampText(id),
								TextColor3 = function()
									return if isLit(id) then Theme.color.inkOnLight else Theme.color.ink
								end,
							}),
							-- Corner badge: the non-colour half of right/wrong.
							create("Frame")({
								Name = "Badge",
								BackgroundTransparency = 1,
								AnchorPoint = Vector2.new(1, 1),
								Position = UDim2.new(1, -2, 1, -2),
								Size = UDim2.fromOffset(20, 20),
								vide.show(function()
									return kinds[id] == "slot" and isPlaced(id)
								end, function()
									return Icons.view("check", 18, Theme.color.inkOnLight)
								end) :: any,
								vide.show(function()
									return rejected() == id or hoverMatch(id) == false
								end, function()
									return Icons.view("close", 18, Theme.color.inkOnLight)
								end) :: any,
							}),
						}),
					}
				end,
			})
			buttons[id] = button
			return button
		end

		local socketList: { Instance } = {}
		for i, slotId in challenge.slotIds do
			table.insert(socketList, cell(slotId, i, Theme.color.surface))
		end

		local fuseList: { Instance } = {}
		for i, fuseId in challenge.fuseIds do
			local button = cell(fuseId, i, Theme.color.surfaceRaised)
			-- A wired fuse leaves the tray (its amps show in the socket).
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
			table.insert(fuseList, holder)
		end

		local socketRow = row("Sockets", socketList, 0)
		local fuseRow = row("Fuses", fuseList, 1)

		-- Every piece is both something to pick and somewhere to drop; a
		-- drop onto the same row is ignored.
		local drag = InputAdapters.Drag({
			items = buttons,
			targets = buttons,
			area = ctx.area,
			onDrop = function(a: string, b: string)
				if kinds[a] == kinds[b] then
					return
				end
				local fuseId = if kinds[a] == "fuse" then a else b
				local slotId = if kinds[a] == "slot" then a else b
				if placed()[fuseId] ~= nil or fuseIn(slotId) ~= nil then
					return
				end
				ctx.submit("FuseDropSubmit", { fuseId = fuseId, slotId = slotId })
			end,
		})
		vide.effect(function()
			held(drag.held())
		end)
		vide.effect(function()
			hovered(drag.hovered())
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
				ctx.setStatus("Wrong socket, match the amps")
				ctx.cue("Bad")
			end
		end

		ctx.setStatus("Match the amps: drag each fuse to its socket")

		local ghost = create("Frame")({
			Name = "DragGhost",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(CELL, CELL),
			BackgroundColor3 = Theme.color.danger,
			BackgroundTransparency = 0.15,
			ZIndex = 10,
			Visible = function()
				return drag.ghost() ~= nil
			end,
			Position = function()
				return drag.ghost() or UDim2.new()
			end,
			Base.corner(Theme.radius.md),
			Base.text("title", {
				Size = UDim2.fromScale(1, 1),
				ZIndex = 11,
				Text = function()
					return ampText(drag.held())
				end,
				TextColor3 = Theme.color.inkOnLight,
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
