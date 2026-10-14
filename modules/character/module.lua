--- Users, characters, groups, money and the roster: everything that outlives a
--- session.
-- @author dop42
--
-- Fatal, because nothing else has a state to read without it: a job board, an
-- inventory and a vehicle all name a character, and there is no character here
-- to name.
--
-- Two ideas run through the whole module and are worth having before reading it.
--
-- 1. A SESSION is a connected machine and a PLAYER is a loaded character. Someone
--    at the selection screen has a session and no player. Every caller that
--    confuses the two either refuses a legitimate connection or trusts a
--    character that was never loaded. Sessions belong to core; the roster of
--    loaded characters belongs here.
-- 2. THERE IS NO EXISTENCE ORACLE. Somebody else's character answers exactly the
--    same code as a character that does not exist (`character.notFound`).
--    Answering "not yours" would tell an attacker the id is real. The attempt is
--    written to the audit log instead.

local M = OPX.Modules.Declare{
	id = 'character',
	side = 'both',
	fatal = true,
}

--- Every event name this module raises, built once so both halves agree.
-- The three prefixes are disjoint by construction (see core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local `TriggerEvent` would
-- otherwise re-enter the `RegisterNetEvent` handler of the same name. A verb may
-- therefore repeat across channels -- NET `loaded` and LOCAL `loaded` are two
-- different names -- but never within one.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL
local INTERNAL = OPX.Channel.INTERNAL

M.Event = {
	-- Server to client. A listener holds `network.events` and uses RegisterNetEvent.
	LOADED = OPX.Event(NET, 'character', 'loaded'),
	UNLOADED = OPX.Event(NET, 'character', 'unloaded'),
	DATA = OPX.Event(NET, 'character', 'data'),
	MONEY = OPX.Event(NET, 'character', 'money'),
	JOB = OPX.Event(NET, 'character', 'job'),
	GANG = OPX.Event(NET, 'character', 'gang'),

	-- Client to server. Every payload is attacker-controlled; only `source` is not.
	--
	-- There is no `select`, no `create` and no `delete` on this wire. A connection
	-- enters on the character its account is LOCKED on and on no other, and the
	-- lock is moved by a command, never by a client message -- `announce` is the
	-- whole of what a client asks for. `name` is the one thing left that a player
	-- types, and it is accepted once per character.
	ANNOUNCE = OPX.Event(NET, 'character', 'announce'),
	NAME = OPX.Event(NET, 'character', 'name'),
	HEADING = OPX.Event(NET, 'character', 'heading'),

	-- The client's own bus, raised after the mirror is updated so that a handler
	-- reading the contract sees the change. Public: a bare AddEventHandler.
	ON_LOADED = OPX.Event(LOCAL, 'character', 'loaded'),
	ON_UNLOADED = OPX.Event(LOCAL, 'character', 'unloaded'),
	ON_CHANGED = OPX.Event(LOCAL, 'character', 'changed'),
	ON_MONEY = OPX.Event(LOCAL, 'character', 'money'),
	ON_JOB = OPX.Event(LOCAL, 'character', 'job'),
	ON_GANG = OPX.Event(LOCAL, 'character', 'gang'),
	-- Server only, public. A character row made, and one deleted (soft): the
	-- creator surface's announcement of both, `(source, { citizenId, userId, ... })`.
	ON_CREATED = OPX.Event(LOCAL, 'character', 'created'),
	ON_DELETED = OPX.Event(LOCAL, 'character', 'deleted'),

	-- Between modules inside one VM. Never crosses the wire.
	IN_LOADED = OPX.Event(INTERNAL, 'character', 'loaded'),
	IN_UNLOADED = OPX.Event(INTERNAL, 'character', 'unloaded'),
	IN_MONEY = OPX.Event(INTERNAL, 'character', 'money'),
	IN_JOB = OPX.Event(INTERNAL, 'character', 'job'),
	IN_GANG = OPX.Event(INTERNAL, 'character', 'gang'),
	-- `(source, citizenId)`. THE CASCADE, AND THE ONLY ONE THERE IS.
	--
	-- Every table keyed on a citizen id carries `ON DELETE CASCADE` onto
	-- `opx77_characters` and NOT ONE OF THEM HAS EVER FIRED on a player deleting
	-- a character, because the delete is SOFT: `deleted_at` is stamped and the
	-- row stays, so the slot is freed without losing the history, and a cascade
	-- fires for a DELETE and never for an UPDATE. The foreign keys are correct
	-- and they answer a different question -- what happens if a row is really
	-- removed, which only the rollback of a failed create ever does.
	--
	-- So this is what removes a deleted character's clothes, needs, down row,
	-- containers and cars, and each of those modules answers for its OWN tables:
	-- a list of table names in one module's config -- which is what
	-- `CHARACTERS.CASCADE_TABLES` is, and it ships empty -- is a list somebody
	-- has to remember to extend every time a module gains a table, and the one
	-- that was forgotten leaves rows nothing will ever read again and nothing
	-- will ever find.
	--
	-- Raised INSIDE the deleting coroutine, so a handler may yield and the purge
	-- has finished before the player is told. It is raised after the row is
	-- stamped, so a handler that reads the character back sees it gone.
	IN_DELETED = OPX.Event(INTERNAL, 'character', 'deleted'),
	IN_PAYCHECK = OPX.Event(INTERNAL, 'character', 'paycheck'),
}

--- Which request a refusal answers.
-- Passed to `OPX.Refuse`, whose channel is core's: without it a client waiting on
-- one of several requests cannot tell which `error.tooFast` is its own.
M.Operation = {
	ENTRY = 'entry',
	NAME = 'name',
}

-- The three helpers below are here rather than in one half because both halves
-- need the same answer from them: a name the client accepts and the server
-- refuses is a form that fails after the player has filled it in.

--- The pattern each half of a character name must match.
-- A letter is described by a byte range rather than `%a`, which is ASCII only and
-- would refuse "Eloise" spelled properly. Four-byte lead bytes are excluded:
-- that is where the emoji live.
local LETTER = '%a\194-\239\128-\191'
M.NAME_PATTERN = ("^[%s][%s '%%-]*$"):format(LETTER, LETTER)

--- Validates one half of a character name against the configured bounds.
-- @author dop42
-- @param value any
-- @return Result
-- CODE POINTS THAT DRAW NOTHING OR TURN THE TEXT AROUND, as inclusive ranges.
-- `LETTER` admits any two- or three-byte sequence, which let a name be two
-- zero-width spaces (a character nobody can read or report), carry a
-- right-to-left override that reverses whatever is drawn after it, or hold a
-- line separator or a C1 control. None of them is a letter in anybody's name.
local INVISIBLE = {
	{ 0x0000, 0x001F }, { 0x007F, 0x009F }, -- C0, DEL and C1 controls
	{ 0x00A0, 0x00A0 }, { 0x00AD, 0x00AD }, -- no-break space, soft hyphen
	{ 0x034F, 0x034F }, { 0x061C, 0x061C }, -- grapheme joiner, Arabic letter mark
	{ 0x115F, 0x1160 }, { 0x17B4, 0x17B5 }, -- Hangul fillers, Khmer inherent vowels
	{ 0x180B, 0x180F }, -- Mongolian variation selectors and vowel separator
	{ 0x2000, 0x200F }, -- the typographic spaces, zero-width, LRM and RLM
	{ 0x2028, 0x202F }, -- line and paragraph separators, LRE..RLO, narrow nbsp
	{ 0x205F, 0x206F }, -- math space, word joiner, invisible operators, LRI..PDI
	{ 0x3000, 0x3000 }, { 0x3164, 0x3164 }, -- ideographic space, Hangul filler
	{ 0xFE00, 0xFE0F }, { 0xFEFF, 0xFEFF }, -- variation selectors, BOM
	{ 0xFFA0, 0xFFA0 }, { 0xFFF0, 0xFFFB }, -- halfwidth filler, specials
}

--- Whether a valid UTF-8 text holds a code point from `INVISIBLE`.
local function hidesSomething(text)
	local codes = utf8 and utf8.codes
	if codes == nil then return false end
	for _, code in codes(text) do
		-- Printable ASCII is the pattern's to decide.
		if code < 0x20 or code >= 0x7F then
			for index = 1, #INVISIBLE do
				local range = INVISIBLE[index]
				if code >= range[1] and code <= range[2] then return true end
			end
		end
	end
	return false
end

function M.ValidateName(value)
	local bounds = M.Settings.CHARACTERS.NAME
	local checked = OPX.Validate.Text(value, {
		min = bounds.MIN,
		max = bounds.MAX,
		pattern = M.NAME_PATTERN,
	})
	if checked.ok and hidesSomething(checked.value) then return OPX.Result.Err('invisible') end
	return checked
end

--- The sentence for a name `ValidateName` refused, and the bounds it names.
-- A name that was too short read "Use letters only (spaces, hyphens and
-- apostrophes allowed)." -- wrong, for a name of letters -- and nothing on the
-- form says how short is too short. Length and spelling are told apart.
-- @author dop42
-- @param checked table the Result `ValidateName` answered
-- @return string the locale key
-- @return table the `{min}` and `{max}` the length sentence names
function M.NameRefusal(checked)
	local bounds = M.Settings.CHARACTERS.NAME
	local reason = type(checked) == 'table' and checked.error or nil
	local key = (reason == 'too-short' or reason == 'too-long') and 'character.nameLength'
		or reason == 'invisible' and 'character.nameInvisible'
		or 'character.badName'
	return key, { min = tonumber(bounds.MIN) or 1, max = tonumber(bounds.MAX) or 1 }
end

--- The two ways `opx.select` can move an account onto another character.
-- @author dop42
--
-- A CLOSED SET, NAMED HERE RATHER THAN SPELLED OUT AT THE COMPARISON, the same
-- shape `spawn.Policy` is and for the same reason: the server branches on these
-- strings, the suite asserts against them and the operator types one into
-- `config/character.lua`.
--
-- THE DIFFERENCE BETWEEN THEM IS NOT A PREFERENCE, and neither covers
-- `opx.create`. A NEW character has no body, so it needs the game's own
-- character creator -- and that creator is drawn by the game's MAIN MENU, for
-- the character-bootstrap transaction, which is spent before the world exists.
-- Measured in game on 2026-09-17 against 2.31.13+op77.81: resetting the
-- bootstrap mid-session does arm a fresh transaction and the creator request IS
-- granted, but no creator is ever drawn -- the shell takes the world down for a
-- bootstrap it now expects answered and the player sits under the loading cover
-- until they kill the connection. The platform has `Open77.network.disconnect`
-- and no reconnect, so there is no soft path to offer either. `opx.create`
-- therefore ends the session whatever this says, and always will.
--
-- An EXISTING character is a different question, because it needs no creator:
-- it needs the right body, which is a body reload the appearance module already
-- performs on its own whenever the loaded character's family differs from the
-- one in play (`ensureFamily`). That is what makes `relog` possible at all.
M.Switch = {
	-- Take the other character here, in the world, with no disconnect: save the
	-- one being left, load the other, place it, and let the client reload the
	-- body, the face and the clothes onto it. The whole of this already existed
	-- as `M.SelectCharacter`; it simply had nothing calling it.
	RELOG = 'relog',
	-- Move the lock and end the session, so the next connection arrives on the
	-- new character. What this module did before the setting existed, and still
	-- the honest fallback: a relog that is refused for any reason falls back to
	-- it rather than leaving the player on a character they asked to leave.
	RECONNECT = 'reconnect',
}

--- What an unreadable `CHARACTERS.SWITCH` falls back to.
-- RECONNECT, because it is what this module did before the setting existed: a
-- fallback that changed behaviour would make a typo in the configuration look
-- like a feature somebody had asked for.
M.SWITCH_DEFAULT = M.Switch.RECONNECT

--- Whether a value is one of the two switch modes.
-- Answers the value itself rather than a boolean, so a caller reads
-- `M.KnownSwitch(raw) or M.SWITCH_DEFAULT` in one line -- but the refusal is
-- still the caller's to journal, because a warning belongs where it can be said
-- once at start rather than on every switch.
-- @author dop42
-- @param value any
-- @return string|nil
function M.KnownSwitch(value)
	if type(value) ~= 'string' then return nil end
	for _, known in pairs(M.Switch) do
		if value == known then return known end
	end
	return nil
end

--- Reads a configured number with a floor.
-- The floor is also the answer for a setting that is missing or not a finite
-- number, so that no caller ever compares a number against nil. The test is
-- finiteness and not `value ~= value`: an infinity passes a NaN test and would
-- freeze an interval. This is where a live tunables service plugs in.
-- @author dop42
-- @param value any
-- @param floor number
-- @return number
function M.Number(value, floor)
	value = tonumber(value)
	if not OPX.Math.IsFinite(value) then return floor end
	if floor and value < floor then return floor end
	return value
end
