--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- CountdownRing (P6-2): a ring that empties clockwise from 12 o'clock,
-- with whole seconds in the middle. Roblox has no arc primitive, so the
-- ring is two half-rings, each clipped to its half and masked by a
-- hard-edged UIGradient on its stroke; ComponentLogic.ringRotations has
-- the maths. Urgency is carried by the number and a pulse as well as
-- colour: calm -> warning -> critical.
--
-- The caller owns time: pass `secondsLeft` as a source driven by the
-- round clock (Clock.luau), so the ring never keeps its own timer that
-- could drift from the server's.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive

export type Props = {
	secondsLeft: Base.Source<number>,
	total: number,
	size: number?, -- reference px, default spacing.xxxl + spacing.lg (64)
	warnAt: number?, -- seconds, default 10
	criticalAt: number?, -- seconds, default 5
	layoutOrder: number?,
	position: UDim2?,
	anchorPoint: Vector2?,
}

local URGENCY_COLOR: { [ComponentLogic.Urgency]: string } = {
	calm = "ink",
	warning = "warning",
	critical = "danger",
}

-- Opaque on the first half of the gradient, transparent on the second,
-- with a hard edge between.
local HALF_MASK = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(0.501, 1),
	NumberSequenceKeypoint.new(1, 1),
})

local function CountdownRing(props: Props): Frame
	local size = props.size or (Theme.spacing.xxxl + Theme.spacing.lg)
	local thickness = math.max(Theme.spacing.xs, math.floor(size / 10))
	local warnAt = props.warnAt or 10
	local criticalAt = props.criticalAt or 5

	local urgency = derive(function(): string
		return ComponentLogic.urgency(props.secondsLeft(), warnAt, criticalAt)
	end)
	local color = function(): Color3
		return Theme.color[URGENCY_COLOR[urgency() :: ComponentLogic.Urgency]]
	end
	-- Snap, don't spring: a ring that lags the number looks wrong, and
	-- the caller already updates it every frame.
	local rotations = derive(function()
		local r, l = ComponentLogic.ringRotations(ComponentLogic.fraction(props.secondsLeft(), props.total))
		return { right = r, left = l }
	end)
	-- A beat on each whole second while critical. Suppressed under
	-- reduced motion, where colour and the "!" suffix carry it instead.
	-- That has to be an explicit check: Env.animate only drops the
	-- spring, so a target that alternates would still jump 8% every
	-- second - a hard flicker, worse than the smooth beat (P6-8).
	local pulse = Env.animate(function(): number
		if urgency() ~= "critical" or Env.reducedMotion() then
			return 1
		end
		return if math.ceil(props.secondsLeft()) % 2 == 0 then 1.08 else 1
	end, Theme.motion.fast)

	-- One half: a clip frame covering its side of the circle, holding a
	-- full-size ring offset so its centre sits on the clip's inner edge.
	local function half(side: "left" | "right"): Frame
		local isRight = side == "right"
		return create("Frame")({
			Name = if isRight then "RightHalf" else "LeftHalf",
			BackgroundTransparency = 1,
			ClipsDescendants = true,
			Size = UDim2.fromScale(0.5, 1),
			Position = UDim2.fromScale(if isRight then 0.5 else 0, 0),
			create("Frame")({
				Name = "Ring",
				BackgroundTransparency = 1,
				Size = UDim2.fromScale(2, 1),
				Position = UDim2.fromScale(if isRight then -1 else 0, 0),
				Base.corner(Theme.radius.pill),
				create("UIStroke")({
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					BorderStrokePosition = Enum.BorderStrokePosition.Inner,
					Thickness = thickness,
					Color = color,
					create("UIGradient")({
						Transparency = HALF_MASK,
						Rotation = function()
							local rot = rotations()
							return if isRight then rot.right else rot.left
						end,
					}),
				}),
			}),
		}) :: Frame
	end

	return create("Frame")({
		Name = "CountdownRing",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(size, size),
		LayoutOrder = props.layoutOrder or 0,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchorPoint or Vector2.zero,
		create("UIScale")({ Scale = pulse }),
		-- Track: the full ring, faint, so the empty part still reads as
		-- "time that's gone" rather than nothing.
		create("Frame")({
			Name = "Track",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.surface,
			Base.corner(Theme.radius.pill),
			create("UIStroke")({
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				BorderStrokePosition = Enum.BorderStrokePosition.Inner,
				Thickness = thickness,
				Color = Theme.color.line,
			}),
		}),
		half("right"),
		half("left"),
		Base.text("title", {
			Name = "Seconds",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.6, 0.5),
			TextColor3 = color,
			Text = function()
				local label = ComponentLogic.countdownLabel(props.secondsLeft())
				return if urgency() == "critical" then label .. "!" else label
			end,
		}),
	}) :: Frame
end

return CountdownRing
