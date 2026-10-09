--!strict
-- Panel (P6-2): the surface everything else sits on. Elevation picks
-- the look: 1 is the flat page; 2 (card, HUD panel) and 3 (modal) are
-- the UI art pass's stage panel, a purple gradient (Tokens.fill.panel)
-- in a gold rim, thicker at 3. No lip here: a lip is a sibling Frame,
-- which would fight `automaticSize`; buttons carry the depth instead.
--
-- Size is the caller's: a Panel that fills a screen REGION is sized in
-- Scale by the screen; a card-sized Panel uses token Offsets or
-- `automaticSize` to hug its content.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Props = {
	elevation: number?, -- 1-3, default 2
	size: UDim2?,
	automaticSize: Enum.AutomaticSize?,
	position: UDim2?,
	anchorPoint: Vector2?,
	padding: number?, -- reference px, default spacing.lg
	title: string?,
	layoutOrder: number?,
	-- Lays children out vertically with this gap; nil for manual layout.
	gap: number?,
	name: string?,
	children: { Instance }?,
}

local function Panel(props: Props): Frame
	local level = Theme.elevation[props.elevation or 2]
	assert(level ~= nil, "Panel: elevation must be 1-3")

	-- Elevation 2 and 3 are the gradient stage panel; 1 stays flat.
	local raised = level ~= Theme.elevation[1]
	local body: { any } = {
		Base.corner(Theme.radius.lg),
		create("UIStroke")({
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = if raised then Theme.fill.panel.rim else Theme.color.line,
			Transparency = level.strokeTransparency,
			Thickness = if level == Theme.elevation[3] then 3 else 2,
		}),
		Base.padding(props.padding or Theme.spacing.lg),
		if raised then create("UIGradient")({ Rotation = 90, Color = Theme.fill.panel.gradient }) else nil,
	}
	if props.gap then
		table.insert(
			body,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, props.gap),
				SortOrder = Enum.SortOrder.LayoutOrder,
			})
		)
	end
	if props.title then
		table.insert(
			body,
			Base.text("title", {
				Name = "Title",
				LayoutOrder = -1,
				Size = UDim2.new(1, 0, 0, Theme.type.title.size + Theme.spacing.xs),
				Text = props.title,
				TextXAlignment = Enum.TextXAlignment.Left,
			})
		)
	end
	local extra: { Instance } = props.children or {}
	for _, child in extra do
		table.insert(body, child)
	end

	local frame = create("Frame")({
		Name = props.name or "Panel",
		Size = props.size or UDim2.fromScale(1, 1),
		AutomaticSize = props.automaticSize or Enum.AutomaticSize.None,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchorPoint or Vector2.zero,
		LayoutOrder = props.layoutOrder or 0,
		-- The UIGradient tints white; a flat panel takes its surface colour.
		BackgroundColor3 = if raised then Color3.new(1, 1, 1) else level.surface,
		BackgroundTransparency = 0,
	}) :: Frame
	for _, child in body do
		(child :: Instance).Parent = frame
	end
	return frame
end

return Panel
