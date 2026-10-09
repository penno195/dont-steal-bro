--!strict
--# selene: allow(mixed_table) -- Vide props + children, see UI/Components/Base.luau
-- The illustrated pieces the hand-drawn task views share: image ids and
-- the few builders more than one view uses (a tintable lamp, a soft glow,
-- the chunky 3D button). The art is generated from SVG and lives with
-- its source in assets/taskviews/ (README there says how to redraw and
-- re-upload); the ids below are those uploads.
--
-- Tintable pieces (lamp glass, button face, glow) are drawn near-white,
-- so ImageColor3 picks their colour and one image serves every use.

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Components.Base)

local create = vide.create

local TaskArt = {}

TaskArt.image = table.freeze({
	glow = "rbxassetid://96266303574461", -- 256x256 radial, white
	lamp = "rbxassetid://74439036798529", -- 128x128 bezel + white glass
	button = "rbxassetid://139424222917940", -- 256x136, 9-sliced
	killPlate = "rbxassetid://93535533002112", -- 480x560
	killButton = "rbxassetid://97048344563976", -- 256x256
	siren = "rbxassetid://70675143544611", -- 256x256
	gauge = "rbxassetid://112878248184079", -- 640x440
	needle = "rbxassetid://109908207651781", -- 64x480, hub at the centre
	airlockTrack = "rbxassetid://134605367931314", -- 640x300
	airlockDoor = "rbxassetid://113955542436103", -- 96x220
	plate = "rbxassetid://126503848455724", -- 256x256, 9-sliced, screwed corners
	well = "rbxassetid://127850483743288", -- 128x128, 9-sliced recess
	breaker = "rbxassetid://105334560523635", -- 176x256 breaker module
	lever = "rbxassetid://110475102640409", -- 72x80 toggle grip
	socket = "rbxassetid://88858068736134", -- 128x128 fuse socket tile
	fuse = "rbxassetid://108626543957160", -- 128x128 glass fuse tile
	cap = "rbxassetid://77165658125877", -- 256x256 red mushroom cap, unlettered
})

local INK = Color3.fromHex("#0E1015")

-- Fetched once on first require, so a view's first open isn't blank.
task.spawn(function()
	local list = {}
	for _, id in TaskArt.image do
		table.insert(list, id)
	end
	pcall(ContentProvider.PreloadAsync, ContentProvider, list)
end)

type Colour = Color3 | () -> Color3
type Number = number | () -> number

-- A round lamp: dark bezel, glass tinted `colour`.
function TaskArt.lamp(props: { name: string?, size: number, colour: Colour, [any]: any }): ImageLabel
	return create("ImageLabel")({
		Name = props.name or "Lamp",
		BackgroundTransparency = 1,
		Image = TaskArt.image.lamp,
		ImageColor3 = props.colour,
		Size = UDim2.fromOffset(props.size, props.size),
		AnchorPoint = props.AnchorPoint,
		Position = props.Position,
		ZIndex = props.ZIndex,
		LayoutOrder = props.LayoutOrder,
	}) :: ImageLabel
end

-- A soft additive-looking halo, centred on its Position.
function TaskArt.glow(props: { size: number, colour: Colour, transparency: Number, [any]: any }): ImageLabel
	return create("ImageLabel")({
		Name = "Glow",
		BackgroundTransparency = 1,
		Image = TaskArt.image.glow,
		ImageColor3 = props.colour,
		ImageTransparency = props.transparency,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = props.Position,
		Size = UDim2.fromOffset(props.size, props.size),
		ZIndex = props.ZIndex,
	}) :: ImageLabel
end

-- A steel backing plate with screwed corners, 9-sliced so it fits any
-- size. `inset` (reference px) is how far it overhangs what it backs.
function TaskArt.plate(props: { name: string?, [any]: any }): ImageLabel
	return create("ImageLabel")({
		Name = props.name or "Plate",
		BackgroundTransparency = 1,
		Image = TaskArt.image.plate,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(72, 72, 184, 184),
		SliceScale = props.sliceScale or 0.5,
		AnchorPoint = props.AnchorPoint,
		Position = props.Position,
		Size = props.Size,
		ZIndex = props.ZIndex,
		LayoutOrder = props.LayoutOrder,
	}) :: ImageLabel
end

-- A dark recessed well (an LCD bezel, a meter's track), 9-sliced.
function TaskArt.well(props: { name: string?, [any]: any }): ImageLabel
	local merged: { [any]: any } = {
		Name = props.name or "Well",
		BackgroundTransparency = 1,
		Image = TaskArt.image.well,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(40, 40, 88, 88),
		SliceScale = props.sliceScale or 0.4,
	}
	for k, v in props do
		if k ~= "name" and k ~= "sliceScale" then
			if type(k) == "number" then
				table.insert(merged, v)
			else
				merged[k] = v
			end
		end
	end
	return create("ImageLabel")(merged) :: ImageLabel
end

-- A meter: a recessed pill track with a glossy fill of `share()` (0..1)
-- in `colour()`. The caller positions and sizes it.
function TaskArt.meter(share: () -> number, colour: () -> Color3): Frame
	return create("Frame")({
		Name = "Meter",
		BackgroundColor3 = Color3.fromHex("#07090D"),
		Base.corner(UDim.new(0.5, 0)),
		create("UIStroke")({ Color = INK, Thickness = 2 }),
		create("UIPadding")({
			PaddingTop = UDim.new(0, 2),
			PaddingBottom = UDim.new(0, 2),
			PaddingLeft = UDim.new(0, 2),
			PaddingRight = UDim.new(0, 2),
		}),
		create("Frame")({
			Name = "Fill",
			BorderSizePixel = 0,
			Size = function()
				return UDim2.fromScale(math.clamp(share(), 0, 1), 1)
			end,
			BackgroundColor3 = colour,
			Base.corner(UDim.new(0.5, 0)),
			create("UIGradient")({
				Rotation = 90,
				Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.new(1, 1, 1)),
					ColorSequenceKeypoint.new(0.35, Color3.fromRGB(235, 235, 235)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 150, 150)),
				}),
			}),
		}),
	}) :: Frame
end

export type ButtonOptions = {
	-- Corner size: 1 suits a wide button, ~0.4 a small square key.
	sliceScale: number?,
	-- Label colour; white (with a dark outline) unless given.
	ink: Color3?,
	textStyle: string?,
	-- Shown greyed out while true (e.g. a keypad while the code plays).
	dimmed: (() -> boolean)?,
}

-- The visual for Base.interactive: a chunky glossy button in `colour`
-- that sinks onto its lip while pressed.
function TaskArt.button(
	label: string,
	colour: Color3,
	options: ButtonOptions?
): (state: Base.Source<Base.State>, focused: Base.Source<boolean>) -> { Instance }
	local opts: ButtonOptions = options or {}
	local pressedColour = colour:Lerp(Color3.new(0, 0, 0), 0.18)
	local dimColour = colour:Lerp(Color3.fromHex("#3A3F48"), 0.6)
	local ink = opts.ink or Color3.new(1, 1, 1)
	local outlined = opts.ink == nil
	return function(state, _focused)
		local down = function()
			return state() == "pressed"
		end
		local dim = function()
			return state() == "disabled" or (opts.dimmed ~= nil and opts.dimmed())
		end
		return {
			create("ImageLabel")({
				Name = "Face",
				BackgroundTransparency = 1,
				Image = TaskArt.image.button,
				ScaleType = Enum.ScaleType.Slice,
				SliceCenter = Rect.new(48, 40, 208, 88),
				SliceScale = opts.sliceScale or 1,
				ImageColor3 = function()
					return if dim() then dimColour elseif down() then pressedColour else colour
				end,
				Size = UDim2.fromScale(1, 1),
				Base.text(opts.textStyle or "headline", {
					Name = "Label",
					AnchorPoint = Vector2.new(0.5, 0.5),
					-- The face sits above an 8%-deep lip; sink with it.
					Position = function()
						return UDim2.fromScale(0.5, if down() then 0.5 else 0.44)
					end,
					Size = UDim2.fromScale(0.8, 0.55),
					Text = label,
					TextColor3 = ink,
					TextTransparency = function()
						return if dim() then 0.45 else 0
					end,
					create("UIStroke")({
						Color = INK,
						Thickness = if outlined then 2.5 else 0,
						Enabled = outlined,
					}),
					-- No Base.text outline too: this stroke is the art's own.
					-- With the display face's outline on top, dark ink on a
					-- grey key (Code Playback's digits) blurred into it.
				}, false),
			}),
		}
	end
end

return table.freeze(TaskArt)
