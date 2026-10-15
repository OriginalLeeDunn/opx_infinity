--- Business: company and gang treasuries, and the boss's HR terminal.
-- @author dop42
--
-- TWO CONTRACTS, ONE MODULE, because the second cannot be written without the
-- first: a boss who moves money needs a treasury, and a treasury nobody manages
-- is a number in a table.
--
--   `accounts` v1 -- one balance per job and per gang (`opx77_company_accounts`,
--   the table the dealership created and still pays sales into: same table, no
--   migration, no data loss), and a LEDGER beside it (`opx77_company_ledger`)
--   in which every movement is one row named by an operation id. The id is a
--   UNIQUE key and the row is written in the same transaction as the balance,
--   so the same opId twice is one movement and the second call answers the
--   first receipt. A withdrawal's row is an INSERT ... SELECT guarded by the
--   balance, so an account can never be overdrawn by two bosses at once: the
--   database decides, not a read in Lua followed by a write.
--
--   `business` v1 -- employment. A grade with `isBoss = true` in
--   `config/character.lua` opens the HR terminal (`/opx.boss`, or the eye row
--   at an office): the roster online and offline, recruiting a nearby player
--   (who has to accept), firing, promoting and demoting inside the grade
--   table, clocking an employee in or out, and -- for `bankAuth` grades --
--   depositing and withdrawing between their cash and the company account.
--   Every change goes through the character contract's SetJob / SetGang /
--   RemovePlayerFromJob / RemovePlayerFromGang, so the `job:beforeSet` hooks,
--   the vetoes, the offline ledger and the `opx:on:character:job` bus all keep
--   working exactly as for a staff command.
--
-- THE SERVER DECIDES EVERYTHING. The client sends a verb and a citizen id; the
-- server re-reads the boss's grade, the target's grade, the rank rule, the cap,
-- the distance and the balance, and answers with a locale key.
--
-- `character` is required (no grades, no roster, no money). `menu`, `form` and
-- `target` are optional: without them the treasury and the contracts still
-- work for other modules, and the terminal is simply not drawn.

local M = OPX.Modules.Declare{
	id = 'business',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'menu', 'form', 'target' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ kind?, key?, office? }`: open the terminal (all my groups, or one at an
	-- office: `office` is the office's index in that group's OFFICES).
	OPEN = OPX.Event(NET, 'business', 'open'),
	-- `{ kind, key, verb, citizenId?, target?, amount? }`: verb one of hire,
	-- fire, promote, demote, duty, deposit, withdraw, nearby.
	ACT = OPX.Event(NET, 'business', 'act'),
	-- `{ id, accept }`: the recruit's answer to an offer.
	ANSWER = OPX.Event(NET, 'business', 'answer'),

	-- Server to client.
	-- The terminal: `{ desks = { {kind, key, label, ...} }, currency }`.
	SHOW = OPX.Event(NET, 'business', 'show'),
	-- Nearby players a boss may recruit: `{ kind, key, rows = { {target, metres} } }`.
	NEARBY = OPX.Event(NET, 'business', 'nearby'),
	-- An offer to the recruit: `{ id, label, grade, ttl }`, or `{ id, closed = true }`.
	OFFER = OPX.Event(NET, 'business', 'offer'),

	-- The public SERVER bus, `(nil, payload)`. Names only, never a position.
	-- `{ kind, key, delta, balance, reason }` -- the `accounts` v1 shape.
	ON_ACCOUNT = OPX.Event(LOCAL, 'accounts', 'changed'),
	-- `{ kind, key, verb, citizenId, by, grade? }`: somebody was hired, fired,
	-- promoted, demoted or clocked by a boss.
	ON_STAFF = OPX.Event(LOCAL, 'business', 'staff'),
}

--- The two kinds of group a treasury belongs to.
M.Kind = { JOB = 'job', GANG = 'gang' }

--- The verbs a boss may send.
M.Verb = {
	HIRE = 'hire', FIRE = 'fire', PROMOTE = 'promote', DEMOTE = 'demote', DUTY = 'duty',
	DEPOSIT = 'deposit', WITHDRAW = 'withdraw', NEARBY = 'nearby',
}
