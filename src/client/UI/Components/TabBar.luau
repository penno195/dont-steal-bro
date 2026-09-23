--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- TabBar (P6-2): equal-width tabs with a sliding indicator. The
-- selected tab is marked three ways - indicator bar, ink colour, and
-- bold vs regular weight - so it doesn't rest on colour.
--
-- Controller: tabs are ordinary selectable buttons (left/right moves
-- focus, A picks), and L1/R1 step the selection from anywhere, the
-- console convention. The shoulder binding lives as long as the bar
-- does, so a screen should unmount a hidden TabBar, not just hide it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Base)
local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Icons = require(script.Parent.Icons)
local Theme = require(script.Parent.Parent.Theme)

local cleanup = vide.cleanup
local create = vide.create

export type Tab = { label: string, icon: string? }

export type Props = {
	tabs: { Tab },
	selected: Base.Source<number>,
	onSelect: (index: number) -> (),
	width: number?, -- reference px; default the reference phone minus gutters
	order: number?, -- SelectionOrder of the first tab
	layoutOrder: number?,
}

local HEIGHT = Theme.touch.iconButton + Theme.spacing.xs -- 48
local INDICATOR = Theme.spacing.xs

local function TabBar(props: Props): Frame
	local count = #props.tabs
	assert(count > 0, "TabBar: needs at least one tab")
	local width = props.width or (360 - 2 * Theme.spacing.lg)
	local tabWidth = math.floor(width / count)

	local conn = UserInputService.InputBegan:Connect(function(input)
		local step = if input.KeyCode == Enum.KeyCode.ButtonR1
			then 1
			elseif input.KeyCode == Enum.KeyCode.ButtonL1 then -1
			else 0
		if step ~= 0 then
			props.onSelect(ComponentLogic.stepTab(props.selected(), count, step))
		end
	end)
	cleanup(conn)

	local indicatorX = Env.animate(function(): number
		return (props.selected() - 1) / count
	end, Theme.motion.base)

	local bar = create("Frame")({
		Name = "TabBar",
		Size = UDim2.fromOffset(tabWidth * count, HEIGHT),
		LayoutOrder = props.layoutOrder or 0,
		BackgroundColor3 = Theme.elevation[2].surface,
		Base.corner(Theme.radius.md),
		create("Frame")({
			Name = "Tabs",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
		}),
		create("Frame")({
			Name = "Indicator",
			AnchorPoint = Vector2.new(0, 1),
			Position = function()
				return UDim2.new(indicatorX(), Theme.spacing.md, 1, 0)
			end,
			Size = UDim2.new(1 / count, -2 * Theme.spacing.md, 0, INDICATOR),
			BackgroundColor3 = Theme.color.brand,
			Base.corner(Theme.radius.pill),
		}),
	}) :: Frame

	local tabsFrame = bar:FindFirstChild("Tabs") :: Frame
	for i, tab in props.tabs do
		local isSelected = function(): boolean
			return props.selected() == i
		end
		local ink = function(): Color3
			return if isSelected() then Theme.color.ink else Theme.color.inkMuted
		end
		local button = Base.interactive({
			name = "Tab" .. i,
			size = Vector2.new(tabWidth, HEIGHT - INDICATOR),
			radius = Theme.radius.md,
			onActivate = function()
				props.onSelect(i)
			end,
			order = (props.order or 0) + i,
			layoutOrder = i,
			visual = function(state, _focused)
				local iconSize = Theme.spacing.lg + Theme.spacing.xs
				return {
					create("Frame")({
						Name = "Overlay",
						Size = UDim2.fromScale(1, 1),
						BackgroundColor3 = Color3.new(1, 1, 1),
						BackgroundTransparency = function()
							return ComponentLogic.variantStyle("ghost", state()).overlayTransparency
						end,
						Base.corner(Theme.radius.md),
					}),
					create("Frame")({
						Name = "Content",
						Size = UDim2.fromScale(1, 1),
						BackgroundTransparency = 1,
						create("UIListLayout")({
							FillDirection = Enum.FillDirection.Horizontal,
							HorizontalAlignment = Enum.HorizontalAlignment.Center,
							VerticalAlignment = Enum.VerticalAlignment.Center,
							Padding = UDim.new(0, Theme.spacing.xs),
							SortOrder = Enum.SortOrder.LayoutOrder,
						}),
						(if tab.icon then Icons.view(tab.icon, iconSize, ink) else nil) :: any,
						Base.text("label", {
							LayoutOrder = 2,
							Size = UDim2.new(
								1,
								-(if tab.icon then iconSize + Theme.spacing.xs else 0) - Theme.spacing.sm,
								0.6,
								0
							),
							Text = tab.label,
							TextColor3 = ink,
							FontFace = function()
								return if isSelected() then Theme.type.label.font else Theme.type.body.font
							end,
						}),
					}),
				}
			end,
		})
		button.Parent = tabsFrame
	end
	return bar
end

return TabBar
