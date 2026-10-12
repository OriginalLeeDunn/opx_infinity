--- Netrunner: jacking into a corp's network, breaching its ICE, and walking out
--- with a door opened, a camera looped or a data shard in the bag.
-- @author dop42
--
-- THE LOOP, AS NIGHT CITY TELLS IT. A runner finds a network's ACCESS POINT --
-- a junction box in a parking garage, a maintenance port behind a vending
-- machine -- and jacks in with a CYBERDECK in their bag. The ICE answers with a
-- BREACH: a run of stepped bars, each one rolled by the server, harder when the
-- network out-tiers the deck. A failed step does not throw the runner out; it
-- raises the TRACE, and a trace that reaches 100% is NetWatch-grade bad news:
-- forced disconnect, the network locked down for a while, and NCPD told where
-- the access point is. Connected, the runner spends deck RAM on DAEMONS --
-- open a door (through the doorlock contract, which keeps its own authority),
-- loop the cameras, mine a data shard, pick at the ICE, wipe the logs -- while
-- the trace climbs on its own. The shard is sold to a BROKER, hot or cold.
-- Blackwall networks feed a per-character NetWatch HEAT that locks a runner
-- out for a day when it flags.
--
-- EVERYTHING IS THE SERVER'S. `Open77.hacking` targets players only, and the
-- platform has no scriptable breach minigame and no device hack for a script
-- to hold (see the design notes), so the breach is ours, and like the doorlock
-- lockpick it is timed by the server: every step is a `progress` bar the server
-- starts and judges, every roll is `M.Roll`, the session -- network, trace,
-- RAM -- lives in this VM's memory, and a client only ever says WHICH access
-- point, WHICH daemon and WHICH broker. The RAM itself lives on the deck item's
-- metadata so a deck drained in one run is still drained in the next.
--
-- Only `character` and `inventory` are required: without the first nobody is
-- paid and nothing is gated, without the second there is no deck to jack in
-- with. `progress` is the breach's clock -- without it nobody breaches -- and
-- is still optional, like every other module here, so a server that removed it
-- keeps its brokers. `doorlock` is the only consumer of the door daemon; a door
-- node with no doorlock refunds the RAM and says why.

local M = OPX.Modules.Declare{
	id = 'netrunner',
	side = 'both',
	fatal = false,
	requires = { 'character', 'inventory' },
	optional = { 'doorlock', 'target', 'progress', 'menu', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ network, node }`: jack in at an access point and start the breach.
	JACK_IN = OPX.Event(NET, 'netrunner', 'jackIn'),
	-- `{ daemon, node }`: run one daemon on one node of the network jacked into.
	DAEMON = OPX.Event(NET, 'netrunner', 'daemon'),
	-- `{}`: jack out.
	JACK_OUT = OPX.Event(NET, 'netrunner', 'jackOut'),
	-- `{ broker }`: sell every data shard in the bag to the broker stood at.
	SELL = OPX.Event(NET, 'netrunner', 'sell'),
	-- `{}`: ask for the session again (the menu was closed).
	ASK = OPX.Event(NET, 'netrunner', 'ask'),

	-- Server to client: the session as the runner may see it, `{ network,
	-- label, phase, ram, ramMax, trace, ice, daemons = { ... }, open }`, or
	-- `{ phase = 'offline' }` when it ended.
	STATE = OPX.Event(NET, 'netrunner', 'state'),
	-- Server to client: an NCPD (or whoever ON_TRACE names) alert about a
	-- network, `{ label, x, y, z, runner? , level }`.
	ALERT = OPX.Event(NET, 'netrunner', 'alert'),

	-- The public SERVER bus, for other resources.
	-- `(player, { cid, network, node, objective, shardSerial, kind, value })`:
	-- a shard was mined -- what a contracts board listens for.
	ON_OBJECTIVE = OPX.Event(LOCAL, 'netrunner', 'objective'),
	-- `(player, { network, label, x, y, z })`: a runner was traced to 100%.
	ON_TRACED = OPX.Event(LOCAL, 'netrunner', 'traced'),
	-- `(player|nil, { network, untilMs })`: a network's cameras were looped.
	ON_CAMERAS = OPX.Event(LOCAL, 'netrunner', 'cameras'),
	-- `(player, { network, door, unlockS })`: a door was opened from the net.
	ON_DOOR = OPX.Event(LOCAL, 'netrunner', 'door'),
}

--- The ACL entries, spelt once. A command's host gate is `command.<name>`.
M.Command = {
	CAPTURE = 'opx.netrunner.capture',
	NETWORKS = 'opx.netrunner.networks',
}

--- The node kinds a network may hold.
M.Kind = {
	ACCESS_POINT = 'access_point',
	DOOR = 'door',
	CAMERA = 'camera',
	TERMINAL = 'terminal',
}

--- What a daemon does. A daemon's EFFECT is one of these and nothing else.
M.Effect = {
	DOOR = 'door',
	CAMERAS = 'cameras',
	SHARD = 'shard',
	ICE_PICK = 'ice_pick',
	WIPE = 'wipe',
}
