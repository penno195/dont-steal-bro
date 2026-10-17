--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- A season pass item up close (owner, 2026-10-17): tapping a tile that
-- isn't ready to claim opens this. Something worn shows on the player's
-- own avatar (UI/AvatarPreview); anything else shows its picture, big.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local AvatarPreview = require(script.Parent.Parent.AvatarPreview)
local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

local STAGE_H = 150

export type Item = {
	title: string, -- what it is, e.g. "Burglar Beanie" or "75 coins"
	body: string, -- which track and when, e.g. "Paid pass · 4 wins"
	def: any?, -- a cosmetic's config, for the avatar
	icon: string, -- SeasonTrackLogic.iconFor
	image: number?, -- its own picture
}

local ItemPreview = {}

function ItemPreview.open(item: Item): () -> ()
	local close: () -> () = function() end
	close = C.Modal.open({
		title = item.title,
		body = item.body,
		lead = true, -- the bigger body face: what it is and when, easy to read
		bodyLines = 1,
		dismissible = true,
		onDismiss = function()
			close()
		end,
		actions = {
			{
				label = "Close",
				variant = "secondary",
				onActivate = function()
					close()
				end,
			},
		},
		content = function()
			local picture = C.Icons.picture(function()
				return item.icon
			end, function()
				return item.image
			end, Theme.color.ink)
			picture.AnchorPoint = Vector2.new(0.5, 0.5)
			picture.Position = UDim2.fromScale(0.5, 0.5)
			picture.Size = UDim2.fromOffset(STAGE_H - 2 * Theme.spacing.md, STAGE_H - 2 * Theme.spacing.md)
			local stage = if AvatarPreview.supports(item.def)
				then AvatarPreview.view({
					def = function()
						return item.def
					end,
					fallback = picture,
				})
				else picture
			return create("Frame")({
				Name = "Stage",
				Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, STAGE_H),
				BackgroundColor3 = Theme.color.background,
				Base.corner(Theme.radius.md),
				stage,
			})
		end,
	})
	return close
end

return ItemPreview
