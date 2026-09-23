--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Components/Base.luau
-- The shared shell every mini-task view is built on (P6-4). A task view
-- is a spec handed to TaskViewBase.define; the result is a plain
-- TaskView (TaskViews/Types.luau) that TaskStationController dispatches to
-- like any other. docs/task-views.md is the author's guide.
--
-- WHAT THE SHELL OWNS, SO NO TASK HAS TO:
--   - Presentation: a full-screen sheet on phones (and on any touch
--     device), a centred window on a big mouse/gamepad screen
--     (TaskViewLogic.presentation). Re-decided live on rotate/resize.
--   - Open/close transitions (slide up / grow), zero under reduced motion.
--   - The header: task name, an elapsed timer, and the close button
--     (the abort path; B on a gamepad does the same).
--   - The status line under the play area, with a feedback icon so a
--     state is never shown by colour alone.
--   - The input lock: camera and character controls frozen from open to
--     close via UI/InputLock, released on EVERY close path - success,
--     abort, and whatever TaskStationController's guards end the attempt
--     for (death, knocked out of range, race over, server TaskEnded).
--   - The play area: a frame inset by Tokens.taskView.edgeMargin from
--     the safe area. A view lays out inside it and can't get closer to
--     an edge than that. In Studio the shell audits every button after
--     open and warns about any under 44 points or inside the margin.
--   - The round-trip: ctx.submit fires the task's own remote with the
--     stationId filled in; results come back through spec.onResult.
--
-- Each attempt builds a fresh Vide root and destroys it on close, so a
-- view's build() can create sources and connections freely; the root's
-- cleanup disconnects them however the attempt ended.

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local vide = require(ReplicatedStorage.Packages.Vide)

local Net = require(ReplicatedStorage.Shared.Net)

local Base = require(script.Parent.Components.Base)
local Env = require(script.Parent.Components.Env)
local IconButton = require(script.Parent.Components.IconButton)
local Icons = require(script.Parent.Components.Icons)
local InputLock = require(script.Parent.InputLock)
local TaskViewLogic = require(script.Parent.TaskViewLogic)
local TaskViewTypes = require(script.Parent.Parent.TaskViews.Types)
local Theme = require(script.Parent.Theme)
local Tokens = require(script.Parent.Tokens)
local UIScaleController = require(script.Parent.Parent.Controllers.UIScaleController)

local cleanup = vide.cleanup
local create = vide.create
local derive = vide.derive
local source = vide.source

local T = Tokens.taskView
local HEADER_HEIGHT = Theme.touch.iconButton
local STATUS_HEIGHT = Theme.touch.iconButton
-- How long the success tick stays up before the sheet leaves. Not
-- motion (nothing moves), so reduced motion keeps it.
local SUCCESS_HOLD = 0.6
local FLASH_SECONDS = 0.4
local FEEDBACKS: { TaskViewLogic.Feedback } = { "Neutral", "Active", "Good", "Bad" }

type Source<T> = Base.Source<T>

export type Context = {
	stationId: string,
	challenge: any,
	attempt: number,
	-- Seconds since the view opened, whole seconds (updates once a second).
	elapsed: Source<number>,
	presentation: Source<TaskViewLogic.Presentation>,
	-- The play area frame build() is parented into. Adapters that hit-
	-- test against it (Drag) take it as `area`.
	area: Frame,
	-- Fires the task's own submission remote with `stationId` added.
	submit: (remote: string, fields: { [string]: any }?) -> (),
	-- The status line: a few words at most, never a sentence.
	setStatus: (text: string, feedback: TaskViewLogic.Feedback?) -> (),
	-- A short visual pulse on the status line, plus an optional sound.
	-- The pulse always happens: no cue is ever sound-only.
	cue: (feedback: TaskViewLogic.Feedback, sound: Sound?) -> (),
	-- Abandon the attempt (same as the close button).
	close: () -> (),
}

export type Spec = {
	taskId: string,
	title: string,
	-- Builds the task's content into ctx.area. Runs inside the attempt's
	-- Vide scope. May return instances to parent into the area.
	build: (ctx: Context) -> { Instance }?,
	-- A non-final result (the attempt stays open). Default: "Keep going".
	-- Success is handled by the shell and never reaches here.
	onProgress: ((ctx: Context) -> ())?,
}

type Attempt = {
	stationId: string,
	ctx: Context,
	close: (immediate: boolean) -> (),
	onSuccess: () -> (),
}

-- Studio-only layout audit: every visible button in `root`, checked
-- against the touch minimum and the edge margin of `screen`.
local function audit(taskId: string, screen: ScreenGui, root: GuiObject)
	local scale = Env.scale()
	local usable = {
		x = screen.AbsolutePosition.X,
		y = screen.AbsolutePosition.Y,
		width = screen.AbsoluteSize.X,
		height = screen.AbsoluteSize.Y,
	}
	for _, d in root:GetDescendants() do
		if d:IsA("GuiButton") and d.Visible and d.Active then
			local p, s = d.AbsolutePosition, d.AbsoluteSize
			local rect = { x = p.X, y = p.Y, width = s.X, height = s.Y }
			if math.min(s.X, s.Y) < Theme.touch.minTargetPoints - 0.5 then
				warn(
					string.format(
						"TaskViewBase[%s]: %s is %dx%d, under the %d-point touch minimum",
						taskId,
						d:GetFullName(),
						s.X,
						s.Y,
						Theme.touch.minTargetPoints
					)
				)
			end
			if TaskViewLogic.violatesEdge(rect, usable, T.edgeMargin * scale - 0.5) then
				warn(
					string.format(
						"TaskViewBase[%s]: %s is inside the %d-px edge margin",
						taskId,
						d:GetFullName(),
						T.edgeMargin
					)
				)
			end
		end
	end
end

local function firstSelectable(root: Instance): GuiObject?
	local best: GuiObject? = nil
	for _, d in root:GetDescendants() do
		if d:IsA("GuiObject") and d.Selectable and d.Visible then
			if best == nil or d.SelectionOrder < best.SelectionOrder then
				best = d
			end
		end
	end
	return best
end

local function open(spec: Spec, stationId: string, challenge: any, session: TaskViewTypes.Session): Attempt
	local lockToken = {}
	InputLock.acquire(lockToken)
	local previousSelection = GuiService.SelectedObject

	local scrimGui = UIScaleController.createScreen("TaskViewScrim", {
		displayOrder = Theme.displayOrder.panel,
		fullBleed = true,
	})
	local gui = UIScaleController.createScreen("TaskView", { displayOrder = Theme.displayOrder.panel + 1 })

	local shown = source(false)
	local closing = false
	-- Set on success: the shell stays up for SUCCESS_HOLD, but nothing
	-- more is submitted and no cue overwrites the tick.
	local finished = false
	local ctxOut: Context
	local areaOut: Frame
	local rootOut: Frame

	local destroyRoot = vide.root(function()
		local usable = source(UIScaleController.getUsableRect())
		cleanup(UIScaleController.observeUsableRect(usable))

		-- (Cast: Vide's derive widens a string-literal union to `string`.)
		local presentation: Source<TaskViewLogic.Presentation> = (derive :: any)(function(): TaskViewLogic.Presentation
			return TaskViewLogic.presentation(
				usable(),
				Env.inputMode() == Enum.PreferredInput.Touch,
				T.windowMinShortAxis
			)
		end)
		local isSheet = derive(function()
			return presentation() == "Sheet"
		end)

		-- Reference-pixel size of the card: the whole usable rect for a
		-- sheet (divided back out of the global scale), the token size
		-- for a window.
		local cardSize = derive(function(): UDim2
			if isSheet() then
				local r, s = usable(), Env.scale()
				return UDim2.fromOffset(r.width / s, r.height / s)
			end
			return UDim2.fromOffset(T.windowSize.width, T.windowSize.height)
		end)

		local status = source("")
		local feedback: Source<TaskViewLogic.Feedback> & ((TaskViewLogic.Feedback) -> TaskViewLogic.Feedback) =
			source("Neutral") :: any
		local style = derive(function()
			return TaskViewLogic.feedback(feedback())
		end)
		local iconCases: { [TaskViewLogic.Feedback]: () -> GuiObject? } = {}
		for i = 1, #FEEDBACKS do
			-- (Indexed, not iterated: a generic for widens the literal union.)
			local fb: TaskViewLogic.Feedback = FEEDBACKS[i] :: any
			local icon = TaskViewLogic.feedback(fb).icon
			iconCases[fb] = function()
				return if icon then Icons.view(icon, Theme.type.label.size, Theme.color.ink) else nil
			end
		end

		local elapsed = source(0)
		local startedAt = os.clock()
		local tick = RunService.Heartbeat:Connect(function()
			local whole = math.floor(os.clock() - startedAt)
			if whole ~= elapsed() then
				elapsed(whole)
			end
		end)
		cleanup(function()
			tick:Disconnect()
		end)

		local b = UserInputService.InputBegan:Connect(function(input)
			if input.KeyCode == Enum.KeyCode.ButtonB then
				session.close()
			end
		end)
		cleanup(function()
			b:Disconnect()
		end)

		create("Frame")({
			Name = "Scrim",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.color.scrim,
			-- A sheet covers the world; a window dims it but leaves it visible.
			BackgroundTransparency = Env.animate(function()
				return if not shown() then 1 elseif isSheet() then 0.2 else 0.5
			end, Theme.motion.base),
			Parent = scrimGui,
		})

		local area = create("Frame")({
			Name = "PlayArea",
			LayoutOrder = 1,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + STATUS_HEIGHT + 2 * Theme.spacing.sm)),
			ClipsDescendants = false,
		}) :: Frame

		local holder = create("Frame")({
			Name = "TaskViewHolder",
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
			Size = cardSize,
			-- Sheet: slides up from below. Window: fixed, grows in (below).
			Position = Env.animate(function(): UDim2
				return if shown() or not isSheet() then UDim2.fromScale(0.5, 0.5) else UDim2.fromScale(0.5, 1.5)
			end, Theme.motion.base),
			Parent = gui,
		}) :: Frame
		cleanup(UIScaleController.attachScale(holder))

		local card = create("Frame")({
			Name = "TaskViewCard",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.elevation[3].surface,
			BackgroundTransparency = function()
				return if isSheet() then 0 else 0.02
			end,
			SelectionGroup = true,
			SelectionBehaviorUp = Enum.SelectionBehavior.Stop,
			SelectionBehaviorDown = Enum.SelectionBehavior.Stop,
			SelectionBehaviorLeft = Enum.SelectionBehavior.Stop,
			SelectionBehaviorRight = Enum.SelectionBehavior.Stop,
			create("UICorner")({
				CornerRadius = function()
					return if isSheet() then UDim.new(0, 0) else Theme.radius.lg
				end,
			}),
			create("UIScale")({
				Name = "Enter",
				Scale = Env.animate(function()
					return if shown() or isSheet() then 1 else 0.92
				end, Theme.motion.base),
			}),
			-- The edge margin. Everything interactive lives inside this.
			create("UIPadding")({
				PaddingTop = UDim.new(0, T.edgeMargin),
				PaddingBottom = UDim.new(0, T.edgeMargin),
				PaddingLeft = UDim.new(0, T.edgeMargin),
				PaddingRight = UDim.new(0, T.edgeMargin),
			}),
			create("UIListLayout")({
				Padding = UDim.new(0, Theme.spacing.sm),
				SortOrder = Enum.SortOrder.LayoutOrder,
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
			}),

			create("Frame")({
				Name = "Header",
				LayoutOrder = 0,
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
				Base.text("title", {
					Size = UDim2.new(1, -(2 * HEADER_HEIGHT + Theme.spacing.sm), 1, 0),
					Text = spec.title,
					TextXAlignment = Enum.TextXAlignment.Left,
				}),
				Base.text("label", {
					Name = "Timer",
					AnchorPoint = Vector2.new(1, 0),
					Position = UDim2.new(1, -(HEADER_HEIGHT + Theme.spacing.sm), 0, 0),
					Size = UDim2.fromOffset(HEADER_HEIGHT * 1.5, HEADER_HEIGHT),
					TextColor3 = Theme.color.inkMuted,
					Text = function()
						return TaskViewLogic.clock(elapsed())
					end,
				}),
				IconButton({
					icon = "close",
					label = "Close task",
					onActivate = session.close,
					order = 1000, -- last in gamepad order: never the default focus
					anchorPoint = Vector2.new(1, 0.5),
					position = UDim2.fromScale(1, 0.5),
				}) :: any,
			}),

			area,

			create("Frame")({
				Name = "Status",
				LayoutOrder = 2,
				BackgroundColor3 = function()
					return Theme.color[style().color]
				end,
				BackgroundTransparency = function()
					return if feedback() == "Neutral" then 1 else 0.75
				end,
				Size = UDim2.new(1, 0, 0, STATUS_HEIGHT),
				Base.corner(Theme.radius.md),
				create("UIStroke")({
					ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
					Color = function()
						return Theme.color[style().color]
					end,
					Thickness = function()
						return style().strokeThickness
					end,
				}),
				create("UIListLayout")({
					FillDirection = Enum.FillDirection.Horizontal,
					HorizontalAlignment = Enum.HorizontalAlignment.Center,
					VerticalAlignment = Enum.VerticalAlignment.Center,
					Padding = UDim.new(0, Theme.spacing.sm),
				}),
				vide.switch(feedback)(iconCases) :: any,
				Base.text("label", {
					Size = UDim2.fromScale(0.8, 1),
					AutomaticSize = Enum.AutomaticSize.None,
					Text = status,
				}),
			}),
			Parent = holder,
		}) :: Frame

		local function setStatus(text: string, fb: TaskViewLogic.Feedback?)
			status(text)
			feedback(fb or "Neutral")
		end

		local flashSerial = 0
		local function cue(fb: TaskViewLogic.Feedback, sound: Sound?)
			flashSerial += 1
			local mine = flashSerial
			local before: TaskViewLogic.Feedback = feedback()
			feedback(fb)
			task.delay(FLASH_SECONDS, function()
				if mine == flashSerial and not closing and not finished then
					feedback(before)
				end
			end)
			if sound ~= nil then
				sound:Play()
			end
		end

		local ctx: Context = {
			stationId = stationId,
			challenge = challenge,
			attempt = session.attempt,
			elapsed = elapsed,
			presentation = presentation,
			area = area,
			submit = function(remote: string, fields: { [string]: any }?)
				if closing or finished then
					return
				end
				local payload: { [string]: any } = if fields then table.clone(fields) else {}
				payload.stationId = stationId
				Net.fireServer(remote, payload)
			end,
			setStatus = setStatus,
			cue = cue,
			close = session.close,
		}

		local built = spec.build(ctx)
		if built ~= nil then
			for _, child in built do
				child.Parent = area
			end
		end

		ctxOut = ctx
		areaOut = area
		rootOut = card
		return nil
	end)

	shown(true)

	task.defer(function()
		if closing then
			return
		end
		if UIScaleController.getInputMode() == Enum.PreferredInput.Gamepad then
			GuiService.SelectedObject = firstSelectable(areaOut)
		end
		if RunService:IsStudio() then
			-- Two frames: one for layout, one for the enter UIScale to settle.
			task.wait(Env.duration(Theme.motion.base) + 0.05)
			if not closing then
				audit(spec.taskId, gui, rootOut)
			end
		end
	end)

	local function close(immediate: boolean)
		if closing then
			return
		end
		closing = true
		-- Control comes back the moment the attempt ends, not after the
		-- exit animation: a player knocked out of a task is already moving.
		InputLock.release(lockToken)
		shown(false)
		local function destroy()
			destroyRoot()
			scrimGui:Destroy()
			gui:Destroy()
			if previousSelection and previousSelection:IsDescendantOf(game) then
				GuiService.SelectedObject = previousSelection
			elseif GuiService.SelectedObject ~= nil and not GuiService.SelectedObject:IsDescendantOf(game) then
				GuiService.SelectedObject = nil
			end
		end
		if immediate then
			destroy()
		else
			task.delay(Env.duration(Theme.motion.base), destroy)
		end
	end

	return {
		stationId = stationId,
		ctx = ctxOut,
		close = close,
		onSuccess = function()
			InputLock.release(lockToken)
			ctxOut.setStatus("Done!", "Good")
			finished = true
			task.delay(SUCCESS_HOLD, close, false)
		end,
	}
end

local TaskViewBase = {}

function TaskViewBase.define(spec: Spec): TaskViewTypes.TaskView
	local current: Attempt? = nil

	local function hide(stationId: string)
		local a = current
		if a == nil or a.stationId ~= stationId then
			return
		end
		current = nil
		a.close(false)
	end

	return {
		taskId = spec.taskId,
		show = function(stationId: string, challenge: any, session: TaskViewTypes.Session)
			if current ~= nil then
				current.close(true)
			end
			current = open(spec, stationId, challenge, session)
		end,
		onResult = function(stationId: string, success: boolean)
			local a = current
			if a == nil or a.stationId ~= stationId then
				return
			end
			if success then
				current = nil
				a.onSuccess()
			elseif spec.onProgress then
				spec.onProgress(a.ctx)
			else
				a.ctx.setStatus("Keep going", "Active")
			end
		end,
		hide = hide,
	}
end

return TaskViewBase
