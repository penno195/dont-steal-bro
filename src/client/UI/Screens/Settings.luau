--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The settings screen (P6-6). Mounted by MenuController.
--
-- DATA: the player's saved settings, via SettingsController - live
-- (pushed by SettingsState on profile load and after every change) and
-- applied locally the moment a control moves. Nothing is requested.
--
-- Every control is a full-width row with one tap target:
--   - a toggle row: tap anywhere on it; On/Off is spelled out, not just
--     a colour or a knob position.
--   - a stepper row: - and + buttons either side of the value. Steppers,
--     not sliders: a slider needs a precise horizontal drag, which a
--     thumb in portrait does badly and a gamepad can't do at all. The
--     steps are SettingsLogic's, so what the server snaps to is exactly
--     what the buttons land on.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local SettingsLogic = require(ReplicatedStorage.Shared.SettingsLogic)
local C = require(script.Parent.Parent.Components)
local Base = require(script.Parent.Parent.Components.Base)
local MenuShell = require(script.Parent.MenuShell)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local derive = vide.derive
local switch = vide.switch

local ROW_H = 56
local STEP_BUTTON = 44
local HINT_H = 34

export type Store = {
	settings: () -> SettingsLogic.PlayerSettings,
	loaded: () -> boolean,
	change: (patch: { [string]: any }) -> (),
	reset: () -> (),
	close: () -> (),
}

local function hint(text: string, order: number): TextLabel
	return Base.text("caption", {
		Name = "Hint",
		LayoutOrder = order,
		Size = UDim2.new(1, 0, 0, HINT_H),
		Text = text,
		TextColor3 = Theme.color.inkMuted,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
end

local function toggleRow(label: string, value: () -> boolean, onToggle: () -> (), order: number): Instance
	return Base.interactive({
		name = label,
		size = Vector2.new(MenuShell.INNER, ROW_H),
		onActivate = onToggle,
		order = order,
		layoutOrder = order,
		radius = Theme.radius.md,
		visual = function(state)
			return {
				create("Frame")({
					Name = "Fill",
					Size = UDim2.fromScale(1, 1),
					BackgroundColor3 = function()
						return if state() == "pressed" then Theme.color.surfaceRaised else Theme.color.surface
					end,
					Base.corner(Theme.radius.md),
					create("UIPadding")({
						PaddingLeft = UDim.new(0, Theme.spacing.md),
						PaddingRight = UDim.new(0, Theme.spacing.md),
					}),
					Base.text("label", {
						Name = "Label",
						AnchorPoint = Vector2.new(0, 0.5),
						Position = UDim2.fromScale(0, 0.5),
						Size = UDim2.new(0.65, 0, 0, Theme.type.label.size + Theme.spacing.xs),
						Text = label,
						TextXAlignment = Enum.TextXAlignment.Left,
					}),
					create("Frame")({
						Name = "Pill",
						AnchorPoint = Vector2.new(1, 0.5),
						Position = UDim2.fromScale(1, 0.5),
						Size = UDim2.fromOffset(72, 32),
						BackgroundColor3 = function()
							return if value() then Theme.color.primary else Theme.color.line
						end,
						Base.corner(Theme.radius.pill),
						Base.text("label", {
							Name = "State",
							Size = UDim2.fromScale(1, 1),
							Text = function()
								return if value() then "On" else "Off"
							end,
							TextColor3 = function()
								return if value() then Theme.color.onPrimary else Theme.color.ink
							end,
						}),
					}),
				}),
			}
		end,
	})
end

local function stepperRow(
	label: string,
	value: () -> number,
	format: (number) -> string,
	lo: number,
	hi: number,
	step: number,
	onSet: (number) -> (),
	order: number
): Frame
	local function nudge(direction: number)
		onSet(math.clamp(value() + direction * step, lo, hi))
	end
	-- A float step can land a hair off the bound; treat within half a step
	-- as at it, so the button greys out when it should.
	local atLo = derive(function()
		return value() <= lo + step / 2
	end)
	local atHi = derive(function()
		return value() >= hi - step / 2
	end)
	local centreW = MenuShell.INNER - 2 * STEP_BUTTON - 2 * Theme.spacing.md

	return create("Frame")({
		Name = label,
		LayoutOrder = order,
		Size = UDim2.fromOffset(MenuShell.INNER, ROW_H + Theme.type.caption.size + Theme.spacing.xs),
		BackgroundTransparency = 1,
		Base.text("caption", {
			Name = "Label",
			Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xs),
			Text = label,
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		create("Frame")({
			Name = "Controls",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.fromOffset(MenuShell.INNER, ROW_H),
			BackgroundColor3 = Theme.color.surface,
			Base.corner(Theme.radius.md),
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
				Padding = UDim.new(0, Theme.spacing.md),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			C.Button({
				label = "-",
				variant = "secondary",
				width = STEP_BUTTON,
				disabled = atLo,
				onActivate = function()
					nudge(-1)
				end,
				order = order * 10,
				layoutOrder = 1,
			}),
			Base.text("title", {
				Name = "Value",
				LayoutOrder = 2,
				Size = UDim2.fromOffset(centreW, ROW_H),
				Text = function()
					return format(value())
				end,
			}),
			C.Button({
				label = "+",
				variant = "secondary",
				width = STEP_BUTTON,
				disabled = atHi,
				onActivate = function()
					nudge(1)
				end,
				order = order * 10 + 1,
				layoutOrder = 3,
			}),
		}),
	}) :: Frame
end

local function percent(v: number): string
	return string.format("%d%%", math.floor(v * 100 + 0.5))
end

local function body(store: Store, height: () -> number): { Instance }
	local s = store.settings
	local function flag(key: string): () -> boolean
		return function()
			return (s() :: any)[key] == true
		end
	end
	local function flip(key: string): () -> ()
		return function()
			store.change({ [key] = not (s() :: any)[key] })
		end
	end
	local function number(key: string): () -> number
		return function()
			return (s() :: any)[key] :: number
		end
	end
	local function set(key: string): (number) -> ()
		return function(v: number)
			store.change({ [key] = v })
		end
	end

	local function form(): Instance
		return create("ScrollingFrame")({
			Name = "Form",
			Size = function()
				return UDim2.fromOffset(MenuShell.INNER, height())
			end,
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 4,
			ScrollingDirection = Enum.ScrollingDirection.Y,
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
			CanvasSize = UDim2.new(),
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Vertical,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			stepperRow(
				"Music volume",
				number("musicVolume"),
				percent,
				0,
				1,
				SettingsLogic.VOLUME_STEP,
				set("musicVolume"),
				1
			),
			stepperRow(
				"Sound effects volume",
				number("sfxVolume"),
				percent,
				0,
				1,
				SettingsLogic.VOLUME_STEP,
				set("sfxVolume"),
				2
			),
			toggleRow("Voice chat mic", flag("voiceEnabled"), flip("voiceEnabled"), 3),
			hint("Your own mic in the Decision Studio. Hearing others is in Roblox's settings.", 4),
			toggleRow("Reduced motion", flag("reducedMotion"), flip("reducedMotion"), 5),
			hint("Removes flashing and screen movement. Roblox's own setting also turns this on.", 6),
			toggleRow("Colour-blind mode", flag("colorBlindMode"), flip("colorBlindMode"), 7),
			hint("Adds labels wherever colour shows a state.", 8),
			stepperRow(
				"Text and HUD size",
				number("hudScale"),
				percent,
				SettingsLogic.HUD_SCALE_MIN,
				SettingsLogic.HUD_SCALE_MAX,
				SettingsLogic.HUD_SCALE_STEP,
				set("hudScale"),
				9
			),
			hint("Roblox's own text size setting also makes this bigger.", 10),
			create("Frame")({
				Name = "ResetSlot",
				LayoutOrder = 11,
				Size = UDim2.fromOffset(MenuShell.INNER, Theme.touch.primaryHeight + Theme.spacing.lg),
				BackgroundTransparency = 1,
				C.Button({
					label = "Reset to defaults",
					variant = "ghost",
					width = MenuShell.INNER,
					onActivate = store.reset,
					order = 200,
					anchorPoint = Vector2.new(0.5, 1),
					position = UDim2.fromScale(0.5, 1),
				}),
			}),
		})
	end

	-- Until the saved values arrive the form would show defaults the
	-- player never chose, and editing them would be refused anyway
	-- (SettingsController.change ignores it), so it isn't shown.
	return {
		switch(store.loaded)({
			[true] = form :: any,
			[false] = function()
				return MenuShell.message("Loading your settings", nil, true) :: any
			end,
		}) :: any,
	}
end

local Settings = {}

function Settings.mount(controller: any, store: Store): () -> ()
	return MenuShell.mount(controller, {
		name = "SettingsScreen",
		title = "Settings",
		onClose = store.close,
		body = function(height)
			return body(store, height)
		end,
	})
end

return Settings
