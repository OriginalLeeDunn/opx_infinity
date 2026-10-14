--- Every string this module puts on screen, in the two languages the runtime ships.
-- @author dop42
--
-- The form module holds no English: Lua resolves every key here and hands it the
-- sentence, the refusals included. The refusal CODES the server answers --
-- `character.*`, `entry.*`, `error.*` -- are not repeated here. They belong to
-- the modules that raise them, every catalogue merges into one, and
-- `OPX.Locale.Exists` finds them from here.

local M = OPX.Modules.Get('entry')

local EN = {
	['entry.name.title'] = 'WHO ARE YOU',
	['entry.name.about'] = 'The name on your papers. It is written once.',
	['entry.name.firstName'] = 'First name',
	['entry.name.lastName'] = 'Last name',
	['entry.name.firstHint'] = 'Vee',
	['entry.name.lastHint'] = 'Vector',

	['entry.refusal.unknown'] = 'That was refused. Try again.',
}

local FR = {
	['entry.name.title'] = 'QUI ÊTES-VOUS',
	['entry.name.about'] = "Le nom qui figure sur vos papiers. Il ne s'écrit qu'une fois.",
	['entry.name.firstName'] = 'Prénom',
	['entry.name.lastName'] = 'Nom',
	['entry.name.firstHint'] = 'Vee',
	['entry.name.lastHint'] = 'Vector',

	['entry.refusal.unknown'] = 'Cela a été refusé. Réessayez.',
}

-- Kept on the module table as well as registered: the two are compared at start,
-- so a key present in one language and missing from the other is named once
-- rather than rendered as its own key on somebody's screen.
M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
