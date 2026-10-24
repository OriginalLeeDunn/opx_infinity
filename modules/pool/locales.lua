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
	['pool.powerLabel'] = 'Shot power',
	['pool.precise'] = 'Fine aim',
	['pool.overview'] = 'Switch table / cue view',
	['pool.release'] = 'Release to shoot · RMB to cancel',
	['pool.tableView'] = 'Table view',
	['pool.cueView'] = 'Cue view',
	['pool.camera'] = 'The aiming view is unavailable. Try again; if this continues, contact an administrator.',
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
	['pool.powerLabel'] = 'Puissance du tir',
	['pool.precise'] = 'Visée précise',
	['pool.overview'] = 'Vue de table / vue de tir',
	['pool.release'] = 'Relâchez pour tirer · Clic droit pour annuler',
	['pool.tableView'] = 'Vue de table',
	['pool.cueView'] = 'Vue de tir',
	['pool.camera'] = 'La vue de tir est indisponible. Réessayez ; si cela persiste, contactez un administrateur.',
	['pool.busy'] = 'Quelqu’un s’entraîne déjà sur cette table.',
	['pool.models'] = 'Cette table est indisponible. Si cela vous semble anormal, contactez un administrateur.',
	['pool.simulation'] = 'Ce tir n’a pas pu être terminé. Replacez les billes ; contactez un administrateur si cela se reproduit.',
}
M.Catalogs = { en = EN, fr = FR }
OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
