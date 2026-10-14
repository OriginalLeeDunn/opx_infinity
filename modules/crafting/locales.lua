--- What the crafting screen says, in both languages.
-- @author dop42
--
-- Every code in `M.Refusal` has a sentence here, and the keys read as machine
-- names on purpose: the screen and the toast both build the key by prefixing
-- `crafting.` to the code the server answered, exactly as `shops` does, so the
-- refusal a player reads and the refusal a log line carries are the same word.
--
-- A CONSUMER'S OWN REFUSALS BELONG UNDER THIS PREFIX TOO. A bench's `canUse`
-- may answer a code of its own -- the gunsmith answers `job_required` and its
-- three siblings -- and crafting prefixes it the same way, because crafting
-- does not know which module a bench belongs to at the moment it draws the row.
-- So a consumer registers `crafting.<its own code>` in its own locales file,
-- and `modules/gunsmith/locales.lua` says so where it does it.

local M = OPX.Modules.Get('crafting')

local EN = {
	['crafting.shelf'] = 'ON THE BENCH  {used}/{queue}',
	['crafting.recipes'] = 'WHAT CAN BE MADE',
	['crafting.ready'] = 'COLLECT',
	['crafting.collectHint'] = 'Finished. Press to take it.',
	['crafting.cookingHint'] = 'Still being made. You can walk away.',
	['crafting.queueStatus'] = '{used} of {queue} on the bench',
	['crafting.handing'] = 'Handing the materials over',
	['crafting.nothingHere'] = 'Nothing is made here yet.',

	['crafting.no_such_bench'] = 'There is no workbench here.',
	['crafting.no_such_recipe'] = 'That is not made here.',
	['crafting.not_for_you'] = 'This bench is not yours to use.',
	['crafting.too_far'] = 'You are not standing at the bench.',
	['crafting.no_position'] = 'Your position could not be read.',
	['crafting.no_character'] = 'Your character is not loaded yet. Try again in a moment.',
	['crafting.short'] = 'You are short of materials.',
	['crafting.cannot_pay'] = 'You cannot cover the bench fee.',
	['crafting.queue_full'] = 'The bench is full. Collect something first.',
	['crafting.no_such_order'] = 'That order is not on the bench any more.',
	['crafting.not_ready'] = 'That is still being made.',
	['crafting.no_room'] = 'You cannot carry that. Make room and come back.',
	['crafting.too_fast'] = 'Slow down.',
	['crafting.downed'] = 'Not from the floor.',
	['crafting.unavailable'] = 'The bench cannot be reached right now.',
}

local FR = {
	['crafting.shelf'] = "SUR L'ÉTABLI  {used}/{queue}",
	['crafting.recipes'] = 'CE QUI SE FABRIQUE ICI',
	['crafting.ready'] = 'RÉCUPÉRER',
	['crafting.collectHint'] = 'Terminé. Validez pour le récupérer.',
	['crafting.cookingHint'] = 'En cours. Vous pouvez partir.',
	['crafting.queueStatus'] = "{used} sur {queue} à l'établi",
	['crafting.handing'] = 'Remise des matériaux',
	['crafting.nothingHere'] = 'On ne fabrique encore rien ici.',

	['crafting.no_such_bench'] = "Il n'y a pas d'établi ici.",
	['crafting.no_such_recipe'] = 'Cela ne se fabrique pas ici.',
	['crafting.not_for_you'] = "Cet établi n'est pas pour vous.",
	['crafting.too_far'] = "Vous n'êtes pas devant l'établi.",
	['crafting.no_position'] = "Votre position n'a pas pu être lue.",
	['crafting.no_character'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['crafting.short'] = 'Il vous manque des matériaux.',
	['crafting.cannot_pay'] = "Vous ne pouvez pas payer les frais de l'établi.",
	['crafting.queue_full'] = "L'établi est plein. Récupérez d'abord une commande.",
	['crafting.no_such_order'] = "Cette commande n'est plus sur l'établi.",
	['crafting.not_ready'] = 'Ce n\'est pas encore terminé.',
	['crafting.no_room'] = 'Vous ne pouvez pas porter cela. Faites de la place.',
	['crafting.too_fast'] = 'Doucement.',
	['crafting.downed'] = 'Pas pendant que vous êtes à terre.',
	['crafting.unavailable'] = "L'établi est injoignable pour le moment.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
