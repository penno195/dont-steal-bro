--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The community reward's pop-up (owner, 2026-10-18): the Hub's notice
-- board by the plinths opens it. It says what joining gets, shows the
-- item, and carries the same live status line as the Locker's FREE tile
-- ("Join request sent...", "Not in the group yet..."). Roblox's own join
-- prompt opens over it; "Join" opens that prompt again. The grant itself
-- is the server's (CommunityRewardCheck), and its claim pop-up closes
-- this one.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create

local STAGE_H = 130
local STATUS_H = Theme.type.body.size * 2

export type Props = {
	name: string, -- the reward's display name
	image: number?, -- its picture
	status: () -> string, -- the live status line (MenuController's communityText)
	join: () -> (), -- opens Roblox's join prompt, then has the server check
	onClosed: () -> (), -- however it closes
}

local CommunityJoin = {}

function CommunityJoin.open(props: Props): () -> ()
	local closeModal: () -> () = function() end
	local closed = false
	local function close()
		if not closed then
			closed = true
			closeModal()
			props.onClosed()
		end
	end
	closeModal = C.Modal.open({
		title = "Free " .. props.name,
		body = "Join the Studio Corvus community and it's yours, free. Once you've joined it goes straight into your Locker.",
		bodyLines = 3,
		dismissible = true,
		onDismiss = function()
			close()
		end,
		actions = {
			{
				label = "Join",
				onActivate = props.join,
			},
			{
				label = "Close",
				variant = "secondary",
				onActivate = function()
					close()
				end,
			},
		},
		content = function()
			return create("Frame")({
				Name = "Reward",
				Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, STAGE_H + Theme.spacing.sm + STATUS_H),
				BackgroundTransparency = 1,
				create("Frame")({
					Name = "Stage",
					Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, STAGE_H),
					BackgroundColor3 = Theme.color.background,
					Base.corner(Theme.radius.md),
					create("ImageLabel")({
						Name = "Picture",
						AnchorPoint = Vector2.new(0.5, 0.5),
						Position = UDim2.fromScale(0.5, 0.5),
						Size = UDim2.fromOffset(STAGE_H - 2 * Theme.spacing.md, STAGE_H - 2 * Theme.spacing.md),
						BackgroundTransparency = 1,
						ScaleType = Enum.ScaleType.Fit,
						Image = if props.image then "rbxassetid://" .. props.image else "",
					}),
				}),
				Base.text("body", {
					Name = "Status",
					Position = UDim2.fromOffset(0, STAGE_H + Theme.spacing.sm),
					Size = UDim2.fromOffset(C.Modal.CONTENT_WIDTH, STATUS_H),
					Text = props.status,
					TextColor3 = Theme.color.inkMuted,
				}),
			})
		end,
	})
	return close
end

return CommunityJoin
