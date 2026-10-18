--!strict
-- The tap sound every button makes (owner, 2026-10-18): one click for a
-- button or tab, another for an X or Close. Base.interactive plays it,
-- so every component built on it gets it for free. AudioController
-- binds the player at start, the same split as Feel: components never
-- require a controller.

local Click = {}

-- "none" for a button with its own feedback (a task's inputs, whose
-- steps already sound through TaskStep / TaskFail).
export type Kind = "click" | "close" | "none"

local CUE: { [Kind]: string } = { click = "UIClick", close = "UIClose" }

local player: ((cueId: string) -> ())? = nil

function Click.bind(play: (cueId: string) -> ())
	player = play
end

function Click.play(kind: Kind?)
	local key: Kind = kind or "click"
	local cueId = CUE[key]
	if cueId ~= nil and player ~= nil then
		player(cueId)
	end
end

-- A Close-labelled button or an X icon closes; anything else clicks.
function Click.kindFor(label: string?, icon: string?): Kind
	if label == "Close" or icon == "close" or icon == "close-button" then
		return "close"
	end
	return "click"
end

return Click
