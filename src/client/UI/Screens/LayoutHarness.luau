--!strict
-- Device test screen for the UI foundation (P6-1). Screenshot it on the
-- real phone, tablet and desktop from docs/perf-budget.md §3 - one
-- screenshot shows everything P6-1 decided:
--
--   - the usable rect twice: once as the ENGINE lays it out (a frame
--     filling a CoreUISafeInsets ScreenGui) and once as the controller
--     COMPUTED it (drawn in absolute pixels on a full-bleed ScreenGui).
--     If the two outlines don't coincide, the controller's inset maths
--     is wrong on that device - visible, not assumed.
--   - the thumb zones for the current orientation, over Roblox's real
--     thumbstick and jump button, so any drift in Roblox's control
--     placement shows up against our reserved rects.
--   - the live numbers: viewport, usable rect, scale, input mode.
--   - a 44-point touch target, a 100-reference-pixel ruler, the type
--     scale, and the Steal/Share pair with its CVD simulations.
--
-- Mounted by UIScaleController when ReplicatedStorage has the
-- UILayoutHarness attribute set. Debug only; nothing here ships to
-- players in normal play.

local GuiService = game:GetService("GuiService")
local Workspace = game:GetService("Workspace")

local ColorVision = require(script.Parent.Parent.ColorVision)
local Layout = require(script.Parent.Parent.Layout)
local Theme = require(script.Parent.Parent.Theme)
local Tokens = require(script.Parent.Parent.Tokens)

-- Overlay colours are labelled in text as well, so the screenshot reads
-- the same to a colour-blind reviewer.
local ZONE_COLOR: { [Layout.ZoneKind]: Color3 } = {
	Primary = Color3.fromHex("#3CCB7F"),
	Secondary = Color3.fromHex("#FFC53D"),
	Info = Color3.fromHex("#4FA3F0"),
	ReservedMove = Color3.fromHex("#F0524F"),
	ReservedJump = Color3.fromHex("#F0524F"),
}

local function frame(props: { [string]: any }): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	for key, value in props do
		(f :: any)[key] = value
	end
	return f
end

local function label(parent: Instance, text: string, style: string, props: { [string]: any }?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.TextColor3 = Theme.color.ink
	l.Text = text
	Theme.applyText(l, style)
	local extra: { [string]: any } = props or {}
	for key, value in extra do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

local function outline(parent: Instance, color: Color3, thickness: number)
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
end

local function stack(parent: Instance, padding: number)
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, padding)
	list.Parent = parent
end

-- Steal = diamond (a square rotated 45), Share = pill. Same size, so
-- the silhouette is the only shape difference.
local function decisionShape(parent: Instance, which: "steal" | "share", fill: Color3, size: number, order: number)
	local cell = frame({ BackgroundTransparency = 1, Size = UDim2.fromOffset(size, size), LayoutOrder = order })
	local spec = Theme.decision[which]
	local shape = frame({
		BackgroundColor3 = fill,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
	})
	if spec.shape == "Diamond" then
		shape.Size = UDim2.fromOffset(size * 0.7, size * 0.7)
		shape.Rotation = 45
	else
		shape.Size = UDim2.fromOffset(size, size * 0.6)
		local corner = Instance.new("UICorner")
		corner.CornerRadius = Theme.radius.pill
		corner.Parent = shape
	end
	shape.Parent = cell
	cell.Parent = parent
end

local LayoutHarness = {}

function LayoutHarness.mount(controller: any): () -> ()
	local connections: { () -> () } = {}

	-- 1. Engine truth: a CoreUISafeInsets ScreenGui's full frame IS the
	--    safe area as Roblox lays it out. Zones go here too, positioned
	--    by Scale exactly as a real HUD would place them.
	local safeGui = controller.createScreen("LayoutHarnessSafe", { displayOrder = Tokens.displayOrder.debug })
	local safeFrame = frame({ BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	outline(safeFrame, Theme.color.success, 4)
	safeFrame.Parent = safeGui

	local zoneLayer = frame({ BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	zoneLayer.Parent = safeFrame

	-- 2. Controller's claim: drawn in absolute pixels on a full-bleed
	--    ScreenGui, a thin outline that should sit on the thick one.
	--    The red outline is the raw viewport, for scale.
	local bleedGui = controller.createScreen(
		"LayoutHarnessBleed",
		{ displayOrder = Tokens.displayOrder.debug + 1, fullBleed = true }
	)
	local viewportFrame = frame({ BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) })
	outline(viewportFrame, Theme.color.danger, 2)
	viewportFrame.Parent = bleedGui
	local computedFrame = frame({ BackgroundTransparency = 1 })
	outline(computedFrame, Theme.color.ink, 1)
	computedFrame.Parent = bleedGui

	-- 3. The readout panel, in reference pixels under the global scale.
	local panel = frame({
		BackgroundColor3 = Theme.elevation[3].surface,
		BackgroundTransparency = 0.1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	local corner = Instance.new("UICorner")
	corner.CornerRadius = Theme.radius.lg
	corner.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, Theme.spacing.md)
	pad.PaddingBottom = UDim.new(0, Theme.spacing.md)
	pad.PaddingLeft = UDim.new(0, Theme.spacing.md)
	pad.PaddingRight = UDim.new(0, Theme.spacing.md)
	pad.Parent = panel
	stack(panel, Theme.spacing.sm)
	panel.Parent = safeFrame
	table.insert(connections, controller.attachScale(panel))

	local readout = label(panel, "", "caption", {
		Size = UDim2.new(1, 0, 0, 96),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		LayoutOrder = 1,
	})
	readout.TextScaled = false
	readout.TextSize = Theme.type.caption.size
	readout.TextWrapped = true

	-- A hit area of minTouchRef reference pixels renders at 44 points.
	-- Next to it, a 100-reference-pixel ruler: measure it on the
	-- screenshot to check the scale the readout claims.
	local sizes = frame({ BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 64), LayoutOrder = 2 })
	local touch = frame({ BackgroundColor3 = Theme.color.brand })
	touch.Parent = sizes
	label(touch, "44pt", "caption", { Size = UDim2.fromScale(1, 1) })
	local ruler = frame({
		BackgroundColor3 = Theme.color.ink,
		Position = UDim2.new(0, 80, 0.5, 0),
		Size = UDim2.fromOffset(100, 4),
	})
	ruler.Parent = sizes
	label(sizes, "100 ref px", "caption", {
		Position = UDim2.new(0, 80, 0.5, 6),
		Size = UDim2.fromOffset(100, 16),
	})
	sizes.Parent = panel

	for i, name in { "display", "headline", "title", "label", "body", "caption" } do
		local style = Theme.type[name]
		label(panel, string.format("%s %d/%d", name, style.size, style.min), name, {
			Size = UDim2.new(1, 0, 0, style.size),
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 10 + i,
		})
	end

	-- Steal/Share as rendered, then as each deficiency sees them.
	type Row = { name: string, fn: (ColorVision.RGB) -> ColorVision.RGB }
	local rows: { Row } = {
		{
			name = "normal",
			fn = function(c: ColorVision.RGB): ColorVision.RGB
				return c
			end,
		},
	}
	for _, deficiency: ColorVision.Deficiency in ColorVision.DEFICIENCIES do
		table.insert(rows, {
			name = deficiency :: string,
			fn = function(c: ColorVision.RGB): ColorVision.RGB
				return ColorVision.simulate(c, deficiency)
			end,
		})
	end
	local steal = ColorVision.fromHex(Tokens.color.steal)
	local share = ColorVision.fromHex(Tokens.color.share)
	for i, row in rows do
		local line = frame({ BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28), LayoutOrder = 20 + i })
		local layout = Instance.new("UIListLayout")
		layout.FillDirection = Enum.FillDirection.Horizontal
		layout.VerticalAlignment = Enum.VerticalAlignment.Center
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Padding = UDim.new(0, Theme.spacing.sm)
		layout.Parent = line
		decisionShape(line, "steal", Color3.fromHex(ColorVision.toHex(row.fn(steal))), 28, 1)
		decisionShape(line, "share", Color3.fromHex(ColorVision.toHex(row.fn(share))), 28, 2)
		label(line, row.name, "caption", {
			Size = UDim2.fromOffset(120, 16),
			TextXAlignment = Enum.TextXAlignment.Left,
			LayoutOrder = 3,
		})
		line.Parent = panel
	end

	local function redrawZones(rect: Layout.Rect)
		zoneLayer:ClearAllChildren()
		for _, zone in Layout.THUMB_ZONES[Layout.orientationOf(rect.width, rect.height)] do
			local r = zone.rect
			local z = frame({
				BackgroundColor3 = ZONE_COLOR[zone.kind],
				BackgroundTransparency = 0.75,
				Position = UDim2.fromScale(r.x, r.y),
				Size = UDim2.fromScale(r.width, r.height),
			})
			outline(z, ZONE_COLOR[zone.kind], 1)
			label(z, zone.kind, "caption", {
				Position = UDim2.fromOffset(4, 4),
				Size = UDim2.new(1, -8, 0, 16),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			z.Parent = zoneLayer
		end
	end

	local function refresh()
		local rect: Layout.Rect = controller.getUsableRect()
		local scale: number = controller.getScale()
		local camera = Workspace.CurrentCamera
		local viewport = if camera ~= nil then camera.ViewportSize else Vector2.zero
		local mm = GuiService.ViewportSizeInMM

		computedFrame.Position = UDim2.fromOffset(rect.x, rect.y)
		computedFrame.Size = UDim2.fromOffset(rect.width, rect.height)

		local touchRef = Layout.minTouchRef(scale, Tokens.touch.minTargetPoints)
		touch.Size = UDim2.fromOffset(touchRef, touchRef)

		readout.Text = table.concat({
			string.format("viewport %dx%d  (%.0fx%.0f mm)", viewport.X, viewport.Y, mm.X, mm.Y),
			string.format("usable %d,%d  %dx%d", rect.x, rect.y, rect.width, rect.height),
			string.format(
				"scale %.3f  (raw %.3f, clamp %.2f-%.2f)",
				scale,
				math.min(rect.width, rect.height) / Tokens.scale.referenceShortAxis,
				Tokens.scale.min,
				Tokens.scale.max
			),
			string.format("orientation %s", Layout.orientationOf(rect.width, rect.height)),
			string.format("input %s", controller.getInputMode().Name),
			string.format("touch target %d ref px = 44pt", touchRef),
			"green thick = engine safe area; white thin = computed",
		}, "\n")
	end

	table.insert(
		connections,
		controller.observeUsableRect(function(rect: Layout.Rect)
			redrawZones(rect)
			refresh()
		end)
	)
	table.insert(connections, controller.observeScale(refresh))
	table.insert(connections, controller.observeInputMode(refresh))

	return function()
		for _, disconnect in connections do
			disconnect()
		end
		safeGui:Destroy()
		bleedGui:Destroy()
	end
end

return LayoutHarness
