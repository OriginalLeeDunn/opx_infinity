--- Player-facing text for the call card, the live chip, the eye rows and every
--- refusal.
-- @author dop42
--
-- EVERY NAME IN `Model.REASONS` HAS A `calls.error.<name>` LINE HERE, and that
-- is not a convention this file hopes somebody keeps. `OPX.RefusalKey` looks a
-- refusal code up in the catalogue and, when it is not there, downgrades it to
-- `error.unavailable` with a warning written to the server log -- so a refusal
-- with no line is a refusal the player is never actually told, and the only
-- trace is a journal line nobody is reading at the time. The test suite walks
-- `Model.REASONS` against both catalogues and fails on a name missing from
-- either.
--
-- Log lines, the audit trail and the refusal CODES themselves stay in English,
-- like every other module here: they are read by an operator in a journal, not
-- by a player on a screen.

local M = OPX.Modules.Get('calls')

local EN = {
	-- The incoming card and the live chip are gone with the eye rows they named;
	-- the hologram below is the whole feature, and their strings went with them.

	-- ── the rows on the eye ──────────────────────────────────────────────────
	-- One row is left: handing your contact to the player you are pointing at.
	['calls.row.share'] = 'Give my contact',

	-- ── the hologram ─────────────────────────────────────────────────────────
	-- The whole feature's vocabulary now: the eye rows above are gone and these
	-- replaced them. See `config/calls.lua`'s KEY block for why.
	['calls.key.holo'] = 'Open holocall',
	['calls.key.answer'] = 'Answer a holocall',
	['calls.key.decline'] = 'Decline or hang up a holocall',
	['calls.holo.incoming'] = 'Incoming call',
	['calls.holo.inCall'] = 'Call in progress',
	['calls.holo.eyebrow'] = 'NETWORK',
	['calls.holo.title'] = 'HOLOCALL',
	['calls.holo.close'] = 'CLOSE',
	['calls.holo.ringing'] = '{name} is calling you.',
	['calls.holo.sharing'] = '{name} wants to give you their contact.',
	-- The same offer under a line that already names the caller: the sphere's second line.
	['calls.holo.contactOffer'] = 'Wants to give you their contact.',
	['calls.holo.calling'] = 'Calling {name}...',
	['calls.holo.offering'] = 'Offering your contact...',
	-- The sphere's line under the callee's name, which already says who.
	['calls.holo.dialing'] = 'Calling...',
	['calls.holo.live'] = 'On a call with {names}.',
	['calls.holo.answer'] = 'ANSWER',
	['calls.holo.refuse'] = 'DECLINE',
	-- The share is a question, so its answers are a question's answers and not
	-- a call's. "le share contact devrais etre un input qui propose un yes or no".
	['calls.holo.yes'] = 'YES',
	['calls.holo.no'] = 'NO',
	['calls.holo.hangUp'] = 'HANG UP',
	-- Takes back what is ringing out, and leaves any live call alone.
	['calls.holo.withdraw'] = 'CANCEL',
	['calls.holo.call'] = 'CALL',
	['calls.holo.add'] = 'ADD',
	['calls.holo.share'] = 'SHARE',
	['calls.holo.tab.contacts'] = 'CONTACTS',
	['calls.holo.tab.recent'] = 'RECENT',
	['calls.holo.noContacts'] = 'No contacts yet. Ask someone nearby to give you theirs.',
	['calls.holo.noRecent'] = 'Nothing yet.',
	-- Four outcomes and four sentences, because "they did not pick up" and "you
	-- missed one" are the same event from two sides and a system that said the
	-- same thing to both would be telling one of them a small lie.
	['calls.holo.outcome.missed'] = 'Missed call',
	['calls.holo.outcome.unanswered'] = 'No answer',
	['calls.holo.outcome.declined'] = 'Declined',
	['calls.holo.outcome.refused'] = 'You declined',

	-- ── what happened ────────────────────────────────────────────────────────
	-- Caller id for somebody who is not in your contacts: never a name to a
	-- stranger.
	['calls.unknown'] = 'Unknown caller',
	['calls.answered'] = '{name} answered.',
	['calls.declined'] = '{name} declined the call.',
	['calls.joined'] = '{name} joined the call.',
	['calls.left'] = '{name} hung up.',
	['calls.ended'] = 'The call ended.',
	['calls.expired'] = '{name} did not answer.',
	['calls.contact.offered'] = '{name} offered you their contact.',
	['calls.contact.saved'] = '{name} is in your contacts.',
	['calls.contact.sent'] = 'Your contact was offered. Waiting for an answer.',
	['calls.contact.declined'] = 'Your contact offer was declined.',
	['calls.contact.unanswered'] = 'Your contact offer was not answered.',
	['calls.cutOff'] = 'The call could not go through: the other side left.',

	-- ── the refusals, one per name in `Model.REASONS` ────────────────────────
	['calls.error.badRequest'] = 'That request made no sense.',
	['calls.error.tooFast'] = 'Slow down.',
	['calls.error.self'] = 'You cannot call yourself.',
	['calls.error.noSuchPlayer'] = 'There is nobody there.',
	['calls.error.notReady'] = 'You are not in the world yet.',
	['calls.error.targetNotReady'] = 'They are not reachable right now.',
	['calls.error.notAlive'] = 'Not while you are down.',
	['calls.error.targetNotAlive'] = 'They cannot take a call right now.',
	['calls.error.alreadyInCall'] = 'You are already on a call.',
	['calls.error.targetInCall'] = 'They are already on a call.',
	['calls.error.alreadyPending'] = 'You already have a call out.',
	['calls.error.targetPending'] = 'Their line is busy.',
	['calls.error.notInCall'] = 'You are not on a call.',
	['calls.error.callFull'] = 'That call is full.',
	['calls.error.alreadyParticipant'] = 'They are already on this call.',
	['calls.error.noSuchInvite'] = 'There is no call waiting for you.',
	['calls.error.expired'] = 'That call already rang out.',
	['calls.error.tooFar'] = 'Stand closer to hand over a contact.',
	['calls.error.notContact'] = 'You can only call people in your contacts.',
	['calls.error.contactTooSoon'] = 'You already offered them your contact. Give them a moment.',
	['calls.error.unreadable'] = 'The server could not place that call. Try again.',
	['calls.error.offline'] = 'Not connected',
	['calls.error.contactsFull'] = 'Your contact list is full. Delete a contact to make room.',
	['calls.contact.forgotten'] = 'Contact deleted.',
	['calls.holo.forget'] = 'DELETE',
	['calls.holo.forgetConfirm'] = 'SURE?',
}

local FR = {
	-- ── la ligne de l'oeil ───────────────────────────────────────────────────
	['calls.row.share'] = 'Donner mon contact',

	-- ── l'hologramme ─────────────────────────────────────────────────────────
	['calls.key.holo'] = 'Ouvrir le holo-appel',
	['calls.key.answer'] = 'Répondre à un holo-appel',
	['calls.key.decline'] = 'Refuser ou raccrocher un holo-appel',
	['calls.holo.incoming'] = 'Appel entrant',
	['calls.holo.inCall'] = 'Appel en cours',
	['calls.holo.eyebrow'] = 'RÉSEAU',
	['calls.holo.title'] = 'HOLO-APPEL',
	['calls.holo.close'] = 'FERMER',
	['calls.holo.ringing'] = '{name} vous appelle.',
	['calls.holo.sharing'] = '{name} veut vous donner son contact.',
	['calls.holo.contactOffer'] = 'Veut vous donner son contact.',
	['calls.holo.calling'] = 'Appel vers {name}...',
	['calls.holo.offering'] = 'Proposition de votre contact...',
	['calls.holo.dialing'] = 'Appel sortant...',
	['calls.holo.live'] = 'En appel avec {names}.',
	['calls.holo.answer'] = 'RÉPONDRE',
	['calls.holo.refuse'] = 'REFUSER',
	['calls.holo.yes'] = 'OUI',
	['calls.holo.no'] = 'NON',
	['calls.holo.hangUp'] = 'RACCROCHER',
	['calls.holo.withdraw'] = 'ANNULER',
	['calls.holo.call'] = 'APPELER',
	['calls.holo.add'] = 'AJOUTER',
	['calls.holo.share'] = 'PARTAGER',
	['calls.holo.tab.contacts'] = 'CONTACTS',
	['calls.holo.tab.recent'] = 'RÉCENTS',
	['calls.holo.noContacts'] = "Aucun contact pour l'instant. Demandez à quelqu'un près de vous de vous donner le sien.",
	['calls.holo.noRecent'] = 'Rien pour le moment.',
	['calls.holo.outcome.missed'] = 'Appel manqué',
	['calls.holo.outcome.unanswered'] = 'Pas de réponse',
	['calls.holo.outcome.declined'] = 'Refusé',
	['calls.holo.outcome.refused'] = 'Vous avez refusé',

	['calls.unknown'] = 'Correspondant inconnu',
	['calls.answered'] = '{name} a répondu.',
	['calls.declined'] = "{name} a refusé l'appel.",
	['calls.joined'] = "{name} a rejoint l'appel.",
	['calls.left'] = '{name} a raccroché.',
	['calls.ended'] = "L'appel est terminé.",
	['calls.expired'] = "{name} n'a pas répondu.",
	['calls.contact.offered'] = '{name} vous propose son contact.',
	['calls.contact.saved'] = '{name} est dans vos contacts.',
	['calls.contact.sent'] = 'Votre contact a été proposé. En attente de réponse.',
	['calls.contact.declined'] = 'Votre proposition de contact a été refusée.',
	['calls.contact.unanswered'] = "Votre proposition de contact est restée sans réponse.",
	['calls.cutOff'] = "L'appel n'a pas pu aboutir : l'autre personne est partie.",

	['calls.error.badRequest'] = "Cette requête n'a aucun sens.",
	['calls.error.tooFast'] = 'Doucement.',
	['calls.error.self'] = 'Vous ne pouvez pas vous appeler vous-même.',
	['calls.error.noSuchPlayer'] = "Il n'y a personne.",
	['calls.error.notReady'] = "Vous n'êtes pas encore dans le monde.",
	['calls.error.targetNotReady'] = "Cette personne n'est pas joignable.",
	['calls.error.notAlive'] = 'Pas pendant que vous êtes à terre.',
	['calls.error.targetNotAlive'] = 'Cette personne ne peut pas répondre.',
	['calls.error.alreadyInCall'] = 'Vous êtes déjà en appel.',
	['calls.error.targetInCall'] = 'Cette personne est déjà en appel.',
	['calls.error.alreadyPending'] = 'Vous avez déjà un appel en cours.',
	['calls.error.targetPending'] = 'Sa ligne est occupée.',
	['calls.error.notInCall'] = "Vous n'êtes pas en appel.",
	['calls.error.callFull'] = 'Cet appel est complet.',
	['calls.error.alreadyParticipant'] = 'Cette personne est déjà sur cet appel.',
	['calls.error.noSuchInvite'] = "Aucun appel ne vous attend.",
	['calls.error.expired'] = 'Cet appel a déjà sonné dans le vide.',
	['calls.error.tooFar'] = 'Rapprochez-vous pour transmettre un contact.',
	['calls.error.notContact'] = "Vous ne pouvez appeler que vos contacts.",
	['calls.error.contactTooSoon'] = 'Vous lui avez déjà proposé votre contact. Laissez-lui un instant.',
	['calls.error.unreadable'] = "Le serveur n'a pas pu placer cet appel. Réessayez.",
	['calls.error.offline'] = 'Hors ligne',
	['calls.error.contactsFull'] = 'Votre liste de contacts est pleine. Supprimez un contact pour faire de la place.',
	['calls.contact.forgotten'] = 'Contact supprimé.',
	['calls.holo.forget'] = 'SUPPRIMER',
	['calls.holo.forgetConfirm'] = 'SÛR ?',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
