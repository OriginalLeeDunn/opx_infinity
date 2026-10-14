--- Every string this module puts on screen, in the two languages the runtime ships.
-- @author dop42
--
-- The view is drawn from these and from nothing else: Lua resolves every key and
-- hands the page a sentence, so the page holds no English of its own. The refusal
-- code below is a catalogue key like any other -- `OPX.Refuse` looks it up on its
-- way out, so a code missing here would reach a player as `error.unavailable`.

local M = OPX.Modules.Get('spawn')

local EN = {
	['spawn.title'] = 'CHOOSE A SPAWN',
	['spawn.eyebrow'] = 'SPAWN',
	['spawn.about'] = 'Pick where you start.',
	['spawn.hint'] = 'Click a location to spawn there.',
	['spawn.placed'] = 'Spawned at {place}.',
	['spawn.timeout'] = 'No choice was made: the server placed you.',
	['spawn.resume'] = 'Where I left off',
	['spawn.resumeHint'] = 'Your last position',
	['spawn.resumed'] = 'Back where you left off.',
	['spawn.placeFailed'] = 'You could not be moved there. You are still where you were.',

	['spawn.noChoice'] = 'That spawn choice is no longer open.',

	-- SPAWN PLACES, by the `id` in config/spawn.lua: the card and its hint
	-- line. A place with no line here keeps the config text.
	['spawn.place.arena'] = 'Freeroam arena',
	['spawn.place.arena.district'] = 'Badlands',
	['spawn.place.city'] = 'City west',
	['spawn.place.city.district'] = 'City Center',
	['spawn.place.coast'] = 'Southwest coast',
	['spawn.place.coast.district'] = 'Badlands',
	['spawn.place.dealer'] = 'Vehicle dealership',
	['spawn.place.dealer.district'] = 'Westbrook',
	['spawn.place.heights'] = 'Northwest heights',
	['spawn.place.heights.district'] = 'North Oak',
	['spawn.place.junction'] = 'Lower Watson junction',
	['spawn.place.junction.district'] = 'Watson',
	['spawn.place.lab'] = 'Open77 laboratory',
	['spawn.place.lab.district'] = 'East',
	['spawn.place.northside'] = 'North promenade',
	['spawn.place.northside.district'] = 'Watson',
	['spawn.place.racegrid'] = 'Westbrook race grid',
	['spawn.place.racegrid.district'] = 'Westbrook',
	['spawn.place.stoop'] = 'King Stoop forecourt',
	['spawn.place.stoop.district'] = 'Watson',
	['spawn.place.underpass'] = 'Lower Watson underpass',
	['spawn.place.underpass.district'] = 'Watson',
}

local FR = {
	['spawn.title'] = 'CHOISISSEZ OÙ APPARAÎTRE',
	['spawn.eyebrow'] = 'APPARITION',
	['spawn.about'] = 'Choisissez où vous commencez.',
	['spawn.hint'] = 'Cliquez sur un lieu pour y apparaître.',
	['spawn.placed'] = 'Apparition à {place}.',
	['spawn.timeout'] = 'Aucun choix : le serveur vous a placé.',
	['spawn.resume'] = "Là où j'étais",
	['spawn.resumeHint'] = 'Votre dernière position',
	['spawn.resumed'] = 'Retour là où vous étiez.',
	['spawn.placeFailed'] = "Le déplacement n'a pas pu se faire : vous n'avez pas bougé.",

	['spawn.noChoice'] = "Ce choix d'apparition n'est plus ouvert.",

	-- SPAWN PLACES, by the `id` in config/spawn.lua: the card and its hint
	-- line. A place with no line here keeps the config text.
	['spawn.place.arena'] = 'Arène libre',
	['spawn.place.arena.district'] = 'Badlands',
	['spawn.place.city'] = 'Centre-ville ouest',
	['spawn.place.city.district'] = 'Centre-ville',
	['spawn.place.coast'] = 'Côte sud-ouest',
	['spawn.place.coast.district'] = 'Badlands',
	['spawn.place.dealer'] = 'Concession de véhicules',
	['spawn.place.dealer.district'] = 'Westbrook',
	['spawn.place.heights'] = 'Hauteurs du nord-ouest',
	['spawn.place.heights.district'] = 'North Oak',
	['spawn.place.junction'] = 'Carrefour du bas Watson',
	['spawn.place.junction.district'] = 'Watson',
	['spawn.place.lab'] = 'Laboratoire Open77',
	['spawn.place.lab.district'] = 'Est',
	['spawn.place.northside'] = 'Promenade nord',
	['spawn.place.northside.district'] = 'Watson',
	['spawn.place.racegrid'] = 'Grille de départ de Westbrook',
	['spawn.place.racegrid.district'] = 'Westbrook',
	['spawn.place.stoop'] = 'Parvis de King Stoop',
	['spawn.place.stoop.district'] = 'Watson',
	['spawn.place.underpass'] = 'Passage souterrain du bas Watson',
	['spawn.place.underpass.district'] = 'Watson',
}

-- Kept on the module table as well as registered: the two are compared at start,
-- so a key present in one language and missing from the other is named once
-- rather than rendered as its own key on somebody's screen.
M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
