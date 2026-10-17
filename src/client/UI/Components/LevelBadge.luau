--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- LevelBadge (payoff-loop step 1c): the account level in the Hub, beside
-- the coin pill and in the same pill. The level sits in a gold disc on
-- the left and a slim XP bar fills on the right, with "LV" over it so
-- the bar doesn't rely on its fill alone. Display only: the level comes
-- from the server (StoreState.level, LevelLogic.progressFor).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local Env = require(script.Parent.Env)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Props = {
	level: Base.Source<number>,
	fraction: Base.Source<number>, -- 0..1 of the way to the next level
	position: UDim2?,
	anchorPoint: Vector2?,
}

-- The coin pill's size, so the two read as a pair.
local HEIGHT = Theme.spacing.xxl -- 32
local WIDTH = Theme.spacing.xxxl * 2 + Theme.spacing.lg -- 112
local INSET = Theme.spacing.sm
local DISC = HEIGHT - Theme.spacing.xs
local BAR = Theme.spacing.xs + Theme.spacing.xxs -- 6

local function LevelBadge(props: Props): Frame
	local fraction = Env.animate(props.fraction, Theme.motion.slow)
	local left = INSET + DISC + Theme.spacing.xs

	local frame = create("Frame")({
		Name = "LevelBadge",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(WIDTH, HEIGHT),
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchorPoint or Vector2.zero,
	}) :: Frame

	local children = Base.raised({
		fill = function()
			return Theme.fill.panel
		end,
		lip = Theme.lip.small,
		radius = Theme.radius.pill,
		children = {
			create("Frame")({
				Name = "Disc",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, INSET - Theme.spacing.xs, 0.5, 0),
				Size = UDim2.fromOffset(DISC, DISC),
				BackgroundColor3 = Color3.new(1, 1, 1),
				ZIndex = 3,
				Base.corner(Theme.radius.pill),
				create("UIGradient")({ Rotation = 90, Color = Theme.fill.primary.gradient }),
				create("UIStroke")({
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
					Color = Theme.fill.primary.lip,
					Thickness = 2,
				}),
				Base.text("button", {
					Name = "Level",
					Size = UDim2.fromScale(1, 1),
					Text = function()
						return tostring(props.level())
					end,
					TextColor3 = Theme.fill.primary.ink,
				}, false),
			}),
			Base.text("caption", {
				Name = "Label",
				Position = UDim2.fromOffset(left, Theme.spacing.xxs),
				Size = UDim2.new(1, -(left + Theme.spacing.md), 0, HEIGHT / 2),
				ZIndex = 3,
				Text = "LEVEL",
				TextColor3 = Theme.color.inkMuted,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			create("Frame")({
				Name = "Track",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, left, 1, -(Theme.spacing.xs + Theme.spacing.xxs)),
				Size = UDim2.new(1, -(left + Theme.spacing.md), 0, BAR),
				BackgroundColor3 = Theme.color.background,
				ZIndex = 3,
				Base.corner(Theme.radius.pill),
				create("Frame")({
					Name = "Fill",
					BackgroundColor3 = Color3.new(1, 1, 1),
					Size = function()
						return UDim2.fromScale(math.clamp(fraction(), 0, 1), 1)
					end,
					Visible = function()
						return fraction() > 0.001
					end,
					ZIndex = 4,
					Base.corner(Theme.radius.pill),
					create("UIGradient")({ Color = ColorSequence.new(Theme.fill.primary.top, Theme.color.brand) }),
				}),
			}),
		},
	})
	for _, child in children do
		child.Parent = frame
	end
	return frame
end

return LevelBadge
