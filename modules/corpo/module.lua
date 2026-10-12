--- Corpo: corporate assignments, standing, enclave security and espionage.
-- @author dop42
--
-- THE LOOP, AS NIGHT CITY TELLS IT. An Arasaka or Militech employee walks up
-- to one of their corp's OFFICES and reads the ASSIGNMENTS BOARD -- courier
-- runs, dead drops, handshakes at a rival's drop, data pulled off a terminal,
-- a floor swept, a VIP walked to their car. They take one; the server hands
-- over the tagged briefcase or shard, points the waypoint, and proves the end
-- of it itself. The corp pays out of its treasury (`accounts`, when that module
-- runs) or in new money under an hourly cap, and STANDING with the corp moves:
-- the better work only shows to the loyal, and a quarterly target pays a bonus.
-- Loyalty has an edge: a rival corp's employee may LIFT a shard off a courier
-- (industrial espionage) and sell it to their own corp, and corp SECURITY may
-- detain a trespasser in an ENCLAVE and hand them to the police.
--
-- EVERYTHING IS THE SERVER'S. The board is generated here (`Access.Generate`,
-- pure, rolled by `M.Roll`), the assignment lives in this VM's memory, the item
-- carries a serial the server checks at the drop, a sweep is timed by the
-- server's own tick against the host's position, a VIP is a server NPC whose
-- position the server reads, every bar (terminal, theft, detention) is a
-- `progress` bar the server starts and judges. A client only ever says WHICH
-- office, WHICH offer, WHICH player.
--
-- Only `character` is required: nobody is paid or gated without it.
-- `inventory` carries the items (no inventory: only sweeps and escorts),
-- `progress` times the bars, `target` and `menu` are the client's surfaces.
-- `accounts`, `contracts` and `police` are SOFT and read through `OPX.Api.Get`
-- at the moment they are needed -- see SHARED_CONTRACTS in the design notes.

local M = OPX.Modules.Declare{
	id = 'corpo',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'inventory', 'progress', 'target', 'menu' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ corp, office }`: show me the board at this office.
	BOARD = OPX.Event(NET, 'corpo', 'board'),
	-- `{ corp, office, offer }`: take this offer.
	ACCEPT = OPX.Event(NET, 'corpo', 'accept'),
	-- `{ verb, offer? }`: abandon | outsource.
	ACT = OPX.Event(NET, 'corpo', 'act'),
	-- `{ corp, list, place }`: hand the item over here (an office or a drop).
	DELIVER = OPX.Event(NET, 'corpo', 'deliver'),
	-- `{}`: pull the data off the assignment's terminal.
	RETRIEVE = OPX.Event(NET, 'corpo', 'retrieve'),
	-- `{}`: meet the VIP at the assignment's pickup.
	MEET = OPX.Event(NET, 'corpo', 'meet'),
	-- `{ target }`: lift a rival courier's shard.
	STEAL = OPX.Event(NET, 'corpo', 'steal'),
	-- `{ target }`: detain a trespasser.
	DETAIN = OPX.Event(NET, 'corpo', 'detain'),
	-- `{}`: who am I to the corps, and what am I working on.
	HELLO = OPX.Event(NET, 'corpo', 'hello'),

	-- Server to client.
	-- `{ corp, label, office, standing, quarter, rows = { ... }, canPublish }`.
	SHOW_BOARD = OPX.Event(NET, 'corpo', 'showBoard'),
	-- The assignment this employee holds, or false: `{ id, kind, label, stage,
	-- target = { corp, list, key, label, x, y, z }, remainingS }`.
	ACTIVE = OPX.Event(NET, 'corpo', 'active'),
	-- `{ corp, grade, security }` or false: what the eye may offer.
	ROLE = OPX.Event(NET, 'corpo', 'role'),
	-- A security or police alert: `{ kind = 'trespass'|'detained', corp, label, x, y, z }`.
	ALERT = OPX.Event(NET, 'corpo', 'alert'),

	-- The public SERVER bus, `(player|nil, payload)`.
	-- `{ cid, corp, kind, template, pay, standing, funded }`
	ON_COMPLETED = OPX.Event(LOCAL, 'corpo', 'completed'),
	-- `{ cid, corp, kind, template, reason }`
	ON_FAILED = OPX.Event(LOCAL, 'corpo', 'failed'),
	-- `{ thiefCid, victimCid, thiefCorp, victimCorp }`
	ON_STOLEN = OPX.Event(LOCAL, 'corpo', 'stolen'),
	-- `{ corp, enclave, suspect, by, police }`
	ON_DETAINED = OPX.Event(LOCAL, 'corpo', 'detained'),
	-- `{ corp, enclave }` with the trespasser as the source.
	ON_TRESPASS = OPX.Event(LOCAL, 'corpo', 'trespass'),
}

--- The ACL entries, spelt once.
M.Command = {
	CAPTURE = 'opx.corpo.capture',
	STATUS = 'opx.corpo.status',
}

--- What an assignment asks.
M.Kind = { DELIVER = 'deliver', RETRIEVE = 'retrieve', SWEEP = 'sweep', ESCORT = 'escort' }

--- Where an assignment stands.
--   goto   walk to the terminal (retrieve) or the pickup (escort)
--   carry  the item is in the bag, take it to the target
--   sweep  hold the floor
--   escort the VIP follows, walk them to the destination
M.Stage = { GOTO = 'goto', CARRY = 'carry', SWEEP = 'sweep', ESCORT = 'escort' }

--- The place lists a corp may hold, config key -> list name.
M.Lists = {
	offices = 'OFFICES', drops = 'DROPS', terminals = 'TERMINALS', floors = 'FLOORS',
	pickups = 'PICKUPS', destinations = 'DESTINATIONS', enclaves = 'ENCLAVES',
}
