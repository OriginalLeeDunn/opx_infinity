--- Player-facing text for the strip row, every refusal and the command help.
-- @author dop42
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English: they are read by an operator in a journal, not by a player on a
-- screen.
--
-- A TELEPORT'S LABELS AND ITS REASON ARE THE OPERATOR'S OWN WORDS and are NOT
-- here. They live in `config/teleports.lua`, they travel on the wire as written,
-- and they are interpolated into `{place}` and `{reason}` below untranslated --
-- exactly as `config/elevators.lua`'s REASON and LABEL are. A server that runs
-- in French names its rooftops in French by writing them that way.

local EN = {
	['teleports.title'] = 'TELEPORT',

	['teleports.key.use'] = 'Use teleport',
	['teleports.prompt'] = 'Go to {place}',
	['teleports.prompt.locked'] = 'Go to {place} (locked)',

	['teleports.arrived'] = 'You arrived at {place}.',

	['teleports.refused'] = 'That trip did not go through. Try again.',
	['teleports.locked'] = 'You do not have access to this teleport.',
	-- The operator's own sentence, shown instead of the line above whenever they
	-- wrote one. It is what makes a locked teleport say why.
	['teleports.lockedReason'] = '{reason}',

	['teleports.noSuchTeleport'] = 'There is no teleport here.',
	['teleports.tooFar'] = 'You are not standing on the teleport.',
	['teleports.noPosition'] = 'Your position could not be read.',
	['teleports.inFlight'] = 'You are already on your way.',
	['teleports.busy'] = 'Finish what you are doing first.',
	['teleports.downed'] = 'Not while you are down.',
	['teleports.inVehicle'] = 'Step out of the vehicle first.',
	['teleports.notAlive'] = 'Not while you are dead.',
	['teleports.notReady'] = 'You are not in the world yet.',
	['teleports.badDestination'] = 'That destination is not a place. Tell a staff member.',
	['teleports.neverArrived'] = 'You did not arrive. Nothing was moved; tell a staff member.',
	['teleports.unavailable'] = 'Teleports are unavailable on this server.',

	['teleports.help.where'] = 'Show every teleport: both ends, its gate and how its trips ' ..
		'have gone.',
	['teleports.help.whereKey'] = 'one teleport to show; all of them when omitted ({keys})',
}

local FR = {
	['teleports.title'] = 'TÉLÉPORTATION',

	['teleports.key.use'] = 'Utiliser la téléportation',
	['teleports.prompt'] = 'Aller à {place}',
	['teleports.prompt.locked'] = 'Aller à {place} (verrouillé)',

	['teleports.arrived'] = 'Vous êtes arrivé à {place}.',

	['teleports.refused'] = "Ce trajet n'a pas abouti. Réessayez.",
	['teleports.locked'] = "Vous n'avez pas accès à cette téléportation.",
	['teleports.lockedReason'] = '{reason}',

	['teleports.noSuchTeleport'] = "Il n'y a pas de téléportation ici.",
	['teleports.tooFar'] = "Vous n'êtes pas sur la téléportation.",
	['teleports.noPosition'] = "Votre position n'a pas pu être lue.",
	['teleports.inFlight'] = 'Vous êtes déjà en route.',
	['teleports.busy'] = "Terminez d'abord ce que vous faites.",
	['teleports.downed'] = 'Pas pendant que vous êtes à terre.',
	['teleports.inVehicle'] = "Sortez d'abord du véhicule.",
	['teleports.notAlive'] = 'Pas pendant que vous êtes mort.',
	['teleports.notReady'] = "Vous n'êtes pas encore dans le monde.",
	['teleports.badDestination'] = "Cette destination n'est pas un lieu. Prévenez un membre de l'équipe.",
	['teleports.neverArrived'] = "Vous n'êtes pas arrivé. Rien n'a bougé ; prévenez un membre de l'équipe.",
	['teleports.unavailable'] = 'Les téléportations sont indisponibles sur ce serveur.',

	['teleports.help.where'] = 'Affiche chaque téléportation : ses deux extrémités, son accès ' ..
		'et ses trajets.',
	['teleports.help.whereKey'] = 'une téléportation à afficher ; toutes si omis ({keys})',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
