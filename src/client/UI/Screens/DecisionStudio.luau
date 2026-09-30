--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The Decision Studio (P6-5). Mounted by DecisionStudioController for
-- the DecisionStudio round state, and by DecisionStudioPreview with a
-- scripted fake Store for device review. docs/decision-studio.md is the
-- design write-up; this header is only the map.
--
-- STAGES (DecisionLogic.stage): Intro -> Negotiate -> Choose -> Locked
-- -> Reveal, one screen whose parts show and hide rather than five
-- screens, so a phase change never rebuilds the seats mid-sentence.
--
-- WHAT GOES WHERE (decluttered 2026-09-26: the middle of the screen,
-- where the finalists stand and their chat bubbles show, stays clear):
--   top      the stage title, (i) How it works, and the countdown;
--            top-left sideways, top-centre in portrait. Pushed below
--            Roblox's chat window when it's open. At the reveal the
--            three seat cards join it and flip. Names and steal/share
--            records float over the finalists' heads instead
--            (FinalistTagController); the prizes are on the loading
--            card before the Studio opens (FinaleLoading).
--   corners  STEAL bottom-left, SHARE bottom-right. Same shape, HOLD
--            written inside.
--   bottom   the chat line between them (or above them when there's
--            no room), then the locked card and the result panel.
--
-- SECRECY: this file never sees another player's choice before the
-- reveal packet, because the Store has nowhere to put one - `locked` is
-- a set of ids, and `reveal` is nil until DecisionReveal parses. The
-- reveal's cards are built the moment it arrives, not preloaded per
-- outcome; both choice faces are drawn from the same two tokens for
-- everyone, so nothing outcome-specific exists early.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Clock = require(ReplicatedStorage.Shared.Clock)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local Feel = require(script.Parent.Parent.Components.Feel)
local DecisionLogic = require(script.Parent.Parent.DecisionLogic)
local Layout = require(script.Parent.Parent.Layout)
local PayoffExplainer = require(script.Parent.PayoffExplainer)
local Theme = require(script.Parent.Parent.Theme)

local create = vide.create
local source = vide.source
local derive = vide.derive
local effect = vide.effect
local cleanup = vide.cleanup
local indexes = vide.indexes
local switch = vide.switch

local Env = C.Env
local Icons = C.Icons

type Choice = DecisionLogic.Choice

-- A Vide source you can also write. Spelled out because the Packages
-- shim doesn't re-export vide.Source's type; this is the same shape.
export type Settable<T> = (() -> T) & ((value: T) -> T)

export type Seat = {
	id: number,
	name: string,
	isSelf: boolean,
	isNPC: boolean,
	-- Forfeited mid-Studio (P3-7). The seat stays and still resolves,
	-- but the card says only that they left - never "votes Share": a
	-- seat that locked before leaving keeps its real choice.
	left: boolean,
}
export type Talk = "speaking" | "typing"

-- What the screen reads. Sources are owned by the mounter, and list
-- entries should be frozen (see RaceHUD.Store for why).
export type Store = {
	selfId: number,
	isFinalist: () -> boolean,
	seats: () -> { Seat },
	phase: () -> DecisionLogic.Phase?,
	endsAt: () -> number?,
	phaseSeconds: { [string]: number }, -- the ring's full length per phase
	locked: () -> { [number]: boolean }, -- who has locked. Ids only - that's all the server sends
	talk: () -> { [number]: Talk },
	confirm: () -> DecisionLogic.Confirm,
	acked: () -> boolean, -- the server has echoed our own lock
	reveal: () -> DecisionLogic.Reveal?,
	personal: () -> DecisionLogic.Personal?,
	chat: () -> DecisionLogic.Rect?, -- Roblox's chat window, screen pixels
	keyboard: (() -> number?)?, -- on-screen keyboard's top edge, screen pixels; nil when closed
	-- The ready-up notice (DecisionLogic.waitingNotice); nil hides it.
	waiting: (() -> string?)?,
	press: (choice: Choice) -> (),
	release: (choice: Choice) -> (),
	dismiss: () -> (),
	-- The finalist's own chat line, sent into the Negotiate channel.
	send: (text: string) -> (),
	typing: () -> (), -- called as the finalist types, for the typing indicator
	-- A spectator's close-up camera on the podiums, and its toggle. Both
	-- nil hides the button (the preview has no camera to move).
	watching: (() -> boolean)?,
	toggleWatch: (() -> ())?,

	now: (() -> number)?, -- clock override for the preview; default Clock.now
}

local CLOCK_STEP = 0.05
local COLUMN = 344
local GAP = Theme.spacing.md
local SEAT_W = 108
local SEAT_H = 112
local AVATAR = 48
local RING = 56
local HEADER_H = 64
local NOTICE_H = 40
local NOTICE_SPINNER = 20
local HEAD_W = 76
local INFO_W = 44 -- the (i) beside the title
local SEAT_CHIP_H = 26 -- a seat's revealed choice, under the name
local STAGE_CARD = Vector2.new(260, 180) -- the big card in the middle at the reveal
local CHOICE_W = 150
local CHOICE_H = 132
local HOLD_CHIP_H = 30
local CHAT_W = 320 -- the chat line between the buttons, landscape
local EDGE = Theme.spacing.lg -- buttons' distance from the screen edges
local CHAT_MAX_FRACTION = 0.3
local KEYBOARD_MAX_FRACTION = 0.6 -- a phone keyboard is ~40-50% of portrait height
local SLIDE_OFF = 24 -- px a thumb may drift off a hold button before it counts as letting go

local STEAL_ACTION = "DecisionStudioSteal"
local SHARE_ACTION = "DecisionStudioShare"
-- Q/E sit under the left hand without touching WASD. X/Y are the left
-- and top face buttons, matching the on-screen left/right order loosely
-- enough to learn; A is jump and B is back, both too easy to hit.
local KEYS: { [Choice]: { Enum.KeyCode } } = {
	Steal = { Enum.KeyCode.Q, Enum.KeyCode.ButtonX },
	Share = { Enum.KeyCode.E, Enum.KeyCode.ButtonY },
}

local STAGE_TITLE: { [string]: string } = {
	Waiting = "THE DECISION STUDIO",
	Intro = "MEET THE FINALISTS",
	Negotiate = "NEGOTIATE",
	Choose = "CHOOSE",
	Locked = "LOCKED IN",
	Reveal = "THE REVEAL",
}
local STAGE_HINT: { [string]: string } = {
	Waiting = "",
	Intro = "Their record is over their heads.",
	Negotiate = "Talk or type. Promises cost nothing.",
	-- The server locks anyone still undecided at the deadline into the
	-- default (DecisionService), so say so - a silent default reads as
	-- the game choosing at random.
	Choose = string.format("Hold to lock in. No pick = %s.", GameConfig.decisionStudioDefaultChoice),
	Locked = "",
	Reveal = "",
}

-- Seat status lines. Frozen and shared, so Vide sees the same table
-- come back and skips the redraw. Every one pairs a glyph with a word.
local STATUS_NONE = table.freeze({ text = "", color = "inkMuted" })
local STATUS: { [string]: { text: string, color: string } } = {
	locked = table.freeze({ text = "🔒 Locked", color = "success" }),
	speaking = table.freeze({ text = "🎙 Speaking", color = "ink" }),
	typing = table.freeze({ text = "💬 Typing…", color = "ink" }),
	deciding = table.freeze({ text = "Deciding…", color = "inkMuted" }),
	left = table.freeze({ text = "✕ Left the Studio", color = "inkMuted" }),
}

local function decisionStyle(choice: Choice)
	return if choice == "Steal" then Theme.decision.steal else Theme.decision.share
end

local function stack(name: string, width: number, gap: number, children: { any }): Frame
	local props: { [any]: any } = {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(width, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, gap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

local function hrow(name: string, order: number, height: number, gap: number, children: { any }): Frame
	local props: { [any]: any } = {
		Name = name,
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(COLUMN, height),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, gap),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for _, child in children do
		table.insert(props, child)
	end
	return create("Frame")(props) :: Frame
end

-- A Steal or Share face: colour, silhouette, icon and word together, so
-- no single cue carries the meaning (Tokens.decision). Steal's badge is
-- a diamond (a square turned 45 degrees, sharp corners); Share's is a
-- pill.
local function face(choice: Choice, size: Vector2, textStyle: string): Frame
	local style = decisionStyle(choice)
	local badge = math.min(size.X, size.Y) * 0.42
	local diamond = style.shape == "Diamond"
	return create("Frame")({
		Name = "Face" .. choice,
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = Theme.color[style.color],
		-- A pill reads as a chip when small; the big reveal card would be an
		-- oval, so large faces get a rounded rectangle.
		Base.corner(if diamond then Theme.radius.sm elseif size.Y >= 100 then Theme.radius.lg else Theme.radius.pill),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.xxs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		create("Frame")({
			Name = "Badge",
			LayoutOrder = 1,
			Size = UDim2.fromOffset(badge, badge),
			BackgroundTransparency = 1,
			create("Frame")({
				Name = "Shape",
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromScale(if diamond then 0.72 else 1.1, if diamond then 0.72 else 0.72),
				Rotation = if diamond then 45 else 0,
				BackgroundColor3 = Theme.color[style.on],
				BackgroundTransparency = 0.8,
				Base.corner(if diamond then Theme.radius.none else Theme.radius.pill),
			}),
			(function()
				local icon = Icons.view(style.icon, badge * 0.7, Theme.color[style.on])
				icon.AnchorPoint = Vector2.new(0.5, 0.5)
				icon.Position = UDim2.fromScale(0.5, 0.5)
				return icon
			end)(),
		}),
		Base.text(textStyle, {
			Name = "Label",
			LayoutOrder = 2,
			Size = UDim2.new(1, -Theme.spacing.sm, 0, Theme.type[textStyle].size + Theme.spacing.xxs),
			Text = style.label,
			TextColor3 = Theme.color[style.on],
		}),
	}) :: Frame
end

-- SEATS ----------------------------------------------------------------

local function headshot(id: number): string
	-- NPC ids are negative and have no Roblox headshot; the rig is in the
	-- room in plain sight, so a plain disc is no secret.
	return if id > 0 then string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", id) else ""
end

local function seatCard(
	seat: () -> Seat,
	index: number,
	store: Store,
	stage: () -> DecisionLogic.Stage,
	step: () -> DecisionLogic.RevealStep?,
	order: () -> { number }
): Frame
	-- Turned once its card has turned in the middle of the screen, in
	-- this screen's own order (DecisionLogic.revealOrder).
	local revealed = derive(function()
		local s = step()
		local position = table.find(order(), seat().id) or index
		return s ~= nil and s.cardsShown >= position
	end)
	local choice = derive(function(): Choice?
		local r = store.reveal()
		return if r ~= nil and revealed() then r.choices[seat().id] else nil
	end)
	local verdict = derive(function(): string?
		local r, s = store.reveal(), step()
		if r == nil or s == nil or not s.outcomeShown then
			return nil
		end
		return if table.find(r.winnerIds, seat().id) ~= nil then "WINS" else "LOSES"
	end)
	-- The status line under the name. Locked is shown the same way for
	-- everyone - the icon and the word, never which way.
	local status = derive(function(): { text: string, color: string }
		local id = seat().id
		if stage() == "Reveal" then
			return STATUS_NONE
		elseif seat().left then
			return STATUS.left
		elseif store.locked()[id] then
			return STATUS.locked
		end
		local talk = store.talk()[id]
		if talk ~= nil then
			return STATUS[talk]
		elseif stage() == "Choose" or stage() == "Locked" then
			return STATUS.deciding
		end
		return STATUS_NONE
	end)

	-- The seat's choice, once its card has turned in the middle: a chip
	-- under the name (it used to cover the name). The drama happens in
	-- the middle; this row is the tally.
	local chip = Base.text("label", {
		Name = "Choice",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -Theme.spacing.sm),
		Size = UDim2.fromOffset(SEAT_W - 2 * Theme.spacing.sm, SEAT_CHIP_H),
		BackgroundTransparency = 0,
		BackgroundColor3 = function()
			local c = choice()
			return if c then Theme.color[decisionStyle(c :: Choice).color] else Theme.color.surfaceRaised
		end,
		TextColor3 = function()
			local c = choice()
			return if c then Theme.color[decisionStyle(c :: Choice).on] else Theme.color.ink
		end,
		Text = function()
			local c = choice()
			return if c then decisionStyle(c :: Choice).label else ""
		end,
		Visible = function()
			return choice() ~= nil
		end,
		ZIndex = 3,
		Base.corner(Theme.radius.pill),
	})

	return create("Frame")({
		Name = "Seat",
		LayoutOrder = index,
		Size = UDim2.fromOffset(SEAT_W, SEAT_H),
		BackgroundColor3 = Theme.elevation[2].surface,
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			Thickness = function()
				return if seat().isSelf or verdict() ~= nil then 2 else 1
			end,
			Color = function()
				local v = verdict()
				if v == "WINS" then
					return Theme.color.success
				elseif v == "LOSES" then
					return Theme.color.line
				end
				return if seat().isSelf then Theme.color.brand else Theme.color.line
			end,
		}),
		create("ImageLabel")({
			Name = "Avatar",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, Theme.spacing.sm),
			Size = UDim2.fromOffset(AVATAR, AVATAR),
			BackgroundColor3 = Theme.color.surfaceRaised,
			Image = function()
				return headshot(seat().id)
			end,
			Base.corner(Theme.radius.pill),
		}),
		Base.text("label", {
			Name = "Name",
			Position = UDim2.fromOffset(Theme.spacing.xs, AVATAR + Theme.spacing.sm + Theme.spacing.xxs),
			Size = UDim2.new(1, -2 * Theme.spacing.xs, 0, Theme.type.label.size),
			Text = function()
				return if seat().isSelf then "You" else seat().name
			end,
			TextTruncate = Enum.TextTruncate.AtEnd,
			TextWrapped = false,
		}),
		Base.text("caption", {
			Name = "Status",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, Theme.spacing.xs, 1, -Theme.spacing.sm),
			Size = UDim2.new(1, -2 * Theme.spacing.xs, 0, Theme.type.caption.size + Theme.spacing.xs),
			Text = function()
				return status().text
			end,
			TextColor3 = function()
				return Theme.color[status().color]
			end,
		}),
		chip,
		-- WINS / LOSES in words as well as the stroke colour.
		Base.text("label", {
			Name = "Verdict",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0),
			Size = UDim2.fromOffset(SEAT_W - Theme.spacing.lg, Theme.type.label.size + Theme.spacing.xs),
			BackgroundColor3 = function()
				return if verdict() == "WINS" then Theme.color.success else Theme.color.surfaceRaised
			end,
			BackgroundTransparency = 0,
			TextColor3 = function()
				return if verdict() == "WINS" then Theme.color.inkOnLight else Theme.color.inkMuted
			end,
			Text = function()
				return verdict() or ""
			end,
			Visible = function()
				return verdict() ~= nil
			end,
			ZIndex = 4,
			Base.corner(Theme.radius.pill),
		}),
	}) :: Frame
end

-- PAYOFF TABLE -----------------------------------------------------------

-- THE REVEAL, CENTRE STAGE -------------------------------------------------

-- One card at a time in the middle of the screen, in this screen's own
-- order (DecisionLogic.revealOrder): it comes up face down under the
-- finalist's name, holds for TIMING.suspense, then turns. After the
-- last card the outcome line takes its place until the result panel.
-- Both faces are built up front, as everywhere else here, so nothing
-- outcome-specific is created at the dramatic moment.
local function revealStage(
	store: Store,
	step: () -> DecisionLogic.RevealStep?,
	order: () -> { number },
	banner: () -> string?
): Frame
	local currentId = derive(function(): number?
		local s = step()
		if s == nil or s.current == 0 then
			return nil
		end
		return order()[s.current]
	end)
	local choice = derive(function(): Choice?
		local r, s, id = store.reveal(), step(), currentId()
		if r == nil or s == nil or id == nil or not s.faceUp then
			return nil
		end
		return r.choices[id]
	end)
	local name = derive(function(): string
		local id = currentId()
		if id == nil then
			return ""
		elseif id == store.selfId then
			return "You"
		end
		for _, seat in store.seats() do
			if seat.id == id then
				return seat.name
			end
		end
		return "Finalist"
	end)
	local showCard = derive(function()
		local s = step()
		return s ~= nil and s.current > 0 and not s.outcomeShown
	end)
	local showBanner = derive(function()
		local s = step()
		return s ~= nil and s.outcomeShown and not s.resultShown
	end)

	local holder = create("Frame")({
		Name = "Flip",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(STAGE_CARD.X, STAGE_CARD.Y),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
	}) :: Frame
	local back = create("Frame")({
		Name = "Back",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Theme.color.surfaceRaised,
		Base.corner(Theme.radius.lg),
		create("UIStroke")({ ApplyStrokeMode = Enum.ApplyStrokeMode.Border, Color = Theme.color.line, Thickness = 2 }),
		Base.text("display", {
			Name = "Mystery",
			Size = UDim2.fromScale(1, 1),
			Text = "?",
			TextColor3 = Theme.color.inkMuted,
		}),
		Parent = holder,
	}) :: Frame
	local faces: { [Choice]: Frame } = {
		Steal = face("Steal", STAGE_CARD, "headline"),
		Share = face("Share", STAGE_CARD, "headline"),
	}
	for _, f in faces do
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Visible = false
		f.Parent = holder
	end

	local full = UDim2.fromOffset(STAGE_CARD.X, STAGE_CARD.Y)
	local function tweenFrom(size: UDim2, style: Enum.EasingStyle)
		if Env.reducedMotion() then
			holder.Size = full
			return
		end
		holder.Size = size
		TweenService:Create(holder, TweenInfo.new(Theme.motion.slow * 1.5, style, Enum.EasingDirection.Out), {
			Size = full,
		}):Play()
	end
	-- A new card rises into place face down...
	effect(function()
		if currentId() ~= nil then
			tweenFrom(UDim2.fromOffset(STAGE_CARD.X * 0.6, STAGE_CARD.Y * 0.6), Enum.EasingStyle.Quad)
		end
	end)
	-- ...then turns: the face grows out of a vertical line. Reduced
	-- motion cuts straight to it - same moment, no movement.
	effect(function()
		local c = choice()
		back.Visible = c == nil
		for key, f in faces do
			f.Visible = key == c
		end
		if c ~= nil then
			tweenFrom(UDim2.fromOffset(0, STAGE_CARD.Y), Enum.EasingStyle.Back)
		end
	end)

	return create("Frame")({
		Name = "RevealStage",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(COLUMN, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Base.text("headline", {
			Name = "Who",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.headline.size + Theme.spacing.xs),
			Text = function()
				local s = step()
				local waiting = s ~= nil and not s.faceUp
				return if waiting then name() .. " chose…" else name()
			end,
			Visible = showCard,
		}),
		create("Frame")({
			Name = "Card",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = full,
			Visible = showCard,
			holder,
		}),
		Base.text("display", {
			Name = "Outcome",
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, Theme.type.display.size * 2 + Theme.spacing.sm),
			Text = function()
				return banner() or ""
			end,
			TextWrapped = true,
			Visible = showBanner,
		}),
	}) :: Frame
end

-- Gone from the Studio (2026-09-26): the prizes are on the loading card
-- (FinaleLoading), and "How it works" is the (i) beside the title.

-- HOLD TO CONFIRM ----------------------------------------------------

-- "HOLD", plus the key on a keyboard or pad. Inside the button, on a
-- chip in the button's own ink, so nobody taps it and wonders why
-- nothing happened.
local function holdHint(choice: Choice): string
	local mode = Env.inputMode()
	if mode == Enum.PreferredInput.Gamepad then
		return if choice == "Steal" then "HOLD X" else "HOLD Y"
	elseif mode == Enum.PreferredInput.KeyboardAndMouse then
		return if choice == "Steal" then "HOLD Q" else "HOLD E"
	end
	return "HOLD"
end

-- The hold button's face: both choices the same shape and size, told
-- apart by colour, icon, word and side of the screen.
local function holdFace(choice: Choice): Frame
	local style = decisionStyle(choice)
	local fill, ink = Theme.color[style.color], Theme.color[style.on]
	local icon = Icons.view(style.icon, 36, ink)
	icon.LayoutOrder = 1
	return create("Frame")({
		Name = "Face" .. choice,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = fill,
		Base.corner(Theme.radius.lg),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		icon :: any,
		Base.text("title", {
			Name = "Label",
			LayoutOrder = 2,
			Size = UDim2.new(1, -Theme.spacing.sm, 0, Theme.type.title.size + Theme.spacing.xxs),
			Text = style.label,
			TextColor3 = ink,
		}),
		create("Frame")({
			Name = "HoldChip",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(CHOICE_W - 2 * Theme.spacing.lg, HOLD_CHIP_H),
			BackgroundColor3 = ink,
			BackgroundTransparency = 0.1,
			Base.corner(Theme.radius.pill),
			Base.text("label", {
				Name = "Hold",
				Size = UDim2.fromScale(1, 1),
				Text = function()
					return holdHint(choice)
				end,
				TextColor3 = fill,
			}),
		}),
	}) :: Frame
end

local function holdButton(choice: Choice, store: Store, enabled: () -> boolean, order: number): Frame
	local readNow = store.now or Clock.now
	local fraction = source(0)
	local mine = derive(function()
		local c = store.confirm()
		return c.state == "Holding" and c.choice == choice
	end)
	local hb = RunService.Heartbeat:Connect(function()
		fraction(
			if mine()
				then DecisionLogic.holdFraction(store.confirm(), readNow(), DecisionLogic.TIMING.holdSeconds)
				else 0
		)
	end)
	cleanup(function()
		hb:Disconnect()
	end)

	local faceFrame = holdFace(choice)
	faceFrame.ZIndex = 1
	local button = create("TextButton")({
		Name = "Hold" .. choice,
		LayoutOrder = order,
		Size = UDim2.fromOffset(CHOICE_W, CHOICE_H),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Selectable = false, -- held with Q/E or X/Y, not by focus + A
		Active = enabled,
		faceFrame,
		-- The fill rises from the bottom while held: progress you can see
		-- without reading, and a second cue that this is a hold, not a tap.
		create("Frame")({
			Name = "Fill",
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = function()
				return UDim2.fromScale(1, fraction())
			end,
			BackgroundColor3 = Theme.color.focus,
			BackgroundTransparency = 0.6,
			ZIndex = 2,
			Base.corner(Theme.radius.lg),
		}),
		-- Dimmed until Choose opens: visible early so the thumb knows
		-- where it's going, inert until it's allowed to go there.
		create("Frame")({
			Name = "Dim",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.background,
			BackgroundTransparency = 0.45,
			Visible = function()
				return not enabled()
			end,
			ZIndex = 3,
			Base.corner(Theme.radius.lg),
		}),
	}) :: TextButton

	-- A press has to land on the button; the release is caught anywhere,
	-- and a thumb that slides clearly off counts as letting go. Letting
	-- go early cancels - a lock needs one unbroken, deliberate hold.
	local owner: any? = nil
	local c1 = button.InputBegan:Connect(function(input: InputObject)
		local kind = input.UserInputType
		if (kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1) and enabled() then
			if owner == nil then
				owner = if kind == Enum.UserInputType.Touch then input else "mouse"
				store.press(choice)
			end
		end
	end)
	local function letGo()
		if owner ~= nil then
			owner = nil
			store.release(choice)
		end
	end
	local function isOwner(input: InputObject): boolean
		return owner == input or (owner == "mouse" and input.UserInputType == Enum.UserInputType.MouseButton1)
	end
	local c2 = UserInputService.InputEnded:Connect(function(input: InputObject)
		if isOwner(input) then
			letGo()
		end
	end)
	local c3 = UserInputService.InputChanged:Connect(function(input: InputObject)
		if owner ~= input then
			return
		end
		local p, pos, size = input.Position, button.AbsolutePosition, button.AbsoluteSize
		if
			p.X < pos.X - SLIDE_OFF
			or p.Y < pos.Y - SLIDE_OFF
			or p.X > pos.X + size.X + SLIDE_OFF
			or p.Y > pos.Y + size.Y + SLIDE_OFF
		then
			letGo()
		end
	end)
	local c4 = UserInputService.WindowFocusReleased:Connect(letGo)
	cleanup(function()
		c1:Disconnect()
		c2:Disconnect()
		c3:Disconnect()
		c4:Disconnect()
	end)

	return button :: any
end

-- The lock, made obviously final: the two buttons are gone, replaced by
-- your choice under a lock with the word FINAL. "Locking…" until the
-- server's DecisionLockedIn echo for you arrives.
local function lockedCard(store: Store, order: number): Frame
	local chosen = derive(function(): Choice
		return store.confirm().choice or "Share"
	end)
	local faceSize = Vector2.new(HEAD_W + 20, 72)
	local faces = {
		Steal = face("Steal", faceSize, "label"),
		Share = face("Share", faceSize, "label"),
	}
	for key: Choice, f in { Steal = faces.Steal, Share = faces.Share } :: { [Choice]: Frame } do
		f.LayoutOrder = 1
		f.Visible = false
		effect(function()
			f.Visible = chosen() == key
		end)
	end
	return create("Frame")({
		Name = "Locked",
		LayoutOrder = order,
		Size = UDim2.fromOffset(COLUMN, 88),
		BackgroundColor3 = Theme.elevation[3].surface,
		Base.corner(Theme.radius.md),
		create("UIStroke")({ Color = Theme.color.success, Thickness = 2 }),
		Base.padding(Theme.spacing.sm),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Horizontal,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.md),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		faces.Steal,
		faces.Share,
		create("Frame")({
			Name = "Words",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, -(HEAD_W + 20 + Theme.spacing.md), 1, 0),
			Base.text("title", {
				Name = "Final",
				Size = UDim2.fromScale(1, 0.55),
				Text = function()
					return if store.acked() then "🔒 LOCKED · FINAL" else "Locking…"
				end,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
			Base.text("caption", {
				Name = "Waiting",
				Position = UDim2.fromScale(0, 0.55),
				Size = UDim2.fromScale(1, 0.45),
				Text = function()
					local waiting = 0
					for _, seat in store.seats() do
						if not store.locked()[seat.id] then
							waiting += 1
						end
					end
					return if waiting == 0
						then "Everyone's in. Revealing…"
						else string.format("Waiting for %d more. You can't change it.", waiting)
				end,
				TextColor3 = Theme.color.inkMuted,
				TextXAlignment = Enum.TextXAlignment.Left,
			}),
		}),
	}) :: Frame
end

-- RESULT -----------------------------------------------------------------

local TONE_COLOR: { [DecisionLogic.Tone]: string } = { win = "success", loss = "danger", neutral = "line" }

local function resultPanel(copy: () -> DecisionLogic.ResultCopy?, store: Store, order: number): Frame
	return create("Frame")({
		Name = "Result",
		LayoutOrder = order,
		Size = UDim2.fromOffset(COLUMN, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.elevation[3].surface,
		Base.corner(Theme.radius.md),
		create("UIStroke")({
			Thickness = 2,
			Color = function()
				local c = copy()
				return Theme.color[if c then TONE_COLOR[c.tone] else "line"]
			end,
		}),
		Base.padding(Theme.spacing.lg),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			Padding = UDim.new(0, Theme.spacing.sm),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Base.text("headline", {
			Name = "Headline",
			LayoutOrder = 1,
			Size = UDim2.new(1, 0, 0, Theme.type.headline.size + Theme.spacing.xs),
			Text = function()
				local c = copy()
				return if c then c.headline else ""
			end,
		}),
		Base.text("title", {
			Name = "Bounty",
			LayoutOrder = 2,
			Size = UDim2.new(1, 0, 0, Theme.type.title.size + Theme.spacing.xxs),
			Text = function()
				local c = copy()
				return if c then c.detail else ""
			end,
			TextColor3 = function()
				local c = copy()
				return if c and c.tone == "win" then Theme.color.success else Theme.color.ink
			end,
		}),
		-- The streak line: for a loser, the number that just died. Same
		-- size and weight as the bounty line - not hidden in a caption,
		-- not blown up into a headline.
		Base.text("title", {
			Name = "Streak",
			LayoutOrder = 3,
			Size = UDim2.new(1, 0, 0, Theme.type.title.size + Theme.spacing.xxs),
			Text = function()
				local c = copy()
				return if c and c.streak then c.streak else ""
			end,
			Visible = function()
				local c = copy()
				return c ~= nil and c.streak ~= nil
			end,
			TextColor3 = Theme.color.inkMuted,
		}),
		C.Button({ label = "Continue", onActivate = store.dismiss, variant = "primary", layoutOrder = 4, order = 1 }),
	}) :: Frame
end

-- MOUNT ------------------------------------------------------------------

local DecisionStudio = {}

-- Owns the hold-to-confirm state for a mounter: the controller and the
-- preview both use it, so they tick the same machine. `send` is called
-- exactly once, on the tick the hold completes. Returns the source,
-- press/release for the Store, and a stop function.
-- The finalist's chat line during Negotiate. Roblox's own chat bar is
-- easy to miss (closed by default, behind a top-bar icon) and on a phone
-- often isn't open at all, so the Studio carries its own: a text field
-- and a Send button, at the bottom between the hold buttons, lifted with the rest of this stack when the on-screen keyboard opens.
-- Enter sends too. What's sent goes through the Negotiate channel
-- exactly as the chat bar's would, so bubbles, filtering and the
-- spectators' read-only view all apply unchanged.
local CHAT_H = 56 -- a primary Button's own height, so the row fits it
local SEND_W = 88
local QUICK_GAP = Theme.spacing.xs
local WATCH_W = 150
-- TextChatService's own per-message limit.
local MAX_MESSAGE = 200

local function chatBox(store: Store, order: number): Frame
	local input = create("TextBox")({
		Name = "Input",
		ClearTextOnFocus = false,
		PlaceholderText = "Type to the others…",
		PlaceholderColor3 = Theme.color.inkMuted,
		Text = "",
		TextColor3 = Theme.color.ink,
		FontFace = Theme.type.body.font,
		TextSize = Theme.type.body.size,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		BackgroundColor3 = Theme.color.surfaceRaised,
		LayoutOrder = 1,
		Size = UDim2.fromOffset(CHAT_W - SEND_W - Theme.spacing.sm, CHAT_H),
		Base.corner(Theme.radius.md),
		Base.padding(Theme.spacing.sm),
	}) :: TextBox

	local function submit()
		local text = string.sub(input.Text, 1, MAX_MESSAGE)
		input.Text = ""
		if string.find(text, "%S") ~= nil then
			store.send(text)
		end
	end

	local focusLost = input.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			submit()
		end
	end)
	local changed = input:GetPropertyChangedSignal("Text"):Connect(function()
		if input.Text ~= "" then
			store.typing()
		end
	end)
	cleanup(function()
		focusLost:Disconnect()
		changed:Disconnect()
	end)

	local row = hrow("Line", 1, CHAT_H, Theme.spacing.sm, {
		input,
		C.Button({ label = "Send", variant = "primary", width = SEND_W, layoutOrder = 2, onActivate = submit }),
	})
	row.Size = UDim2.fromOffset(CHAT_W, CHAT_H)

	-- One tap sends a stock line (DecisionLogic.QUICK_PHRASES) through
	-- the same store.send as the box, so it's just chat.
	local phrases = DecisionLogic.QUICK_PHRASES
	local quickW = (CHAT_W - (#phrases - 1) * QUICK_GAP) / #phrases
	local quick: { any } = {}
	for index, phrase in phrases do
		table.insert(
			quick,
			C.Button({
				label = phrase,
				variant = "secondary",
				width = quickW,
				layoutOrder = index,
				onActivate = function()
					store.send(phrase)
				end,
			})
		)
	end
	local quickRow = hrow("QuickChat", 2, Theme.touch.primaryHeight, QUICK_GAP, quick)
	quickRow.Size = UDim2.fromOffset(CHAT_W, Theme.touch.primaryHeight)

	local block = stack("Chat", CHAT_W, Theme.spacing.xs, { row, quickRow })
	block.LayoutOrder = order
	return block
end

function DecisionStudio.confirmer(
	send: (choice: Choice) -> (),
	allowed: () -> boolean,
	now: (() -> number)?
): (Settable<DecisionLogic.Confirm>, (Choice) -> (), (Choice) -> (), () -> ())
	local readNow = now or Clock.now
	local state: Settable<DecisionLogic.Confirm> = source(DecisionLogic.OPEN)
	local hb = RunService.Heartbeat:Connect(function()
		local c = state()
		if c.state ~= "Holding" then
			return
		end
		if not allowed() then
			state(DecisionLogic.OPEN) -- Choose closed under the thumb
			return
		end
		local nextState, lockedNow = DecisionLogic.tick(c, readNow(), DecisionLogic.TIMING.holdSeconds)
		if lockedNow then
			state(nextState)
			send(nextState.choice :: Choice)
		end
	end)
	local function press(choice: Choice)
		if allowed() then
			state(DecisionLogic.press(state(), choice, readNow()))
		end
	end
	local function release(choice: Choice)
		state(DecisionLogic.release(state(), choice))
	end
	return state, press, release, function()
		hb:Disconnect()
	end
end

-- `controller` is UIScaleController. Returns unmount.
function DecisionStudio.mount(controller: any, store: Store): () -> ()
	local gui = controller.createScreen("DecisionStudio", { displayOrder = Theme.displayOrder.panel }) :: ScreenGui

	local destroy = vide.root(function()
		local readNow = store.now or Clock.now
		local now = source(readNow())
		local hb = RunService.Heartbeat:Connect(function()
			now(math.floor(readNow() / CLOCK_STEP) * CLOCK_STEP)
		end)
		cleanup(function()
			hb:Disconnect()
		end)

		local orientation =
			source(Layout.orientationOf(controller.getUsableRect().width, controller.getUsableRect().height))
		cleanup(controller.observeUsableRect(function(rect: Layout.Rect)
			orientation(Layout.orientationOf(rect.width, rect.height))
		end))
		local portrait = derive(function()
			return orientation() == "Portrait"
		end)

		-- Cast: derive widens a string-literal union back to `string`
		-- (the same luau-lsp gap DecisionService's own comment documents).
		local stage = derive(function(): DecisionLogic.Stage
			return DecisionLogic.stage(
				store.phase(),
				store.reveal(),
				store.confirm().state == "Locked",
				store.isFinalist()
			)
		end) :: () -> DecisionLogic.Stage
		local seatCount = derive(function()
			return math.max(1, #store.seats())
		end)
		local step = derive(function(): DecisionLogic.RevealStep?
			local r = store.reveal()
			if r == nil then
				return nil
			end
			return DecisionLogic.revealStep(now() - r.revealAt, seatCount())
		end)
		-- The order the cards turn on THIS screen (your own first).
		local order = derive(function(): { number }
			local ids: { number } = {}
			for _, seat in store.seats() do
				table.insert(ids, seat.id)
			end
			local r = store.reveal()
			return if r then DecisionLogic.revealOrder(ids, r.choices, store.selfId) else ids
		end)
		local outcomeShown = derive(function()
			local s = step()
			return s ~= nil and s.outcomeShown
		end)
		local resultShown = derive(function()
			local s = step()
			return s ~= nil and s.resultShown
		end)
		local banner = derive(function(): string?
			local r = store.reveal()
			if r == nil or not outcomeShown() then
				return nil
			end
			-- 0 is nobody's id (users are positive, NPCs negative), so
			-- this is the room-wide line, the same on every screen.
			return DecisionLogic.resultCopy(r, 0, nil).headline
		end)
		local copy = derive(function(): DecisionLogic.ResultCopy?
			local r = store.reveal()
			return if r then DecisionLogic.resultCopy(r, store.selfId, store.personal()) else nil
		end)
		local secondsLeft = derive(function()
			local endsAt = store.endsAt()
			return if endsAt then math.max(0, endsAt - now()) else 0
		end)
		local chooseOpen = derive(function()
			return stage() == "Choose"
		end)

		-- Header: title, hint, (i), countdown. Titles carries the outcome
		-- banner, so it's what the reveal punches (FeelController, P8-3).
		local header = hrow("Header", 1, HEADER_H, GAP, {
			create("Frame")({
				Name = "Titles",
				Feel.scale("Reveal"),
				LayoutOrder = 1,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(COLUMN - RING - INFO_W - 2 * GAP, HEADER_H),
				Base.text("title", {
					Name = "Title",
					Size = UDim2.fromScale(1, 0.55),
					Text = function()
						return STAGE_TITLE[stage()] -- the outcome line is big in the middle now
					end,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
				Base.text("caption", {
					Name = "Hint",
					Position = UDim2.fromScale(0, 0.55),
					Size = UDim2.fromScale(1, 0.45),
					Text = function()
						if stage() == "Locked" and not store.isFinalist() then
							return "You're watching this one."
						end
						return STAGE_HINT[stage()]
					end,
					TextColor3 = Theme.color.inkMuted,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
			}),
			-- "How it works" (P6-8), now that the payoff table is gone.
			create("Frame")({
				Name = "Info",
				LayoutOrder = 2,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(INFO_W, HEADER_H),
				C.IconButton({
					icon = "info",
					label = "How it works",
					onActivate = function()
						PayoffExplainer.open(seatCount())
					end,
					order = 900,
					anchorPoint = Vector2.new(0.5, 0.5),
					position = UDim2.fromScale(0.5, 0.5),
				}) :: any,
			}),
			(function()
				-- CountdownRing takes a fixed total, so it's rebuilt per
				-- phase by switch (which scopes each one); the reveal has
				-- no countdown - its clock is revealAt.
				local ringPhase = derive(function(): string?
					if store.endsAt() == nil or stage() == "Reveal" then
						return nil
					end
					return store.phase()
				end)
				local map: { [string]: () -> Instance } = {}
				for phase, total in store.phaseSeconds do
					map[phase] = function()
						return C.CountdownRing({ secondsLeft = secondsLeft, total = total, size = RING })
					end
				end
				return create("Frame")({
					Name = "Ring",
					LayoutOrder = 3,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(RING, RING),
					switch(ringPhase)(map),
				})
			end)(),
		})

		-- The seats only come up for the reveal, to flip each finalist's
		-- card. Until then the names and records are over their heads in
		-- the world (FinalistTagController), and the seats were clutter.
		local seatsRow = hrow("Seats", 2, SEAT_H + Theme.spacing.md, Theme.spacing.sm, {
			indexes(store.seats, function(seat: () -> Seat, index: number)
				return seatCard(seat, index, store, stage, step, order)
			end) :: any,
		})
		effect(function()
			seatsRow.Visible = stage() == "Reveal"
		end)

		-- "Waiting for 2 more…" after you close the loading card, so the
		-- quiet room doesn't read as stalled.
		local waitingText = derive(function(): string?
			return if store.waiting then store.waiting() else nil
		end)
		local notice = create("Frame")({
			Name = "Waiting",
			LayoutOrder = 3,
			Size = UDim2.fromOffset(COLUMN, NOTICE_H),
			BackgroundColor3 = Theme.color.surfaceRaised,
			Visible = function()
				return waitingText() ~= nil
			end,
			Base.corner(Theme.radius.pill),
			Base.padding(Theme.spacing.sm),
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				VerticalAlignment = Enum.VerticalAlignment.Center,
			}),
			create("Frame")({
				Name = "SpinnerBox",
				LayoutOrder = 1,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(NOTICE_SPINNER, NOTICE_SPINNER),
				Base.spinner(NOTICE_SPINNER, function()
					return Theme.color.inkMuted
				end) :: any,
			}),
			Base.text("label", {
				Name = "Text",
				LayoutOrder = 2,
				Size = UDim2.fromOffset(0, NOTICE_SPINNER),
				AutomaticSize = Enum.AutomaticSize.X,
				Text = function()
					return waitingText() or ""
				end,
			}),
		})

		local info = stack("Info", COLUMN, GAP, { header, seatsRow, notice })
		info.Parent = gui
		cleanup(controller.attachScale(info))

		-- The reveal itself, big in the middle of the screen.
		local centre = revealStage(store, step, order, banner)
		centre.AnchorPoint = Vector2.new(0.5, 0.5)
		centre.Position = UDim2.fromScale(0.5, 0.45)
		centre.Parent = gui
		cleanup(controller.attachScale(centre))
		effect(function()
			centre.Visible = stage() == "Reveal"
		end)

		-- The two hold buttons, Steal in the bottom-left corner and Share
		-- in the bottom-right: one per thumb on a phone held sideways,
		-- and the middle of the screen - where the finalists stand and
		-- their chat bubbles show - stays clear.
		local stealButton = holdButton("Steal", store, chooseOpen, 1)
		local shareButton = holdButton("Share", store, chooseOpen, 2)
		local buttonsUp = derive(function()
			local s = stage()
			return store.isFinalist() and (s == "Intro" or s == "Negotiate" or s == "Choose")
		end)
		for _, b in { stealButton, shareButton } do
			b.Parent = gui
			cleanup(controller.attachScale(b))
			effect(function()
				b.Visible = buttonsUp()
			end)
		end

		local locked = lockedCard(store, 3)
		Feel.attach(locked, "Locked") -- punches on your lock-in (P8-3)
		effect(function()
			locked.Visible = store.isFinalist() and store.confirm().state == "Locked" and stage() ~= "Reveal"
		end)
		local result = resultPanel(copy, store, 4)
		effect(function()
			result.Visible = resultShown()
		end)

		local chatRow = chatBox(store, 0)
		effect(function()
			chatRow.Visible = store.isFinalist() and stage() == "Negotiate"
		end)

		local decide = stack("Decide", COLUMN, GAP, { chatRow, locked, result })
		decide.Parent = gui
		cleanup(controller.attachScale(decide))

		-- Spectators only: swap the balcony view for a close-up on the
		-- podiums and back (DecisionStudioController's watch camera).
		-- Placed in the layout effect below.
		local watching = store.watching
		local toggleWatch = store.toggleWatch
		local watchButton: GuiObject? = nil
		if watching ~= nil and toggleWatch ~= nil then
			local button = C.Button({
				label = function()
					return if watching() then "Balcony view" else "Watch up close"
				end,
				variant = "secondary",
				width = WATCH_W,
				onActivate = toggleWatch,
				anchorPoint = Vector2.new(1, 1),
			})
			button.Parent = gui
			cleanup(controller.attachScale(button))
			effect(function()
				local s = stage()
				button.Visible = not store.isFinalist()
					and (s == "Intro" or s == "Negotiate" or s == "Choose" or s == "Reveal")
			end)
			watchButton = button
		end

		-- Placement. Portrait: info from the top (below the chat window),
		-- decide from the bottom. Landscape: side by side. Positions are
		-- in the ScreenGui's own space, which is already inside the safe
		-- area; the chat window's rect is in screen space, so it's moved
		-- into ours before insetting.
		local guiRect = source({ x = 0, y = 0, width = 0, height = 0 } :: DecisionLogic.Rect)
		local function readGui()
			guiRect({
				x = gui.AbsolutePosition.X,
				y = gui.AbsolutePosition.Y,
				width = gui.AbsoluteSize.X,
				height = gui.AbsoluteSize.Y,
			})
		end
		readGui()
		local c1 = gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(readGui)
		local c2 = gui:GetPropertyChangedSignal("AbsolutePosition"):Connect(readGui)
		cleanup(function()
			c1:Disconnect()
			c2:Disconnect()
		end)
		local top = derive(function()
			local g = guiRect()
			local chat = store.chat()
			local local_ = if chat
				then { x = chat.x - g.x, y = chat.y - g.y, width = chat.width, height = chat.height }
				else nil
			local usable = { x = 0, y = Theme.spacing.sm, width = g.width, height = g.height }
			return DecisionLogic.chatInset(local_, usable, Theme.spacing.sm, CHAT_MAX_FRACTION)
		end)
		local keyboard = store.keyboard
		local lift = derive(function()
			local g = guiRect()
			local kbTop = if keyboard then keyboard() else nil
			local usable = { x = 0, y = 0, width = g.width, height = g.height }
			return DecisionLogic.keyboardLift(
				if kbTop then kbTop - g.y else nil,
				usable,
				Theme.spacing.md,
				KEYBOARD_MAX_FRACTION
			)
		end)
		-- Whether the chat line fits between the two buttons (a phone or
		-- PC held sideways), or has to sit above them (portrait, or a
		-- squarer tablet). In reference px, like everything it measures.
		local between = derive(function()
			local width = guiRect().width / math.max(Env.scale(), 0.01)
			return width >= 2 * (CHOICE_W + EDGE + GAP) + CHAT_W
		end)
		effect(function()
			local margin = lift()
			local scale = Env.scale()
			local edge = EDGE * scale
			info.AnchorPoint = if portrait() then Vector2.new(0.5, 0) else Vector2.new(0, 0)
			info.Position = if portrait() then UDim2.new(0.5, 0, 0, top()) else UDim2.fromOffset(edge, top())
			stealButton.AnchorPoint = Vector2.new(0, 1)
			stealButton.Position = UDim2.new(0, edge, 1, -(edge + margin))
			shareButton.AnchorPoint = Vector2.new(1, 1)
			shareButton.Position = UDim2.new(1, -edge, 1, -(edge + margin))
			local above = if buttonsUp() and not between() then (CHOICE_H + GAP) * scale else 0
			decide.AnchorPoint = Vector2.new(0.5, 1)
			decide.Position = UDim2.new(0.5, 0, 1, -(edge + margin + above))
			-- Bottom-right, where a finalist's Share button sits: a spectator
			-- has no hold buttons, it's in thumb reach, and the top right
			-- is Roblox's player list.
			if watchButton ~= nil then
				watchButton.Position = UDim2.new(1, -edge, 1, -(edge + margin))
			end
		end)

		-- Keyboard and gamepad: hold Q/X for Steal, E/Y for Share. Bound
		-- on touch too (a tablet with a keyboard). ContextActionService
		-- doesn't fire while a TextBox has focus, so typing "q" in chat
		-- can never start a lock.
		local function bind(action: string, choice: Choice)
			ContextActionService:BindAction(action, function(_, inputState: Enum.UserInputState)
				if inputState == Enum.UserInputState.Begin then
					if not chooseOpen() then
						return Enum.ContextActionResult.Pass
					end
					store.press(choice)
					return Enum.ContextActionResult.Sink
				elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
					store.release(choice)
				end
				return Enum.ContextActionResult.Pass
			end, false, table.unpack(KEYS[choice]))
			cleanup(function()
				ContextActionService:UnbindAction(action)
			end)
		end
		bind(STEAL_ACTION, "Steal")
		bind(SHARE_ACTION, "Share")
	end)

	return function()
		destroy()
		gui:Destroy()
	end
end

return DecisionStudio
