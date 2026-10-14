--- The character's face, the clothes it wears, the looks other players are sent,
--- and the one announcement that lets anybody into the world.
-- @author dop42
--
-- FATAL, and not for the usual reason. Every joining player carries a hold named
-- `__platform` on the readiness gate that no Lua may take or release and that has
-- no deadline. It clears on exactly one thing: a client announcing
-- `open77:session:gameplayReady`. This module is what sends it. Without it the
-- loading cover never lifts, no world loads, no gate ever opens and nobody sees
-- anybody else's body. It also spends the one-shot character bootstrap at join,
-- which is what decides the body the world loads with.
--
-- Two ideas run through the whole module.
--
-- 1. A FACE IS NOT A MESH. A snapshot is a list of positions in the engine's
--    customization catalogue -- for each option, which index the player chose --
--    so it only means anything against the catalogue it was captured on. A face
--    from another game build is refused, never applied: applying it would put a
--    different face on the puppet rather than failing.
-- 2. A FUNCTION THAT YIELDS MUST BE ABLE TO GIVE UP. Every restore, every editor
--    and every publication carries a generation token, and a thread holding an
--    older one stops instead of finishing work for a character that has gone.
--
-- The body family is NOT chosen by a form. The engine's own character creator
-- asks for it and builds the face in the same flow, and what it answers is
-- written once to `charInfo.gender` on the character row; from then on this
-- module only reloads the world onto it. That is also why `gender` inside a
-- snapshot is something else entirely: the engine's opaque 64-bit body hash,
-- never the female/male string.

local M = OPX.Modules.Declare{
	id = 'appearance',
	side = 'both',
	-- Every face and every clothing record is keyed on the citizen id, and only
	-- the character module knows which character a player has loaded.
	requires = { 'character' },
	-- THE TWO VIEWS, and neither is a requirement. This module owns the state
	-- machines behind the appearance panel and the fitting room and draws
	-- neither; `client/view.lua` hands the first to `menu` and the second to
	-- `panel`. With them absent the state machines still run, still refuse
	-- correctly and still publish -- nothing draws, which is exactly what
	-- happened before this seam had an other end. Declared so the two are
	-- ordered ahead of this module rather than because anything breaks.
	optional = { 'menu', 'panel' },
	fatal = true,
}

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (core/shared/channels.lua): the
-- host dispatcher matches on the name alone, so a local `TriggerEvent` on a NET
-- name would re-enter the `RegisterNetEvent` handler of that name.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL
local INTERNAL = OPX.Channel.INTERNAL

M.Event = {
	-- Client to server. Every payload is attacker-controlled; only `source` is not.
	SAVE_FACE = OPX.Event(NET, 'appearance', 'saveFace'),
	SAVE_CLOTHING = OPX.Event(NET, 'appearance', 'saveClothing'),
	PRESENT = OPX.Event(NET, 'appearance', 'present'),
	ABSENT = OPX.Event(NET, 'appearance', 'absent'),
	REPLAY = OPX.Event(NET, 'appearance', 'replay'),
	-- `DIAGNOSTIC` was here, with its own forty-line bound on the server. It is
	-- `OPX.Note` now: `modules/diagnostics` had opened the same door for the same
	-- reason, and two independent inventions of one thing belong a level down.
	-- One bound and one counter, rather than two racing for the same journal.

	-- Server to client.
	FACE_SAVED = OPX.Event(NET, 'appearance', 'faceSaved'),
	CLOTHING_SAVED = OPX.Event(NET, 'appearance', 'clothingSaved'),
	REFUSED = OPX.Event(NET, 'appearance', 'refused'),
	PRESENT_ACK = OPX.Event(NET, 'appearance', 'presentAck'),
	-- THE PLAYER ASKING FOR THEIR OWN APPEARANCE PANEL, and it is the only way in
	-- that is not the join. The panel and the fitting room have had a contract
	-- (`OpenPanel`, `OpenWardrobe`) since they were written and NOTHING IN THIS
	-- RUNTIME EVER CALLED EITHER -- so 'offer it at creation and otherwise only
	-- when the player asks' had no second half at all: a policy of 'first' or
	-- 'never' meant the room was unreachable for the rest of the character's life.
	-- A command rather than a key: `open77_pause` owns Escape, the menu owns F1,
	-- and a third binding for a screen a player opens twice a session is a key
	-- taken away from something they use every minute.
	OPEN_PANEL = OPX.Event(NET, 'appearance', 'openPanel'),

	-- The fitting room, opened on a player from the server. A DIFFERENT SCREEN
	-- from `OPEN_PANEL` above, which is the appearance panel: this one borrows
	-- the puppet and puts the slot sliders up. Staff reach it through the admin
	-- menu; nothing a player can raise reaches it, because the gate that decides
	-- whether a room may open at all lives on their client and is not something
	-- the wire should be able to talk past.
	OPEN_WARDROBE = OPX.Event(NET, 'appearance', 'openWardrobe'),
	REPLAYED = OPX.Event(NET, 'appearance', 'replayed'),
	LOOK = OPX.Event(NET, 'appearance', 'look'),
	RESEND = OPX.Event(NET, 'appearance', 'resend'),
	-- A command asked for one of the two views, and `kind` names which. The
	-- server owns the command and the client owns the state machine, so this is
	-- how the first reaches the second -- the same shape `admin` uses for its
	-- own travel doors.
	SHOW = OPX.Event(NET, 'appearance', 'show'),

	-- Client to server, every two minutes while a fitting room is open: "the
	-- room is still up". The server keeps the room's save grant alive with it,
	-- up to a hard cap, so a long browse is not answered "not saved".
	ROOM_ALIVE = OPX.Event(NET, 'appearance', 'roomAlive'),

	-- The client's own bus. `decision` is what this module says after every
	-- decision it reaches, and is public: a bare AddEventHandler listens to it.
	-- `view` is the seam a view module attaches to; see client/wardrobe.lua.
	ON_DECISION = OPX.Event(LOCAL, 'appearance', 'decision'),
	ON_VIEW = OPX.Event(LOCAL, 'appearance', 'view'),

	-- Between modules inside one VM. Never crosses the wire.
	IN_FACE = OPX.Event(INTERNAL, 'appearance', 'face'),
	IN_CLOTHING = OPX.Event(INTERNAL, 'appearance', 'clothing'),
}

--- Host-owned names this module listens to, or raises at the host.
-- `OPX.Host` lists the ones core uses; these belong to the appearance, session
-- and shell services, and are listed once here so a typo is a nil index.
M.HostEvent = {
	CONFIRMED = 'open77:appearance:confirmed',
	CANCELLED = 'open77:appearance:cancelled',
	RESTORE_FAILED = 'open77:appearance:restore_failed',
	RESET_COMPLETE = 'open77:playerReset:complete',
	-- The same reset, given up on by the host. A resource-client event on the
	-- devkit's list beside `complete`; nothing here listened to it, so a reset
	-- that failed was waited on for the whole of RESET_WAIT_MS.
	RESET_FAILED = 'open77:playerReset:failed',
	SHELL_HIDE = 'open77:shell:hide',
	BUCKET_CHANGE = 'onPlayerBucketChange',
}

--- Which request a refusal answers.
-- Without it a client waiting on a face save and a clothing save at once cannot
-- tell which refusal is whose.
M.Operation = {
	SAVE_FACE = 'appearance.saveFace',
	SAVE_CLOTHING = 'appearance.saveClothing',
}

--- The platform's own appearance package.
-- It spends the same one-shot bootstrap, stores its own clothing and hands out
-- its own looks, so both halves of this module stand down while it runs rather
-- than fighting it over the same puppet.
M.OFFICIAL = 'open77_appearance'

--- The three answers to "which world enters are handed the fitting room?".
-- @author dop42
--
-- A CLOSED SET, NAMED HERE RATHER THAN SPELLED OUT AT THE COMPARISON, and the
-- same shape `spawn.Policy` is for the same reason: the client half branches on
-- these three strings, the suite asserts against them and the operator types one
-- of them into `config/appearance.lua`. A literal `'never'` written at each of
-- those places is three copies of a value with nothing keeping them in step, and
-- a typo in any one of them is a branch that is simply never taken.
--
-- Declared in module.lua and not in the client half because this file is the one
-- both sides and the test host load: the vocabulary has to be nameable from
-- outside the half that acts on it.
M.WardrobePolicy = {
	-- Only a character the game's own creator has just built. `created` on the
	-- decision bus is what says so, and it is raised once per character ever --
	-- so this is "dress the new one, never interrupt anybody else".
	FIRST = 'first',
	-- Every world enter, a returning character included, once its stored clothes
	-- are on. The room opens over a dressed puppet rather than a pristine one,
	-- so 'cancel' really does put back what the player was wearing.
	ALWAYS = 'always',
	-- Nobody, ever. No room, no retry thread, and nothing on the bus for the join
	-- sequence to wait behind: the spawn menu follows the name form directly.
	NEVER = 'never',
}

--- What an unreadable `WARDROBE.OFFER_POLICY` falls back to.
-- FIRST, because it is what this module did when the setting was the boolean
-- `OPEN_AFTER_CREATION` and that boolean shipped true: a fallback that changed
-- behaviour would make a typo in the configuration look like a feature somebody
-- had asked for.
M.WARDROBE_POLICY_DEFAULT = M.WardrobePolicy.FIRST

--- Whether a value is one of the three fitting-room policies.
-- Answers the value itself rather than a boolean, so a caller reads
-- `M.KnownWardrobePolicy(raw) or M.WARDROBE_POLICY_DEFAULT` in one line -- but
-- the refusal is still the caller's to journal, because a warning belongs where
-- it can be said once at start rather than on every join.
-- @author dop42
-- @param value any
-- @return string|nil
function M.KnownWardrobePolicy(value)
	if type(value) ~= 'string' then return nil end
	for _, known in pairs(M.WardrobePolicy) do
		if value == known then return known end
	end
	return nil
end

--- Settles the configured fitting-room policy, naming a bad one in the journal.
-- @author dop42
--
-- RESOLVED ONCE, at `Init`, for the reason `spawn.Init` resolves its own: a
-- setting read at the point of use is a setting whose typo is reported on every
-- join, in the middle of a join's own log lines, where nobody reads it. Resolved
-- at boot it is said once, in the block an operator scans after editing a config
-- file, and every join afterwards reads a value already known to be one of three.
--
-- A NAMED FUNCTION rather than the handful of lines inlined in the client's
-- `Init`, which is where `spawn` puts its own, because this module is `both` and
-- its client half REFUSES TO START at all on a host with no native appearance
-- API. Here, the suite can put a value in front of it without standing up a
-- client VM full of natives the test host does not have -- and the journal line
-- about a typo is exactly the line an operator on such a host still needs.
-- @return string one of `M.WardrobePolicy`
function M.ResolveWardrobePolicy()
	local config = type(M.Settings.WARDROBE) == 'table' and M.Settings.WARDROBE or {}
	local configured = config.OFFER_POLICY
	local policy = M.KnownWardrobePolicy(configured)
	if policy ~= nil then return policy end

	-- NAMED, NOT SILENT. An unknown policy that quietly became 'first' would be
	-- indistinguishable from an operator who meant 'first', and one that quietly
	-- became 'never' would look exactly like the fitting room being broken. Both
	-- values are on the line so the journal says what was refused and what is
	-- running instead.
	Open77.log.warn(('[appearance] WARDROBE.OFFER_POLICY %s is not one of ' ..
		'first/always/never; offering on %s instead')
		:format(tostring(configured), M.WARDROBE_POLICY_DEFAULT))
	return M.WARDROBE_POLICY_DEFAULT
end

-- The two body families the engine and `charInfo.gender` know. Both halves read
-- this, so a family one accepts and the other refuses cannot happen.
local FAMILIES = { female = true, male = true }

--- Whether a value names one of the two body families.
-- @author dop42
-- @param value any
-- @return boolean
function M.IsFamily(value)
	return type(value) == 'string' and FAMILIES[value] == true
end

--- Whether a stored face from this game build may be read back.
-- @author dop42
-- @param value any
-- @return boolean
function M.BuildAccepted(value)
	local builds = M.Settings.GAME_BUILDS
	return type(value) == 'string' and type(builds) == 'table' and builds[value] == true
end

--- Reads a configured duration, nil when it is not a finite non-negative number.
-- Every deadline in this module goes through it, so a setting somebody emptied
-- falls back to the shipped value rather than freezing a wait for ever: an
-- infinity passes every `<` a plain guard would write.
-- @author dop42
-- @param value any
-- @return number|nil
function M.ConfigMs(value)
	local wait = tonumber(value)
	if not OPX.Math.IsFinite(wait) or wait < 0 then return nil end
	return wait
end
