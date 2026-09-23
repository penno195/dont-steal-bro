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
-- WHAT GOES WHERE, PORTRAIT (the design target):
--   top      the three seats: name, reputation line, and a status that
--            is speaking / typing / deciding / locked - never a choice
--            until the reveal flips the card.
--            Pushed below Roblox's chat window when it's open, because
--            a player with no voice negotiates entirely inside it.
--   middle   the stage title and the phase countdown.
--   bottom   the payoff table (always, until the outcome is shown),
--            then the Steal/Share hold buttons in the thumb's reach.
-- Landscape splits the same parts into two columns.
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
local Base = require(script.Parent.Parent.Components.Base)
local C = require(script.Parent.Parent.Components)
local DecisionLogic = require(script.Parent.Parent.DecisionLogic)
local Layout = require(script.Parent.Parent.Layout)
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
	reputation: string, -- DecisionLogic.reputationLabel, already formatted
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
	press: (choice: Choice) -> (),
	release: (choice: Choice) -> (),
	dismiss: () -> (),
	now: (() -> number)?, -- clock override for the preview; default Clock.now
}

local CLOCK_STEP = 0.05
local COLUMN = 344
local GAP = Theme.spacing.md
local SEAT_W = 108
local SEAT_H = 132
local AVATAR = 48
local RING = 56
local HEADER_H = 64
local ROW_H = 44
local HEAD_W = 76
local CHOICE_W = 164
local CHOICE_H = 96
local CHAT_MAX_FRACTION = 0.3
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
	Intro = "Their history is all you get.",
	Negotiate = "Talk or type. Promises cost nothing.",
	Choose = "Hold to lock in. It's final.",
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
		Base.corner(if diamond then Theme.radius.sm else Theme.radius.pill),
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
	step: () -> DecisionLogic.RevealStep?
): Frame
	local revealed = derive(function()
		local s = step()
		return s ~= nil and s.cardsShown >= index
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

	-- One face per choice, built now and hidden, so the reveal is a
	-- visibility flip rather than instance creation at the dramatic
	-- moment. Both exist for every seat from the start, which is why
	-- their existence says nothing.
	local faceSize = Vector2.new(SEAT_W - 2 * Theme.spacing.xs, SEAT_H - AVATAR - Theme.spacing.md)
	local faces: { [Choice]: Frame } = {
		Steal = face("Steal", faceSize, "label"),
		Share = face("Share", faceSize, "label"),
	}
	local holder = create("Frame")({
		Name = "Revealed",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -Theme.spacing.xs),
		Size = UDim2.fromOffset(faceSize.X, faceSize.Y),
		BackgroundTransparency = 1,
		ClipsDescendants = true,
		ZIndex = 3,
		Visible = false,
	}) :: Frame
	for _, f in faces do
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5, 0.5)
		f.Visible = false
		f.Parent = holder
	end
	-- The flip: the face grows out of a vertical line, like a card
	-- turning. Reduced motion cuts straight to it - same moment, no
	-- movement.
	effect(function()
		local c = choice()
		for key, f in faces do
			f.Visible = key == c
		end
		holder.Visible = c ~= nil
		if c ~= nil then
			local full = UDim2.fromOffset(faceSize.X, faceSize.Y)
			if Env.reducedMotion() then
				holder.Size = full
			else
				holder.Size = UDim2.fromOffset(0, faceSize.Y)
				TweenService:Create(
					holder,
					TweenInfo.new(Theme.motion.slow, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
					{ Size = full }
				):Play()
			end
		end
	end)

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
			Name = "Reputation",
			Position = UDim2.fromOffset(
				Theme.spacing.xs,
				AVATAR + Theme.spacing.sm + Theme.type.label.size + Theme.spacing.xs
			),
			Size = UDim2.new(1, -2 * Theme.spacing.xs, 0, Theme.type.caption.size + Theme.spacing.xxs),
			Text = function()
				return seat().reputation
			end,
			TextColor3 = Theme.color.inkMuted,
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
		holder,
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

local function payoffTable(seats: () -> number, order: number): Frame
	local rows = derive(function()
		return DecisionLogic.payoffRows(seats())
	end)
	local function cellsOf(row: () -> DecisionLogic.PayoffRow): Frame
		local width = derive(function()
			local n = #row().cells
			return math.floor((COLUMN - 2 * Theme.spacing.sm - HEAD_W - n * Theme.spacing.xs) / n)
		end)
		return create("Frame")({
			Name = "Cells",
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(COLUMN - 2 * Theme.spacing.sm - HEAD_W - Theme.spacing.xs, ROW_H),
			create("UIListLayout")({
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, Theme.spacing.xs),
				SortOrder = Enum.SortOrder.LayoutOrder,
			}),
			indexes(function()
				return row().cells
			end, function(cell: () -> DecisionLogic.PayoffCell, i: number)
				local nothing = function()
					return cell().prize == "Nothing"
				end
				return create("Frame")({
					Name = "Cell",
					LayoutOrder = i,
					Size = function()
						return UDim2.fromOffset(width(), ROW_H)
					end,
					BackgroundColor3 = Theme.color.surfaceRaised,
					BackgroundTransparency = function()
						return if nothing() then 0.6 else 0
					end,
					Base.corner(Theme.radius.sm),
					Base.text("caption", {
						Name = "When",
						Size = UDim2.fromScale(1, 0.45),
						Text = function()
							return cell().when
						end,
						TextColor3 = Theme.color.inkMuted,
					}),
					Base.text("label", {
						Name = "Prize",
						Position = UDim2.fromScale(0, 0.45),
						Size = UDim2.fromScale(1, 0.55),
						Text = function()
							local label = DecisionLogic.PRIZE_LABEL[cell().prize]
							return if nothing() then "✕ " .. label else label
						end,
						TextColor3 = function()
							return if nothing() then Theme.color.inkMuted else Theme.color.ink
						end,
					}),
				})
			end) :: any,
		}) :: Frame
	end

	return create("Frame")({
		Name = "Payoff",
		LayoutOrder = order,
		Size = UDim2.fromOffset(COLUMN, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.elevation[2].surface,
		Base.corner(Theme.radius.md),
		Base.padding(Theme.spacing.sm),
		create("UIListLayout")({
			FillDirection = Enum.FillDirection.Vertical,
			Padding = UDim.new(0, Theme.spacing.xs),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Base.text("caption", {
			Name = "Heading",
			LayoutOrder = 0,
			Size = UDim2.new(1, 0, 0, Theme.type.caption.size + Theme.spacing.xxs),
			Text = "WHAT YOU GET, IF THE OTHERS…",
			TextColor3 = Theme.color.inkMuted,
			TextXAlignment = Enum.TextXAlignment.Left,
		}),
		indexes(rows, function(row: () -> DecisionLogic.PayoffRow, i: number)
			local headSize = Vector2.new(HEAD_W, ROW_H)
			return create("Frame")({
				Name = "Row",
				LayoutOrder = i,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, ROW_H),
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					Padding = UDim.new(0, Theme.spacing.xs),
					SortOrder = Enum.SortOrder.LayoutOrder,
				}),
				-- rows() is always Steal then Share, so each head is fixed.
				face(if i == 1 then "Steal" else "Share", headSize, "caption"),
				cellsOf(row),
			})
		end) :: any,
	}) :: Frame
end

-- HOLD TO CONFIRM ----------------------------------------------------

local function holdButton(choice: Choice, store: Store, enabled: () -> boolean, order: number): Frame
	local style = decisionStyle(choice)
	local diamond = style.shape == "Diamond"
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

	local faceFrame = face(choice, Vector2.new(CHOICE_W, CHOICE_H), "title")
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
			Base.corner(if diamond then Theme.radius.sm else Theme.radius.pill),
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
			Base.corner(if diamond then Theme.radius.sm else Theme.radius.pill),
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

	return create("Frame")({
		Name = "HoldSlot" .. choice,
		LayoutOrder = order,
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(CHOICE_W, CHOICE_H + Theme.type.caption.size + Theme.spacing.xs),
		button :: any,
		Base.text("caption", {
			Name = "KeyHint",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 1),
			Size = UDim2.new(1, 0, 0, Theme.type.caption.size),
			Text = function()
				local mode = Env.inputMode()
				if mode == Enum.PreferredInput.Gamepad then
					return if choice == "Steal" then "Hold X" else "Hold Y"
				elseif mode == Enum.PreferredInput.KeyboardAndMouse then
					return if choice == "Steal" then "Hold Q" else "Hold E"
				end
				return "Hold"
			end,
			TextColor3 = Theme.color.inkMuted,
		}),
	}) :: Frame
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

		-- Seats + header.
		local header = hrow("Header", 2, HEADER_H, GAP, {
			create("Frame")({
				Name = "Titles",
				LayoutOrder = 1,
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(COLUMN - RING - GAP, HEADER_H),
				Base.text("title", {
					Name = "Title",
					Size = UDim2.fromScale(1, 0.55),
					Text = function()
						return banner() or STAGE_TITLE[stage()]
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
					LayoutOrder = 2,
					BackgroundTransparency = 1,
					Size = UDim2.fromOffset(RING, RING),
					switch(ringPhase)(map),
				})
			end)(),
		})

		local seatsRow = hrow("Seats", 1, SEAT_H + Theme.spacing.md, Theme.spacing.sm, {
			indexes(store.seats, function(seat: () -> Seat, index: number)
				return seatCard(seat, index, store, stage, step)
			end) :: any,
		})

		local info = stack("Info", COLUMN, GAP, { seatsRow, header })
		info.Parent = gui
		cleanup(controller.attachScale(info))

		-- Payoff + actions + result.
		local payoff = payoffTable(seatCount, 1)
		effect(function()
			payoff.Visible = not outcomeShown()
		end)
		local buttons = hrow("Choices", 2, CHOICE_H + Theme.type.caption.size + Theme.spacing.xs, GAP, {
			holdButton("Steal", store, chooseOpen, 1),
			holdButton("Share", store, chooseOpen, 2),
		})
		effect(function()
			local s = stage()
			buttons.Visible = store.isFinalist() and (s == "Intro" or s == "Negotiate" or s == "Choose")
		end)
		local locked = lockedCard(store, 3)
		effect(function()
			locked.Visible = store.isFinalist() and store.confirm().state == "Locked" and stage() ~= "Reveal"
		end)
		local result = resultPanel(copy, store, 4)
		effect(function()
			result.Visible = resultShown()
		end)

		local decide = stack("Decide", COLUMN, GAP, { payoff, buttons, locked, result })
		decide.Parent = gui
		cleanup(controller.attachScale(decide))

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
		effect(function()
			local margin = Theme.spacing.md
			if portrait() then
				info.AnchorPoint = Vector2.new(0.5, 0)
				info.Position = UDim2.new(0.5, 0, 0, top())
				decide.AnchorPoint = Vector2.new(0.5, 1)
				decide.Position = UDim2.new(0.5, 0, 1, -margin)
			else
				info.AnchorPoint = Vector2.new(0.5, 0)
				info.Position = UDim2.new(0.28, 0, 0, top())
				decide.AnchorPoint = Vector2.new(0.5, 1)
				decide.Position = UDim2.new(0.72, 0, 1, -margin)
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
