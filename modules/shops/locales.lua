--- What the shops say, in both languages.
-- @author dop42
--
-- Every refusal a player can be shown has a sentence here. A code that reaches
-- `OPX.NotifyLocale` without one becomes `error.unavailable` with the real code
-- logged -- which is a safety net and not a plan, so the net is left unused.

local M = OPX.Modules.Get('shops')

local EN = {
	['shops.row'] = 'Open fitting room',

	-- Refusals. `no_such_shop`, `too_far`, `position_unknown`, `not_for_you` and `downed`
	-- are the five `shopAt` can answer and are prefixed with `shops.` by the
	-- caller, so their keys read oddly on purpose -- they are machine names.
	['shops.no_such_shop'] = 'There is no shop here.',
	['shops.too_far'] = 'You are not close enough to the counter.',
	['shops.position_unknown'] = 'Your position could not be read.',
	['shops.not_for_you'] = 'This shop does not serve you.',
	['shops.downed'] = 'Nobody serves you from the floor.',
	['shops.redeemAtShop'] = 'An outfit code is used at a clothing shop\'s counter.',
	['shops.redeemInRoom'] = 'Open the fitting room first: the outfit is tried on there, at this shop\'s prices.',

	['shops.unavailable'] = 'The fitting room is not available right now.',
	['shops.cannotDress'] = 'Those clothes would not go on.',
	['shops.cannotPay'] = 'You cannot afford that: {total} needed.',
	['shops.paid'] = 'Paid {total} at {shop}.',
	['shops.room.total'] = 'On Save: {total}',

	['shops.noSuchLook'] = 'That look is not on offer.',
	['shops.notForYou'] = 'Your job does not entitle you to that.',
	['shops.notHere'] = 'That look is not carried here.',

	['shops.noCharacter'] = 'Your character is not loaded yet. Try again in a moment.',
	['shops.nameNeeded'] = 'Give the outfit a name.',
	['shops.tooMany'] = 'You already keep {max} outfits. Delete one first.',
	['shops.nothingWorn'] = 'You are not wearing anything that can be saved yet.',
	['shops.saved'] = 'Saved as {name}.',
	['shops.saveFailed'] = 'The outfit could not be saved.',
	['shops.deleteFailed'] = 'That outfit could not be deleted.',
	['shops.listFailed'] = 'Your outfits could not be read.',
	['shops.noSuchOutfit'] = 'That outfit is not yours.',
	['shops.outfitUnreadable'] = 'That outfit cannot be read back.',

	['shops.sharingOff'] = 'Sharing is turned off on this server.',
	['shops.badCode'] = 'That is not a code.',
	['shops.noSuchCode'] = 'No outfit answers that code.',
	['shops.codeFailed'] = 'A code could not be minted. Try again.',

	-- The category strip on the fitting-room screen, and the two lists and two
	-- forms behind it. Four words at most each: these are buttons in a row and
	-- the row wraps rather than shrinks.
	['shops.group.looks'] = 'Uniforms',
	['shops.group.outfits'] = 'My outfits',
	['shops.group.save'] = 'Save outfit',
	['shops.group.code'] = 'Outfit code',

	['shops.looks.title'] = 'Ready-made looks',
	['shops.looks.empty'] = 'This counter has nothing ready to wear.',
	['shops.outfits.title'] = 'Your saved outfits',
	['shops.outfits.empty'] = 'You have not saved an outfit yet.',
	['shops.outfits.wear'] = 'Wear outfit',
	['shops.outfits.share'] = 'Get a share code',
	['shops.outfits.delete'] = 'Delete outfit',
	['shops.outfits.deleteConfirm'] = 'Yes, delete {name}',
	['shops.outfits.keep'] = 'Keep it',
	['shops.outfits.shared'] = 'Share code: {code}',

	['shops.save.title'] = 'Save what you are wearing',
	['shops.save.field'] = 'Name',
	-- SAID WHEN THE SAVE IS QUEUED AND NOT WHEN IT LANDS, because those are
	-- different moments here: the server writes down what a character IS wearing,
	-- and inside an open fitting room that is still the look they walked in with.
	['shops.save.queued'] = 'It will be saved as {name} when you finish here.',
	['shops.save.dropped'] = 'You left without keeping the look, so {name} was not saved.',

	['shops.code.title'] = 'Wear a shared outfit',
	['shops.code.field'] = 'Code',
	['shops.code.hint'] = '{length} characters, read out by another player.',

	['shops.noSurface'] = 'That screen is not available right now.',
	['shops.dressFailed'] = 'That outfit would not go on.',
}

local FR = {
	['shops.row'] = "Ouvrir la cabine d'essayage",

	['shops.no_such_shop'] = "Il n'y a pas de boutique ici.",
	['shops.too_far'] = 'Vous êtes trop loin du comptoir.',
	['shops.position_unknown'] = "Votre position n'a pas pu être lue.",
	['shops.not_for_you'] = 'Cette boutique ne vous est pas ouverte.',
	['shops.downed'] = 'Personne ne vous sert tant que vous êtes à terre.',
	['shops.redeemAtShop'] = "Un code de tenue s'utilise au comptoir d'une boutique de vêtements.",
	['shops.redeemInRoom'] = "Ouvrez d'abord la cabine d'essayage : la tenue s'y essaie, aux prix de cette boutique.",

	['shops.unavailable'] = "La cabine d'essayage n'est pas disponible pour le moment.",
	['shops.cannotDress'] = "Impossible d'enfiler ces vêtements.",
	['shops.cannotPay'] = 'Vous ne pouvez pas payer : {total} nécessaires.',
	['shops.paid'] = 'Vous avez payé {total} chez {shop}.',
	['shops.room.total'] = "À l'enregistrement : {total}",

	['shops.noSuchLook'] = "Cette tenue n'est pas proposée.",
	['shops.notForYou'] = 'Votre métier ne vous y donne pas droit.',
	['shops.notHere'] = "Cette tenue n'est pas vendue ici.",

	['shops.noCharacter'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['shops.nameNeeded'] = 'Donnez un nom à la tenue.',
	['shops.tooMany'] = 'Vous gardez déjà {max} tenues. Supprimez-en une.',
	['shops.nothingWorn'] = 'Vous ne portez encore rien qui puisse être enregistré.',
	['shops.saved'] = 'Enregistrée sous {name}.',
	['shops.saveFailed'] = "La tenue n'a pas pu être enregistrée.",
	['shops.deleteFailed'] = "Cette tenue n'a pas pu être supprimée.",
	['shops.listFailed'] = "Vos tenues n'ont pas pu être lues.",
	['shops.noSuchOutfit'] = "Cette tenue n'est pas la vôtre.",
	['shops.outfitUnreadable'] = 'Cette tenue est illisible.',

	['shops.sharingOff'] = 'Le partage est désactivé sur ce serveur.',
	['shops.badCode'] = "Ce n'est pas un code.",
	['shops.noSuchCode'] = 'Aucune tenue ne répond à ce code.',
	['shops.codeFailed'] = "Un code n'a pas pu être généré. Réessayez.",

	['shops.group.looks'] = 'Uniformes',
	['shops.group.outfits'] = 'Mes tenues',
	['shops.group.save'] = 'Enregistrer',
	['shops.group.code'] = 'Code de tenue',

	['shops.looks.title'] = 'Tenues prêtes à porter',
	['shops.looks.empty'] = "Ce comptoir n'a rien de prêt à porter.",
	['shops.outfits.title'] = 'Vos tenues enregistrées',
	['shops.outfits.empty'] = "Vous n'avez encore enregistré aucune tenue.",
	['shops.outfits.wear'] = 'Porter la tenue',
	['shops.outfits.share'] = 'Obtenir un code de partage',
	['shops.outfits.delete'] = 'Supprimer la tenue',
	['shops.outfits.deleteConfirm'] = 'Oui, supprimer {name}',
	['shops.outfits.keep'] = 'La garder',
	['shops.outfits.shared'] = 'Code de partage : {code}',

	['shops.save.title'] = 'Enregistrer votre tenue actuelle',
	['shops.save.field'] = 'Nom',
	['shops.save.queued'] = 'Elle sera enregistrée sous {name} quand vous aurez fini.',
	['shops.save.dropped'] = "La tenue n'a pas été gardée : {name} n'a pas été enregistrée.",

	['shops.code.title'] = 'Porter une tenue partagée',
	['shops.code.field'] = 'Code',
	['shops.code.hint'] = "{length} caractères, dictés par un autre joueur.",

	['shops.noSurface'] = "Cet écran n'est pas disponible pour le moment.",
	['shops.dressFailed'] = "Impossible d'enfiler cette tenue.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
