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
local Layout = require(script.Parent.Parent.Layout)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
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
-- Sideways the four tiles go in one row: a phone held sideways is only
-- ~420 reference px tall, and the 2x2 grid pushed "Got it" off the
-- bottom (playtest 2026-10-04). The rest of the card stays COLUMN wide.
local WIDE = 4 * TILE_W + 3 * Theme.spacing.sm
local TILE_H = 88
local ICON = 32
local CHIP_H = 32
local SPINNER = 24
local BUTTON_H = 48

-- Every prize is coins now (design-decisions.md Q1's 2026-10-02 case),
-- so a tier is a pile of coin icons: three, two, one, or a cross for
-- nothing (rewards-roadmap.md step 3). How many coins is the tier, never
-- an amount: this card is up before lock-in, where Q7 allows words only.
local PRIZE_COINS: { [string]: number } = { Big = 3, Medium = 2, Small = 1 }
local COIN = 20
local COIN_STEP = (ICON - COIN) / 2 -- three coins fill the icon square

local function coinPile(count: number): Instance
	local coins = {}
	for i = 1, count do
		local coin = Icons.view("coin", COIN, Theme.color.warning)
		-- Bottom-left to top-right, so the pile grows up and across.
		coin.Position = UDim2.fromOffset((i - 1) * COIN_STEP, (3 - i) * COIN_STEP)
		coin.ZIndex = i
		table.insert(coins, coin)
	end
	return create("Frame")({
		Name = "Coins",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(ICON, ICON),
		coins,
	})
end

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
	local views: { [string]: () -> Instance } = {
		Nothing = function()
			return Icons.view("close", ICON, Theme.color.inkMuted)
		end,
	}
	for prize, count in PRIZE_COINS do
		views[prize] = function()
			return coinPile(count)
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
		local orientation =
			source(Layout.orientationOf(controller.getUsableRect().width, controller.getUsableRect().height))
		cleanup(controller.observeUsableRect(function(rect: Layout.Rect)
			orientation(Layout.orientationOf(rect.width, rect.height))
		end))
		local width = derive(function()
			return if orientation() == "Portrait" then COLUMN else WIDE
		end)

		local column = create("Frame")({
			Name = "Column",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = function()
				return UDim2.fromOffset(width(), 0)
			end,
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
				Size = function()
					return UDim2.fromOffset(width(), 0)
				end,
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
		-- Fit to height: whatever the layout, a screen too short for the
		-- card shrinks it rather than cutting off "Got it". A GuiObject
		-- honours one UIScale and the column's is the global one, so the
		-- fit goes on a full-screen holder, which scales about its centre.
		local holder = create("Frame")({
			Name = "Fit",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			Parent = gui,
		})
		local fit = create("UIScale")({ Parent = holder }) :: UIScale
		column.Parent = holder
		cleanup(controller.attachScale(column))
		local function refit()
			local natural = column.AbsoluteSize.Y / math.max(fit.Scale, 0.01)
			local room = gui.AbsoluteSize.Y - 2 * Theme.spacing.sm
			local scale = if natural > 0 then math.clamp(room / natural, 0.5, 1) else 1
			if math.abs(fit.Scale - scale) > 0.005 then
				fit.Scale = scale
			end
		end
		for _, signal in
			{
				column:GetPropertyChangedSignal("AbsoluteSize"),
				gui:GetPropertyChangedSignal("AbsoluteSize"),
			}
		do
			cleanup(signal:Connect(refit))
		end
		refit()
	end)

	return function()
		destroy()
		gui:Destroy()
		backdropGui:Destroy()
	end
end

return FinaleLoading
