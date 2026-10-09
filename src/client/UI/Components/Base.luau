--!strict
-- Vide's create() takes properties and children in one table by design.
--# selene: allow(mixed_table)
-- Primitives the components are built from (P6-2): themed text, corner
-- and stroke helpers, the focus ring, the loading spinner, and
-- `interactive` - the one hit-area implementation every tappable
-- component shares, so touch-target padding, focus and the
-- pressed/hovered/disabled/loading states are written exactly once.
--
-- SIZING (docs/ui-foundation.md "Scale vs Offset"): component contents
-- are Offsets in REFERENCE pixels taken from Theme tokens, under a
-- screen root carrying UIScaleController.attachScale. Scale is used for
-- fills and fractions inside a component (a progress fill, a centred
-- child). A hand-typed Offset that isn't a token is a bug.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local effect = vide.effect
local cleanup = vide.cleanup

export type Source<T> = () -> T
export type State = ComponentLogic.State

local Base = {}

-- Wraps a plain value as a source so props can be either.
function Base.read<T>(value: T | Source<T>): Source<T>
	if type(value) == "function" then
		return value :: Source<T>
	end
	return function(): T
		return value :: T
	end
end

function Base.corner(radius: UDim): Instance
	return create("UICorner")({ CornerRadius = radius })
end

function Base.padding(px: number): Instance
	local u = UDim.new(0, px)
	return create("UIPadding")({ PaddingTop = u, PaddingBottom = u, PaddingLeft = u, PaddingRight = u })
end

-- A themed label. TextScaled bounded by a UITextSizeConstraint
-- (architecture.md §5.6): it fits its box, but never shrinks below the
-- style's `min` or grows past its `size`. Box size comes from `props`.
-- `outline` false drops the display face's outline: dark ink on a light
-- fill (a gold button) would blur into a dark outline.
function Base.text(styleName: string, props: { [any]: any }, outline: boolean?): TextLabel
	local style = Theme.type[styleName]
	assert(style ~= nil, string.format("Base.text: no type style %q", styleName))
	local merged: { [any]: any } = {
		BackgroundTransparency = 1,
		FontFace = style.font,
		TextScaled = true,
		TextColor3 = Theme.color.ink,
		TextWrapped = true,
		create("UITextSizeConstraint")({ MaxTextSize = style.size, MinTextSize = style.min }),
		-- Display-face labels carry a dark outline (Tokens.outline).
		if style.outline and outline ~= false
			then create("UIStroke")({
				Name = "Outline",
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
				Color = Theme.outline.color,
				Thickness = Theme.outline.thickness,
			})
			else nil,
	}
	for k, v in props do
		if type(k) == "number" then
			table.insert(merged, v)
		else
			merged[k] = v
		end
	end
	local label = create("TextLabel")(merged) :: TextLabel
	-- Setting TextScaled turns TextWrapped back on, and Vide applies
	-- properties in no fixed order, so a caller's `TextWrapped = false`
	-- was silently lost (names wrapped mid-word instead of shrinking).
	-- Re-apply it once TextScaled has been set.
	if merged.TextWrapped == false then
		label.TextWrapped = false
	end
	return label
end

-- The focus ring: a stroke outside the visual in Theme.color.focus.
-- Always drawn for gamepad and keyboard focus (never hidden to look
-- clean - on a controller it's the only cursor there is).
function Base.focusRing(focused: Source<boolean>): Instance
	return create("UIStroke")({
		Name = "FocusRing",
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		-- Inner, like every border stroke in the UI: an Outer stroke
		-- draws past the element's edge, so a card flush against a
		-- ScrollingFrame's (or any ClipsDescendants) edge lost that side
		-- of its outline (playtest, 2026-10-06).
		BorderStrokePosition = Enum.BorderStrokePosition.Inner,
		Color = Theme.color.focus,
		Thickness = 3,
		Enabled = focused,
	})
end

-- A small spinning arc for the loading state. Under reduced motion it
-- holds still: three dots read as "working" without movement.
function Base.spinner(size: number, color: Source<Color3>): GuiObject
	local rotation = source(0)
	effect(function()
		if Env.reducedMotion() then
			return
		end
		local conn = RunService.RenderStepped:Connect(function(dt: number)
			rotation((rotation() + dt * 360) % 360)
		end)
		cleanup(conn)
	end)

	return create("Frame")({
		Name = "Spinner",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(size, size),
		BackgroundTransparency = 1,
		Rotation = rotation,
		create("UIStroke")({
			Color = color,
			Thickness = 3,
			Enabled = function()
				return not Env.reducedMotion()
			end,
			create("UIGradient")({
				-- Hard edge: a three-quarter arc.
				Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(0.74, 0),
					NumberSequenceKeypoint.new(0.75, 1),
					NumberSequenceKeypoint.new(1, 1),
				}),
			}),
		}),
		Base.corner(Theme.radius.pill),
		Base.text("label", {
			Size = UDim2.fromScale(1, 1),
			Text = "...",
			TextColor3 = color,
			Visible = Env.reducedMotion,
		}),
	}) :: Frame
end

-- INTERACTIVE ----------------------------------------------------------

export type InteractiveProps = {
	name: string?,
	-- Visual size in reference pixels. The hit area is at least this,
	-- padded up to the 44-point minimum at the current scale.
	size: Vector2 | Source<Vector2>,
	disabled: (boolean | Source<boolean>)?,
	loading: (boolean | Source<boolean>)?,
	onActivate: () -> (),
	-- Controller/keyboard navigation order (GuiObject.SelectionOrder):
	-- lower is visited first when the group is entered.
	order: number?,
	layoutOrder: number?,
	position: (UDim2 | Source<UDim2>)?,
	anchorPoint: Vector2?,
	-- The visual's corner radius, which the focus ring follows.
	radius: UDim?,
	-- Builds the visual. It's parented inside the hit area, centred, and
	-- sized to `size`; the builder only supplies its contents.
	visual: (state: Source<State>, focused: Source<boolean>) -> { Instance },
}

-- Returns the hit area (a transparent TextButton). State precedence
-- and which states accept input live in ComponentLogic; this only
-- turns input events into the booleans it ranks.
function Base.interactive(props: InteractiveProps): TextButton
	local disabled: Source<boolean> = Base.read(props.disabled or false)
	local loading: Source<boolean> = Base.read(props.loading or false)
	local visualSize: Source<Vector2> = Base.read(props.size)

	local hovered = source(false)
	local pressed = source(false)
	local focused = source(false)

	-- Hover only means something with a mouse. On touch, Roblox fires
	-- MouseEnter on tap and never a matching leave, which would leave a
	-- button stuck "hovered" after the finger lifts.
	-- (Cast: Vide's source<T> widens a string-literal union to `string`,
	-- which would lose the State type at every read.)
	local state: Source<State> & ((State) -> State) = source("idle") :: any
	effect(function()
		state(ComponentLogic.resolveState({
			disabled = disabled(),
			loading = loading(),
			pressed = pressed(),
			hovered = hovered() and Env.inputMode() == Enum.PreferredInput.KeyboardAndMouse,
		}))
	end)

	local hit = derive(function(): Vector2
		local v = visualSize()
		local minRef = Env.minTouchRef()
		local w = ComponentLogic.hitArea(v.X, minRef)
		local h = ComponentLogic.hitArea(v.Y, minRef)
		return Vector2.new(w, h)
	end)

	local function isPress(input: InputObject): boolean
		local t = input.UserInputType
		return t == Enum.UserInputType.MouseButton1
			or t == Enum.UserInputType.Touch
			or input.KeyCode == Enum.KeyCode.ButtonA
			or input.KeyCode == Enum.KeyCode.Return
	end

	return create("TextButton")({
		Name = props.name or "Interactive",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		LayoutOrder = props.layoutOrder or 0,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchorPoint or Vector2.zero,
		Size = function()
			local h = hit()
			return UDim2.fromOffset(h.X, h.Y)
		end,
		Selectable = function()
			return not disabled()
		end,
		SelectionOrder = props.order or 0,
		-- Suppress Roblox's default selection highlight; the FocusRing
		-- on the visual is the one focus indicator, styled to the theme.
		SelectionImageObject = create("Frame")({ BackgroundTransparency = 1, Size = UDim2.fromScale(0, 0) }),

		MouseEnter = function()
			hovered(true)
		end,
		MouseLeave = function()
			hovered(false)
			pressed(false)
		end,
		InputBegan = function(input: InputObject)
			if isPress(input) then
				pressed(true)
			end
		end,
		InputEnded = function(input: InputObject)
			if isPress(input) then
				pressed(false)
			end
		end,
		SelectionGained = function()
			focused(true)
		end,
		SelectionLost = function()
			focused(false)
			pressed(false)
		end,
		Activated = function()
			if ComponentLogic.acceptsInput(state()) then
				props.onActivate()
			end
		end,

		create("Frame")({
			Name = "Visual",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = function()
				local v = visualSize()
				return UDim2.fromOffset(v.X, v.Y)
			end,
			BackgroundTransparency = 1,
			create("UIScale")({
				Scale = Env.animate(function()
					return ComponentLogic.pressScale(state())
				end, Theme.motion.fast),
			}),
			-- The ring follows the visual's shape, not the square hit area.
			Base.corner(props.radius or Theme.radius.md),
			Base.focusRing(focused),
			props.visual(state, focused),
		}),
	}) :: TextButton
end

-- Just the stage-panel gradient (on a Base.STAGE_BACKGROUND Frame), for
-- a surface that keeps its own stroke - a store tile's rarity rim. While
-- `lit` is true it lifts a step toward white: the pressed/selected look.
local LIT = 0.12
function Base.stageGradient(lit: Source<boolean>?): Instance
	local panel = Theme.fill.panel
	local litGradient =
		ColorSequence.new(panel.top:Lerp(Color3.new(1, 1, 1), LIT), panel.bottom:Lerp(Color3.new(1, 1, 1), LIT))
	return create("UIGradient")({
		Rotation = 90,
		Color = function()
			return if lit and lit() then litGradient else panel.gradient
		end,
	})
end

export type StageProps = {
	-- Rim colour; default the gold panel rim.
	rim: (Color3 | Source<Color3>)?,
	-- Rim thickness in reference px; default 2.
	thickness: (number | Source<number>)?,
	-- The gradient; default the stage panel's (Tokens.fill.panel).
	gradient: ColorSequence?,
}

-- The UI art pass's stage-panel surface for a plain Frame: a vertical
-- UIGradient and an inner rim stroke, as children. The UIGradient TINTS,
-- so the Frame's BackgroundColor3 must be Base.STAGE_BACKGROUND (white);
-- any other colour comes out murky.
-- Typed `any`: Vide takes a nested child array, but a props table whose
-- other children are Instances would refuse a `{ Instance }` among them.
function Base.stage(props: StageProps?): any
	local p: StageProps = props or {}
	return {
		create("UIGradient")({ Rotation = 90, Color = p.gradient or Theme.fill.panel.gradient }),
		create("UIStroke")({
			Name = "Rim",
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = p.rim or Theme.fill.panel.rim,
			Thickness = p.thickness or 2,
		}),
	}
end

-- The background a Base.stage Frame takes.
Base.STAGE_BACKGROUND = Color3.new(1, 1, 1)

export type RaisedProps = {
	fill: Source<Theme.Fill>,
	-- Lip depth (Theme.lip). The surface is that much shorter than the
	-- box, so lip and surface together never spill past it.
	lip: number,
	radius: UDim,
	-- True drops the surface onto its lip: the press.
	sunk: Source<boolean>?,
	rimThickness: number?,
	-- A white sheen over the top 40% (the mockup's glossy buttons).
	gloss: boolean?,
	-- Fades lip, surface and rim together (the ghost variant at rest).
	transparency: Source<number>?,
	-- Children of the surface (content, overlays).
	children: { any }?,
}

-- The UI art pass's raised surface (Tokens.fill): a darker lip Frame
-- under a gradient surface with a rim stroke. Roblox has no box-shadow;
-- this is the shadow. Returns the two Frames for the caller to parent.
function Base.raised(props: RaisedProps): { Instance }
	local lip = props.lip
	local transparency: Source<number> = props.transparency or function()
		return 0
	end
	local sunk: Source<boolean> = props.sunk or function()
		return false
	end
	local surface: { [any]: any } = {
		Name = "Surface",
		Size = UDim2.new(1, 0, 1, -lip),
		Position = Env.animate(function(): UDim2
			return UDim2.fromOffset(0, if sunk() then lip else 0)
		end, Theme.motion.fast),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = transparency,
		ZIndex = 2,
		Base.corner(props.radius),
		create("UIGradient")({
			Rotation = 90,
			Color = function()
				return props.fill().gradient
			end,
		}),
		create("UIStroke")({
			Name = "Rim",
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = function()
				return props.fill().rim
			end,
			Thickness = props.rimThickness or 2,
			Transparency = transparency,
		}),
		if props.gloss
			then create("Frame")({
				Name = "Gloss",
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, Theme.spacing.xs),
				Size = UDim2.new(1, -Theme.spacing.md, 0.4, 0),
				BackgroundColor3 = Color3.new(1, 1, 1),
				ZIndex = 2,
				Base.corner(props.radius),
				create("UIGradient")({
					Rotation = 90,
					Transparency = NumberSequence.new(0.55, 1),
				}),
			})
			else nil,
	}
	local children: { any } = props.children or {}
	for _, child in children do
		table.insert(surface, child)
	end
	return {
		create("Frame")({
			Name = "Lip",
			Size = UDim2.new(1, 0, 1, -lip),
			Position = UDim2.fromOffset(0, lip),
			BackgroundColor3 = function()
				return props.fill().lip
			end,
			BackgroundTransparency = transparency,
			Base.corner(props.radius),
		}),
		create("Frame")(surface),
	}
end

return Base
