--!strict
-- The first-time tutorial's pure rules (design-decisions.md, "the
-- first-time tutorial"). No Roblox API: tested headlessly.
--
-- Finishing the guided practice round pays GameConfig.tutorial's
-- reward once per account. DataService.claimTutorialReward makes the
-- "once": it sets the profile flag and applies these grants in one
-- mutation, so a crash keeps both or neither.

local TutorialLogic = {}

-- Structurally Validate.TutorialConfig's reward fields.
export type RewardConfig = {
	rewardCosmeticId: string,
	rewardCurrency: number,
	rewardPowerUps: { [string]: number },
}

-- Structurally StoreLogic.Grant (kept require-free).
export type Grant = {
	kind: "Currency" | "PowerUpStock" | "Cosmetic",
	amount: number?,
	powerUpId: string?,
	cosmeticId: string?,
}

-- What finishing pays. The cap is left out while its cosmetic is
-- disabled (no model yet): an invisible hat is no gift. Power-ups are
-- sorted by id so the change log reads the same every time.
function TutorialLogic.rewardGrants(config: RewardConfig, cosmeticEnabled: boolean): { Grant }
	local grants: { Grant } = {}
	if cosmeticEnabled then
		table.insert(grants, { kind = "Cosmetic", cosmeticId = config.rewardCosmeticId })
	end
	if config.rewardCurrency > 0 then
		table.insert(grants, { kind = "Currency", amount = config.rewardCurrency })
	end
	local ids: { string } = {}
	for id, count in config.rewardPowerUps do
		if count > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		table.insert(grants, { kind = "PowerUpStock", powerUpId = id, amount = config.rewardPowerUps[id] })
	end
	return grants
end

-- ===== the guided round (seam 3) ============================================
--
-- Owner's answers, 2026-10-15: the guided round has no race clock, the
-- bots never use power-ups, and they go easy - slower than usual, and
-- held off the finish line so the player always makes the top 3.

-- May a bot complete its LAST task now? Only while that still leaves a
-- top-3 seat for every human who hasn't finished. Once the humans are
-- done (or gone), the bots finish freely, which is what ends a race
-- with no clock. A held bot just keeps "working" at its station.
function TutorialLogic.botMayFinish(botsFinished: number, humansUnfinished: number, qualifierCount: number): boolean
	return humansUnfinished == 0 or botsFinished + humansUnfinished < qualifierCount
end

-- Structurally NPCLogic.SkillProfile (kept require-free).
export type SkillProfile = {
	id: string,
	weight: number,
	durationScale: number,
	moveSpeedScale: number,
}

-- A bot's usual profile, slowed for the guided round. A copy: the
-- shared config profile is never touched.
function TutorialLogic.easyProfile(profile: SkillProfile, durationScale: number, moveSpeedScale: number): SkillProfile
	return {
		id = profile.id,
		weight = profile.weight,
		durationScale = profile.durationScale * durationScale,
		moveSpeedScale = profile.moveSpeedScale * moveSpeedScale,
	}
end

return TutorialLogic
