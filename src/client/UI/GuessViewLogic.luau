--!strict
-- The pure half of the Guess Token picker (payoff-loop step 2c): a
-- knocked-out player's one guess at which finalist walks out of the
-- Decision Studio. No Roblox API, no requires; tested under Lune
-- (tests/GuessViewLogic.spec).
--
-- The server owns the guess (GuessService, GuessLogic.validate). This
-- only tracks what this client asked for and what the server said:
--
--   Open --Pick--> Sending --Ack--> Locked     (final, never changes)
--                     \--Timeout--> Refused    (final for the round)
--
-- FinaleGuessAccepted is the only way in to Locked, and its targetId
-- wins over whatever was tapped. No ack in time means the server
-- refused it (wrong state, already guessed, the window closed at the
-- outcome), so the picker says so and closes rather than resending: a
-- resend could only be refused again. A late ack still locks it in.
--
-- Nothing here is streak-related. The picker is the guesser's own and
-- names only finalists, so it shows nobody's streak (design-decisions.md
-- Q7 condition 1).

local GuessViewLogic = {}

export type Status = "Open" | "Sending" | "Locked" | "Refused"

export type Guess = {
	status: Status,
	targetId: number?, -- the tapped (Sending/Refused) or acked (Locked) finalist
}

export type Event = { type: "Pick", targetId: number } | { type: "Ack", targetId: number } | { type: "Timeout" }

-- Seconds to wait for FinaleGuessAccepted before reading the silence as
-- a refusal. Remotes are ordered and reliable, so this only has to beat
-- a slow round trip on a phone.
GuessViewLogic.ACK_TIMEOUT = 4

GuessViewLogic.OPEN = table.freeze({ status = "Open" } :: Guess)

function GuessViewLogic.step(guess: Guess, event: Event): Guess
	if event.type == "Pick" then
		if guess.status ~= "Open" then
			return guess
		end
		return table.freeze({ status = "Sending", targetId = event.targetId } :: Guess)
	elseif event.type == "Ack" then
		if guess.status == "Locked" then
			return guess -- one guess per round: a second ack changes nothing
		end
		return table.freeze({ status = "Locked", targetId = event.targetId } :: Guess)
	elseif event.type == "Timeout" then
		if guess.status ~= "Sending" then
			return guess
		end
		return table.freeze({ status = "Refused", targetId = guess.targetId } :: Guess)
	end
	return guess
end

-- Whether the picker is up at all. Only for someone who raced this
-- round and isn't a finalist, once the Studio has a phase, and until
-- the reveal starts (the server has closed the window by then; the
-- result is on the results screen).
function GuessViewLogic.visible(isFinalist: boolean, raced: boolean, hasPhase: boolean, revealed: boolean): boolean
	return raced and not isFinalist and hasPhase and not revealed
end

function GuessViewLogic.canPick(guess: Guess): boolean
	return guess.status == "Open"
end

-- How a finalist's card reads: the one picked (or being sent) is
-- marked, the rest dim once the guess is out of the player's hands.
export type CardState = "Pickable" | "Picked" | "Dimmed"

function GuessViewLogic.cardState(guess: Guess, finalistId: number): CardState
	if guess.status == "Open" then
		return "Pickable"
	end
	return if guess.targetId == finalistId then "Picked" else "Dimmed"
end

-- The picker's line under its title. `nameOf` names a finalist.
function GuessViewLogic.line(guess: Guess, nameOf: (id: number) -> string): string
	local status = guess.status
	if status == "Sending" then
		return "Placing your guess…"
	elseif status == "Locked" then
		local id = guess.targetId
		return string.format("Your guess: %s. Locked in.", if id then nameOf(id) else "?")
	elseif status == "Refused" then
		return "Your guess didn't go through this round."
	end
	return "Right, and a lone stealer or sharer wins you a streak shield."
end

function GuessViewLogic.title(guess: Guess): string
	return if guess.status == "Open" then "Who walks out?" else "Your Guess Token"
end

return GuessViewLogic
