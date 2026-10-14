--- The panel's default words, which a caller's spec overrides field by field.
-- @author dop42
--
-- `panel.count` keeps its placeholders: the page fills them itself, because the
-- page is the only side that knows how many rows fit and which of them are
-- drawn. It is handed the template, never a rendered line.

OPX.Locale.Register('en', {
	['panel.count'] = '{from}-{to} of {total}',
	['panel.empty'] = 'Nothing to show here.',
	['panel.loading'] = 'Loading...',
	['panel.search'] = 'Search',
	-- What the picker grid writes under the box that empties a slot. It is the
	-- page's word and not a caller's because index 0 is the CONTRACT's meaning of
	-- "none of them" -- every `sliders` caller has that position whether it thought
	-- about it or not -- and a caller may still override it like any other label.
	['panel.nothing'] = 'Nothing',
	['panel.confirmYes'] = 'Confirm',
	['panel.confirmNo'] = 'Cancel',
})

OPX.Locale.Register('fr', {
	['panel.count'] = '{from}-{to} sur {total}',
	['panel.empty'] = 'Rien à afficher ici.',
	['panel.loading'] = 'Chargement...',
	['panel.search'] = 'Rechercher',
	['panel.nothing'] = 'Rien',
	['panel.confirmYes'] = 'Confirmer',
	['panel.confirmNo'] = 'Annuler',
})
