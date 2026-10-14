--- Player-facing text owned by the menu module.
-- @author dop42
--
-- The key hints and the confirmation rows `confirm` builds: every other string a
-- menu draws is the caller's own.

OPX.Locale.Register('en', {
	['menu.key.choose'] = 'Choose',
	['menu.key.select'] = 'Select',
	['menu.key.change'] = 'Change',
	['menu.key.back'] = 'Back',
	['menu.confirm.title'] = '{label}?',
	['menu.confirm.yes'] = 'Yes, {label}',
	['menu.confirm.no'] = 'No, keep it',
})

OPX.Locale.Register('fr', {
	['menu.key.choose'] = 'Choisir',
	['menu.key.select'] = 'Valider',
	['menu.key.change'] = 'Changer',
	['menu.key.back'] = 'Retour',
	['menu.confirm.title'] = '{label} ?',
	['menu.confirm.yes'] = 'Oui : {label}',
	['menu.confirm.no'] = 'Non, garder',
})
