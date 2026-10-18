--!strict
-- The pop-up queue (owner, 2026-10-18): "pop-ups never compete". Modal
-- is one at a time and a second open replaces the first, so two rewards
-- landing together (a gift as the tutorial reveal plays, a level-up
-- behind a claim) used to wipe each other off screen unseen. Every
-- reward pop-up now goes through here instead: one runs at a time, in
-- the order pushed, and the next waits until the current one is closed.
--
-- An entry starts only once the screen is clear: no Modal up (any
-- dialog, queued or not, so a pop-up never lands over a confirm or a
-- tutorial step) and no loading screen. An entry's own `ready` adds
-- conditions of its caller's (e.g. no round in play); the queue waits on
-- the head entry rather than skipping it, so the order always holds.
--
-- ClaimPopup.open pushes for its callers; anything else that shows a
-- reward (the tutorial's prize reveal) pushes its own entry and calls
-- `done` when it has finished, usually via PopupQueue.whenModalCloses.

local Players = game:GetService("Players")

local PopupQueue = {}

export type Entry = {
	-- Shows the pop-up; calls `done` once it's gone. May yield.
	run: (done: () -> ()) -> (),
	-- Extra conditions before it may start; nil = only a clear screen.
	ready: (() -> boolean)?,
}

local POLL = 0.25 -- seconds between checks while waiting
-- A beat between one pop-up going and the next arriving, so the second
-- reads as a new thing rather than the first changing under the thumb.
local GAP = 0.35

local queue: { Entry } = {}
local pumping = false

local function screenClear(playerGui: Instance): boolean
	return playerGui:FindFirstChild("Modal") == nil and playerGui:FindFirstChild("LoadingCover") == nil
end

local function pump()
	if pumping then
		return
	end
	pumping = true
	task.spawn(function()
		local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
		while #queue > 0 do
			local entry = queue[1]
			local ready = entry.ready
			if not screenClear(playerGui) or (ready ~= nil and not ready()) then
				task.wait(POLL)
				continue
			end
			table.remove(queue, 1)
			local finished = false
			local function done()
				finished = true
			end
			local ok, err = pcall(function()
				entry.run(done)
			end)
			if not ok then
				-- A broken entry must not hold up every pop-up after it.
				warn("PopupQueue: a pop-up failed to show: " .. tostring(err))
				finished = true
			end
			while not finished do
				task.wait(POLL)
			end
			task.wait(GAP)
		end
		pumping = false
	end)
end

-- Queues a pop-up. Returns `cancel`, which drops it if it hasn't started
-- (a started one is closed the way it was opened, by its own caller).
function PopupQueue.push(entry: Entry): () -> ()
	table.insert(queue, entry)
	pump()
	return function()
		local index = table.find(queue, entry)
		if index ~= nil then
			table.remove(queue, index)
		end
	end
end

-- Calls `done` once the Modal on screen now is gone, however it goes
-- (its own button, a tap outside, or another dialog replacing it); at
-- once if there is none. For an entry whose pop-up is a Modal.
function PopupQueue.whenModalCloses(done: () -> ())
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local modal = playerGui:FindFirstChild("Modal")
	if modal == nil then
		done()
		return
	end
	modal.Destroying:Once(done)
end

-- How many pop-ups are waiting (not counting the one on screen).
function PopupQueue.pending(): number
	return #queue
end

return PopupQueue
