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

local CARD_W = 76
local CARD_H = 96
local NAME_H = 2 * Theme.type.caption.size + Theme.spacing.xxs
local POP_FROM = 0.6 -- the cards' starting scale, before they bounce in

export type Reward = {
	premium: boolean,
	text: string, -- what the reward is, e.g. "75 coins"
	icon: string, -- SeasonTrackLogic.iconFor of its grant
	image: number?, -- the item's own picture, if it has one
}

local function card(reward: Reward, order: number): Instance
	local fill = if reward.premium then Theme.fill.seasonPaid else Theme.fill.seasonFree
	local icon = C.Icons.picture(function()
		return reward.icon
	end, function()
		return reward.image
	end, fill.ink)
	icon.AnchorPoint = Vector2.new(0.5, 0)
	icon.Position = UDim2.fromScale(0.5, 0)
	icon.Size = UDim2.new(1, 0, 1, -(NAME_H + Theme.spacing.xs))
	create("UIAspectRatioConstraint")({ AspectRatio = 1, Parent = icon })
	return create("Frame")({
		Name = "Reward" .. order,
		LayoutOrder = order,
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundTransparency = 1,
		Base.raised({
			fill = function()
				return fill
			end,
			lip = Theme.lip.small,
			radius = Theme.radius.md,
			rimThickness = 3,
			gloss = true,
			children = {
				Base.padding(Theme.spacing.xs),
				icon,
				Base.text("caption", {
					Name = "Item",
					AnchorPoint = Vector2.new(0, 1),
					Position = UDim2.fromScale(0, 1),
					Size = UDim2.new(1, 0, 0, NAME_H),
					Text = reward.text,
					TextColor3 = fill.ink,
					FontFace = Font.new(Theme.type.caption.font.Family, Enum.FontWeight.Bold),
					TextWrapped = true,
					TextYAlignment = Enum.TextYAlignment.Bottom,
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
			local cards: { Instance } = {}
			for index, reward in rewards do
				table.insert(cards, card(reward, index))
			end
			local frame = create("Frame")({
				Name = "Rewards",
				Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				scale,
				create("UIGridLayout")({
					CellSize = UDim2.fromOffset(CARD_W, CARD_H),
					CellPadding = UDim2.fromOffset(Theme.spacing.sm, Theme.spacing.sm),
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				cards,
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
