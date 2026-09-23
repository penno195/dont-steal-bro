--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- Device review screen for the component library (P6-2): every
-- component in every state at once, so one screenshot per device
-- reviews the whole set (docs/components.md "Device review").
--
-- States are FORCED where the component allows it (disabled, loading)
-- and demonstrated live where it can't be forced (hover and press need
-- a real finger or mouse - the gallery says so under each). A small
-- clock drives the countdown rings and progress so motion - and its
-- absence under reduced motion - can be checked too.
--
-- Mounted by UIScaleController when ReplicatedStorage has the
-- UIComponentGallery attribute set. Debug only.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local C = require(script.Parent.Parent.Components)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local cleanup = vide.cleanup

local COLUMN = 360 - 2 * Theme.spacing.lg

local function caption(text: string, order: number): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = "Caption"
	label.BackgroundTransparency = 1
	label.LayoutOrder = order
	label.Size = UDim2.fromOffset(COLUMN, Theme.type.caption.size + Theme.spacing.xs)
	label.Text = text
	label.TextColor3 = Theme.color.inkMuted
	label.TextXAlignment = Enum.TextXAlignment.Left
	Theme.applyText(label, "caption")
	return label
end

-- A labelled cell: the component, then a one-line caption naming the
-- state, so a reviewer reading the screenshot needn't guess.
local function cell(name: string, item: GuiObject, order: number): Frame
	return create("Frame")({
		Name = name,
		LayoutOrder = order,
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.new(),
		create("UIListLayout")({
			Padding = UDim.new(0, Theme.spacing.xxs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		item,
		caption(name, 2),
	}) :: Frame
end

-- A titled, wrapping row of cells.
local function section(title: string, order: number, cells: { Instance }): Frame
	local row = create("Frame")({
		Name = "Cells",
		LayoutOrder = 2,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			Padding = UDim.new(0, Theme.spacing.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}) :: Frame
	for _, c in cells do
		c.Parent = row
	end
	return C.Panel({
		name = title,
		title = title,
		layoutOrder = order,
		size = UDim2.fromScale(1, 0),
		automaticSize = Enum.AutomaticSize.Y,
		gap = Theme.spacing.sm,
		children = { row :: Instance },
	})
end

local function gallery(usableWidth: () -> number): Instance
	local t = source(0)
	local conn = RunService.Heartbeat:Connect(function(dt)
		t(t() + dt)
	end)
	cleanup(conn)
	local noop = function() end

	-- Cycles 20 -> 0 so all three urgency colours show in turn.
	local cycling = function(): number
		return 20 - (t() % 20)
	end
	local tab = source(1)
	local coins = function(): number
		return 1200 + math.floor(t() / 3) * 250
	end

	local localPlayer = Players.LocalPlayer
	local myId = if localPlayer then localPlayer.UserId else 1

	local sections = {
		section("Button", 1, {
			cell("primary · idle/hover/press live", C.Button({ label = "Ready", onActivate = noop, order = 1 }), 1),
			cell("secondary", C.Button({ label = "Later", variant = "secondary", onActivate = noop, order = 2 }), 2),
			cell("danger", C.Button({ label = "Leave", variant = "danger", onActivate = noop, order = 3 }), 3),
			cell("disabled", C.Button({ label = "Ready", disabled = true, onActivate = noop, order = 4 }), 4),
			cell("loading", C.Button({ label = "Ready", loading = true, onActivate = noop, order = 5 }), 5),
			cell("with icon", C.Button({ label = "Shop", icon = "shop", onActivate = noop, order = 6 }), 6),
		}),
		section("IconButton", 2, {
			cell("ghost", C.IconButton({ icon = "close", label = "Close", onActivate = noop, order = 10 }), 1),
			cell(
				"secondary",
				C.IconButton({
					icon = "settings",
					label = "Settings",
					variant = "secondary",
					onActivate = noop,
					order = 11,
				}),
				2
			),
			cell(
				"primary",
				C.IconButton({ icon = "bolt", label = "Use", variant = "primary", onActivate = noop, order = 12 }),
				3
			),
			cell(
				"disabled",
				C.IconButton({ icon = "back", label = "Back", disabled = true, onActivate = noop, order = 13 }),
				4
			),
			cell(
				"loading",
				C.IconButton({ icon = "shop", label = "Shop", loading = true, onActivate = noop, order = 14 }),
				5
			),
		}),
		section("Progress and countdown", 3, {
			cell(
				"ProgressBar · live",
				C.ProgressBar({
					label = "Fuses rewired",
					value = function()
						return (t() * 0.8) % 6
					end,
					max = 5,
					width = COLUMN - 2 * Theme.spacing.lg,
				}),
				1
			),
			cell(
				"ProgressBar · full",
				C.ProgressBar({
					label = "Complete",
					value = 5,
					max = 5,
					color = "success",
					width = COLUMN - 2 * Theme.spacing.lg,
				}),
				2
			),
			cell(
				"ring · calm",
				C.CountdownRing({
					secondsLeft = function()
						return 45
					end,
					total = 60,
				}),
				3
			),
			cell(
				"ring · warning",
				C.CountdownRing({
					secondsLeft = function()
						return 8
					end,
					total = 60,
				}),
				4
			),
			cell(
				"ring · critical",
				C.CountdownRing({
					secondsLeft = function()
						return 3
					end,
					total = 60,
				}),
				5
			),
			cell("ring · live 20s", C.CountdownRing({ secondsLeft = cycling, total = 20 }), 6),
		}),
		section("TaskCard", 4, {
			cell(
				"todo · tappable",
				C.TaskCard({
					title = "Pressure Valve",
					location = "Engine Room",
					status = "todo",
					onActivate = noop,
					order = 20,
				}),
				1
			),
			cell(
				"active · live",
				C.TaskCard({
					title = "Fuse Rewire",
					location = "Reactor",
					status = "active",
					progress = function()
						return (t() * 0.1) % 1
					end,
					onActivate = noop,
					order = 21,
				}),
				2
			),
			cell("done", C.TaskCard({ title = "Code Playback", location = "Bridge", status = "done" }), 3),
			cell(
				"locked (disabled)",
				C.TaskCard({ title = "Final Vault", location = "???", status = "locked", onActivate = noop, order = 22 }),
				4
			),
		}),
		section("PlayerRow", 5, {
			cell(
				"you · rank + streak",
				C.PlayerRow({
					userId = myId,
					displayName = if localPlayer then localPlayer.DisplayName else "You",
					title = "Trusted Sharer",
					rank = 1,
					trailing = "12",
					trailingIcon = "flame",
					isLocalPlayer = true,
				}),
				1
			),
			cell(
				"other · long name truncates",
				C.PlayerRow({
					userId = 1,
					displayName = "AVeryLongDisplayNameThatMustTruncate",
					title = "Notorious Stealer",
					rank = 2,
					trailing = "3",
					trailingIcon = "flame",
				}),
				2
			),
			cell("no rank, no title", C.PlayerRow({ userId = 1, displayName = "Roblox" }), 3),
		}),
		section("CurrencyPill and TabBar", 6, {
			cell("pill · counts live", C.CurrencyPill({ amount = coins }), 1),
			cell(
				"pill · abbreviated · tappable",
				C.CurrencyPill({ amount = 1234567, icon = "gem", onActivate = noop, order = 30 }),
				2
			),
			cell(
				"TabBar · L1/R1 or tap",
				C.TabBar({
					tabs = {
						{ label = "Shop", icon = "shop" },
						{ label = "Titles", icon = "trophy" },
						{ label = "Stats", icon = "star" },
					},
					selected = tab,
					onSelect = tab,
					order = 40,
					width = COLUMN - 2 * Theme.spacing.lg,
				}),
				3
			),
		}),
		section("Modal and Toast", 7, {
			cell(
				"Modal.card (inline)",
				C.Modal.card({
					title = "Leave the race?",
					body = "Your streak resets if you leave now.",
					actions = {
						{ label = "Stay", onActivate = noop },
						{ label = "Leave", variant = "danger", onActivate = noop },
					},
					dismissible = true,
					onDismiss = noop,
				}),
				1
			),
			cell("Toast · info", C.Toast.card({ text = "Ava used Freeze on you!", kind = "info" }), 2),
			cell("Toast · success", C.Toast.card({ text = "+250 coins", kind = "success" }), 3),
			cell("Toast · warning", C.Toast.card({ text = "10 seconds left", kind = "warning" }), 4),
			cell("Toast · danger", C.Toast.card({ text = "You were eliminated", kind = "danger" }), 5),
			cell(
				"open a real modal / toast",
				C.Button({
					label = "Open modal",
					variant = "secondary",
					order = 50,
					onActivate = function()
						local close: () -> () = noop
						close = C.Modal.open({
							title = "Real modal",
							body = "Scrim is full-bleed; B, the X or tapping outside dismisses.",
							actions = {
								{
									label = "Toast me",
									onActivate = function()
										C.Toast.show("Hello from the gallery", "success")
									end,
								},
								{
									label = "Close",
									variant = "secondary",
									onActivate = function()
										close()
									end,
								},
							},
							dismissible = true,
							onDismiss = function()
								close()
							end,
						})
					end,
				}),
				6
			),
		}),
	}

	-- As wide as the screen in reference px (usable width / scale), so the
	-- sections wrap to one column on a phone and several on a tablet.
	-- fromScale(1, 0) would be wrong here: the UIScale shrinks it too.
	local content = create("Frame")({
		Name = "Content",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0),
		Size = function()
			return UDim2.fromOffset(math.max(COLUMN, usableWidth() / C.Env.scale()), 0)
		end,
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			Wraps = true,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("UIPadding")({
			PaddingTop = UDim.new(0, Theme.spacing.md),
			PaddingBottom = UDim.new(0, Theme.spacing.md),
		}),
	}) :: Frame
	for _, s in sections do
		s.Size = UDim2.fromOffset(COLUMN, 0)
		s.Parent = content
	end
	return content
end

local ComponentGallery = {}

-- Takes the UIScaleController (passed in, like LayoutHarness, so this
-- debug module isn't required on a normal client). Returns unmount.
function ComponentGallery.mount(controller: any): () -> ()
	local gui = controller.createScreen("UIComponentGallery", { displayOrder = Theme.displayOrder.debug })
	local destroy = vide.root(function()
		-- The region (the scrolling viewport) is Scale; the content inside
		-- it is authored in reference px under the global UIScale.
		local scroller = create("ScrollingFrame")({
			Name = "Scroller",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.background,
			BorderSizePixel = 0,
			ScrollBarThickness = Theme.spacing.xs,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
			Parent = gui,
		}) :: ScrollingFrame
		local usableWidth = source(controller.getUsableRect().width)
		cleanup(controller.observeUsableRect(function(rect)
			usableWidth(rect.width)
		end))
		local content = gallery(usableWidth)
		content.Parent = scroller
		cleanup(controller.attachScale(content))
	end)
	return function()
		destroy()
		gui:Destroy()
	end
end

return ComponentGallery
