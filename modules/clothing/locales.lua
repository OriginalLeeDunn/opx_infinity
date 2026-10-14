--- Player-facing text for the strip row, every refusal and the command help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A store's LABEL is the operator's own words and lives in config, not
-- here.
--
-- The room a store opens draws its own strings (`wardrobe.*`, owned by the
-- appearance module): a store adds a door and no vocabulary for what is behind
-- it.

local EN = {
	['clothing.title'] = 'CLOTHING',

	['clothing.key.use'] = 'Open fitting room',
	['clothing.prompt'] = 'Open fitting room',

	['clothing.refused'] = 'That could not be done.',

	['clothing.noSuchStore'] = 'There is no clothing store here.',
	['clothing.noPosition'] = 'Your position could not be read.',
	['clothing.captureFailed'] = 'That store could not be saved.',
	['clothing.noWardrobe'] = 'The fitting room is unavailable on this server.',
	['clothing.wardrobeRefused'] = 'The fitting room cannot open right now.',

	['clothing.help.add'] = 'Put a clothing store marker where you are standing.',
	['clothing.help.addKey'] = 'durable name for the store, e.g. store_jinguji',
	['clothing.help.addLabel'] = 'what players read; the name itself when omitted',
	['clothing.help.remove'] = 'Delete a captured store. A store from config is not removable here.',
	['clothing.help.removeKey'] = 'the name the store was captured under',
	['clothing.help.list'] = 'Show every clothing store: position, bucket and where it comes from.',
}

local FR = {
	['clothing.title'] = 'VÊTEMENTS',

	['clothing.key.use'] = "Ouvrir la cabine d'essayage",
	['clothing.prompt'] = "Ouvrir la cabine d'essayage",

	['clothing.refused'] = "Cela n'a pas pu être fait.",

	['clothing.noSuchStore'] = "Il n'y a pas de boutique de vêtements ici.",
	['clothing.noPosition'] = "Votre position n'a pas pu être lue.",
	['clothing.captureFailed'] = "Cette boutique n'a pas pu être enregistrée.",
	['clothing.noWardrobe'] = "La cabine d'essayage est indisponible sur ce serveur.",
	['clothing.wardrobeRefused'] = "La cabine d'essayage ne peut pas s'ouvrir pour le moment.",

	['clothing.help.add'] = 'Place un marqueur de boutique de vêtements là où vous êtes.',
	['clothing.help.addKey'] = 'nom durable de la boutique, ex. store_jinguji',
	['clothing.help.addLabel'] = 'ce que lisent les joueurs ; le nom si omis',
	['clothing.help.remove'] = "Supprime une boutique capturée. Une boutique de config ne l'est pas ici.",
	['clothing.help.removeKey'] = 'le nom sous lequel la boutique a été capturée',
	['clothing.help.list'] = "Affiche chaque boutique : position, bucket et origine.",
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
