--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- PlayerRow (P6-2): one player in a list - standings, lobby, results.
-- Avatar headshot, display name, equipped title underneath, an optional
-- rank on the left and a trailing value (streak, bounty) on the right.
-- The local player's row is outlined in brand so they find themselves
-- in a list of six at a glance.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Props = {
	userId: number,
	displayName: string,
	title: string?,
	rank: number?,
	-- Right-hand value, e.g. a streak count, with an optional icon key.
	trailing: (string | Base.Source<string>)?,
	trailingIcon: string?,
	isLocalPlayer: boolean?,
	width: number?,
	layoutOrder: number?,
}

local HEIGHT = Theme.spacing.xxxl + Theme.spacing.sm -- 56
local AVATAR = Theme.spacing.xxl + Theme.spacing.sm -- 40
local RANK = Theme.spacing.xl
local DEFAULT_WIDTH = 360 - 2 * Theme.spacing.lg

-- The rbxthumb content URL loads the headshot without a yielding
-- GetUserThumbnailAsync call, so building a row never blocks.
local function headshot(userId: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
end

local function PlayerRow(props: Props): Frame
	local hasRank = props.rank ~= nil
	local left = Theme.spacing.md + (if hasRank then RANK + Theme.spacing.sm else 0)
	local textLeft = left + AVATAR + Theme.spacing.md
	local trailingWidth = if props.trailing then Theme.spacing.xxxl + Theme.spacing.lg else 0

	return create("Frame")({
		Name = "PlayerRow",
		Size = UDim2.fromOffset(props.width or DEFAULT_WIDTH, HEIGHT),
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.elevation[2].surface,
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = if props.isLocalPlayer then Theme.color.brand else Theme.color.line,
			Thickness = if props.isLocalPlayer then 2 else 1,
			Transparency = if props.isLocalPlayer then 0 else Theme.elevation[2].strokeTransparency,
		}),
		(if hasRank
			then Base.text("label", {
				Name = "Rank",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, Theme.spacing.md, 0.5, 0),
				Size = UDim2.fromOffset(RANK, RANK),
				Text = tostring(props.rank),
				TextColor3 = Theme.color.inkMuted,
			})
			else nil) :: any,
		create("ImageLabel")({
			Name = "Avatar",
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, left, 0.5, 0),
			Size = UDim2.fromOffset(AVATAR, AVATAR),
			BackgroundColor3 = Theme.color.surfaceRaised,
			Image = headshot(props.userId),
			Base.corner(Theme.radius.pill),
		}),
		Base.text("label", {
			Name = "DisplayName",
			Position = UDim2.fromOffset(textLeft, Theme.spacing.sm),
			Size = UDim2.new(
				1,
				-(textLeft + trailingWidth + Theme.spacing.md),
				0,
				Theme.type.label.size + Theme.spacing.xxs
			),
			Text = props.displayName,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
		Base.text("caption", {
			Name = "Title",
			Position = UDim2.fromOffset(textLeft, Theme.spacing.sm + Theme.type.label.size + Theme.spacing.xs),
			Size = UDim2.new(
				1,
				-(textLeft + trailingWidth + Theme.spacing.md),
				0,
				Theme.type.caption.size + Theme.spacing.xxs
			),
			Text = props.title or "",
			Visible = props.title ~= nil,
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextWrapped = false,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}),
		(if props.trailing
			then create("Frame")({
				Name = "Trailing",
				AnchorPoint = Vector2.new(1, 0.5),
				Position = UDim2.new(1, -Theme.spacing.md, 0.5, 0),
				Size = UDim2.fromOffset(trailingWidth, Theme.spacing.xl),
				BackgroundTransparency = 1,
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Right,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Theme.spacing.xs),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				(if props.trailingIcon
					then Icons.view(props.trailingIcon, Theme.spacing.lg + Theme.spacing.xs, Theme.color.warning)
					else nil) :: any,
				Base.text("label", {
					LayoutOrder = 2,
					Size = UDim2.new(1, -(Theme.spacing.lg + Theme.spacing.sm), 1, 0),
					Text = props.trailing,
					TextXAlignment = Enum.TextXAlignment.Right,
				}),
			})
			else nil) :: any,
	}) :: Frame
end

return PlayerRow
