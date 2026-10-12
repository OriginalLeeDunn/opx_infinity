--- Player-facing text for the radio: the menu, the air, the refusals.
-- @author dop42
--
-- A channel's LABEL and SHORT are the operator's words (config/radio.lua) and
-- are never translated.

local EN = {
	['radio.title'] = 'RADIO',
	['radio.key.talk'] = 'Radio: push to talk',

	['radio.menu.power'] = 'Power',
	['radio.menu.on'] = 'ON',
	['radio.menu.off'] = 'OFF',
	['radio.menu.channels'] = 'Channels',
	['radio.menu.noHandset'] = 'No radio in your bag',
	['radio.menu.join'] = 'Join',
	['radio.menu.leave'] = 'Leave',
	['radio.menu.select'] = 'Talk on this channel',
	['radio.menu.mute'] = 'Mute',
	['radio.menu.none'] = 'No channel for your job right now',
	['radio.menu.close'] = 'Close',

	['radio.status.off'] = 'OFF',
	['radio.status.listening'] = 'LISTENING',
	['radio.status.active'] = 'TX',
	['radio.status.muted'] = 'MUTED',

	['radio.air.on'] = 'On air: {channel}',
	['radio.air.no_channel'] = 'No channel selected: open the radio (/opx.radio).',
	['radio.air.down'] = 'You cannot key the radio right now.',
	['radio.air.held_too_long'] = 'Transmission cut: the key was held too long.',
	['radio.air.channel_changed'] = 'Channel changed: key up again.',
	['radio.air.channel_left'] = 'You left that channel.',
	['radio.air.power_off'] = 'The radio is off.',
	['radio.air.voice_refused'] = 'The channel did not answer.',

	['radio.error.invalid'] = 'That was refused.',
	['radio.error.too_fast'] = 'Slow down.',
	['radio.error.not_loaded'] = 'You need a character for that.',
	['radio.error.unknown_channel'] = 'There is no such channel.',
	['radio.error.not_allowed'] = 'Your badge does not open that channel.',
	['radio.error.power_off'] = 'Turn the radio on first.',
	['radio.error.no_handset'] = 'You need a radio in your bag.',
	['radio.error.full'] = 'Your radio cannot hold another channel.',
	['radio.error.voice_refused'] = 'The channel did not answer. Try again.',
	['radio.error.not_joined'] = 'Join that channel first.',
	['radio.error.no_menu'] = 'The radio menu is not available right now.',

	['radio.help.radio'] = 'Open your radio: channels, mute, power',
	['radio.help.channels'] = 'List the radio channels and who is on them',
}

local FR = {
	['radio.title'] = 'RADIO',
	['radio.key.talk'] = 'Radio : appuyer pour parler',

	['radio.menu.power'] = 'Alimentation',
	['radio.menu.on'] = 'ON',
	['radio.menu.off'] = 'OFF',
	['radio.menu.channels'] = 'Canaux',
	['radio.menu.noHandset'] = 'Pas de radio dans votre sac',
	['radio.menu.join'] = 'Rejoindre',
	['radio.menu.leave'] = 'Quitter',
	['radio.menu.select'] = 'Parler sur ce canal',
	['radio.menu.mute'] = 'Couper le son',
	['radio.menu.none'] = 'Aucun canal pour votre métier pour l\'instant',
	['radio.menu.close'] = 'Fermer',

	['radio.status.off'] = 'OFF',
	['radio.status.listening'] = 'ÉCOUTE',
	['radio.status.active'] = 'TX',
	['radio.status.muted'] = 'COUPÉ',

	['radio.air.on'] = 'En émission : {channel}',
	['radio.air.no_channel'] = 'Aucun canal choisi : ouvrez la radio (/opx.radio).',
	['radio.air.down'] = 'Vous ne pouvez pas utiliser la radio maintenant.',
	['radio.air.held_too_long'] = 'Émission coupée : touche tenue trop longtemps.',
	['radio.air.channel_changed'] = 'Canal changé : rappuyez pour parler.',
	['radio.air.channel_left'] = 'Vous avez quitté ce canal.',
	['radio.air.power_off'] = 'La radio est éteinte.',
	['radio.air.voice_refused'] = 'Le canal n\'a pas répondu.',

	['radio.error.invalid'] = 'Refusé.',
	['radio.error.too_fast'] = 'Doucement.',
	['radio.error.not_loaded'] = 'Il vous faut un personnage pour ça.',
	['radio.error.unknown_channel'] = 'Ce canal n\'existe pas.',
	['radio.error.not_allowed'] = 'Votre badge n\'ouvre pas ce canal.',
	['radio.error.power_off'] = 'Allumez d\'abord la radio.',
	['radio.error.no_handset'] = 'Il vous faut une radio dans votre sac.',
	['radio.error.full'] = 'Votre radio ne peut pas tenir un canal de plus.',
	['radio.error.voice_refused'] = 'Le canal n\'a pas répondu. Réessayez.',
	['radio.error.not_joined'] = 'Rejoignez d\'abord ce canal.',
	['radio.error.no_menu'] = 'Le menu radio n\'est pas disponible pour le moment.',

	['radio.help.radio'] = 'Ouvrir votre radio : canaux, son, alimentation',
	['radio.help.channels'] = 'Lister les canaux radio et qui les écoute',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
