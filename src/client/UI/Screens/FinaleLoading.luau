--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The finale loading card (2026-09-26). Covers the gap between the race
-- ending and the Decision Studio opening: Qualified, the move onto the
-- set, and the Studio's Intro. Everyone sees it, finalist or not.
-- Mounted by DecisionStudioController, which owns when it comes down.
--
-- What it shows, top to bottom: who made the final, the prizes on the
-- table (one tile each, from DecisionLogic.rewardTiles, so it can't
-- disagree with the resolver), the one-line lesson, and a spinner that
-- becomes a "Got it" button once the Intro starts (2026-09-28).
-- Words only for the prizes, never amounts (DecisionLogic.prizeFor).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local DecisionLogic = require(script.Parent.Parent.DecisionLogic)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive
local indexes = vide.indexes
local cleanup = vide.cleanup

local Icons = C.Icons

export type Finalist = { id: number, name: string }

export type Store = {
	selfId: number,
	finalists: () -> { Finalist }, -- empty until the server names them
	canDismiss: (() -> boolean)?, -- true once the Studio's Intro is up
	onDismiss: (() -> ())?, -- "Got it"
}

local COLUMN = 344
local TILE_W = (COLUMN - Theme.spacing.sm) / 2
local TILE_H = 88
local ICON = 32
local CHIP_H = 32
local SPINNER = 24
local BUTTON_H = 48

-- Stand-in glyphs until RewardTables (design-decisions.md Q1) gives the
-- packages real art. Tinted so the tiers read at a glance.
local PRIZE_ICON: { [string]: { icon: string, color: string } } = {
	Big = { icon = "trophy", color = "warning" },
	Medium = { icon = "gem", color = "brand" },
	Small = { icon = "star", color = "ink" },
	Nothing = { icon = "close", color = "inkMuted" },
}

local FinaleLoading = {}

local function list(direction: Enum.FillDirection, gap: number): Instance
	return create("UIListLayout")({
		FillDirection = direction,
		Padding = UDim.new(0, gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Center,
		VerticalAlignment = Enum.VerticalAlignment.Center,
	})
end

local function tile(entry: () -> DecisionLogic.RewardTile, order: number): Frame
	local nothing = function()
		return entry().prize == "Nothing"
	end
	-- Icons.view takes a key, not a source, so the icon is switched per
	-- prize (the tile list only changes if the seat count does).
	local views: { [string]: () -> Instance } = {}
	for prize, style in PRIZE_ICON do
		views[prize] = function()
			return Icons.view(style.icon, ICON, Theme.color[style.color])
		end
	end
	local prize = derive(function(): string
		return entry().prize
	end)
	return create("Frame")({
		Name = "Reward",
		LayoutOrder = order,
		Size = UDim2.fromOffset(TILE_W, TILE_H),
		BackgroundColor3 = Theme.elevation[2].surface,
		BackgroundTransparency = function()
			return if nothing() then 0.5 else 0
		end,
		Base.corner(Theme.radius.md),
		Base.padding(Theme.spacing.sm),
		create("Frame")({
			Name = "Icon",
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(ICON, ICON),
			vide.switch(prize)(views) :: any,
		}),
		Base.text("label", {
			Name = "Prize",
			Position = UDim2.fromOffset(ICON + Theme.spacing.sm, 0),
			Size = UDim2.new(1, -(ICON + Theme.spacing.sm), 0, ICON),
			Text = function()
				return DecisionLogic.PRIZE_LABEL[entry().prize]
			end,
			TextColor3 = function()
				return if nothing() then Theme.color.inkMuted else Theme.color.ink
			end,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Base.text("caption", {
			Name = "How",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, Theme.type.caption.size * 2 + Theme.spacing.xxs),
			Text = function()
				return entry().how
			end,
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
		}),
	}) :: Frame
end

-- `controller` is UIScaleController. Returns unmount.
function FinaleLoading.mount(controller: any, store: Store): () -> ()
	local order = Theme.displayOrder.panel + 5 -- over the Studio screen it hides, under modals
	local backdropGui = controller.createScreen("FinaleLoadingBackdrop", { displayOrder = order, fullBleed = true })
	local gui = controller.createScreen("FinaleLoading", { displayOrder = order + 1 })

	create("Frame")({
		Name = "Backdrop",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.background,
		BackgroundTransparency = 0.08,
		Parent = backdropGui,
	})

	local destroy = vide.root(function()
		local seats = derive(function()
			local n = #store.finalists()
			return if n == 0 then 3 else n -- NPCs fill empty seats (Q2), so 3 until told otherwise
		end)
		local tiles = derive(function()
			return DecisionLogic.rewardTiles(seats())
		end)
		local canDismiss = derive(function()
			return store.canDismiss ~= nil and store.canDismiss()
		end)
		local isFinalist = derive(function()
			for _, f in store.finalists() do
				if f.id == store.selfId then
					return true
				end
			end
			return false
		end)

		local column = create("Frame")({
			Name = "Column",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(COLUMN, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			list(Enum.FillDirection.Vertical, Theme.spacing.md),
			Base.text("headline", {
				Name = "Title",
				LayoutOrder = 1,
				Size = UDim2.new(1, 0, 0, Theme.type.headline.size + Theme.spacing.xs),
				Text = "THE DECISION STUDIO",
			}),
			Base.text("body", {
				Name = "Subtitle",
				LayoutOrder = 2,
				Size = UDim2.new(1, 0, 0, Theme.type.body.size + Theme.spacing.xs),
				Text = function()
					return if isFinalist()
						then "You made the final! Steal or Share?"
						else "The final three decide. Steal or Share?"
				end,
				TextColor3 = function()
					return if isFinalist() then Theme.color.success else Theme.color.inkMuted
				end,
			}),
			create("Frame")({
				Name = "Finalists",
				LayoutOrder = 3,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, CHIP_H),
				Visible = function()
					return #store.finalists() > 0
				end,
				list(Enum.FillDirection.Horizontal, Theme.spacing.xs),
				indexes(store.finalists, function(f: () -> Finalist, i: number)
					local isSelf = function()
						return f().id == store.selfId
					end
					return create("Frame")({
						Name = "Chip",
						LayoutOrder = i,
						Size = UDim2.fromOffset((COLUMN - 2 * Theme.spacing.xs) / 3, CHIP_H),
						BackgroundColor3 = Theme.color.surfaceRaised,
						Base.corner(Theme.radius.pill),
						create("UIStroke")({
							ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
							Color = function()
								return if isSelf() then Theme.color.brand else Theme.color.line
							end,
							Thickness = function()
								return if isSelf() then 2 else 1
							end,
						}),
						Base.text("caption", {
							Name = "Name",
							Size = UDim2.fromScale(1, 1),
							Text = function()
								return if isSelf() then "You" else f().name
							end,
							TextTruncate = Enum.TextTruncate.AtEnd,
						}),
					})
				end) :: any,
			}),
			Base.text("caption", {
				Name = "Heading",
				LayoutOrder = 4,
				Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xs),
				Text = "WHAT'S ON THE TABLE",
				TextColor3 = Theme.color.inkMuted,
			}),
			create("Frame")({
				Name = "Rewards",
				LayoutOrder = 5,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(COLUMN, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				create("UIGridLayout")({
					CellSize = UDim2.fromOffset(TILE_W, TILE_H),
					CellPadding = UDim2.fromOffset(Theme.spacing.sm, Theme.spacing.sm),
					SortOrder = Enum.SortOrder.LayoutOrder,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
				}),
				indexes(tiles, function(entry: () -> DecisionLogic.RewardTile, i: number)
					return tile(entry, i)
				end) :: any,
			}),
			Base.text("label", {
				Name = "Lesson",
				LayoutOrder = 6,
				Size = UDim2.new(1, 0, 0, Theme.type.label.size * 2 + Theme.spacing.xs),
				Text = "★ " .. DecisionLogic.EXPLAINER.lesson,
				TextColor3 = Theme.color.steal,
				TextWrapped = true,
			}),
			-- Once the Studio's Intro starts, "Got it" closes the card. It
			-- saves nothing on its own: the Intro only ends early when
			-- every finalist is ready (FinaleRoster.allReady).
			create("Frame")({
				Name = "Dismiss",
				LayoutOrder = 8,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, BUTTON_H),
				Visible = canDismiss,
				C.Button({
					label = "Got it",
					onActivate = function()
						if store.onDismiss then
							store.onDismiss()
						end
					end,
					width = COLUMN,
					anchorPoint = Vector2.new(0.5, 0.5),
					position = UDim2.fromScale(0.5, 0.5),
				}) :: any,
			}),
			create("Frame")({
				Name = "Loading",
				LayoutOrder = 7,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, SPINNER),
				Visible = function()
					return not canDismiss()
				end,
				list(Enum.FillDirection.Horizontal, Theme.spacing.sm),
				create("Frame")({
					Name = "SpinnerBox",
					LayoutOrder = 1,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(SPINNER, SPINNER),
					Base.spinner(SPINNER, function()
						return Theme.color.inkMuted
					end) :: any,
				}),
				Base.text("caption", {
					Name = "Status",
					LayoutOrder = 2,
					Size = UDim2.fromOffset(180, SPINNER),
					Text = "Heading to the Studio…",
					TextColor3 = Theme.color.inkMuted,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
			}),
		}) :: Frame
		column.Parent = gui
		cleanup(controller.attachScale(column))
	end)

	return function()
		destroy()
		gui:Destroy()
		backdropGui:Destroy()
	end
end

return FinaleLoading
