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
-- piece lights red and a live wire in its stripe colour follows the
-- thumb; hovering a piece on the other row flashes green if the amps
-- match and red if not. A drop only SENDS the pair; once the server
-- accepts it a wire stays strung between the two and both turn green.
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
local WIRE = 6 -- wire thickness
local PLUG = 18 -- the plug on the end of a wire being dragged
local WIRE_OUTLINE = Color3.fromHex("#0B0E14")

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
	explainer = "Drag a wire from each fuse to the socket with the same amps. Wire all four to restore power.",

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
			if isPlaced(id) then
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
								BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
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
								Size = UDim2.fromOffset(22, 22),
								vide.show(function()
									return kinds[id] == "slot" and isPlaced(id)
								end, function()
									return Icons.view("check-badge", 22, Theme.color.inkOnLight)
								end) :: any,
								vide.show(function()
									return rejected() == id or hoverMatch(id) == false
								end, function()
									return Icons.view("cross-badge", 22, Theme.color.inkOnLight)
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

		-- A wired fuse stays put, strung to its socket: pieces never move
		-- under a thumb mid-reach.
		local fuseList: { Instance } = {}
		for i, fuseId in challenge.fuseIds do
			table.insert(fuseList, cell(fuseId, i, Theme.color.surfaceRaised))
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

		-- WIRES. Laid out from the pieces' absolute positions every frame
		-- (a handful of frames; the card's enter scale and a rotate both
		-- move the pieces). Everything is in scale units of the area -
		-- like the Drag adapter's ghost - so the area's UIScale can't
		-- throw the ends off the pieces; only the thickness is an offset.
		local wireLayer = create("Frame")({
			Name = "Wires",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 0,
		}) :: Frame

		local function wireFrame(name: string, color: Color3): Frame
			return create("Frame")({
				Name = name,
				AnchorPoint = Vector2.new(0.5, 0.5),
				BorderSizePixel = 0,
				BackgroundColor3 = color,
				Visible = false,
				Base.corner(Theme.radius.pill),
				create("UIStroke")({
					BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = WIRE_OUTLINE,
					Thickness = 1.5,
				}),
				Parent = wireLayer,
			}) :: Frame
		end

		-- Where a wire meets a piece: the socket's bottom edge or the
		-- fuse's top edge, the sides that face each other.
		local function endOf(id: string): Vector2
			local g = buttons[id]
			local p, s = g.AbsolutePosition, g.AbsoluteSize
			return Vector2.new(p.X + s.X / 2, if kinds[id] == "slot" then p.Y + s.Y else p.Y)
		end

		local function lay(wire: Frame, from: Vector2, to: Vector2)
			local a, s = ctx.area.AbsolutePosition, ctx.area.AbsoluteSize
			if s.X <= 0 or s.Y <= 0 then
				wire.Visible = false
				return
			end
			local mid, delta = (from + to) / 2 - a, to - from
			wire.Position = UDim2.fromScale(mid.X / s.X, mid.Y / s.Y)
			wire.Size = UDim2.new(delta.Magnitude / s.X, 0, 0, WIRE)
			wire.Rotation = math.deg(math.atan2(delta.Y, delta.X))
			wire.Visible = true
		end

		local wires: { [string]: Frame } = {}
		for _, fuseId in challenge.fuseIds do
			wires[fuseId] = wireFrame(fuseId .. "Wire", AMP_COLORS[amps[fuseId]] or Theme.color.line)
		end
		-- The wire being dragged draws over the pieces, not under them.
		local liveLayer = create("Frame")({
			Name = "LiveWire",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			ZIndex = 10,
		}) :: Frame
		local liveWire = wireFrame("Wire", Theme.color.line)
		liveWire.Parent = liveLayer
		local plug = create("Frame")({
			Name = "Plug",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(PLUG, PLUG),
			ZIndex = 2,
			Visible = false,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({
				BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = WIRE_OUTLINE,
				Thickness = 2,
			}),
			Parent = liveLayer,
		}) :: Frame

		local wireConn = RunService.Heartbeat:Connect(function()
			local current = placed()
			for fuseId, wire in wires do
				local slotId = current[fuseId]
				if slotId ~= nil then
					lay(wire, endOf(fuseId), endOf(slotId))
				else
					wire.Visible = false
				end
			end
			-- The live wire: from the held piece to the dragged ghost.
			local h, at = drag.held(), drag.ghost()
			if h ~= nil and at ~= nil and not isPlaced(h) then
				local a, s = ctx.area.AbsolutePosition, ctx.area.AbsoluteSize
				local tip = Vector2.new(a.X + at.X.Scale * s.X, a.Y + at.Y.Scale * s.Y)
				local color = AMP_COLORS[amps[h]] or Theme.color.line
				liveWire.BackgroundColor3 = color
				plug.BackgroundColor3 = color
				plug.Position = at
				plug.Visible = true
				lay(liveWire, endOf(h), tip)
			else
				liveWire.Visible = false
				plug.Visible = false
			end
		end)
		vide.cleanup(function()
			wireConn:Disconnect()
		end)

		return { wireLayer :: Instance, socketRow :: Instance, fuseRow :: Instance, liveLayer :: Instance }
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
