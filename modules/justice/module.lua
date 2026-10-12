--- Justice: licences, the criminal record, counsel and the court of Night City.
-- @author dop42
--
-- WHAT THIS MODULE OWNS: the City Hall desks, the licences (the character
-- metadata key `licences` and the `licence_card` item), the criminal record
-- (`opx77_justice_records`), counsel (`opx77_justice_counsel`: who represents
-- whom) and the court's docket (`opx77_justice_cases`). Everything else is
-- reached through a contract, softly:
--
--   character   jobs, duty, the purse, the metadata (required)
--   inventory   the licence card (optional: no card, the licence still holds)
--   target      the eye rows: the desk, a player, the self row of the office
--   menu, form  what the desk, the record and the office draw with
--   accounts    the city treasury fees, bail and fines go to (owner: business)
--   invoices    the bill a court fine is sent as (owner: invoices)
--   police      the jail a verdict asks for (owner: police; never required)
--
-- SERVER AUTHORITATIVE. A client asks "sell me this licence", "show this
-- record", "approve request 12"; the server re-reads the job, the duty, the
-- reach, the counsel row and the purse every time, and answers with a locale
-- code. Money moves first, value second, and a value that cannot be given
-- gives the money back.
--
-- THE POLICE TALK TO THIS MODULE, NOT THE OTHER WAY. The `police` module
-- (NCPD, built in parallel) writes an arrest with `justice.AddRecord`, reads
-- with `GetRecord`/`HasWarrant`, checks a permit with `HasLicence` and pulls
-- one with `RevokeLicence`. Nothing here requires it.

local M = OPX.Modules.Declare{
	id = 'justice',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'inventory', 'target', 'menu', 'form' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

M.Event = {
	-- Client to server. Every field is re-read; `source` is the only truth.
	-- `(deskKey)`: open a City Hall desk.
	DESK = OPX.Event(NET, 'justice', 'desk'),
	-- `(deskKey, licenceKind)`: buy a licence at a desk.
	BUY = OPX.Event(NET, 'justice', 'buy'),
	-- `(deskKey, warrantId)`: pay the bail set on one's own warrant.
	BAIL = OPX.Event(NET, 'justice', 'bail'),
	-- `(deskKey)`: end one's own representation.
	DISMISS = OPX.Event(NET, 'justice', 'dismiss'),
	-- `(playerId | citizenId)`: police, a judge, or the client's lawyer reads a record.
	RECORD = OPX.Event(NET, 'justice', 'record'),
	-- `(playerId)`: a lawyer offers to represent a citizen standing close.
	OFFER = OPX.Event(NET, 'justice', 'offer'),
	-- `(inviteId, accepted)`: the citizen's answer.
	CONSENT = OPX.Event(NET, 'justice', 'consent'),
	-- `()`: a lawyer's or a judge's office (the self row).
	OFFICE = OPX.Event(NET, 'justice', 'office'),
	-- `(entryId)`: a lawyer asks a judge to expunge an entry of a client.
	EXPUNGE = OPX.Event(NET, 'justice', 'expunge'),
	-- `(entryId, approved)`: a judge rules on an expungement request.
	RULE = OPX.Event(NET, 'justice', 'rule'),
	-- `{ citizenId, reason, bail }`: a judge signs a warrant.
	WARRANT = OPX.Event(NET, 'justice', 'warrant'),
	-- `(warrantId, bail | nil, cancel)`: a judge sets bail or lifts a warrant.
	SET_BAIL = OPX.Event(NET, 'justice', 'setBail'),
	-- `{ citizenId, code, summary }`: a judge opens a case.
	CASE = OPX.Event(NET, 'justice', 'case'),
	-- `{ caseId, verdict, fine, jail, notes }`: a judge closes a case.
	VERDICT = OPX.Event(NET, 'justice', 'verdict'),
	-- `{ citizenId, kind, reason }`: a judge revokes a licence.
	REVOKE = OPX.Event(NET, 'justice', 'revoke'),

	-- Server to client.
	-- `{ key, label, money, licences, record, warrants, counsel }`.
	DESK_DATA = OPX.Event(NET, 'justice', 'deskData'),
	-- `{ citizenId, name, rows, warrants, viewer }`.
	RECORD_DATA = OPX.Event(NET, 'justice', 'recordData'),
	-- `{ role, clients | (pending, cases, warrants, crimes, licences) }`.
	OFFICE_DATA = OPX.Event(NET, 'justice', 'officeData'),
	-- `{ id, lawyer, ms }`: a lawyer offers to represent you.
	INVITE = OPX.Event(NET, 'justice', 'invite'),
	-- `{ ok, code, ... }`: the answer to every request.
	ANSWER = OPX.Event(NET, 'justice', 'answer'),

	-- The public server bus.
	-- `(citizenId, { id, kind, code, label, fine, jail, source })`: an entry was written.
	ON_RECORD = OPX.Event(LOCAL, 'justice', 'record'),
	-- `(citizenId, { kind, action = 'issued'|'revoked', by })`.
	ON_LICENCE = OPX.Event(LOCAL, 'justice', 'licence'),
}

--- The character metadata key this module owns.
M.LICENCES_KEY = 'licences'

--- The ACL entries.
M.Command = {
	DESKS = 'opx.justice.desks',
	CAPTURE = 'opx.justice.capture',
}

--- The entry kinds the record holds.
M.Kind = { OFFENCE = 'offence', VERDICT = 'verdict', WARRANT = 'warrant' }
