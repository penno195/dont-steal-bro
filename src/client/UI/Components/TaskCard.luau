--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- TaskCard (P6-2): one task in the race checklist - its name, where it
-- is, and how far along. Status is spelled out and iconned as well as
-- coloured. Tappable (e.g. "show me the way") only when `onActivate` is
-- given and the task isn't locked.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Icons = require(script.Parent.Icons)
local ProgressBar = require(script.Parent.ProgressBar)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

export type Status = "locked" | "todo" | "active" | "done"

export type Props = {
	title: string,
	location: string?,
	status: Status | Base.Source<Status>,
	-- 0..1, shown while active.
	progress: (number | Base.Source<number>)?,
	onActivate: (() -> ())?,
	width: number?,
	order: number?,
	layoutOrder: number?,
}

local STATUS: { [Status]: { icon: string, color: string, text: string } } = {
	locked = { icon = "lock", color = "inkMuted", text = "Locked" },
	todo = { icon = "star", color = "ink", text = "To do" },
	active = { icon = "bolt", color = "warning", text = "In progress" },
	done = { icon = "check", color = "success", text = "Done" },
}

local HEIGHT = Theme.spacing.xxxl + Theme.spacing.xl -- 72
local DEFAULT_WIDTH = 360 - 2 * Theme.spacing.lg

local function contents(
	props: Props,
	status: Base.Source<Status>,
	state: Base.Source<ComponentLogic.State>?
): { Instance }
	local progress: Base.Source<number> = Base.read(props.progress or 0)
	local info = function()
		return STATUS[status()]
	end
	local iconSize = Theme.spacing.xl
	local textLeft = Theme.spacing.md + iconSize + Theme.spacing.md
	local iconCases: { [Status]: () -> GuiObject } = {}
	for key, s in STATUS do
		iconCases[key :: Status] = function()
			return Icons.view(s.icon, iconSize, Theme.color[s.color])
		end
	end

	return {
		create("Frame")({
			Name = "Surface",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.elevation[2].surface,
			Base.corner(Theme.radius.md),
			create("UIStroke")({
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = function()
					return if status() == "active" then Theme.color.warning else Theme.color.line
				end,
				Transparency = function()
					return if status() == "active" then 0 else Theme.elevation[2].strokeTransparency
				end,
			}),
			create("Frame")({
				Name = "Overlay",
				Size = UDim2.fromScale(1, 1),
				BackgroundColor3 = Color3.new(1, 1, 1),
				BackgroundTransparency = function()
					return if state then ComponentLogic.variantStyle("secondary", state()).overlayTransparency else 1
				end,
				Base.corner(Theme.radius.md),
			}),
			create("Frame")({
				Name = "IconSlot",
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2.new(0, Theme.spacing.md, 0.5, 0),
				Size = UDim2.fromOffset(iconSize, iconSize),
				BackgroundTransparency = 1,
				-- Rebuilt when status changes: the glyph itself differs.
				vide.switch(status)(iconCases) :: any,
			}),
			Base.text("label", {
				Name = "Title",
				Position = UDim2.fromOffset(textLeft, Theme.spacing.sm),
				Size = UDim2.new(0.62, -textLeft, 0, Theme.type.label.size + Theme.spacing.xxs),
				Text = props.title,
				TextColor3 = function()
					return if status() == "locked" then Theme.color.inkMuted else Theme.color.ink
				end,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Base.text("caption", {
				Name = "Status",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -Theme.spacing.md, 0, Theme.spacing.sm),
				Size = UDim2.new(0.38, -Theme.spacing.md, 0, Theme.type.label.size),
				Text = function()
					return info().text
				end,
				TextColor3 = function()
					return Theme.color[info().color]
				end,
				TextXAlignment = Enum.TextXAlignment.Right,
			}),
			Base.text("caption", {
				Name = "Location",
				Position = UDim2.fromOffset(textLeft, Theme.spacing.sm + Theme.type.label.size + Theme.spacing.xs),
				Size = UDim2.new(1, -(textLeft + Theme.spacing.md), 0, Theme.type.caption.size + Theme.spacing.xxs),
				Text = props.location or "",
				TextColor3 = Theme.color.inkMuted,
				TextXAlignment = Enum.TextXAlignment.Left,
				Visible = function()
					return status() ~= "active" and props.location ~= nil
				end,
			}),
			create("Frame")({
				Name = "ProgressSlot",
				BackgroundTransparency = 1,
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.new(0, textLeft, 1, -Theme.spacing.md),
				Size = UDim2.new(1, -(textLeft + Theme.spacing.md), 0, Theme.spacing.md),
				Visible = function()
					return status() == "active"
				end,
				ProgressBar({
					value = function()
						return progress() * 100
					end,
					max = 100,
					color = "warning",
				}),
			}),
		}),
	}
end

local function TaskCard(props: Props): GuiObject
	local status: Base.Source<Status> = Base.read(props.status)
	local width = props.width or DEFAULT_WIDTH
	local onActivate = props.onActivate

	if onActivate == nil then
		local frame = create("Frame")({
			Name = "TaskCard",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(width, HEIGHT),
			LayoutOrder = props.layoutOrder or 0,
		}) :: Frame
		for _, child in contents(props, status, nil) do
			child.Parent = frame
		end
		return frame
	end

	return Base.interactive({
		name = "TaskCard",
		size = Vector2.new(width, HEIGHT),
		radius = Theme.radius.md,
		disabled = function()
			return status() == "locked"
		end,
		onActivate = onActivate,
		order = props.order,
		layoutOrder = props.layoutOrder,
		visual = function(state, _focused)
			return contents(props, status, state)
		end,
	})
end

return TaskCard
