--- Player-facing text of the target eye and its list.
-- @author dop42
--
-- `target.key` is the label the pause menu shows beside the rebindable key, so it
-- is read once at start and never re-read: the host keeps the name it was given
-- when the mapping was registered.

local M = OPX.Modules.Get('target')

local EN = {
	-- The eye's own row: the SERVER id, for a report to staff. Never the
	-- character's id or name: never a name to a stranger.
	['target.identify.row'] = 'Show server ID',
	['target.identify.title'] = 'SERVER ID',
	['target.identify.copied'] = 'Server id {server} — copied',
	['target.identify.shown'] = 'Server id {server}',
	['target.key'] = 'Target (hold)',
	['target.looking'] = 'Looking…',
	['target.unavailable'] = 'Action unavailable',
	['target.confirm'] = 'Confirm: {label}',
}

local FR = {
	['target.identify.row'] = "Voir l'identifiant",
	['target.identify.title'] = 'ID SERVEUR',
	['target.identify.copied'] = 'ID serveur {server} — copié',
	['target.identify.shown'] = 'ID serveur {server}',
	['target.key'] = 'Cibler (maintenir)',
	['target.looking'] = 'Recherche…',
	['target.unavailable'] = 'Action indisponible',
	['target.confirm'] = 'Confirmer : {label}',
}

M.Catalogs = { en = EN, fr = FR }

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
