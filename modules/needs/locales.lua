--- Player-facing text owned by the needs module.
-- @author dop42
--
-- Every word on the strip is a chip label the calling module supplied, so that
-- module is where it is translated. What is here is the staff command's.

OPX.Locale.Register('en', {
	['needs.help.set'] = "Set a player's need to a value",
	['needs.help.player'] = 'Player id',
	['needs.help.need'] = 'hunger, thirst, stamina or streetCred',
	['needs.help.value'] = "The new value, clamped to the need's bounds",
	['needs.usage.set'] = 'usage: <player> <need> <value>',
	['needs.refused'] = 'The need was not set: {reason}',
	['needs.done.set'] = '{need} is now {value} for player {player}.',
})
OPX.Locale.Register('fr', {
	['needs.help.set'] = "Régler un besoin d'un joueur à une valeur",
	['needs.help.player'] = 'Identifiant du joueur',
	['needs.help.need'] = 'hunger, thirst, stamina ou streetCred',
	['needs.help.value'] = 'La nouvelle valeur, bornée aux limites du besoin',
	['needs.usage.set'] = 'usage : <joueur> <besoin> <valeur>',
	['needs.refused'] = "Le besoin n'a pas été réglé : {reason}",
	['needs.done.set'] = '{need} vaut maintenant {value} pour le joueur {player}.',
})
