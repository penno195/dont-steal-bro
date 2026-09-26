--!strict
-- Device review for the Decision Studio (P6-5): the real DecisionStudio
-- screen, fed a scripted fake Store instead of remotes, so every stage
-- can be screenshotted and the hold buttons tried without a live round
-- (docs/decision-studio.md "Device review"). One loop is a whole
-- finale on short timers: Intro, Negotiate with the rivals taking turns
-- to speak and type, Choose with the rivals locking in, then the reveal
-- and result. Each loop plays the next outcome branch and alternates
-- the preview player between winning and losing a 7-win streak.
--
-- The preview player can hold Steal or Share during Choose like the
-- real thing; their pick is shown as theirs, but the scripted branch
-- decides the reveal.
--
-- Mounted by UIScaleController when ReplicatedStorage has the
-- UIDecisionStudioPreview attribute set. Debug only.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local vide = require(ReplicatedStorage.Packages.Vide)

local Clock = require(ReplicatedStorage.Shared.Clock)
local DecisionLogic = require(script.Parent.Parent.DecisionLogic)
local DecisionStudio = require(script.Parent.DecisionStudio)

local source = vide.source

local SELF = 1
local RIVAL_A = 2
local RIVAL_B = -3 -- an NPC seat, to check the no-headshot disc
local SECONDS = { Intro = 3, Negotiate = 6, Choose = 8 }

type Script = { branch: string, choices: { [number]: DecisionLogic.Choice }, winners: { number } }
local SCRIPTS: { Script } = {
	{
		branch = "SoleSteal",
		choices = { [SELF] = "Share", [RIVAL_A] = "Steal", [RIVAL_B] = "Share" },
		winners = { RIVAL_A },
	},
	{
		branch = "LoneShare",
		choices = { [SELF] = "Share", [RIVAL_A] = "Steal", [RIVAL_B] = "Steal" },
		winners = { SELF },
	},
	{ branch = "AllSteal", choices = { [SELF] = "Steal", [RIVAL_A] = "Steal", [RIVAL_B] = "Steal" }, winners = {} },
	{
		branch = "AllShare",
		choices = { [SELF] = "Share", [RIVAL_A] = "Share", [RIVAL_B] = "Share" },
		winners = { SELF, RIVAL_A, RIVAL_B },
	},
	{
		branch = "SoleSteal",
		choices = { [SELF] = "Steal", [RIVAL_A] = "Share", [RIVAL_B] = "Share" },
		winners = { SELF },
	},
}

local DecisionStudioPreview = {}

function DecisionStudioPreview.mount(controller: any): () -> ()
	local phase: DecisionStudio.Settable<DecisionLogic.Phase?> = source(nil)
	local endsAt = source(nil :: number?)
	local locked = source({} :: { [number]: boolean })
	local talk: DecisionStudio.Settable<{ [number]: DecisionStudio.Talk }> = source({})
	local speaking: { [number]: DecisionStudio.Talk } = { [RIVAL_A] = "speaking" }
	local typing: { [number]: DecisionStudio.Talk } = { [RIVAL_B] = "typing" }
	local acked = source(false)
	local reveal = source(nil :: DecisionLogic.Reveal?)
	local personal = source(nil :: DecisionLogic.Personal?)
	local seats = source({
		table.freeze({
			id = SELF,
			name = "You",
			isSelf = true,
			isNPC = false,
			reputation = "Stole 2 of 5",
			left = false,
		}),
		table.freeze({
			id = RIVAL_A,
			name = "Rival",
			isSelf = false,
			isNPC = false,
			reputation = "Steals 71% of 24",
			left = false,
		}),
		table.freeze({
			id = RIVAL_B,
			name = "Bot",
			isSelf = false,
			isNPC = true,
			reputation = "No history yet",
			left = false,
		}),
	} :: { DecisionStudio.Seat })

	local function lock(id: number)
		local nextLocked = table.clone(locked())
		nextLocked[id] = true
		locked(nextLocked)
	end

	local confirm, press, release, stopConfirm = DecisionStudio.confirmer(function()
		task.delay(0.3, function() -- the server's echo
			lock(SELF)
			acked(true)
		end)
	end, function()
		return phase() == "Choose" and reveal() == nil
	end)

	local running = true
	local store: DecisionStudio.Store = {
		selfId = SELF,
		isFinalist = function()
			return true
		end,
		seats = seats,
		phase = phase,
		endsAt = endsAt,
		phaseSeconds = SECONDS,
		locked = locked,
		talk = talk,
		confirm = confirm,
		acked = acked,
		reveal = reveal,
		personal = personal,
		chat = function()
			return nil
		end,
		press = press,
		release = release,
		dismiss = function()
			reveal(nil) -- skip to the next loop's Intro sooner
		end,
		send = function(text: string)
			print("DecisionStudioPreview: would send", text)
		end,
		typing = function() end,
	}

	local function enter(name: DecisionLogic.Phase, seconds: number)
		phase(name)
		endsAt(Clock.now() + seconds)
	end

	task.spawn(function()
		local loop = 0
		while running do
			loop += 1
			local scene = SCRIPTS[(loop - 1) % #SCRIPTS + 1]
			locked({})
			acked(false)
			reveal(nil)
			personal(nil)
			confirm(DecisionLogic.OPEN)

			enter("Intro", SECONDS.Intro)
			task.wait(SECONDS.Intro)

			enter("Negotiate", SECONDS.Negotiate)
			for i = 1, SECONDS.Negotiate do
				talk(if i % 3 == 1 then speaking elseif i % 3 == 2 then typing else {})
				task.wait(1)
			end
			talk({})

			enter("Choose", SECONDS.Choose)
			task.delay(2, lock, RIVAL_B)
			task.delay(4, lock, RIVAL_A)
			task.wait(SECONDS.Choose)
			if not running then
				break
			end

			local won = table.find(scene.winners, SELF) ~= nil
			local losers = {}
			for id in scene.choices do
				if not table.find(scene.winners, id) then
					table.insert(losers, id)
				end
			end
			phase("Reveal")
			endsAt(nil)
			reveal(DecisionLogic.parseReveal({
				choices = scene.choices,
				outcome = {
					branch = scene.branch,
					winners = (function()
						local list = {}
						for _, id in scene.winners do
							table.insert(list, { playerId = id })
						end
						return list
					end)(),
					loserIds = losers,
				},
				revealAt = Clock.now() + 0.2,
			}))
			personal(table.freeze({ streakBefore = 7, streakAfter = if won then 8 else 0, won = won }))
			local length = DecisionLogic.revealLength(3) + 4
			local waited = 0
			while running and reveal() ~= nil and waited < length do
				task.wait(0.25)
				waited += 0.25
			end
		end
	end)

	local unmount = DecisionStudio.mount(controller, store)
	return function()
		running = false
		stopConfirm()
		unmount()
	end
end

return DecisionStudioPreview
