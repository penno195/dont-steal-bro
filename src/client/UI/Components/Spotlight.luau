--!strict
--# selene: allow(mixed_table) -- Vide props + children, see Base.luau
-- Spotlight (tutorial v2, docs/onboarding.md "Tutorial v2"): the screen
-- dims and only one GuiObject takes input. A pulsing ring sits around
-- it and its inside is left clear, so the real control shows through
-- and a tap on it is a tap on the control itself. A caption card (title
-- and body) sits above the target, or below it if there's no room.
--
--   Spotlight.open(props)  puts it on screen and returns `close`.
--
-- The dim is four panels around the hole rather than one sheet with a
-- hole cut in it: Roblox has no cut-out, and the panels are Active, so
-- they sink every tap that isn't on the target. Nothing sits over the
-- hole, so input there falls through to the control below.
--
-- The target is re-read every frame (`props.target` is a getter): it
-- can move, resize, or be rebuilt (the queue card swaps its main
-- button). While it's missing the whole spotlight hides, so the player
-- is never left behind a dim with nothing they can press.
--
-- The screen is a safe-area one, like every interactive screen
-- (UIScaleController.createScreen), so a target's AbsolutePosition is
-- in this screen's coordinates too. It doesn't clip to the safe area,
-- and the panels run past the edges, so the dim still covers the notch.
--
-- On a gamepad, opening selects the target. One spotlight at a time:
-- opening a second replaces the first (createScreen reuses the name).

local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local vide = require(ReplicatedStorage.Packages.Vide)

local ComponentLogic = require(script.Parent.ComponentLogic)
local Env = require(script.Parent.Env)
local Modal = require(script.Parent.Modal)
local Theme = require(script.Parent.Parent.Theme)
local UIScaleController = require(script.Parent.Parent.Parent.Controllers.UIScaleController)

local cleanup = vide.cleanup
local create = vide.create
local source = vide.source

export type Props = {
	-- What to light, read every frame. nil hides the spotlight.
	target: () -> GuiObject?,
	title: string,
	body: string,
}

-- Screen px. PAD is the clear space between the target and the ring;
-- BLEED how far the dim runs past the screen edge.
local PAD = 8
local BLEED = 200
local RING = 4
local GAP = 12
local MARGIN = 16
local PULSE_SECONDS = 1.2
-- The card is the Modal's width, and has no actions.
local CARD_WIDTH = Modal.CONTENT_WIDTH + 2 * Theme.spacing.lg

local Spotlight = {}

function Spotlight.open(props: Props): () -> ()
	local previousSelection = GuiService.SelectedObject
	local closed = false
	local shown = source(false)

	local gui = UIScaleController.createScreen("Spotlight", { displayOrder = Theme.displayOrder.modal })
	gui.ClipToDeviceSafeArea = false
	gui.Enabled = false

	local panels: { Frame } = {}
	local ring: Frame
	local holder: Frame
	local card: Frame

	local destroyRoot = vide.root(function()
		local dim = Env.animate(function()
			return if shown() then 0.35 else 1
		end, Theme.motion.base)
		for i = 1, 4 do
			panels[i] = create("Frame")({
				Name = "Dim",
				Active = true,
				BorderSizePixel = 0,
				BackgroundColor3 = Theme.color.scrim,
				BackgroundTransparency = dim,
				Parent = gui,
			}) :: Frame
		end
		ring = create("Frame")({
			Name = "Ring",
			BackgroundTransparency = 1,
			create("UICorner")({ CornerRadius = Theme.radius.md }),
			create("UIStroke")({
				Name = "Stroke",
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
				Color = Theme.color.rim,
				Thickness = RING,
			}),
			Parent = gui,
		}) :: Frame
		-- Global scale on a holder, the card centred in it (as in Modal):
		-- the holder's height follows the card's measured one.
		holder = create("Frame")({
			Name = "CaptionHolder",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Size = UDim2.fromOffset(CARD_WIDTH, 0),
			BackgroundTransparency = 1,
			Parent = gui,
		}) :: Frame
		cleanup(UIScaleController.attachScale(holder))
		card = Modal.card({ title = props.title, body = props.body, bodyLines = 2, actions = {} })
		card.AnchorPoint = Vector2.new(0.5, 0.5)
		card.Position = UDim2.fromScale(0.5, 0.5)
		card.Parent = holder
		local function syncHolder()
			local global = holder.AbsoluteSize.X / CARD_WIDTH
			if global > 0 then
				holder.Size = UDim2.fromOffset(CARD_WIDTH, card.AbsoluteSize.Y / global)
			end
		end
		cleanup(card:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncHolder))
		syncHolder()
	end)

	local start = os.clock()
	local selected = false
	local function step()
		local target = props.target()
		if target == nil or not target:IsDescendantOf(game) or target.AbsoluteSize.X <= 0 then
			gui.Enabled = false
			selected = false
			return
		end
		gui.Enabled = true
		local screen = gui.AbsoluteSize
		local rect = {
			x = target.AbsolutePosition.X,
			y = target.AbsolutePosition.Y,
			w = target.AbsoluteSize.X,
			h = target.AbsoluteSize.Y,
		}
		for i, r in ComponentLogic.spotlightPanels(rect, PAD, screen.X, screen.Y, BLEED) do
			panels[i].Position = UDim2.fromOffset(r.x, r.y)
			panels[i].Size = UDim2.fromOffset(r.w, r.h)
		end
		-- The pulse: the ring breathes outward and fades a little.
		local pulse = if Env.reducedMotion()
			then 0
			else math.abs(math.sin((os.clock() - start) / PULSE_SECONDS * math.pi))
		local grow = PAD / 2 + 4 * pulse
		ring.Position = UDim2.fromOffset(rect.x - grow, rect.y - grow)
		ring.Size = UDim2.fromOffset(rect.w + 2 * grow, rect.h + 2 * grow)
		local stroke = ring:FindFirstChild("Stroke") :: UIStroke
		stroke.Transparency = 0.4 * pulse
		local hole = { x = rect.x - PAD, y = rect.y - PAD, w = rect.w + 2 * PAD, h = rect.h + 2 * PAD }
		local size = card.AbsoluteSize
		local x, y = ComponentLogic.captionPosition(hole, size.X, size.Y, screen.X, screen.Y, GAP, MARGIN)
		holder.Position = UDim2.fromOffset(x + size.X / 2, y + size.Y / 2)
		if not selected and Env.isGamepad() then
			selected = true
			GuiService.SelectedObject = target
		end
	end
	local stepConn = RunService.RenderStepped:Connect(step)
	step()
	shown(true)

	return function()
		if closed then
			return
		end
		closed = true
		shown(false)
		-- The dim fades; the ring and caption go at once.
		ring.Visible = false
		holder.Visible = false
		task.delay(Env.duration(Theme.motion.base), function()
			stepConn:Disconnect()
			destroyRoot()
			gui:Destroy()
			if previousSelection and previousSelection:IsDescendantOf(game) then
				GuiService.SelectedObject = previousSelection
			end
		end)
	end
end

return Spotlight
