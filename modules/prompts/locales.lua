--- The key cap names and the hold tag.
-- @author dop42
--
-- These keys are never written literally anywhere in the code: a cap's name is
-- composed as `prompts.key.<NAME>` from the key the host reports, upper-cased,
-- and tested with `OPX.Locale.Exists` before it is resolved. Every entry below
-- is therefore live, and a key with no entry is drawn as the host spells it.
--
-- A caller's own labels are not here. They belong to the module that posted the
-- row, which is where they are translated.

OPX.Locale.Register('en', {
	['prompts.hold'] = 'HOLD',

	['prompts.key.SPACE'] = 'SPACE',
	['prompts.key.ENTER'] = 'ENTER',
	['prompts.key.RETURN'] = 'ENTER',
	['prompts.key.ESC'] = 'ESC',
	['prompts.key.ESCAPE'] = 'ESC',
	['prompts.key.BACKSPACE'] = 'BKSP',
	['prompts.key.DELETE'] = 'DEL',
	['prompts.key.INSERT'] = 'INS',
	['prompts.key.HOME'] = 'HOME',
	['prompts.key.END'] = 'END',
	['prompts.key.PAGEUP'] = 'PG UP',
	['prompts.key.PAGEDOWN'] = 'PG DN',
	['prompts.key.CAPSLOCK'] = 'CAPS',
	['prompts.key.TAB'] = 'TAB',
	['prompts.key.SHIFT'] = 'SHIFT',
	['prompts.key.CTRL'] = 'CTRL',
	['prompts.key.CONTROL'] = 'CTRL',
	['prompts.key.ALT'] = 'ALT',
	['prompts.key.MOUSE'] = 'MOUSE',
	['prompts.key.LMB'] = 'LMB',
	['prompts.key.RMB'] = 'RMB',
	['prompts.key.MMB'] = 'MMB',
	['prompts.key.SCROLL'] = 'SCROLL',

	-- What the contract answers a calling resource; never a toast of ours.
	['prompts.invalidOwner'] = 'That owner name is not valid.',
	['prompts.invalidId'] = 'That prompt id is not valid.',
	['prompts.invalidPlayer'] = 'There is no such player.',
	['prompts.limit'] = 'The key strip is full.',
	['prompts.ownerLimit'] = 'This resource already has as many prompt groups as it may.',
	['prompts.notFound'] = 'There is no such prompt group.',
})

OPX.Locale.Register('fr', {
	['prompts.hold'] = 'MAINTENIR',

	['prompts.key.SPACE'] = 'ESPACE',
	['prompts.key.ENTER'] = 'ENTRÉE',
	['prompts.key.RETURN'] = 'ENTRÉE',
	['prompts.key.ESC'] = 'ÉCHAP',
	['prompts.key.ESCAPE'] = 'ÉCHAP',
	['prompts.key.BACKSPACE'] = 'RETOUR',
	['prompts.key.DELETE'] = 'SUPPR',
	['prompts.key.INSERT'] = 'INSER',
	['prompts.key.HOME'] = 'ORIGINE',
	['prompts.key.END'] = 'FIN',
	['prompts.key.PAGEUP'] = 'PG PRÉC',
	['prompts.key.PAGEDOWN'] = 'PG SUIV',
	['prompts.key.CAPSLOCK'] = 'MAJ',
	['prompts.key.TAB'] = 'TAB',
	['prompts.key.SHIFT'] = 'MAJ',
	['prompts.key.CTRL'] = 'CTRL',
	['prompts.key.CONTROL'] = 'CTRL',
	['prompts.key.ALT'] = 'ALT',
	['prompts.key.MOUSE'] = 'SOURIS',
	['prompts.key.LMB'] = 'CLIC G',
	['prompts.key.RMB'] = 'CLIC D',
	['prompts.key.MMB'] = 'CLIC M',
	['prompts.key.SCROLL'] = 'MOLETTE',

	['prompts.invalidOwner'] = "Ce nom de propriétaire n'est pas valide.",
	['prompts.invalidId'] = "Cet identifiant d'invite n'est pas valide.",
	['prompts.invalidPlayer'] = "Ce joueur n'existe pas.",
	['prompts.limit'] = 'La barre des touches est pleine.',
	['prompts.ownerLimit'] = "Cette ressource a déjà autant de groupes d'invites qu'elle peut.",
	['prompts.notFound'] = "Ce groupe d'invites n'existe pas.",
})
