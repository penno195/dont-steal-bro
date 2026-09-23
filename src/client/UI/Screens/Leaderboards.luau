--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The leaderboards screen (P6-6). Mounted by MenuController.
--
-- DATA: three boards, each CACHED server-side and broadcast
-- (LeaderboardState for all-time, PeriodBoardState for daily/weekly,
-- every 60-120s). MenuController keeps the latest of each for the whole
-- session, so opening the screen shows the last broadcast at once.
-- There is no request remote: "Loading" means nothing has arrived yet,
-- and the screen says so rather than pretending to fetch. Staleness
-- travels with the entries (BoardLogic.view) and shows as a banner.
--
-- 100 ROWS ON A CHEAP PHONE. The list is virtualised: the canvas is the
-- full height (BoardLogic.contentHeight) so the scrollbar is honest,
-- but only the rows in view plus OVERSCAN either side exist
-- (BoardLogic.visibleRange). `values` keys rows by entry, so a row that
-- stays in view while scrolling is kept, not rebuilt.
--
-- The viewer's own row is pinned under the list, always visible: their
-- rank when on the board, BoardLogic.offListLabel() when not.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local BoardLogic = require(script.Parent.Parent.BoardLogic)
local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local MenuShell = require(script.Parent.MenuShell)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local effect = vide.effect
local values = vide.values
local switch = vide.switch

local TAB_H = 48
local ROW_H = 56 -- PlayerRow's height
local GAP = Theme.spacing.xs
local OVERSCAN = 4
local BANNER_H = 28
local PINNED_H = ROW_H + Theme.spacing.sm

export type Store = {
	selfId: number,
	-- Latest payload per tab; nil until that board's first broadcast.
	boards: () -> { [string]: BoardLogic.Payload },
	close: () -> (),
}

-- A list item with its position fixed, frozen so `values` sees the same
-- key for the same row across scroll updates.
type Slot = { entry: BoardLogic.Entry, index: number }

local TAB_LABELS: { [string]: string } = { Daily = "Daily", Weekly = "Weekly", AllTime = "All-time" }

local function streakText(n: number): string
	return tostring(n)
end

local function list(
	tab: () -> BoardLogic.Tab,
	view: () -> BoardLogic.View,
	selfId: number,
	height: () -> number
): Instance
	local offset = source(0)
	local slots = derive(function(): { Slot }
		local out: { Slot } = {}
		for i, entry in view().rows do
			out[i] = table.freeze({ entry = entry, index = i })
		end
		return out
	end)
	local visible = derive(function(): { Slot }
		local all = slots()
		local first, last = BoardLogic.visibleRange(offset(), height(), ROW_H, GAP, #all, OVERSCAN)
		local out = {}
		for i = first, last do
			table.insert(out, all[i])
		end
		return out
	end)

	local frame = create("ScrollingFrame")({
		Name = "Rows",
		Size = function()
			return UDim2.fromOffset(MenuShell.INNER, height())
		end,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 4,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		CanvasSize = function()
			return UDim2.fromOffset(0, BoardLogic.contentHeight(#slots(), ROW_H, GAP))
		end,
		-- Each row sits at its own index's offset. No UIListLayout: it
		-- would stack the few built rows at the top of the canvas.
		values(visible, function(slot: Slot)
			local row = C.PlayerRow({
				userId = slot.entry.userId,
				displayName = slot.entry.displayName,
				rank = slot.entry.rank,
				trailing = streakText(slot.entry.bestStreak),
				trailingIcon = "flame",
				isLocalPlayer = slot.entry.userId == selfId,
				width = MenuShell.INNER - 8, -- clear of the scrollbar
			})
			row.Position = UDim2.fromOffset(0, (slot.index - 1) * (ROW_H + GAP))
			return row :: any
		end) :: any,
	}) :: ScrollingFrame

	-- Canvas offset is in absolute px; the rows are in reference px under
	-- the UIScale, so divide it back out.
	frame:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		local scale = C.Env.scale()
		offset(frame.CanvasPosition.Y / math.max(scale, 0.01))
	end)

	-- Back to the top on a tab switch. A refresh of the same board keeps
	-- the viewer where they were.
	effect(function()
		tab()
		frame.CanvasPosition = Vector2.zero
	end)

	return frame
end

local function pinned(view: () -> BoardLogic.View, selfId: number): Instance
	local player = Players.LocalPlayer
	return create("Frame")({
		Name = "Pinned",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromOffset(MenuShell.INNER, PINNED_H),
		BackgroundColor3 = Theme.color.background,
		BorderSizePixel = 0,
		create("Frame")({
			Name = "Rule",
			Size = UDim2.new(1, 0, 0, 1),
			BackgroundColor3 = Theme.color.line,
			BorderSizePixel = 0,
		}),
		-- Rebuilt whenever the board is (a new Viewer table each time), so
		-- a refreshed rank can't be left showing the old one.
		values(
			derive(function()
				return { view().viewer }
			end),
			function(v: BoardLogic.Viewer)
				local row = C.PlayerRow({
					userId = selfId,
					displayName = player.DisplayName,
					rank = v.rank,
					title = if v.onList then nil else BoardLogic.offListLabel(),
					trailing = if v.onList then streakText(v.bestStreak or 0) else nil,
					trailingIcon = if v.onList then "flame" else nil,
					isLocalPlayer = true,
					width = MenuShell.INNER,
				})
				row.AnchorPoint = Vector2.new(0, 1)
				row.Position = UDim2.fromScale(0, 1)
				return row :: any
			end
		) :: any,
	})
end

local function body(store: Store, height: () -> number): { Instance }
	local tabIndex = source(1)
	-- Cast: derive widens a string-literal union back to `string`.
	local tab = derive(function(): BoardLogic.Tab
		return BoardLogic.TABS[tabIndex()]
	end) :: () -> BoardLogic.Tab
	local view = derive(function(): BoardLogic.View
		return BoardLogic.view(store.boards()[tab()], store.selfId)
	end)
	local phase = derive(function(): string
		return view().phase
	end)
	local stale = derive(function()
		return view().stale
	end)

	local tabs = {}
	for _, id in BoardLogic.TABS do
		table.insert(tabs, { label = TAB_LABELS[id], icon = if id == "AllTime" then "trophy" else "star" })
	end

	-- Height left for the list once the tabs, the banner (when shown)
	-- and the pinned row have taken theirs.
	local listHeight = derive(function()
		local h = height() - TAB_H - Theme.spacing.sm - PINNED_H
		if stale() then
			h -= BANNER_H + Theme.spacing.xs
		end
		return math.max(0, h)
	end)

	return {
		C.TabBar({
			tabs = tabs,
			selected = tabIndex,
			onSelect = tabIndex,
			width = MenuShell.INNER,
			order = 1,
		}),
		create("Frame")({
			Name = "Content",
			Position = UDim2.fromOffset(0, TAB_H + Theme.spacing.sm),
			Size = function()
				return UDim2.fromOffset(MenuShell.INNER, height() - TAB_H - Theme.spacing.sm)
			end,
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.xs),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			-- Staleness: icon AND words, never a colour alone.
			create("Frame")({
				Name = "StaleBanner",
				LayoutOrder = 1,
				Visible = stale,
				Size = UDim2.fromOffset(MenuShell.INNER, BANNER_H),
				BackgroundColor3 = Theme.color.warning,
				Base.corner(Theme.radius.sm),
				Base.text("caption", {
					Name = "Text",
					Size = UDim2.fromScale(1, 1),
					Text = "⚠ Showing older results. The board will refresh soon.",
					TextColor3 = Theme.color.inkOnLight,
				}),
			}),
			create("Frame")({
				Name = "ListSlot",
				LayoutOrder = 2,
				Size = function()
					return UDim2.fromOffset(MenuShell.INNER, listHeight())
				end,
				BackgroundTransparency = 1,
				-- Keyed on phase only: the Ready list follows `view` itself,
				-- so a refresh updates rows in place instead of rebuilding.
				switch(phase)({
					Loading = function()
						return MenuShell.message("Loading the board", "Boards update every minute or two.", true)
					end,
					Empty = function()
						return MenuShell.message(
							derive(function()
								return (BoardLogic.emptyText(tab()))
							end),
							derive(function()
								local _, line = BoardLogic.emptyText(tab())
								return line
							end)
						)
					end,
					Ready = function()
						return list(tab, view, store.selfId, listHeight) :: any
					end,
				}) :: any,
			}),
		}),
		create("Frame")({
			Name = "PinnedSlot",
			Size = UDim2.fromScale(1, 1),
			BackgroundTransparency = 1,
			pinned(view, store.selfId),
		}),
	}
end

local Leaderboards = {}

function Leaderboards.mount(controller: any, store: Store): () -> ()
	return MenuShell.mount(controller, {
		name = "LeaderboardsScreen",
		title = "Leaderboards",
		onClose = store.close,
		body = function(height)
			return body(store, height)
		end,
	})
end

return Leaderboards
