--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The staff panel (staff-tools.md step 4). Mounted by MenuController,
-- whose launcher shows its button to staff only (liveOps.adminUserIds).
-- The server checks again and decides; this only builds the request.
--
--   +-------------+-------------+
--   | Give to     | Gift        |   left: everyone here, or one player
--   |  Everyone   |  Coins ...  |   right: the kind, then its amount or
--   |  Player A   | Amount      |          which cosmetic
--   |  ...        |  [100][500] |
--   +-------------+-------------+
--   | 500 coins to Player A?    |   footer: what Give will do (or what's
--   |                   [Give ] |   missing, or the server's reply)
--   +---------------------------+
--
-- Portrait (and any too-narrow landscape) gets one scrolling column
-- with the same footer.
--
-- GIVE TAKES TWO TAPS. The first arms it and the footer asks "...?",
-- the second sends. Changing anything disarms it. There are no caps
-- (design-decisions.md), so a slip of the thumb is the one thing this
-- screen guards against.
--
-- Names only: display name and username, never a streak or a title
-- (Q7 condition 1).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local MenuShell = require(script.Parent.MenuShell)
local StaffPanelLogic = require(script.Parent.Parent.StaffPanelLogic)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local effect = vide.effect
local cleanup = vide.cleanup
local indexes = vide.indexes
local show = vide.show
local untrack = vide.untrack

local ROW_H = 48
local CAPTION_H = Theme.type.caption.size + Theme.spacing.sm
local STATUS_H = 34
local FOOTER_H = STATUS_H + Theme.spacing.xs + Theme.touch.primaryHeight
local PRESET_GAP = Theme.spacing.sm
local CHECK = 20

export type Store = {
	-- Everyone in this server, already in StaffPanelLogic.sortPlayers order.
	players: () -> { StaffPanelLogic.PlayerEntry },
	-- Every cosmetic, in StaffPanelLogic.sortCosmetics order.
	cosmetics: { StaffPanelLogic.CosmeticEntry },
	cosmeticName: (string) -> string,
	-- The server's reply to the last give (nil until one arrives).
	result: () -> StaffPanelLogic.Result?,
	-- A give is on its way and the reply hasn't come back yet.
	busy: () -> boolean,
	give: (payload: { [string]: any }) -> (),
	close: () -> (),
}

local function caption(text: string | () -> string, width: number, order: number): TextLabel
	return Base.text("caption", {
		Name = "Caption",
		LayoutOrder = order,
		Size = UDim2.fromOffset(width, CAPTION_H),
		Text = text,
		TextColor3 = Theme.color.inkMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
	})
end

-- A full-width row that is picked or not, like a radio button. Picked
-- is spelled out by a check mark as well as the colour.
local function choiceRow(
	label: string | () -> string,
	picked: () -> boolean,
	onPick: () -> (),
	width: number,
	order: number
): Instance
	return Base.interactive({
		name = "Choice",
		size = Vector2.new(width, ROW_H),
		onActivate = onPick,
		order = order,
		layoutOrder = order,
		radius = Theme.radius.md,
		visual = function(state)
			return {
				create("Frame")({
					Name = "Fill",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = Base.STAGE_BACKGROUND,
					Base.stageGradient(function()
						return state() == "pressed"
					end),
					create("UIStroke")({
						BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
						ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
						Color = function()
							return if picked() then Theme.color.primary else Theme.color.line
						end,
						Thickness = function()
							return if picked() then 3 else 2
						end,
					}),
					Base.corner(Theme.radius.md),
					create("UIPadding")({
						PaddingLeft = UDim.new(0, Theme.spacing.md),
						PaddingRight = UDim.new(0, Theme.spacing.md),
					}),
					Base.text("label", {
						Name = "Label",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
						Size = UDim2.new(1, -(CHECK + Theme.spacing.sm), 0, Theme.type.label.size + Theme.spacing.xs),
						Text = label,
						TextXAlignment = Enum.TextXAlignment.Left,
						TextTruncate = Enum.TextTruncate.AtEnd,
					}),
					create("Frame")({
						Name = "Check",
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						Size = UDim2.fromOffset(CHECK, CHECK),
						BackgroundTransparency = 1,
						Visible = picked,
						C.Icons.view("check", CHECK, Theme.color.primary),
					}),
				}),
			}
		end,
	})
end

local function list(name: string, width: number, height: () -> number, children: { any }): ScrollingFrame
	local props: { [any]: any } = {
		Name = name,
		Size = function()
			return UDim2.fromOffset(width + MenuShell.SCROLLBAR, height())
		end,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = MenuShell.SCROLLBAR,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		CanvasSize = UDim2.new(),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("ScrollingFrame")(props) :: ScrollingFrame
end

local function body(store: Store, height: () -> number, layout: MenuShell.BodyLayout): { Instance }
	local pane = layout.pane
	local fullWidth = if layout.split then 2 * pane + MenuShell.GUTTER else pane

	-- ----- the selection -----------------------------------------------------
	local target = source("Player" :: "Player" | "Server")
	local userId = source(nil :: number?)
	local kind = source("Currency" :: StaffPanelLogic.Kind)
	local amountText = source(tostring(StaffPanelLogic.KINDS[1].presets[1]))
	local cosmeticId = source(nil :: string?)

	local function pickKind(next: StaffPanelLogic.Kind)
		if untrack(kind) == next then
			return
		end
		kind(next)
		local def = StaffPanelLogic.kindDef(next)
		if def ~= nil and #def.presets > 0 then
			amountText(tostring(def.presets[1]))
		end
	end

	local inServer = derive(function(): { number }
		local ids = {}
		for _, entry in store.players() do
			table.insert(ids, entry.userId)
		end
		return ids
	end)
	-- The chosen player left: forget them, so Give can't arm on a ghost.
	effect(function()
		local id = userId()
		if id ~= nil and table.find(inServer(), id) == nil then
			userId(nil)
		end
	end)

	local built = derive(function(): { payload: { [string]: any }?, missing: string? }
		local payload, missing = StaffPanelLogic.payload(
			{
				target = target(),
				userId = userId(),
				kind = kind(),
				amountText = amountText(),
				cosmeticId = cosmeticId(),
			} :: any,
			inServer()
		)
		return { payload = payload, missing = missing }
	end)

	-- ----- two taps, and the reply ------------------------------------------
	local armed = source(false)
	local replyShown = source(false)
	effect(function()
		built()
		armed(false)
		replyShown(false)
	end)
	effect(function()
		if store.result() ~= nil then
			replyShown(true)
		end
	end)

	local function nameOf(id: number): string
		for _, entry in untrack(store.players) do
			if entry.userId == id then
				return StaffPanelLogic.playerLabel(entry)
			end
		end
		return "a player who left"
	end
	local summary = derive(function(): string?
		local payload = built().payload
		if payload == nil then
			return nil
		end
		return StaffPanelLogic.summary(payload, nameOf, store.cosmeticName, #inServer())
	end)

	local function onGive()
		local payload = untrack(built).payload
		if payload == nil or untrack(store.busy) then
			return
		end
		if not untrack(armed) then
			armed(true)
			return
		end
		armed(false)
		store.give(payload)
	end

	-- ----- left: who ---------------------------------------------------------
	local whoRows: { any } = {
		caption("Give to", pane, 1),
		choiceRow(function()
			return string.format("Everyone in this server (%d)", #inServer())
		end, function()
			return target() == "Server"
		end, function()
			target("Server")
		end, pane, 2),
		create("Frame")({
			Name = "Players",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(pane, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			indexes(store.players, function(entry: () -> StaffPanelLogic.PlayerEntry, index: number)
				return choiceRow(function()
					return StaffPanelLogic.playerLabel(entry())
				end, function()
					return target() == "Player" and userId() == entry().userId
				end, function()
					target("Player")
					userId(untrack(entry).userId)
				end, pane, 10 + index)
			end) :: any,
		}),
	}

	-- ----- right: what -------------------------------------------------------
	local kindRows: { any } = { caption("Gift", pane, 100) }
	for i, def in StaffPanelLogic.KINDS do
		table.insert(
			kindRows,
			choiceRow(def.label, function()
				return kind() == def.kind
			end, function()
				pickKind(def.kind)
			end, pane, 100 + i)
		)
	end

	local takesAmount = derive(function(): boolean
		local def = StaffPanelLogic.kindDef(kind())
		return def ~= nil and def.takesAmount
	end)
	local isCosmetic = derive(function(): boolean
		return kind() == "Cosmetic"
	end)

	local function amountSection(): Instance
		local presetW = (pane - 2 * PRESET_GAP) / 3
		local input = create("TextBox")({
			Name = "Amount",
			LayoutOrder = 3,
			ClearTextOnFocus = false,
			PlaceholderText = "Any whole number",
			PlaceholderColor3 = Theme.color.inkMuted,
			Text = amountText,
			TextColor3 = Theme.color.ink,
			FontFace = Theme.type.body.font,
			TextSize = Theme.type.body.size,
			TextXAlignment = Enum.TextXAlignment.Left,
			-- A dark well, as the Decision Studio's chat box: it's where you type.
			BackgroundColor3 = Theme.color.background,
			Size = UDim2.fromOffset(pane, ROW_H),
			Base.corner(Theme.radius.md),
			Base.padding(Theme.spacing.sm),
			create("UIStroke")({
				BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Theme.color.line,
				Thickness = 2,
			}),
		}) :: TextBox
		-- Live, so the footer and Give follow what's typed.
		local changed = input:GetPropertyChangedSignal("Text"):Connect(function()
			amountText(input.Text)
		end)
		cleanup(function()
			changed:Disconnect()
		end)

		return create("Frame")({
			Name = "AmountSection",
			LayoutOrder = 200,
			Size = UDim2.fromOffset(pane, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			caption("Amount (no cap)", pane, 1),
			create("Frame")({
				Name = "Presets",
				LayoutOrder = 2,
				Size = UDim2.fromOffset(pane, Theme.touch.iconButton),
				BackgroundTransparency = 1,
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					Padding = UDim.new(0, PRESET_GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				indexes(
					derive(function(): { number }
						local def = StaffPanelLogic.kindDef(kind())
						return if def then def.presets else {}
					end),
					function(amount: () -> number, index: number)
						return C.Button({
							label = derive(function()
								return tostring(amount())
							end),
							variant = "secondary",
							compact = true,
							width = presetW,
							onActivate = function()
								amountText(tostring(untrack(amount)))
							end,
							order = 200 + index,
							layoutOrder = index,
						})
					end
				) :: any,
			}),
			input,
		})
	end

	local function cosmeticSection(): Instance
		local rows: { any } = {
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			caption("Cosmetic", pane, 0),
		}
		for i, entry in store.cosmetics do
			table.insert(
				rows,
				choiceRow(string.format("%s  ·  %s", entry.name, entry.category), function()
					return cosmeticId() == entry.id
				end, function()
					cosmeticId(entry.id)
				end, pane, 300 + i)
			)
		end
		local props: { [any]: any } = {
			Name = "CosmeticSection",
			LayoutOrder = 200,
			Size = UDim2.fromOffset(pane, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}
		for _, row in rows do
			table.insert(props, row)
		end
		return create("Frame")(props)
	end

	table.insert(kindRows, show(takesAmount, amountSection) :: any)
	table.insert(kindRows, show(isCosmetic, cosmeticSection) :: any)

	-- ----- footer ------------------------------------------------------------
	local status = derive(function(): string
		local result = store.result()
		if replyShown() and result ~= nil then
			return result.message
		end
		local line = summary()
		if line == nil then
			return built().missing or ""
		end
		return if armed() then "Give " .. line .. "?" else line
	end)
	local statusColor = derive(function(): Color3
		local result = store.result()
		if replyShown() and result ~= nil then
			return if result.ok then Theme.color.success else Theme.color.danger
		end
		if armed() then
			return Theme.color.warning
		end
		return if summary() == nil then Theme.color.inkMuted else Theme.color.ink
	end)

	local footer = create("Frame")({
		Name = "Footer",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromOffset(fullWidth, FOOTER_H),
		BackgroundTransparency = 1,
		Base.text("label", {
			Name = "Status",
			Size = UDim2.fromOffset(fullWidth, STATUS_H),
			Text = status,
			TextColor3 = statusColor,
			TextXAlignment = Enum.TextXAlignment.Left,
		}) :: Instance,
		C.Button({
			label = derive(function()
				if store.busy() then
					return "Giving"
				end
				return if armed() then "Tap again to give" else "Give"
			end),
			variant = "primary",
			width = pane,
			disabled = derive(function()
				return built().payload == nil
			end),
			loading = store.busy,
			onActivate = onGive,
			order = 900,
			anchorPoint = Vector2.new(1, 1),
			position = UDim2.fromScale(1, 1),
		}),
	})

	local listH = function(): number
		return math.max(0, height() - FOOTER_H - Theme.spacing.sm)
	end

	if layout.split then
		local right = list("What", pane, listH, kindRows)
		right.Position = UDim2.fromOffset(pane + MenuShell.GUTTER, 0)
		return { list("Who", pane, listH, whoRows), right, footer }
	end
	local all: { any } = {}
	for _, row in whoRows do
		table.insert(all, row)
	end
	for _, row in kindRows do
		table.insert(all, row)
	end
	return { list("Form", pane, listH, all), footer }
end

local StaffPanel = {}

function StaffPanel.mount(controller: any, store: Store): () -> ()
	return MenuShell.mount(controller, {
		name = "StaffPanel",
		title = "Staff gifts",
		onClose = store.close,
		split = true,
		body = function(height, layout)
			return body(store, height, layout)
		end,
	})
end

return StaffPanel
