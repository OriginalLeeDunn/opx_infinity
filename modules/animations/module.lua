--- Emotes and animations: the commands, the picker and the animation contract.
-- @author dop42
--
-- This module is NOT the authority on what plays. The platform's animation
-- service owns every playback, replicates it to the bucket, and refuses a dead
-- player, a player in a vehicle or a second animation over another owner's, on
-- its own. All this module decides is what it ASKS the service for: the
-- catalogue as config leaves it, a per-player rate and a readiness gate. It
-- provides no animation of its own and writes nothing to the database.
--
-- The catalogue it offers is the rows written in shared/catalogue.lua AND the
-- platform's own catalogue, read at runtime from `Open77.animations.list`; and
-- an emote with a nearby player -- the coordinator's own carry, escort, give
-- and heal from either side, or any two offered profiles, one per body -- goes
-- through the platform's two-player coordinator, `Open77.playerInteractions`,
-- after this module has asked the other player and they have accepted.
--
-- `downed`, `menu`, `form` and `prompts` are optional. Without `menu` there is no
-- picker and the commands and the contract still work; without `form` the picker
-- keeps every screen and loses only its search box; without `prompts` the
-- stop key is simply not drawn; without `downed` the picker never closes itself.
-- Each absence costs one logged line and nothing else.

local M = OPX.Modules.Declare{
	id = 'animations',
	side = 'both',
	fatal = false,
	-- `target` is optional too, and it is optional ON PURPOSE rather than
	-- required: a runtime without the eye is a runtime where the walking paces
	-- are unreachable, which is a missing convenience and not a broken module.
	-- But it MUST be named. `Resolve` orders modules by what they declare, so
	-- without this line nothing put `target` ahead of `animations` on the
	-- client, `OPX.Api.Get('target')` answered nil in `Walk.Start`, and the pace
	-- rows were never registered at all -- reported from the game the same hour
	-- they shipped.
	-- `character` names the two players of an emote with a nearby player by
	-- their characters rather than their accounts; without it, the account name.
	optional = { 'downed', 'menu', 'form', 'prompts', 'target', 'character' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
M.Event = {
	-- Client to server. Every payload is a claim by the player; only `source` is
	-- not.
	PLAY = OPX.Event(NET, 'animations', 'play'),
	STOP = OPX.Event(NET, 'animations', 'stop'),
	HELLO = OPX.Event(NET, 'animations', 'hello'),
	-- An emote with a nearby player: the ask, then the invited player's answer.
	DUO = OPX.Event(NET, 'animations', 'duo'),
	REPLY = OPX.Event(NET, 'animations', 'reply'),

	-- Server to client. The offer arrives in parts: the whole catalogue in one
	-- event is past the client's 1,024-value decoder.
	OFFER = OPX.Event(NET, 'animations', 'offer'),
	ANSWER = OPX.Event(NET, 'animations', 'answer'),
	CANCEL = OPX.Event(NET, 'animations', 'cancel'),
	PICKER = OPX.Event(NET, 'animations', 'picker'),
	INVITE = OPX.Event(NET, 'animations', 'invite'),
	UNINVITE = OPX.Event(NET, 'animations', 'uninvite'),
	NOTICE = OPX.Event(NET, 'animations', 'notice'),

	-- The client's own bus. Public: a bare AddEventHandler reaches these.
	ON_RESULT = OPX.Event(LOCAL, 'animations', 'result'),
	ON_CHANGED = OPX.Event(LOCAL, 'animations', 'changed'),
	ON_FAILED = OPX.Event(LOCAL, 'animations', 'failed'),
}

--- The platform's own animation wire, observed in its client and undocumented.
-- These names belong to the service and may not be renamed or re-channelled:
-- the host refuses them from anything but the server, which is what stops a
-- neighbouring resource forging a playback state.
M.Wire = {
	STATE = 'open77:animations:state',
	SNAPSHOT = 'open77:animations:snapshot',
	RESULT = 'open77:animations:result',
	SYNC = 'open77:animations:sync',
	STOP = 'open77:animations:stopRequest',
}

--- The platform package whose client poses bodies instead, while it runs.
M.OFFICIAL = 'open77_animations'

--- Longest step duration the platform service accepts on the wire.
M.SERVICE_MAX_MS = 600000

--- Shortest duration a request may name: under a second a clip reads as a tic.
M.MIN_DURATION_MS = 1000

--- Largest request serial a client may send.
M.MAX_REQUEST_ID = 2147483647
