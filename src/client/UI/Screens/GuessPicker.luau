--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The Guess Token picker (payoff-loop step 2c): a knocked-out player's
-- one guess at which finalist walks out. Built by DecisionStudio.mount,
-- which places it in the bottom-left corner a spectator has free (a
-- finalist's Steal button sits there). GuessViewLogic is the pure half:
-- when it shows, what each card and line say.
--
-- One card per finalist seat, NPC seats included, in seat order. A tap
-- is the whole guess: it's final, so there's no second step to undo.
-- The picker never sees a choice or a streak, only seat names.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local GuessViewLogic = require(script.Parent.Parent.GuessViewLogic)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive
local indexes = vide.indexes

local GuessPicker = {}

GuessPicker.CARD_W = 100
GuessPicker.PER_ROW = 3 -- three finalists is the usual Studio; more wrap
local GAP = Theme.spacing.sm
local PAD = Theme.spacing.sm
GuessPicker.WIDTH = GuessPicker.PER_ROW * GuessPicker.CARD_W + (GuessPicker.PER_ROW - 1) * GAP + 2 * PAD

export type Seat = { id: number, name: string }

export type Props = {
	seats: () -> { Seat },
	guess: () -> GuessViewLogic.Guess,
	pick: (targetId: number) -> (),
}

function GuessPicker.build(props: Props): Frame
	local guess = props.guess
	local function nameOf(id: number): string
		for _, seat in props.seats() do
			if seat.id == id then
				return seat.name
			end
		end
		return "a finalist"
	end
	local line = derive(function()
		return GuessViewLogic.line(guess(), nameOf)
	end)

	return create("Frame")({
		Name = "GuessPicker",
		Size = UDim2.fromOffset(GuessPicker.WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Base.STAGE_BACKGROUND,
		Base.corner(Theme.radius.md),
		Base.stage(),
		Base.padding(PAD),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Base.text("label", {
			Name = "Title",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.label.size + Theme.spacing.xs),
			Text = function()
				return GuessViewLogic.title(guess())
			end,
			TextWrapped = false,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		Base.text("caption", {
			Name = "Line",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, 2 * Theme.type.caption.size + Theme.spacing.xs),
			Text = line,
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
			TextYAlignment = Enum.TextYAlignment.Top,
		}),
		create("Frame")({
			Name = "Cards",
			LayoutOrder = 3,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			create("UIGridLayout")({
				CellSize = UDim2.fromOffset(GuessPicker.CARD_W, Theme.touch.iconButton),
				CellPadding = UDim2.fromOffset(GAP, GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			indexes(props.seats, function(seat: () -> Seat, index: number)
				local state = derive(function(): GuessViewLogic.CardState
					return GuessViewLogic.cardState(guess(), seat().id)
				end)
				-- In a cell of its own: a UIGridLayout sizes its children, and
				-- the button sizes its own hit area (Base.interactive).
				return create("Frame")({
					Name = "Cell",
					LayoutOrder = index,
					BackgroundTransparency = 1,
					C.Button({
						label = function()
							local name = seat().name
							return if state() == "Picked" then "✓ " .. name else name
						end,
						variant = "secondary",
						compact = true,
						width = GuessPicker.CARD_W,
						order = 700 + index,
						anchorPoint = Vector2.new(0.5, 0.5),
						position = UDim2.fromScale(0.5, 0.5),
						-- The picked card disables too: the guess is final.
						disabled = function()
							return state() ~= "Pickable"
						end,
						onActivate = function()
							props.pick(seat().id)
						end,
					}),
				})
			end) :: any,
		}),
	}) :: Frame
end

return GuessPicker
