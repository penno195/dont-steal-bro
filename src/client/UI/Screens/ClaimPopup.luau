--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The season-pass claim pop-up (user request 2026-10-09): what a Claim or
-- Claim All just paid, as a row of reward cards in the pass rows' gold
-- (pass) and blue (free), popping in over the store. The caller plays the
-- SeasonClaim cue alongside it - UI modules don't reach controllers.
--
-- Display only: what was paid is the server's (SeasonLogic.claim), read
-- back from StoreState by SeasonTrackLogic.claimedBetween.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

-- Card sizes (art pass, 2026-10-10): one or two rewards get big cards,
-- three or more get small ones so a Claim All still fits the modal's
-- width three to a row. Either way the picture sits in its own inset
-- well with an even margin all round, and the name is centred under it.
local BIG = { w = 132, style = "label" }
local SMALL = { w = 92, style = "body" }
local PAD = Theme.spacing.sm -- card edge to well, and well to name
local WELL_INSET = 0.12 -- the picture's margin inside its well, per side
local PER_ROW = 3 -- small cards; one or two big ones are a single row anyway
local POP_FROM = 0.6 -- the cards' starting scale, before they bounce in

type CardSize = typeof(BIG)

-- Two lines of the size's text style.
local function nameHeight(size: CardSize): number
	return 2 * Theme.type[size.style].size + Theme.spacing.xxs
end

local function cardHeight(size: CardSize): number
	return PAD + (size.w - 2 * PAD) + PAD + nameHeight(size) + PAD + Theme.lip.small
end

export type Reward = {
	premium: boolean,
	text: string, -- what the reward is, e.g. "75 coins"
	icon: string, -- SeasonTrackLogic.iconFor of its grant
	image: number?, -- the item's own picture, if it has one
}

local function card(reward: Reward, order: number, size: CardSize): Instance
	local fill = if reward.premium then Theme.fill.seasonPaid else Theme.fill.seasonFree
	local well = size.w - 2 * PAD
	local picture = C.Icons.picture(function()
		return reward.icon
	end, function()
		return reward.image
	end, fill.ink)
	picture.AnchorPoint = Vector2.new(0.5, 0.5)
	picture.Position = UDim2.fromScale(0.5, 0.5)
	picture.Size = UDim2.fromScale(1 - 2 * WELL_INSET, 1 - 2 * WELL_INSET)
	picture.ZIndex = 3
	return create("Frame")({
		Name = "Reward" .. order,
		LayoutOrder = order,
		Size = UDim2.fromOffset(size.w, cardHeight(size)),
		BackgroundTransparency = 1,
		Base.raised({
			fill = function()
				return fill
			end,
			lip = Theme.lip.small,
			radius = Theme.radius.md,
			rimThickness = 3,
			children = {
				-- The well: a darker inset square that frames the picture.
				create("Frame")({
					Name = "Well",
					Position = UDim2.fromOffset(PAD, PAD),
					Size = UDim2.fromOffset(well, well),
					BackgroundColor3 = Theme.color.outline,
					BackgroundTransparency = 0.75,
					ZIndex = 2,
					Base.corner(Theme.radius.md),
					create("UIStroke")({
						Color = fill.rim,
						Thickness = 1.5,
						Transparency = 0.5,
					}),
					picture,
				}),
				Base.text(size.style, {
					Name = "Item",
					Position = UDim2.fromOffset(PAD, PAD + well + PAD),
					Size = UDim2.new(1, -2 * PAD, 0, nameHeight(size)),
					Text = reward.text,
					TextColor3 = fill.ink,
					FontFace = Font.new(Theme.type[size.style].font.Family, Enum.FontWeight.Bold),
					TextXAlignment = Enum.TextXAlignment.Center,
					TextYAlignment = Enum.TextYAlignment.Center,
					ZIndex = 3,
				}),
			},
		}) :: any,
	})
end

local ClaimPopup = {}

-- Opens the pop-up over whatever is on screen; returns `close`. A second
-- claim while it's up replaces it (Modal is one at a time).
function ClaimPopup.open(rewards: { Reward }): () -> ()
	local close: () -> () = function() end
	close = C.Modal.open({
		title = if #rewards == 1 then "REWARD CLAIMED!" else string.format("%d REWARDS CLAIMED!", #rewards),
		dismissible = true,
		onDismiss = function()
			close()
		end,
		actions = {
			{
				label = "Nice!",
				variant = "primary",
				onActivate = function()
					close()
				end,
			},
		},
		content = function()
			local scale = create("UIScale")({ Scale = POP_FROM })
			local size = if #rewards <= 2 then BIG else SMALL
			-- Rows of up to PER_ROW, each centred, so a short last row
			-- sits in the middle rather than hugging the left.
			local rows: { Instance } = {}
			for first = 1, #rewards, PER_ROW do
				local row = create("Frame")({
					Name = "Row" .. #rows + 1,
					LayoutOrder = #rows + 1,
					Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, cardHeight(size)),
					BackgroundTransparency = 1,
					create("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, Theme.spacing.sm),
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						SortOrder = Enum.SortOrder.LayoutOrder,
					}),
				})
				for index = first, math.min(first + PER_ROW - 1, #rewards) do
					card(rewards[index], index, size).Parent = row
				end
				table.insert(rows, row)
			end
			local frame = create("Frame")({
				Name = "Rewards",
				Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				scale,
				create("UIListLayout")({
					Padding = UDim.new(0, Theme.spacing.sm),
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				rows,
			})
			-- The bounce in: a back-eased overshoot from POP_FROM.
			TweenService:Create(
				scale,
				TweenInfo.new(C.Env.duration(0.35), Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Scale = 1 }
			):Play()
			return frame
		end,
	})
	return close
end

return ClaimPopup
