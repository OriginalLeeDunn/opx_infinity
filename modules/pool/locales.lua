--- Short player instructions; engine details stay in operator diagnostics.
-- @author dop42
local M = OPX.Modules.Get('pool')
local EN = {
	['pool.enter'] = 'Practise pool',
	['pool.aim'] = 'Aim / cancel',
	['pool.charge'] = 'Hold to charge, release to shoot',
	['pool.walk'] = 'Walk around the table to line up',
	['pool.rack'] = 'Reset the practice balls',
	['pool.leave'] = 'Leave the table',
	['pool.rolling'] = 'Wait for the balls to stop.',
	['pool.power'] = 'Power {power}%',
	['pool.busy'] = 'Someone is already practising at this table.',
	['pool.models'] = 'This table is unavailable. If this seems wrong, please contact an administrator.',
	['pool.simulation'] = 'This shot could not be completed. Reset the balls; contact an administrator if it happens again.',
}
local FR = {
	['pool.enter'] = 'S’entraîner au billard',
	['pool.aim'] = 'Viser / annuler',
	['pool.charge'] = 'Maintenir pour doser, relâcher pour tirer',
	['pool.walk'] = 'Faites le tour de la table pour vous aligner',
	['pool.rack'] = 'Replacer les billes d’entraînement',
	['pool.leave'] = 'Quitter la table',
	['pool.rolling'] = 'Attendez que les billes s’arrêtent.',
	['pool.power'] = 'Puissance {power} %',
	['pool.busy'] = 'Quelqu’un s’entraîne déjà sur cette table.',
	['pool.models'] = 'Cette table est indisponible. Si cela vous semble anormal, contactez un administrateur.',
	['pool.simulation'] = 'Ce tir n’a pas pu être terminé. Replacez les billes ; contactez un administrateur si cela se reproduit.',
}
M.Catalogs = { en = EN, fr = FR }
OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
