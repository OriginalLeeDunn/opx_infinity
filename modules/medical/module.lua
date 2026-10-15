--- Medical services: Trauma Team, the street doc, and whoever else answers a body.
-- @author dop42
--
-- A CONTRACT, NOT A CHARITY. Night City's emergency medicine is private. Trauma
-- Team International comes in an AV for a client whose biomonitor flatlined and
-- for nobody else; a street ripperdoc patches anybody with the eddies. This
-- module is the machinery both of those share, and `config/medical.lua` is where
-- a server says which services exist and what each one does. A service is a
-- config entry, never a code path: adding a corpo in-house medic is a block of
-- config, not a file.
--
-- WHAT IT OWNS:
--   * the CALLS -- a body on the ground becomes a call on the board of every
--     service whose rules say it answers that body (`server/dispatch.lua`);
--   * the TREATMENTS -- revive a body that is down, heal a body that is hurt,
--     each gated by job, grade and duty, paid with items from the medic's bag;
--   * the SUBSCRIPTIONS -- Silver, Gold, Platinum: what makes Trauma Team come
--     on its own, and cheaper;
--   * the BILL -- what the patient owes, what happens when they cannot pay, and
--     what the medic earns.
--
-- WHAT IT DOES NOT OWN: being down. `downed` decides who is down and is the
-- only thing that stands a body back up; a revive here is a call to its
-- `Revive` contract with this service's health share, never a respawn of its
-- own. `downed` is a hard requirement for that reason -- a medical module on a
-- server where nobody can go down has nothing to do.
--
-- THE DISPATCH IS ITS OWN FILE ON PURPOSE. `server/dispatch.lua` is plain table
-- arithmetic over calls and responders with no host call in it, so it can be
-- tested off-platform and lifted into a shared `dispatch` module the day the
-- police need the same board.

local M = OPX.Modules.Declare{
	id = 'medical',
	side = 'both',
	fatal = false,
	requires = { 'character', 'downed' },
	-- `target` is client-only, so a hard requirement would mark the server half
	-- unavailable; see the same note in `modules/hauling/module.lua`.
	optional = { 'target', 'progress', 'inventory', 'menu', 'animations' },
}

local NET, LOCAL = OPX.Channel.NET, OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Client to server. `source` is the connection's; every field is re-read.
	BOARD = OPX.Event(NET, 'medical', 'board'),          -- list the open calls
	TAKE = OPX.Event(NET, 'medical', 'take'),            -- { callId }
	DROP = OPX.Event(NET, 'medical', 'drop'),            -- { callId }
	OPTIONS = OPX.Event(NET, 'medical', 'options'),      -- { target? } what may I do here
	TREAT = OPX.Event(NET, 'medical', 'treat'),          -- { target, service, treatment }
	CONSENT = OPX.Event(NET, 'medical', 'consent'),      -- { inviteId, accepted }
	DESK = OPX.Event(NET, 'medical', 'desk'),            -- { service, desk }
	SUBSCRIBE = OPX.Event(NET, 'medical', 'subscribe'),  -- { service, desk, tier }

	-- Server to client.
	ALERT = OPX.Event(NET, 'medical', 'alert'),          -- a call opened that this medic may take
	CLOSED = OPX.Event(NET, 'medical', 'closed'),        -- { callId } gone from the board
	BOARD_VIEW = OPX.Event(NET, 'medical', 'boardView'), -- the board, as this medic may see it
	OPTIONS_VIEW = OPX.Event(NET, 'medical', 'optionsView'),
	DESK_VIEW = OPX.Event(NET, 'medical', 'deskView'),
	ASK = OPX.Event(NET, 'medical', 'ask'),              -- a consent invitation to a patient
	WAYPOINT = OPX.Event(NET, 'medical', 'waypoint'),    -- { x, y, z }
	ANSWER = OPX.Event(NET, 'medical', 'answer'),        -- { ok, code, ... }

	-- The public server bus, `(source, payload)`. Raised by the server only.
	ON_CALL = OPX.Event(LOCAL, 'medical', 'call'),       -- opened / taken / closed
	ON_TREATED = OPX.Event(LOCAL, 'medical', 'treated'), -- a treatment landed and was billed
	ON_SUBSCRIBED = OPX.Event(LOCAL, 'medical', 'subscribed'),
}

--- The kinds of act. REVIVE and HEAL are configured TREATMENTS; CARRY is the
--- service's own CARRY block, offered beside them. A fourth would need a fourth
--- branch on the server, so the set is closed here rather than spelt at each site.
M.Kind = { REVIVE = 'revive', HEAL = 'heal', CARRY = 'carry' }

--- The two pseudo-treatment names the client may send beside a configured one.
M.CARRY, M.PUT_DOWN = 'carry', 'putdown'

--- Why a call exists.
M.Reason = {
	-- The biomonitor of a subscriber whose tier says AUTO_ALERT.
	BIOMONITOR = 'biomonitor',
	-- The patient pressed "wait for help".
	DISTRESS = 'distress',
}
