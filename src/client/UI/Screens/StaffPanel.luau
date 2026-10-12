--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The staff panel (staff-tools.md step 4). Mounted by MenuController,
-- whose launcher shows its button to staff only (liveOps.adminUserIds).
-- The server checks again and decides; this only builds the request.
--
-- A small window, not a full-screen menu (owner, 2026-10-12, after the
-- Squishie merge game's staff panel): the game stays visible around it.
-- One scrolling column of chip grids, and a footer that never scrolls:
--
--   +-------------------------------------+
--   | STAFF GIFTS                     (X) |
--   | Give to                             |
--   | [Everyone] [Player A] [Pl B] [Pl C] |
--   | Gift                                |
--   | [Coins][Cosmetic][Nav][Unl.][Saves] |
--   | Amount                              |
--   | [ 500    ] [100] [500] [1000]       |   or, for a cosmetic: a
--   |                                     |   search box over a grid
--   |-------------------------------------|
--   | 500 coins to Player A?      [Give ] |
--   +-------------------------------------+
--
-- GIVE TAKES TWO TAPS. The first arms it and the footer asks "...?",
-- the second sends. Changing anything disarms it. There are no caps
-- (design-decisions.md), so a slip of the thumb is the one thing this
-- screen guards against.
--
-- Names only: display name and username, never a streak or a title
-- (Q7 condition 1).

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
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

-- Reference px. Landscape's short side is ~360 at the current scale, so
-- the window leaves the game visible above and below it.
local WIDTH = 480
local HEIGHT = 280
local PAD = Theme.spacing.md
local INNER = WIDTH - 2 * PAD
local SCROLLBAR = 4
local LIST_W = INNER - SCROLLBAR - Theme.spacing.xs
local HEADER_H = 34
local CLOSE_SIZE = 32
local CHIP_H = 32
local GAP = Theme.spacing.xs + 2
local CAPTION_H = Theme.type.caption.size + Theme.spacing.xs
local FOOTER_H = 40
local GIVE_W = 150
local AMOUNT_W = 130
local CLOSE_ACTION = "StaffPanelClose"
-- Seconds for a new section to grow the canvas before scrolling to it.
local SCROLL_WAIT = 0.1

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

local function chipWidth(perRow: number): number
	return math.floor((LIST_W - (perRow - 1) * GAP) / perRow)
end

local function caption(text: string, order: number): TextLabel
	return Base.text("caption", {
		Name = "Caption",
		LayoutOrder = order,
		Size = UDim2.fromOffset(LIST_W, CAPTION_H),
		Text = text,
		TextColor3 = Theme.color.inkMuted,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Bottom,
	})
end

-- One pickable chip, like a radio button. Picked = gold fill and a
-- thicker rim, a brightness change as well as a colour one.
local function chip(
	label: string | () -> string,
	picked: () -> boolean,
	onPick: () -> (),
	width: number,
	order: number,
	visible: (() -> boolean)?
): Instance
	local button = Base.interactive({
		name = "Chip",
		size = Vector2.new(width, CHIP_H),
		onActivate = onPick,
		order = order,
		layoutOrder = order,
		radius = Theme.radius.sm,
		visual = function(state)
			return {
				create("Frame")({
					Name = "Fill",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = function()
						return if picked() then Theme.color.primary else Theme.color.surfaceRaised
					end,
					BackgroundTransparency = function()
						return if state() == "pressed" then 0.2 else 0
					end,
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
					Base.corner(Theme.radius.sm),
					Base.padding(Theme.spacing.xs),
					Base.text("label", {
						Name = "Label",
						Size = UDim2.fromScale(1, 1),
						Text = label,
						TextColor3 = function()
							return if picked() then Theme.color.onPrimary else Theme.color.ink
						end,
						TextTruncate = Enum.TextTruncate.AtEnd,
					}),
				}),
			}
		end,
	})
	if visible ~= nil then
		effect(function()
			button.Visible = visible()
		end)
	end
	return button
end

-- A wrapping grid of chips that grows to fit them.
local function grid(name: string, perRow: number, order: number, children: { any }): Frame
	local props: { [any]: any } = {
		Name = name,
		LayoutOrder = order,
		Size = UDim2.fromOffset(LIST_W, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		create("UIGridLayout")({
			CellSize = UDim2.fromOffset(chipWidth(perRow), CHIP_H),
			CellPadding = UDim2.fromOffset(GAP, GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

-- A typing box whose text is `text`, kept equal to what's typed, live.
local function textBox(placeholder: string, text: any, width: number, order: number): TextBox
	local box = create("TextBox")({
		Name = "Input",
		LayoutOrder = order,
		ClearTextOnFocus = false,
		PlaceholderText = placeholder,
		PlaceholderColor3 = Theme.color.inkMuted,
		Text = text,
		TextColor3 = Theme.color.ink,
		FontFace = Theme.type.body.font,
		TextSize = Theme.type.body.size,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		-- A dark well, as the Decision Studio's chat box: it's where you type.
		BackgroundColor3 = Theme.color.background,
		Size = UDim2.fromOffset(width, CHIP_H),
		Base.corner(Theme.radius.sm),
		Base.padding(Theme.spacing.xs),
		create("UIStroke")({
			BorderStrokePosition = Enum.BorderStrokePosition.Inner, -- see Base.focusRing
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Color = Theme.color.line,
			Thickness = 2,
		}),
	}) :: TextBox
	local changed = box:GetPropertyChangedSignal("Text"):Connect(function()
		text(box.Text)
	end)
	cleanup(function()
		changed:Disconnect()
	end)
	return box
end

local function window(store: Store): Frame
	-- ----- the selection -----------------------------------------------------
	local target = source("Player" :: "Player" | "Server")
	local userId = source(nil :: number?)
	local kind = source("Currency" :: StaffPanelLogic.Kind)
	local amountText = source(tostring(StaffPanelLogic.KINDS[1].presets[1]))
	local cosmeticId = source(nil :: string?)
	local search = source("")

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

	-- ----- who ---------------------------------------------------------------
	local whoGrid = grid("Who", 4, 2, {
		chip(function()
			return string.format("Everyone here (%d)", #inServer())
		end, function()
			return target() == "Server"
		end, function()
			target("Server")
		end, chipWidth(4), 1),
		indexes(store.players, function(entry: () -> StaffPanelLogic.PlayerEntry, index: number)
			return chip(function()
				return StaffPanelLogic.playerLabel(entry())
			end, function()
				return target() == "Player" and userId() == entry().userId
			end, function()
				target("Player")
				userId(untrack(entry).userId)
			end, chipWidth(4), 1 + index)
		end) :: any,
	})

	-- ----- what --------------------------------------------------------------
	local kindChips: { any } = {}
	for i, def in StaffPanelLogic.KINDS do
		table.insert(
			kindChips,
			chip(def.label, function()
				return kind() == def.kind
			end, function()
				pickKind(def.kind)
			end, chipWidth(#StaffPanelLogic.KINDS), i)
		)
	end

	local takesAmount = derive(function(): boolean
		local def = StaffPanelLogic.kindDef(kind())
		return def ~= nil and def.takesAmount
	end)
	local isCosmetic = derive(function(): boolean
		return kind() == "Cosmetic"
	end)

	-- One row: the box (any whole number, no cap) and the quick picks.
	local function amountSection(): Instance
		local presetW = math.floor((LIST_W - AMOUNT_W - 3 * GAP) / 3)
		return create("Frame")({
			Name = "Amount",
			LayoutOrder = 6,
			Size = UDim2.fromOffset(LIST_W, CHIP_H),
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			textBox("Amount", amountText, AMOUNT_W, 1),
			indexes(
				derive(function(): { number }
					local def = StaffPanelLogic.kindDef(kind())
					return if def then def.presets else {}
				end),
				function(amount: () -> number, index: number)
					return chip(function()
						return tostring(amount())
					end, function()
						return StaffPanelLogic.parseAmount(amountText()) == amount()
					end, function()
						amountText(tostring(untrack(amount)))
					end, presetW, 1 + index)
				end
			) :: any,
		})
	end

	-- A search box over every cosmetic; tap one to pick it.
	local function cosmeticSection(): Instance
		local chips: { any } = {}
		for i, entry in store.cosmetics do
			table.insert(
				chips,
				chip(
					string.format("%s (%s)", entry.name, entry.category),
					function()
						return cosmeticId() == entry.id
					end,
					function()
						cosmeticId(entry.id)
					end,
					chipWidth(2),
					i,
					function()
						return StaffPanelLogic.matches(entry, search())
					end
				)
			)
		end
		return create("Frame")({
			Name = "Cosmetics",
			LayoutOrder = 6,
			Size = UDim2.fromOffset(LIST_W, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, GAP),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			textBox("Search cosmetics", search, LIST_W, 1),
			grid("Grid", 2, 2, chips),
		})
	end

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

	local listH = HEIGHT - 2 * PAD - HEADER_H - FOOTER_H - 2 * Theme.spacing.xs

	local giftCaption = caption("Gift", 3)
	local panel = C.Panel({
		name = "Window",
		elevation = 3,
		size = UDim2.fromOffset(WIDTH, HEIGHT),
		anchorPoint = Vector2.new(0.5, 0.5),
		position = UDim2.fromScale(0.5, 0.5),
		padding = PAD,
		children = {
			create("Frame")({
				Name = "Header",
				Size = UDim2.fromOffset(INNER, HEADER_H),
				BackgroundTransparency = 1,
				Base.text("title", {
					Name = "Title",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.new(1, -(CLOSE_SIZE + Theme.spacing.sm), 0, HEADER_H - Theme.spacing.sm),
					Text = "Staff gifts",
					TextXAlignment = Enum.TextXAlignment.Left,
				}) :: Instance,
				C.IconButton({
					icon = "close-button",
					iconSize = CLOSE_SIZE,
					label = "Close",
					onActivate = store.close,
					order = 1000, -- last in gamepad order: never the default focus
					anchorPoint = Vector2.new(1, 0.5),
					position = UDim2.fromScale(1, 0.5),
				}),
			}),
			create("ScrollingFrame")({
				Name = "Form",
				Position = UDim2.fromOffset(0, HEADER_H + Theme.spacing.xs),
				Size = UDim2.fromOffset(INNER, listH),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = SCROLLBAR,
				ScrollingDirection = Enum.ScrollingDirection.Y,
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
				CanvasSize = UDim2.new(),
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Vertical,
					Padding = UDim.new(0, GAP),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				caption("Give to", 1),
				whoGrid,
				giftCaption,
				grid("What", #StaffPanelLogic.KINDS, 4, kindChips),
				show(takesAmount, function()
					return caption("Amount (type any number, no cap)", 5)
				end) :: any,
				show(isCosmetic, function()
					return caption("Cosmetic", 5)
				end) :: any,
				show(takesAmount, amountSection) :: any,
				show(isCosmetic, cosmeticSection) :: any,
			}) :: Instance,
			create("Frame")({
				Name = "Footer",
				AnchorPoint = Vector2.new(0, 1),
				Position = UDim2.fromScale(0, 1),
				Size = UDim2.fromOffset(INNER, FOOTER_H),
				BackgroundTransparency = 1,
				Base.text("label", {
					Name = "Status",
					AnchorPoint = Vector2.new(0, 0.5),
					Position = UDim2.fromScale(0, 0.5),
					Size = UDim2.new(1, -(GIVE_W + Theme.spacing.sm), 1, 0),
					Text = status,
					TextColor3 = statusColor,
					TextXAlignment = Enum.TextXAlignment.Left,
				}) :: Instance,
				C.Button({
					label = derive(function()
						if store.busy() then
							return "Giving"
						end
						return if armed() then "Tap to confirm" else "Give"
					end),
					variant = "primary",
					compact = true,
					width = GIVE_W,
					disabled = derive(function()
						return built().payload == nil
					end),
					loading = store.busy,
					onActivate = onGive,
					order = 900,
					anchorPoint = Vector2.new(1, 0.5),
					position = UDim2.fromScale(1, 0.5),
				}),
			}),
		},
	})

	-- Picking Cosmetic scrolls "Gift" to the top, so the search box and
	-- the grid under it come into view rather than sitting below the
	-- fold. CanvasPosition is in screen px under the window's UIScale,
	-- the same as AbsolutePosition (found in Studio: dividing by the
	-- scale stopped short). It waits for the grid to grow the canvas
	-- first, or the scroll is clamped short.
	local form = panel:FindFirstChild("Form") :: ScrollingFrame
	effect(function()
		if not isCosmetic() then
			return
		end
		task.delay(SCROLL_WAIT, function()
			local gap = giftCaption.AbsolutePosition.Y - form.AbsolutePosition.Y
			form.CanvasPosition = Vector2.new(0, math.max(0, form.CanvasPosition.Y + gap))
		end)
	end)
	return panel
end

local StaffPanel = {}

-- Mounts the window; returns the unmount.
function StaffPanel.mount(controller: any, store: Store): () -> ()
	local gui = controller.createScreen("StaffPanel", { displayOrder = Theme.displayOrder.panel }) :: ScreenGui
	local destroy = vide.root(function()
		local frame = window(store)
		controller.attachScale(frame)
		frame.Parent = gui
		-- Escape / gamepad B close it, as they do a full-screen menu.
		ContextActionService:BindAction(CLOSE_ACTION, function(_, inputState: Enum.UserInputState)
			if inputState == Enum.UserInputState.Begin then
				store.close()
			end
			return Enum.ContextActionResult.Sink
		end, false, Enum.KeyCode.ButtonB, Enum.KeyCode.Escape)
		cleanup(function()
			ContextActionService:UnbindAction(CLOSE_ACTION)
		end)
	end)
	return function()
		destroy()
		gui:Destroy()
	end
end

return StaffPanel
