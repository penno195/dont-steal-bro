--!strict
-- Device review for the race HUD (P6-3): the real RaceHUD screen, fed a
-- scripted fake Store instead of remotes, so every state can be
-- screenshotted without a live round (docs/race-hud.md "Device
-- review"). Every STEP seconds it moves to the next scene: a different
-- effect, a different place against the qualification line, the arrow
-- turned 45 degrees further, and the power-up slot alternating between
-- held and empty.
--
-- Mounted by UIScaleController when ReplicatedStorage has the
-- UIRaceHUDPreview attribute set. Debug only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Clock = require(ReplicatedStorage.Shared.Clock)
local HudLogic = require(script.Parent.Parent.HudLogic)
local RaceHUD = require(script.Parent.RaceHUD)

local source = vide.source

local STEP = 4
local SELF = 1

local TITLES = { "Code Playback", "Pressure Valve", "Fuse Rewire", "Vent Purge", "Code Playback", "Pressure Valve" }

-- One scene per step. `mine` is the preview player's task count against
-- a fixed field of rivals on 5, 4, 3, 3, 1: it walks from out, to on
-- the line, to safe.
type Scene = { mine: number, effect: HudLogic.Effect?, held: boolean }
local SCENES: { Scene } = {
	{ mine = 1, effect = { id = "freeze", category = "HardControl", kind = "Debuff", expiresAt = 0 }, held = true },
	{ mine = 2, effect = { id = "slow-field", category = "Movement", kind = "Debuff", expiresAt = 0 }, held = false },
	{ mine = 3, effect = { id = "blind", category = "Vision", kind = "Debuff", expiresAt = 0 }, held = true },
	{ mine = 4, effect = { id = "sprint-boost", category = "Movement", kind = "Buff", expiresAt = 0 }, held = false },
	{ mine = 5, effect = { id = "gravity", category = "Gravity", kind = "Debuff", expiresAt = 0 }, held = true },
	{ mine = 6, effect = nil, held = false },
}
local RIVALS = { 5, 4, 3, 3, 1 }

local RaceHUDPreview = {}

function RaceHUDPreview.mount(controller: any): () -> ()
	local start = Clock.now()
	local endsAt = source((start + 300) :: number?)
	local tasks = source({} :: { RaceHUD.TaskRow })
	local progress = source({} :: { HudLogic.ProgressEntry })
	local held = source(nil :: RaceHUD.Held?)
	local pending = source(false)
	local effects = source({} :: { HudLogic.Effect })
	local objective = source(nil :: RaceHUD.Objective?)

	local step = 0
	local function show(scene: Scene)
		local rows: { RaceHUD.TaskRow } = {}
		for i, title in TITLES do
			table.insert(rows, table.freeze({ title = title, completed = i <= scene.mine }))
		end
		tasks(rows)

		local field: { HudLogic.ProgressEntry } = { { playerId = SELF, tasksCompleted = scene.mine } }
		for i, count in RIVALS do
			table.insert(field, { playerId = SELF + i, tasksCompleted = count })
		end
		progress(field)

		local e = scene.effect
		local running: { HudLogic.Effect } = {}
		if e then
			local expiresAt = Clock.now() + STEP - 0.5
			local entry = { id = e.id, category = e.category, kind = e.kind, expiresAt = expiresAt }
			table.insert(running, table.freeze(entry))
		end
		effects(running)
		held(if scene.held then table.freeze({ id = "freeze", name = "Freeze" }) else nil)
		objective(
			if scene.mine < #TITLES
				then table.freeze({ bearing = (step * 45) % 360 - 180, distance = 12 + step * 7 })
				else nil
		)
	end

	local store: RaceHUD.Store = {
		selfId = SELF,
		qualifierCount = 3,
		raceSeconds = 300,
		endsAt = endsAt,
		tasks = tasks,
		progress = progress,
		held = held,
		pending = pending,
		effects = effects,
		objective = objective,
		-- Spin for a moment, then empty the slot: what a real use does.
		use = function()
			pending(true)
			task.delay(0.6, function()
				pending(false)
				held(nil)
			end)
		end,
	}

	local running = true
	task.spawn(function()
		while running do
			step += 1
			show(SCENES[(step - 1) % #SCENES + 1])
			-- Loop the countdown too, so its warning and critical colours
			-- show up without a five-minute wait: the last 20s of the race.
			if step % #SCENES == 1 then
				endsAt(Clock.now() + 20)
			end
			task.wait(STEP)
		end
	end)

	local unmount = RaceHUD.mount(controller, store)
	return function()
		running = false
		unmount()
	end
end

return RaceHUDPreview
