--- Radio: service channels -- NCPD dispatch, the Trauma Team net, a gang's
--- frequency -- on the platform's own voice.
-- @author dop42
--
-- MEMBERSHIP IS THE SERVER'S, AND SO IS THE RIGHT TO SPEAK. A channel is a
-- config entry (`config/radio.lua`) and a resource-owned voice channel
-- (`Open77.voice.createChannel`, mode `radio`). The server decides who is on
-- which channel from the character's job, grade, duty and gang, plus the
-- handset in their bag, and re-decides it on every `opx:on:character:job` /
-- `gang` / `loaded` and `opx:on:inventory:items` it hears, and on a slow sweep
-- for whatever nobody announced. A client only ASKS: join, leave, select, mute,
-- power, key up, key down -- and every one of those is re-checked here.
--
-- WHY A MEMBER IS A LISTENER UNTIL THE KEY IS HELD. A client routes its own
-- microphone (`Open77.voice.setTransmitting`'s intent), and two other things on
-- this machine route it too: the platform's voice key, and a live holocall,
-- which asserts `all` -- every speakable channel plus proximity -- for as long
-- as the call lasts (`modules/calls/client/main.lua`). Had a radio membership
-- been speakable all the time, a phone call would have gone out on NCPD
-- dispatch. So every membership is `canSpeak = false`, and the radio key asks
-- the server to lift that on the SELECTED channel; letting go puts it back.
-- The first tenth of a second of a transmission is the price (a real radio
-- keys up too), and nothing else on this machine can reach the channel.
--
-- Only `character` is required: without it nobody qualifies for anything.
-- `inventory` is the handset (without it REQUIRE_ITEM cannot be honoured and
-- the module says so and opens the channels without it); `menu` is the picker;
-- `downed` keeps a downed character off the air.

local M = OPX.Modules.Declare{
	id = 'radio',
	side = 'both',
	fatal = false,
	requires = { 'character' },
	optional = { 'inventory', 'menu', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	-- `{ verb, channel?, on? }`, verb one of `join`, `leave`, `select`, `mute`,
	-- `power`, `ask` (send me the state, and open the menu).
	REQUEST = OPX.Event(NET, 'radio', 'request'),
	-- `{ on }`: the talk key went down (true) or up (false).
	TALK = OPX.Event(NET, 'radio', 'talk'),

	-- Server to client: what this player's radio looks like now, `{ power,
	-- handset, active, talking, channels = { { key, label, short, joined,
	-- muted, active, auto } }, open? }`.
	STATE = OPX.Event(NET, 'radio', 'state'),
	-- Server to client: the right to speak was granted or taken back,
	-- `{ on, channel = short tag, code? }`.
	KEYED = OPX.Event(NET, 'radio', 'keyed'),

	-- The public SERVER bus, for other resources.
	-- `(player, { citizenId, channels = { key... }, active })`: the channels a
	-- player is on changed.
	ON_CHANGED = OPX.Event(LOCAL, 'radio', 'changed'),
}

--- The ACL entries, spelt once. A command's host gate is `command.<name>`.
M.Command = {
	RADIO = 'opx.radio',
	CHANNELS = 'opx.radio.channels',
}

--- The verbs a REQUEST may carry, as a closed set.
M.Verbs = { join = true, leave = true, select = true, mute = true, power = true, ask = true }
