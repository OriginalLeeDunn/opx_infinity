--- What the armouries say, in both languages.
-- @author dop42
--
-- TWO PREFIXES, AND THE SECOND ONE IS NOT A MISTAKE.
--
--   `gunsmith.` is this module's own: the two row labels, and every refusal the
--   CHEST door answers -- which includes the codes `inventory.OpenStash` hands
--   back, because they reach the player through this module's event.
--
--   `crafting.` carries the four refusals the job GATE answers. The crafting
--   module builds the key by prefixing `crafting.` to whatever code a bench's
--   `canUse` returned -- it cannot do otherwise, since it does not know which
--   module a bench belongs to at the moment it draws a greyed row -- so the
--   sentence has to be registered under that prefix, by whoever owns the code.
--   The alternative was teaching crafting to look up a per-consumer namespace,
--   which is a lookup table of module ids inside a module that is meant not to
--   know any.
--
-- The four are the SAME FOUR WORDS the elevators module refuses a floor with,
-- deliberately: one vocabulary for "your job does not get you in", so a player
-- who has read one refusal has read them all.

local M = OPX.Modules.Get('gunsmith')

local EN = {
	['gunsmith.bench'] = 'Use workbench',
	['gunsmith.chest'] = 'Open armoury stock',

	['gunsmith.no_such_chest'] = 'There is no armoury stock here.',
	['gunsmith.not_for_you'] = 'This armoury is not yours.',
	['gunsmith.job_required'] = 'You do not hold the job this asks for.',
	['gunsmith.grade_too_low'] = 'Your grade is too low for this.',
	['gunsmith.off_duty'] = 'You must be on duty for this.',
	['gunsmith.job_stale'] = 'Your character is out of date. Try again in a moment.',
	['gunsmith.no_character'] = 'Your character is not loaded yet. Try again in a moment.',
	['gunsmith.too_far'] = 'You are not standing at the armoury stock.',
	['gunsmith.not_ready'] = 'Your bag is not ready yet.',
	['gunsmith.dead'] = 'Not while you are down.',
	['gunsmith.not_loaded'] = 'Your bag is not loaded.',
	['gunsmith.bad_argument'] = 'That chest is misconfigured.',
	['gunsmith.unavailable'] = 'The armoury cannot be reached right now.',

	['crafting.job_required'] = 'You do not hold the job this asks for.',
	['crafting.grade_too_low'] = 'Your grade is too low for this.',
	['crafting.off_duty'] = 'You must be on duty for this.',
	['crafting.job_stale'] = 'Your character is out of date. Try again in a moment.',
}

local FR = {
	['gunsmith.bench'] = "Utiliser l'établi",
	['gunsmith.chest'] = "Ouvrir le stock de l'armurerie",

	['gunsmith.no_such_chest'] = "Il n'y a pas de stock d'armurerie ici.",
	['gunsmith.not_for_you'] = "Cette armurerie n'est pas la vôtre.",
	['gunsmith.job_required'] = "Vous n'exercez pas le métier demandé.",
	['gunsmith.grade_too_low'] = 'Votre grade est trop bas pour cela.',
	['gunsmith.off_duty'] = 'Vous devez être en service pour cela.',
	['gunsmith.job_stale'] = "Votre personnage n'est plus à jour. Réessayez dans un instant.",
	['gunsmith.no_character'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['gunsmith.too_far'] = "Vous n'êtes pas devant le stock de l'armurerie.",
	['gunsmith.not_ready'] = "Votre sac n'est pas encore prêt.",
	['gunsmith.dead'] = 'Pas pendant que vous êtes à terre.',
	['gunsmith.not_loaded'] = "Votre sac n'est pas chargé.",
	['gunsmith.bad_argument'] = 'Ce coffre est mal configuré.',
	['gunsmith.unavailable'] = "L'armurerie est injoignable pour le moment.",

	['crafting.job_required'] = "Vous n'exercez pas le métier demandé.",
	['crafting.grade_too_low'] = 'Votre grade est trop bas pour cela.',
	['crafting.off_duty'] = 'Vous devez être en service pour cela.',
	['crafting.job_stale'] = "Votre personnage n'est plus à jour. Réessayez dans un instant.",
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
