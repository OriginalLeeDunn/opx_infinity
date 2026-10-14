--- French player-facing text and refusal codes.
-- @author dop42

OPX.Locale.Register('fr', {
	['error.unavailable'] = "Ce n'est pas disponible pour le moment.",
	['error.badRequest'] = "Cette requête n'a pas pu être lue.",
	['error.payloadRefused'] = 'Cette réponse était trop volumineuse pour être affichée.',
	['error.rpc_timeout'] = 'Cela a pris trop de temps. Réessayez.',
	['error.rpc_failed'] = "Cela n'a pas abouti.",
	['error.tooFast'] = 'Doucement.',
	['error.noPermission'] = 'Vous ne pouvez pas faire cela.',
	['error.incapacitated'] = 'Pas pendant que vous êtes à terre.',
	['money.amount'] = '{amount} {currency}',
	['money.separator'] = ' ',
	['money.type.EDDIES'] = '€$',
	['money.type.BANK'] = '€$ (banque)',
	['notify.kind.info'] = 'INFO',
	['notify.kind.success'] = 'FAIT',
	['notify.kind.warning'] = 'ATTENTION',
	['notify.kind.error'] = 'ÉCHEC',
})

-- The creator surface: what an export answers another resource when it refuses.
-- See core/server/exports.lua and core/client/exports.lua.
OPX.Locale.Register('fr', {
	['export.callerDenied'] = "Cette ressource n'est pas autorisée à faire cet appel.",
	['export.badArgument'] = "Un argument de cet appel n'a pas pu être lu.",
	['export.booting'] = 'Le serveur démarre encore. Réessayez dans un instant.',
	['export.mustAwait'] = "Cet appel atteint la base de données : faites-le avec Open77.exports.call et attendez-le.",
	['export.badValue'] = "Cette valeur n'est pas une donnée simple : booléens, nombres, texte et tables de ceux-ci.",
	['export.tooLarge'] = "Cette valeur dépasse la taille que ce serveur accorde à une ressource.",
	['export.notSubscribable'] = "Cet événement n'est pas de ceux auxquels une autre ressource peut s'abonner.",
	['export.ownerTaken'] = "Cette ressource porte le nom d'un module de ce serveur, dont elle partagerait les lignes.",
	['export.duplicate'] = "Ce message exact vient d'être montré à ce joueur.",
	['export.usableTaken'] = "Un autre propriétaire gère déjà l'utilisation de cet objet.",
})

-- Weather: the status line a player reads, the command usage lines and every
-- refusal code the authority can answer.
OPX.Locale.Register('fr', {
	['weather.title'] = 'MÉTÉO',

	['weather.status'] = 'Il est {time}. Une journée dure {minutes} minutes réelles. Le ciel est {weather}.',
	['weather.status.clockHeld'] = "L'horloge est figée.",
	['weather.status.scheduleHeld'] = 'Le cycle météo est figé.',
	['weather.status.nextRoll'] = 'Prochain tirage dans {seconds}s.',
	['weather.status.revision'] = 'Révision {revision}.',
	['weather.status.degraded'] = "Aucun préréglage météo utilisable n'est configuré.",

	['weather.presets.header'] = 'préréglages météo (nom / préréglage moteur / poids / secondes) :',
	['weather.presets.row'] = '  {name} {preset} p={weight} {min}..{max}s  transition {transition}s',

	['weather.usage.set'] = 'utilisation : <preset> [transitionSeconds]',
	['weather.usage.next'] = 'utilisation : aucun argument',
	['weather.usage.freeze'] = 'utilisation : <on|off>',
	['weather.usage.time'] = 'utilisation : <HH:MM[:SS]>',
	['weather.usage.timeFreeze'] = 'utilisation : <on|off>',
	['weather.usage.dayLength'] = 'utilisation : <realMinutes>',
	['weather.usage.wait'] = 'utilisation : <heures>',

	['weather.error.invalidTime'] = "Ce n'est pas une heure valide. Utilisez HH:MM ou HH:MM:SS.",
	['weather.error.invalidDayLength'] = 'Une journée dure entre 1 minute et 7 jours.',
	['weather.error.dayTooShort'] = "Cette journée est trop courte pour qu'un client la suive.",
	['weather.error.unknownPreset'] = "Ce préréglage météo n'existe pas.",
	['weather.error.presetHint'] = "Ce préréglage météo n'existe pas. Lancez {command} pour voir la liste.",
	['weather.error.invalidTransition'] = 'Une transition dure entre 0 et 300 secondes.',
	['weather.error.noPresets'] = "Aucun préréglage météo n'est configuré.",
	['weather.error.unknown'] = "Cette action n'a pas abouti.",
	['weather.error.invalidHours'] = 'Attendez entre 1 et 23 heures entières.',
	['weather.error.playersOnly'] = 'Seul un joueur en jeu peut avancer sa propre horloge.',
	['weather.wait.done'] = "Votre horloge avance de {hours} h, dans votre jeu seulement. L'heure commune revient dans 20 minutes.",

	['weather.help.status'] = "Affiche l'heure et la météo synchronisées.",
	['weather.help.presets'] = 'Liste les préréglages météo configurés.',
	['weather.help.set'] = 'Passe à un préréglage météo.',
	['weather.help.set.preset'] = 'parmi {names}',
	['weather.help.set.seconds'] = 'durée de transition ; omettre pour celle du préréglage',
	['weather.help.next'] = 'Tire tout de suite dans la table météo pondérée.',
	['weather.help.freeze'] = 'Fige ou relance le cycle météo.',
	['weather.help.onOff'] = 'on le fige, off le relance',
	['weather.help.time'] = "Règle l'horloge de référence.",
	['weather.help.time.value'] = 'sur 24 heures, par exemple 21:30',
	['weather.help.timeFreeze'] = "Fige ou relance l'horloge.",
	['weather.help.dayLength'] = "Définit la durée d'une journée en minutes réelles.",
	['weather.help.dayLength.minutes'] = '180 correspond à la cadence du moteur',
	['weather.help.wait'] = "Avancez votre propre horloge, pour l'attente d'une mission.",
	['weather.help.wait.hours'] = 'heures entières, de 1 à 23',
})
