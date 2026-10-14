--- Player-facing text for the down screen and its refusals.
-- @author dop42
--
-- The keys keep the `medic.` prefix they were written under, so a view already
-- drawing them needs no rewriting. The catalogues are also kept on the module
-- table: the server compares them at start and names a key present in one and
-- missing from the other.

local M = OPX.Modules.Get('downed')

local EN = {
	['medic.screen.eyebrow'] = 'BIOMONITOR // NEURAL LINK DEGRADED',
	['medic.screen.title'] = 'FLATLINE',
	['medic.screen.subtitle'] = 'Critical vitals. You are down.',
	['medic.screen.vitals'] = 'VITALS',
	['medic.screen.bpm'] = 'BPM',
	['medic.screen.down'] = 'DOWN FOR',
	['medic.screen.signal'] = 'DISTRESS SIGNAL',
	['medic.screen.signalOff'] = 'NOT SENT',
	['medic.screen.signalOn'] = 'BROADCASTING',

	['medic.wait.label'] = 'CALL FOR HELP',
	['medic.wait.hint'] = 'Broadcast a distress signal and hold on.',
	['medic.wait.active'] = 'SIGNAL SENT',
	['medic.wait.activeHint'] = 'Distress signal sent. Stay with us.',

	['medic.giveUp.label'] = 'GIVE UP',
	['medic.giveUp.hint'] = 'Hold to wake up at the nearest medical center.',
	['medic.giveUp.locked'] = 'Available in {time}',
	['medic.giveUp.holding'] = 'KEEP HOLDING',

	['medic.refused.too_soon'] = 'Not yet. Hold on a little longer.',
	['medic.refused.no_hospital'] = 'No medical center is configured.',
	['medic.refused.respawn_refused'] = 'The medical center could not take you. Try again.',
	['medic.refused.not_incarnated'] = 'Your body is not in the world yet.',
	['medic.refused.gate_closed'] = 'Still joining; try again in a moment.',
	['medic.refused.gate_unreadable'] = 'The server cannot move you right now.',
	['medic.refused.failed'] = 'That could not be done.',

	['medic.wait.paged'] = '{count} Trauma Team medic(s) paged. Stay with us.',
	['medic.wait.nobody'] = 'No Trauma Team medic is on duty. Hold on, or give up when it unlocks.',

	['medic.notice.treating'] = '{name} of the Trauma Team is working on you.',
	['medic.notice.stopped'] = 'The medic stopped. Hold on.',
	['medic.notice.teamInbound'] = 'The Trauma Team is on its way: their AV is inbound.',
	['medic.notice.teamTreating'] = 'A Trauma Team medic is working on you.',

	['medic.key.treat'] = 'Trauma Team: treat a downed player',
	['medic.help.treat'] = 'Treat the downed player nearest to you (Trauma Team, on duty)',
	['medic.row.treat'] = 'Treat {name}',
	['medic.page.title'] = 'TRAUMA TEAM // DISTRESS SIGNAL',
	['medic.page.body'] = '{name} is down near {x}, {y}. The pin is on your map.',
	['medic.page.pin'] = 'Distress: {name}',
	['medic.treat.bar'] = 'Treating {name}',
	['medic.treat.done'] = '{name} is back on their feet.',
	['medic.treat.paid'] = '{name} is back on their feet. {amount} paid into {account}.',
	['medic.treat.refused.off'] = 'The Trauma Team is not in service on this server.',
	['medic.treat.refused.no_patient'] = 'Nobody is down within reach.',
	['medic.treat.refused.self'] = 'You cannot treat yourself.',
	['medic.treat.refused.not_medic'] = 'Only an on-duty Trauma Team medic can do that.',
	['medic.treat.refused.down'] = 'You are down yourself.',
	['medic.treat.refused.busy'] = 'You are already treating somebody.',
	['medic.treat.refused.cooldown'] = 'Catch your breath first.',
	['medic.treat.refused.not_down'] = 'They do not need a medic any more.',
	['medic.treat.refused.taken'] = 'Another medic is already treating them.',
	['medic.treat.refused.no_position'] = 'Their position could not be read.',
	['medic.treat.refused.too_far'] = 'Get closer to the body.',
	['medic.treat.refused.too_soon'] = 'The treatment was cut short.',
	['medic.treat.refused.nothing_running'] = 'No treatment is running.',
	['medic.treat.refused.revive_refused'] = 'The revive did not take. Try again.',
	['medic.treat.refused.patient_up'] = 'They are already back on their feet.',
	['medic.treat.refused.medic_gone'] = 'The treatment stopped.',
	['medic.treat.refused.cancelled'] = 'Treatment cancelled.',
	['medic.treat.refused.interrupted'] = 'Treatment interrupted.',
	['medic.treat.refused.stopped'] = 'Treatment stopped.',
	['medic.treat.refused.no_bar'] = 'The treatment could not start here.',
	['medic.treat.refused.failed'] = 'That could not be done.',
}

local FR = {
	['medic.screen.eyebrow'] = 'BIOMONITEUR // LIAISON NEURALE DÉGRADÉE',
	['medic.screen.title'] = 'FLATLINE',
	['medic.screen.subtitle'] = 'Signes vitaux critiques. Vous êtes à terre.',
	['medic.screen.vitals'] = 'SIGNES VITAUX',
	['medic.screen.bpm'] = 'BPM',
	['medic.screen.down'] = 'À TERRE DEPUIS',
	['medic.screen.signal'] = 'SIGNAL DE DÉTRESSE',
	['medic.screen.signalOff'] = 'NON ÉMIS',
	['medic.screen.signalOn'] = 'EN ÉMISSION',

	['medic.wait.label'] = 'APPELER LES SECOURS',
	['medic.wait.hint'] = 'Émettre un signal de détresse et tenir bon.',
	['medic.wait.active'] = 'SIGNAL ÉMIS',
	['medic.wait.activeHint'] = 'Signal de détresse émis. Restez avec nous.',

	['medic.giveUp.label'] = 'ABANDONNER',
	['medic.giveUp.hint'] = 'Maintenir pour vous réveiller au centre médical le plus proche.',
	['medic.giveUp.locked'] = 'Disponible dans {time}',
	['medic.giveUp.holding'] = 'CONTINUEZ DE MAINTENIR',

	['medic.refused.too_soon'] = 'Pas encore. Tenez encore un peu.',
	['medic.refused.no_hospital'] = "Aucun centre médical n'est configuré.",
	['medic.refused.respawn_refused'] = "Le centre médical n'a pas pu vous prendre. Réessayez.",
	['medic.refused.not_incarnated'] = "Votre corps n'est pas encore dans le monde.",
	['medic.refused.gate_closed'] = 'Connexion en cours ; réessayez dans un instant.',
	['medic.refused.gate_unreadable'] = "Le serveur ne peut pas vous déplacer pour l'instant.",
	['medic.refused.failed'] = "Cette action n'a pas abouti.",

	['medic.wait.paged'] = '{count} médecin(s) du Trauma Team alerté(s). Restez avec nous.',
	['medic.wait.nobody'] = "Aucun médecin du Trauma Team n'est en service. Tenez bon, ou abandonnez quand c'est possible.",

	['medic.notice.treating'] = '{name}, du Trauma Team, s\'occupe de vous.',
	['medic.notice.stopped'] = "Le médecin s'est arrêté. Tenez bon.",
	['medic.notice.teamInbound'] = "Le Trauma Team arrive : leur AV est en approche.",
	['medic.notice.teamTreating'] = "Un médecin du Trauma Team s'occupe de vous.",

	['medic.key.treat'] = 'Trauma Team : soigner un joueur à terre',
	['medic.help.treat'] = 'Soigner le joueur à terre le plus proche (Trauma Team, en service)',
	['medic.row.treat'] = 'Soigner {name}',
	['medic.page.title'] = 'TRAUMA TEAM // SIGNAL DE DÉTRESSE',
	['medic.page.body'] = '{name} est à terre près de {x}, {y}. Le repère est sur votre carte.',
	['medic.page.pin'] = 'Détresse : {name}',
	['medic.treat.bar'] = 'Soins : {name}',
	['medic.treat.done'] = '{name} est de nouveau sur pied.',
	['medic.treat.paid'] = '{name} est de nouveau sur pied. {amount} versés sur {account}.',
	['medic.treat.refused.off'] = "Le Trauma Team n'est pas en service sur ce serveur.",
	['medic.treat.refused.no_patient'] = "Personne n'est à terre à portée.",
	['medic.treat.refused.self'] = 'Vous ne pouvez pas vous soigner vous-même.',
	['medic.treat.refused.not_medic'] = 'Seul un médecin du Trauma Team en service peut faire cela.',
	['medic.treat.refused.down'] = 'Vous êtes vous-même à terre.',
	['medic.treat.refused.busy'] = "Vous soignez déjà quelqu'un.",
	['medic.treat.refused.cooldown'] = "Reprenez d'abord votre souffle.",
	['medic.treat.refused.not_down'] = "Cette personne n'a plus besoin de médecin.",
	['medic.treat.refused.taken'] = 'Un autre médecin la soigne déjà.',
	['medic.treat.refused.no_position'] = "Sa position n'a pas pu être lue.",
	['medic.treat.refused.too_far'] = 'Approchez-vous du corps.',
	['medic.treat.refused.too_soon'] = 'Les soins ont été interrompus.',
	['medic.treat.refused.nothing_running'] = "Aucun soin n'est en cours.",
	['medic.treat.refused.revive_refused'] = "La réanimation n'a pas pris. Réessayez.",
	['medic.treat.refused.patient_up'] = 'Cette personne est déjà sur pied.',
	['medic.treat.refused.medic_gone'] = 'Les soins se sont arrêtés.',
	['medic.treat.refused.cancelled'] = 'Soins annulés.',
	['medic.treat.refused.interrupted'] = 'Soins interrompus.',
	['medic.treat.refused.stopped'] = 'Soins arrêtés.',
	['medic.treat.refused.no_bar'] = 'Les soins ne peuvent pas commencer ici.',
	['medic.treat.refused.failed'] = "Cette action n'a pas abouti.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
