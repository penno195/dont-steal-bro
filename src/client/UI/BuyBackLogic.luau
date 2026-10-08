--!strict
-- The streak buy-back offer's screen rules (design-decisions.md Q7,
-- "buying back a streak"), kept free of Roblox calls so they're tested
-- headlessly (tests/BuyBackLogic.spec.luau). BuyBackController draws
-- what this decides.
--
-- WHERE IT SHOWS. The offer lasts until the player's next race starts,
-- so it appears in two places:
--   * the end screen: the card opens by itself once, a few seconds
--     after the Results screen comes up, so the streak card lands first;
--   * the Hub: a "Save streak" button that reopens the card. It never
--     opens by itself there - the player has usually just said no.
-- The server already holds the offer back until a round's Results, so
-- nothing here has to keep it secret.
--
-- THE PRICE is what Roblox reports for the product (managed pricing can
-- move it), falling back to the config's display price until that
-- answer arrives. Roblox's own prompt always shows the real charge.

local BuyBackLogic = {}

-- StoreState.buyBack, as StoreService sends it.
export type Offer = {
	key: string,
	streak: number,
	robuxPrice: number,
}

-- How long the end screen shows before the card opens over it.
BuyBackLogic.REVEAL_WAIT = 4

-- Round states with a screen of their own (MenuController.IN_PLAY).
local IN_PLAY: { [string]: boolean } = {
	Loading = true,
	Intro = true,
	Race = true,
	Qualified = true,
	DecisionStudio = true,
}

-- Reads StoreState.buyBack defensively: a malformed payload is no offer.
function BuyBackLogic.read(payload: any): Offer?
	if type(payload) ~= "table" then
		return nil
	end
	local offer = payload.buyBack
	if
		type(offer) ~= "table"
		or type(offer.key) ~= "string"
		or type(offer.streak) ~= "number"
		or offer.streak < 1
		or type(offer.robuxPrice) ~= "number"
	then
		return nil
	end
	return { key = offer.key, streak = offer.streak, robuxPrice = offer.robuxPrice }
end

-- One offer's identity: a new loss is a new offer, even at the same tier.
-- Only a streak and a tier are known client-side, so a second loss of
-- the same streak counts as the same offer - harmless, since the card
-- opens on its own at most once per Results screen anyway.
function BuyBackLogic.id(offer: Offer): string
	return string.format("%s:%d", offer.key, offer.streak)
end

-- Whether the end screen should open the card now. `shownFor` is the
-- offer id the card last opened for by itself.
function BuyBackLogic.shouldAutoOpen(offer: Offer?, menu: string?, resultsOpenFor: number, shownFor: string?): boolean
	if offer == nil or menu ~= "Results" then
		return false
	end
	return resultsOpenFor >= BuyBackLogic.REVEAL_WAIT and shownFor ~= BuyBackLogic.id(offer)
end

-- Whether the Hub's "Save streak" button shows: an offer, the Hub, and
-- nothing else on screen.
function BuyBackLogic.buttonVisible(offer: Offer?, isHub: boolean, menu: string?, roundState: string?): boolean
	return offer ~= nil and isHub and menu == nil and not IN_PLAY[roundState or ""]
end

function BuyBackLogic.price(offer: Offer, livePrice: number?): number
	return if livePrice ~= nil and livePrice > 0 then livePrice else offer.robuxPrice
end

function BuyBackLogic.buyLabel(offer: Offer, livePrice: number?): string
	return string.format("Save it for %d R$", BuyBackLogic.price(offer, livePrice))
end

function BuyBackLogic.buttonLabel(offer: Offer): string
	return string.format("Save streak %d", offer.streak)
end

function BuyBackLogic.title(offer: Offer): string
	return string.format("Save your streak of %d?", offer.streak)
end

function BuyBackLogic.body(offer: Offer): string
	return string.format(
		"Buy it back and carry on from %d instead of 0. The offer ends when your next race starts.",
		offer.streak
	)
end

-- What to say when StoreState changes while a buy-back is being bought:
-- the offer gone means the receipt landed and the streak is back.
function BuyBackLogic.landed(buyingKey: string?, before: Offer?, after: Offer?): string?
	if buyingKey == nil or before == nil or before.key ~= buyingKey or after ~= nil then
		return nil
	end
	return string.format("Streak saved: you're back on %d.", before.streak)
end

return BuyBackLogic
