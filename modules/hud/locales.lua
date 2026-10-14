--- Player-facing text owned by the HUD.
-- @author dop42
--
-- Most of these are resolved by the PAGE and not here: a gauge label, a chip
-- caption and the two vehicle captions travel as keys and the page looks them up
-- in the catalogue it was handed at boot. The handful this module resolves
-- itself are the ones the page draws verbatim -- the speed unit, the voice
-- distance and the word on a key cap -- because each is a formatted sentence
-- rather than a name.

OPX.Locale.Register('en', {
	['hud.info.eyebrow'] = 'STATUS',

	['hud.gauge.health'] = 'HEALTH',
	['hud.gauge.armor'] = 'ARMOR',
	['hud.gauge.stamina'] = 'STAMINA',
	['hud.gauge.hunger'] = 'HUNGER',
	['hud.gauge.thirst'] = 'THIRST',

	['hud.info.job'] = 'JOB',
	['hud.info.cred'] = 'CRED',

	-- A money line's caption, by the purse's config id. Without one the HUD drew
	-- the raw id, so a French HUD read BANK.
	['hud.money.EDDIES'] = 'EDDIES',
	['hud.money.BANK'] = 'BANK',

	['hud.voice.state.idle'] = 'MIC',
	['hud.voice.state.detected'] = 'MIC',
	['hud.voice.state.talking'] = 'TX',
	['hud.voice.state.muted'] = 'MUTED',
	['hud.voice.state.offline'] = 'OFFLINE',
	['hud.voice.mode.whisper'] = 'WHISPER',
	['hud.voice.mode.normal'] = 'NORMAL',
	['hud.voice.mode.shout'] = 'SHOUT',
	['hud.voice.mode.proximity'] = 'RANGE',
	['hud.voice.distance'] = '{metres} M',
	['hud.voice.open'] = 'OPEN',

	['hud.vehicle.unit'] = 'KM/H',
	['hud.vehicle.integrity'] = 'INTEGRITY',
	['hud.vehicle.airborne'] = 'AIRBORNE',
	['hud.vehicle.fuel'] = 'FUEL',
})

OPX.Locale.Register('fr', {
	['hud.info.eyebrow'] = 'ÉTAT',

	['hud.gauge.health'] = 'SANTÉ',
	['hud.gauge.armor'] = 'ARMURE',
	['hud.gauge.stamina'] = 'ENDURANCE',
	['hud.gauge.hunger'] = 'FAIM',
	['hud.gauge.thirst'] = 'SOIF',

	['hud.info.job'] = 'MÉTIER',
	['hud.info.cred'] = 'CRED',

	['hud.money.EDDIES'] = 'EDDIES',
	['hud.money.BANK'] = 'BANQUE',

	['hud.voice.state.idle'] = 'MICRO',
	['hud.voice.state.detected'] = 'MICRO',
	['hud.voice.state.talking'] = 'TX',
	['hud.voice.state.muted'] = 'COUPÉ',
	['hud.voice.state.offline'] = 'HORS LIGNE',
	['hud.voice.mode.whisper'] = 'CHUCHOTÉ',
	['hud.voice.mode.normal'] = 'NORMAL',
	['hud.voice.mode.shout'] = 'CRIÉ',
	['hud.voice.mode.proximity'] = 'PORTÉE',
	['hud.voice.distance'] = '{metres} M',
	['hud.voice.open'] = 'OUVERT',

	['hud.vehicle.unit'] = 'KM/H',
	['hud.vehicle.integrity'] = 'INTÉGRITÉ',
	['hud.vehicle.airborne'] = 'EN VOL',
	['hud.vehicle.fuel'] = 'CARBURANT',
})
