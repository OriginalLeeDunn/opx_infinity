--- Multicharacter: the roster, creation, deletion, selection and placement.
-- @author dop42
--
-- Everything here reads the database, so every function in this file is
-- coroutine only.

local M = OPX.Modules.Get('character')

local Result = OPX.Result

--- The health pool this server places a body with, in points.
--- Read at call time and never captured: `config/shared.lua` is a shared script
--- and the value is an operator's to change between restarts, not a constant to
--- bake into a closure at load.
local function healthMaximum()
	local shared = OPX.Config.SHARED.HEALTH
	local wanted = type(shared) == 'table' and OPX.Math.Finite(shared.MAX) or nil
	-- 1 rather than 100 as the floor: a pool of zero would make every fraction
	-- below a division by zero, and a body nobody can hurt is not what an
	-- operator who typed a bad number meant. The engine's own default is the
	-- fallback, because it is the only value certain to work.
	if wanted == nil or wanted < 1 then return 100 end
	return math.floor(wanted)
end

--- The stored health of a character, in points, against the pool it will be
--- placed in.
---
--- HEALTH IS PERSISTED IN POINTS, so every row written before `HEALTH.MAX`
--- existed holds a number on a 0..100 scale. Read naively against a pool of
--- 250, a character who logged out unhurt comes back at 40% -- a punishment for
--- a setting they did not change, applied to everybody at once, the first time
--- the pool is raised. A row at or above what the old scale called full is
--- therefore placed full. It costs nothing once the pool has been raised: a
--- character hurt below the legacy full value still comes back hurt.
local function healthPoints(stored, maximum)
	local points = OPX.Math.Finite(stored)
	if points == nil then return maximum end

	local shared = OPX.Config.SHARED.HEALTH
	local legacy = type(shared) == 'table' and OPX.Math.Finite(shared.LEGACY_FULL) or nil
	if legacy ~= nil and maximum > legacy and points >= legacy then return maximum end

	return OPX.Math.Clamp(points, 0, maximum)
end

--- Answers how many characters an account may hold.
local function slotsFor(userId)
	return M.Settings.CHARACTERS.SLOTS_BY_USER[userId]
		or M.Number(M.Settings.CHARACTERS.DEFAULT_SLOTS, 3)
end

--- Trims a character entity to what the selection screen shows.
-- Deliberately not the whole entity: the money, the metadata and the stored
-- position are nobody's business until a character is loaded, not even the
-- account holder's.
local function toSummary(entity)
	return {
		citizenId = entity.citizenId,
		cid = entity.cid,
		firstName = entity.charInfo.firstName,
		lastName = entity.charInfo.lastName,
		gender = entity.charInfo.gender,
		job = entity.job and entity.job.label,
		gang = entity.gang and entity.gang.name ~= 'none' and entity.gang.label or nil,
		lastLoggedOut = entity.lastLoggedOut,
	}
end

--- The account's characters, and which one it is locked on. Coroutine only.
-- @author dop42
--
-- Nothing is sent to the client: there is no selection screen to fill. This is
-- read by the command that prints the list, and by nothing else.
-- @param source Source
-- @return Result `{ characters, slots, active }`
function M.ListCharacters(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local account = M.Storage.UpsertAccount(session.userId, session.displayName)
	if not account.ok then return account end

	local characters = M.Storage.FetchAll(session.userId)
	if not characters.ok then return characters end

	local active = M.Storage.FetchActive(session.userId)

	local list = characters.value
	local summaries = {}
	for i = 1, #list do summaries[i] = toSummary(list[i]) end

	return Result.Ok({
		characters = summaries,
		slots = slotsFor(session.userId),
		active = active.ok and active.value or nil,
	})
end

--- Creates a character on the caller's own account. Coroutine only.
-- @author dop42
--
-- IT CARRIES NOTHING. A character is a row before it is anybody: the body family
-- is the game's own creator's answer (`SetBodyFamily`), the name is typed once
-- the player is in the world (`SetName`), and both are written to this row after
-- the fact, once each. There is nothing to validate here and nothing a client
-- could send that would be believed -- the account comes from the session, which
-- is the only value a client cannot forge.
-- @param source Source
-- @return Result the summary of the row that was made
function M.CreateCharacter(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	if OPX.Cooling(source, 'create', 3000) then
		return Result.Err('error.tooFast', tostring(source))
	end

	-- The ceiling counts ROWS and not characters: a soft delete keeps the row
	-- while `NextCid` frees the slot.
	local rows = M.Storage.CountRows(session.userId)
	if not rows.ok then return rows end
	local ceiling = M.Number(M.Settings.CHARACTERS.ROW_CEILING, 60)
	if rows.value >= ceiling then
		Open77.log.warn(('[character] %s has %d character rows, at the ceiling of %d')
			:format(session.userId, rows.value, ceiling))
		return Result.Err('character.rowLimit', tostring(ceiling))
	end

	local slots = slotsFor(session.userId)
	local cid = M.Storage.NextCid(session.userId, slots)
	if not cid.ok then return cid end

	local job = M.Groups.ResolveJob(M.Settings.PLAYER.DEFAULT_JOB, 0)
	if not job.ok then return job end
	local gang = M.Groups.ResolveGang(M.Settings.PLAYER.DEFAULT_GANG, 0)
	if not gang.ok then return gang end

	local money = {}
	for moneyType in pairs(OPX.Config.SHARED.MONEY.TYPES) do
		money[moneyType] = math.floor(tonumber(M.Settings.MONEY.STARTING[moneyType]) or 0)
	end

	local entity
	for attempt = 1, 5 do
		entity = {
			citizenId = OPX.CitizenId.Generate(),
			userId = session.userId,
			cid = cid.value,
			name = session.displayName,
			-- Names and `gender` are absent ON PURPOSE, and nothing may read either
			-- as though it were there: the body family is unknown until the creator
			-- answers one, and the name until the player has typed it. `M.IsFamily`
			-- is false for nil on both sides, and a nameless row draws as its slot.
			charInfo = {
				phone = OPX.String.Random('111-111-1111'),
			},
			money = money,
			job = job.value,
			gang = gang.value,
			position = nil,
			metadata = OPX.Table.DeepCopy(M.Settings.PLAYER.STARTING_METADATA),
		}

		local inserted = M.Storage.Insert(entity)
		if inserted.ok then break end

		-- Only a collision is worth another draw; any other error would fail five
		-- times over.
		if not tostring(inserted.detail or ''):lower():find('duplicate') then
			return inserted
		end
		if attempt == 5 then
			return Result.Err('error.unavailable', 'no free citizen id after 5 draws')
		end
		Open77.log.warn('[character] citizen id collision, drawing another')
	end

	-- The two membership rows are not optional: making a job primary checks the
	-- membership row, and a character without one would be refused its own default
	-- job for ever. If they fail the character is removed rather than answered --
	-- the row is seconds old, holds nothing, and the memberships cascade.
	local jobRow = M.Storage.UpsertGroup(entity.citizenId, 'job', entity.job.name, 0)
	local gangRow = M.Storage.UpsertGroup(entity.citizenId, 'gang', entity.gang.name, 0)
	if not jobRow.ok or not gangRow.ok then
		local failed = not jobRow.ok and jobRow or gangRow
		local undone = M.Storage.DeleteRow(entity.citizenId)
		if not undone.ok then
			Open77.log.error(('[character] %s was inserted, its memberships failed (%s), and the ' ..
				'row could not be removed either (%s): it has to go by hand')
				:format(entity.citizenId, tostring(failed.detail), tostring(undone.detail)))
		end
		return Result.Err('error.unavailable', tostring(failed.detail))
	end

	OPX.Audit.Log({
		event = 'character.create',
		message = ('slot %d'):format(entity.cid),
		citizenId = entity.citizenId,
		userId = session.userId,
		source = source,
	})
	Open77.log.info(('[character] %s created %s, slot %d, with no name and no body yet')
		:format(session.displayName, entity.citizenId, entity.cid))
	OPX.Publish(M.Event.ON_CREATED, source, {
		citizenId = entity.citizenId,
		userId = session.userId,
		slot = entity.cid,
	})

	return Result.Ok(toSummary(entity))
end

-- Forward-declared: `M.SwitchTo` below takes the other character here in the
-- world when the operator asked for a relog, and the function that does it is
-- three hundred lines further down. Declared here rather than moving either of
-- them, because without the `local` the call in `SwitchTo` would compile against
-- a GLOBAL of the same name -- nil, and a raise inside a command thread rather
-- than anything a reader would look for.
local enterCharacter

--- Ends a session so that the next one enters on the lock as it now stands.
-- @author dop42
--
-- THE DISCONNECT IS THE MECHANISM, not a punishment, and it is why moving the
-- lock is a command and not a menu. The body a world is loaded with is the
-- character bootstrap's answer, and that transaction is spent before the world
-- exists -- so the only honest way to play another character is to arrive as one.
-- The departure path saves the character that was loaded, exactly as a quit does.
local function endSession(source, reason)
	local dropped, why = Open77.players.disconnect(source, reason)
	if dropped then return true end
	Open77.log.error(('[character] %d could not be disconnected for a character change: %s')
		:format(source, tostring(why)))
	return false
end

--- Locks the account on another of its characters and ends the session.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result the summary of the character that was locked
function M.SwitchTo(source, citizenId)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end

	local wanted = M.Storage.FetchOne(parsed.value)
	if not wanted.ok then return wanted end

	-- Somebody else's character answers the same code as one that does not exist:
	-- anything else is an oracle for which citizen ids are real.
	if wanted.value.userId ~= session.userId then
		OPX.Audit.Security('character.notYours',
			('player %d asked to be locked on %s'):format(source, parsed.value),
			{ userId = session.userId, owner = wanted.value.userId }, source)
		return Result.Err('character.notFound', parsed.value)
	end

	local current = M.GetPlayer(source)
	if current ~= nil and current.PlayerData.citizenId == parsed.value then
		return Result.Err('character.alreadyPlaying', parsed.value)
	end

	local already = M.GetPlayerByCitizenId(parsed.value)
	if already ~= nil and already.PlayerData.source ~= source then
		return Result.Err('character.inUse', parsed.value)
	end

	local locked = M.Storage.SetActive(session.userId, parsed.value)
	if not locked.ok then return locked end

	OPX.Audit.Log({
		event = 'character.switch',
		message = parsed.value,
		citizenId = current and current.PlayerData.citizenId or nil,
		userId = session.userId,
		source = source,
	})

	-- THE SOFT PATH, when the operator asked for it. `enterCharacter` was written
	-- for exactly this and had nothing calling it: it awaits the save of the
	-- character being left, refuses the switch rather than losing it, loads the
	-- other one, and -- because the gate is already open for somebody standing in
	-- the world -- places the body on the spot instead of queueing it. It sets the
	-- lock itself at the end, so the next connection comes back to whatever
	-- actually entered.
	--
	-- Only an EXISTING character can go this way, which is all this function ever
	-- handles: a new one needs the game's own creator, and that is a join-time
	-- screen. See `M.Switch` for the measurement behind that.
	if M.SwitchMode == M.Switch.RELOG then
		local entered = enterCharacter(source, parsed.value)
		if entered.ok then return Result.Ok(toSummary(wanted.value)) end
		-- FALLING BACK RATHER THAN STOPPING. The lock has already moved, so a
		-- player left standing here is on a character they asked to leave and
		-- would get the other one on their next connection anyway. The disconnect
		-- makes that connection now, and saves them again on the way out.
		Open77.log.warn(('[character] the in-world switch to %s was refused (%s); ' ..
			'ending the session instead'):format(parsed.value, tostring(entered.error)))
	end

	endSession(source, locale('session.switching'))
	return Result.Ok(toSummary(wanted.value))
end

--- Takes the account off every character, so the next session builds one.
-- Nothing is created here: the row is made by the connection that needs it, which
-- is also what hands the player to the creator.
-- @author dop42
-- @param source Source
-- @return Result
function M.NewCharacter(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local rows = M.Storage.CountRows(session.userId)
	if not rows.ok then return rows end
	local ceiling = M.Number(M.Settings.CHARACTERS.ROW_CEILING, 60)
	if rows.value >= ceiling then return Result.Err('character.rowLimit', tostring(ceiling)) end

	local characters = M.Storage.FetchAll(session.userId)
	if not characters.ok then return characters end
	local slots = slotsFor(session.userId)
	if #characters.value >= slots then return Result.Err('character.limit', tostring(slots)) end

	local cleared = M.Storage.ClearActive(session.userId)
	if not cleared.ok then return cleared end

	OPX.Audit.Log({
		event = 'character.new',
		message = ('%d of %d slots used'):format(#characters.value, slots),
		userId = session.userId,
		source = source,
	})
	endSession(source, locale('session.newCharacter'))
	return Result.Ok({ used = #characters.value, slots = slots })
end

--- Soft-deletes a character, and removes everything else it owned.
-- @author dop42
--
-- THE WORKER BEHIND BOTH DOORS: a player deleting their own with `/opx.delete`,
-- and staff deleting somebody else's from the menu. Every check about WHO may do
-- it belongs to the caller -- ownership and `SELF_DELETE` on one side, the ACL on
-- the other -- and none of it is repeated here, so the two cannot drift into
-- removing different amounts of a character.
--
-- `owner` is the account the character belongs to, which is NOT the account
-- asking when staff are the ones asking. Coroutine only.
-- @param citizenId CitizenId already parsed
-- @param owner string the user id the character belongs to
-- @param source Source|nil who asked, for the audit trail
-- @return Result
local function removeCharacter(citizenId, owner, source)
	-- Read BEFORE the delete: the lock is joined against living characters, so a
	-- soft-deleted one answers as no lock at all and this would never match.
	local active = M.Storage.FetchActive(owner)
	local wasActive = active.ok and active.value == citizenId

	-- Out of the world first, or the autosave rewrites the row a minute later.
	local online = M.GetPlayerByCitizenId(citizenId)
	if online then M.Logout(online.PlayerData.source) end

	local deleted = M.Storage.SoftDelete(citizenId)
	if not deleted.ok then return deleted end

	-- A lock naming a character that is gone would cost the next connection a
	-- failed entry before it gave up on it.
	if wasActive then M.Storage.ClearActive(owner) end

	-- THIS MODULE'S OWN SATELLITE TABLE, and it is here rather than left to the
	-- foreign key for the reason the whole block below exists: the delete above is
	-- SOFT, and a cascade fires for a DELETE and never for an UPDATE. Every job
	-- and gang membership of a deleted character used to stay, and `group` listings
	-- counted them.
	M.Storage.DeleteCascade('opx77_character_groups', 'citizen_id', citizenId)

	-- The operator's escape hatch, for tables this runtime does not own. Every
	-- table a MODULE owns is purged by that module on the announcement below
	-- instead, because a list of other people's table names in one config file is
	-- a list somebody has to remember to extend.
	local cascades = M.Settings.CHARACTERS.CASCADE_TABLES
	for i = 1, #cascades do
		local target = cascades[i]
		M.Storage.DeleteCascade(target[1], target[2], citizenId)
	end

	OPX.Audit.Log({
		event = 'character.delete',
		severity = 'warn',
		citizenId = citizenId,
		userId = owner,
		source = source,
	})

	-- THE CASCADE THE FOREIGN KEYS CANNOT DO. Clothes, needs, the down row,
	-- containers and cars are each removed by the module that owns them; see the
	-- event's own comment in module.lua for why none of it happens by itself.
	--
	-- UNDER pcall, and that is not defensive habit: the audit above has already
	-- been written and `endSession` below is what gets a player out of a character
	-- that no longer exists. A handler that raised would skip it and leave them
	-- standing in the world as nobody, with no screen left to choose on.
	local announced, failure = pcall(TriggerEvent, M.Event.IN_DELETED, source, citizenId)
	if not announced then
		Open77.log.error(('[character] a handler raised while %s was being deleted: %s')
			:format(citizenId, tostring(failure)))
	end
	-- And to every other resource, which keeps its own rows keyed on the
	-- citizen id and has no other way to learn they belong to nobody now.
	OPX.Publish(M.Event.ON_DELETED, online and online.PlayerData.source or nil, {
		citizenId = citizenId,
		userId = owner,
		-- The connection that asked: the player themself, staff, or nil for the
		-- console.
		by = tonumber(source),
	})

	-- Deleting a character somebody is PLAYING leaves them in the world as nobody,
	-- and there is no screen left to choose another one on. Their session ends,
	-- and the next one enters on whatever the lock now says -- a new character,
	-- when this one was it.
	--
	-- `online` and not `source`: staff delete other people's characters, so the
	-- connection that has to end is the one holding the character, which is very
	-- often not the one that asked.
	if online ~= nil then
		endSession(online.PlayerData.source, locale('session.characterDeleted'))
	end
	return Result.Ok(citizenId)
end

--- Whether a player may delete their own character at all.
local function selfDeleteAllowed()
	return M.Settings.CHARACTERS.SELF_DELETE ~= false
end

--- Soft-deletes one of the caller's OWN characters.
-- The cooldown also protects the audit log, since every refused delete writes a
-- security line.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.DeleteCharacter(source, citizenId)
	if OPX.Cooling(source, 'delete', 3000) then
		return Result.Err('error.tooFast', tostring(source))
	end
	-- REFUSED, NOT HIDDEN, AND FIRST. A player who is not allowed to do this is
	-- told so; a command that silently did nothing would have them trying it again
	-- and then asking staff whether it had worked. Ahead of the session read and
	-- the id parse because on a server where this door is shut the answer is the
	-- same for everybody and for every id -- there is nothing to be learnt from
	-- which ids are real, and nothing to look up to say no.
	if not selfDeleteAllowed() then
		return Result.Err('character.deleteNotAllowed', tostring(source))
	end

	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end

	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end
	citizenId = parsed.value

	local fetched = M.Storage.FetchOne(citizenId)
	if not fetched.ok then return fetched end
	-- Somebody else's character answers the same code as a missing one.
	if fetched.value.userId ~= session.userId then
		OPX.Audit.Security('character.deleteRefused',
			('player %d tried to delete %s'):format(source, citizenId),
			{ userId = session.userId, owner = fetched.value.userId }, source)
		return Result.Err('character.notFound', citizenId)
	end

	return removeCharacter(citizenId, session.userId, source)
end

--- Every character on ANOTHER account, for staff who have passed the ACL.
-- @author dop42
--
-- `M.ListCharacters` beside it reads the CALLER's account out of their session,
-- which is right for `/opx.characters` and useless to staff: called with the
-- operator's source it lists the operator's own characters. This one is handed
-- the account to read, and the ownership question is the access list's rather
-- than this function's -- the same split as `M.RemoveCharacter`.
--
-- It does NOT upsert the account row, which the self-service version does: that
-- write exists so a player's first connection records them, and staff reading a
-- roster must not create the thing they are reading.
-- Coroutine only.
-- @param userId UserId
-- @return Result `{ characters, slots, active }`
function M.ListCharactersFor(userId)
	if type(userId) ~= 'string' or userId == '' then
		return Result.Err('character.notFound', tostring(userId))
	end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local characters = M.Storage.FetchAll(userId)
	if not characters.ok then return characters end

	local active = M.Storage.FetchActive(userId)

	local list = characters.value
	local summaries = {}
	for i = 1, #list do
		summaries[i] = toSummary(list[i])
		-- Staff read a row to act on it, and every action takes a citizen id: the
		-- creation date is what tells two otherwise identical unnamed characters
		-- apart, and it is the only date this schema has ever held. There is no
		-- birth date -- lifepath, origin and date of birth were all dropped -- so
		-- there is nothing here for staff to edit, only a record of what happened.
		summaries[i].createdAt = list[i].createdAt
	end

	return Result.Ok({
		characters = summaries,
		slots = slotsFor(userId),
		active = active.ok and active.value or nil,
	})
end

--- The fewest characters a search term may carry.
-- @author dop42
--
-- THREE, AND THE NUMBER IS THE WHOLE RATE LIMIT ARGUMENT. A contains-search over
-- the character table is a scan that stops at the first 26 matches, so its cost
-- is inversely proportional to how common the term is: `a` matches nearly every
-- row and is answered off the front of the primary key almost for free, while a
-- term that matches NOTHING reads the whole table before it can say so. One
-- character is a term an operator types by accident on the way to typing a name,
-- and each of those is a full pass. Three is the shortest term somebody means.
M.FIND_MIN_TERM = 3

-- The longest one. Past this it is not a name, and a `LIKE` pattern that long
-- matches nothing while costing the same scan as one that does.
local FIND_MAX_TERM = 48

-- The longest cursor halves that may come back off the wire. A citizen id is
-- VARCHAR(16) and a MySQL timestamp is 19 characters; both are bound as
-- parameters, so the caps are a sanity floor on a forged cursor and not the
-- thing that stops an injection -- nothing here is concatenated into SQL.
local FIND_MAX_CURSOR = 16
local FIND_MAX_SEEN = 32

--- Whether a value is a usable non-empty string no longer than a cap.
local function shortText(value, cap)
	return type(value) == 'string' and value ~= '' and #value <= cap
end

--- Finds characters across EVERY account, for staff who have passed the ACL.
-- @author dop42
--
-- WHY THE MODULE THAT OWNS ONE ACCOUNT ALSO OWNS THIS. `ListCharactersFor` above
-- reads the characters of an account somebody is holding, and the account is the
-- bound: whatever it answers, it is one person's rows. This one is handed no
-- account at all, because the person it is looking for is NOT CONNECTED and
-- there is no session to read an account out of. It is still a question about
-- what a character is, so it is answered here and reached through the contract,
-- and `admin` calls it from the server where the caller has been through the
-- access list.
--
-- IT NEVER ANSWERS THE WHOLE TABLE. Two modes, and both are bounded in the SQL
-- rather than here:
--
--   recent   the most recently played characters, newest first, paged by a SEEK
--            on (last_logged_out, citizen_id). This is the landing view and it
--            is what staff open the screen for -- "who was just here".
--   search   a term of at least `M.FIND_MIN_TERM` characters against the
--            character's name, the account's display name and the citizen id,
--            paged by a seek on the primary key.
--
-- THERE IS NO "EVERYBODY" MODE, and leaving it out is the design. A staff member
-- has no use for page 187 of ten thousand strangers sorted by nothing, and the
-- query that would serve it is exactly the one that falls over. Everything this
-- answers is either recent or asked for by name.
--
-- IT DOES NOT KNOW WHO IS ONLINE and must not: whether a character is being
-- played is a fact about the runtime that is already stale by the time a row
-- crosses the wire, and a WHERE clause that filtered on it would be a lie with a
-- precise-looking count attached. The caller stamps that, from memory, at the
-- moment it sends.
-- Coroutine only.
-- @param request table `{ mode, term, seenAt, cursor }`
-- @return Result `{ characters, mode, more, seenAt, cursor }`
function M.FindCharacters(request)
	if type(request) ~= 'table' then return Result.Err('error.badRequest', 'request') end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local mode = request.mode
	if mode ~= 'recent' and mode ~= 'search' then
		return Result.Err('error.badRequest', tostring(mode))
	end

	local found
	if mode == 'search' then
		local term = request.term
		if type(term) ~= 'string' then return Result.Err('character.searchShort', 'term') end
		term = OPX.String.Trim((term:gsub('%c', ' ')))
		-- Bytes and not characters, and deliberately the stricter reading: a
		-- two-character term in a multi-byte script would pass a character count
		-- and cost the same full scan the floor exists to refuse.
		if #term < M.FIND_MIN_TERM then
			return Result.Err('character.searchShort', tostring(#term))
		end
		if #term > FIND_MAX_TERM then term = term:sub(1, FIND_MAX_TERM) end
		-- The empty string is below every citizen id, so the first page needs no
		-- branch of its own -- see `FindByTerm`.
		local cursor = shortText(request.cursor, FIND_MAX_CURSOR) and request.cursor or ''
		found = M.Storage.FindByTerm(term, cursor)
	elseif shortText(request.cursor, FIND_MAX_CURSOR)
		and shortText(request.seenAt, FIND_MAX_SEEN) then
		found = M.Storage.FindRecentAfter(request.seenAt, request.cursor)
	else
		-- Half a cursor is no cursor. A seek needs both halves of the sort key, and
		-- reading page one again beats reading a page nobody asked for.
		found = M.Storage.FindRecent()
	end
	if not found.ok then return found end

	-- THE PROBE ROW IS DROPPED HERE AND NEVER SENT. The statements ask for one row
	-- past the page so that `more` can be answered at all; sending it would put a
	-- row on the operator's screen that the next page then shows again.
	local rows = found.value
	local more = #rows > M.Storage.FIND_PAGE
	while #rows > M.Storage.FIND_PAGE do rows[#rows] = nil end

	local last = rows[#rows]
	return Result.Ok({
		characters = rows,
		mode = mode,
		-- False rather than absent when the page is the last one: the caller draws
		-- a row from this and `nil` would read as "not answered yet".
		more = more,
		-- The cursor of the LAST ROW SHOWN, which is what the next seek starts
		-- after. Nil when the page is the last one, so a client cannot ask for a
		-- page that was already said not to exist.
		cursor = more and last and last.citizenId or nil,
		seenAt = more and last and mode == 'recent'
			and last.lastLoggedOut and tostring(last.lastLoggedOut) or nil,
	})
end

--- Renames ANY character, online or not, for staff who have passed the ACL.
-- @author dop42
--
-- `M.SetName` beside it is WRITE-ONCE by design: a character is named by the
-- player who made it, once, and a second write is refused by name so that a
-- client which thinks it owns the name learns that it does not. That rule is for
-- players and it is kept. Staff are the reason a rename has to exist at all --
-- somebody typed a slur, or a name with a typo in it that the player cannot fix
-- because the door closed behind them -- so this is a different door with a
-- different check on it, and it deliberately does not call the other one.
--
-- OFFLINE IS THE NORMAL CASE. A character that needs renaming is usually not the
-- one its account is standing in, so the row is edited directly when nobody is
-- holding it. The `name` column is the denormalised "First Last" the roster
-- reads, so it is rewritten with the halves and never left to drift.
-- Coroutine only.
-- @param citizenId CitizenId
-- @param firstName string
-- @param lastName string
-- @param source Source|nil the staff member, for the audit trail
-- @return Result
function M.RenameCharacter(citizenId, firstName, lastName, source)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end
	citizenId = parsed.value

	-- The same bounds a player's own name is held to. Staff get a bigger door,
	-- not a different alphabet: a name only staff could have written is a name
	-- every other reader of the column still has to cope with.
	local first = M.ValidateName(firstName)
	if not first.ok then return Result.Err('character.badName', 'firstName') end
	local last = M.ValidateName(lastName)
	if not last.ok then return Result.Err('character.badName', 'lastName') end

	local full = ('%s %s'):format(first.value, last.value)

	-- THE ROW IS SETTLED BEFORE IT IS ASKED WHO HOLDS IT, not after: the wait
	-- yields, and a login that finished during it would leave `online` saying
	-- nobody while a loaded character is about to save over the row edited
	-- below. From the lookup to `Enter` nothing yields.
	if not M.Ledger.Settle(citizenId) then
		return Result.Err('error.unavailable', 'the character row is being written')
	end
	local online = M.GetPlayerByCitizenId(citizenId)

	if online ~= nil then
		-- THROUGH THE LIVE CHARACTER, not the row: an autosave a minute later
		-- would write the loaded charInfo straight back over a row edited
		-- underneath it, and the rename would simply undo itself.
		local charInfo = online.PlayerData.charInfo
		charInfo.firstName, charInfo.lastName = first.value, last.value
		online.PlayerData.name = full
		online.Functions.UpdatePlayerData()
		local saved = M.Save(online, false)
		if not saved.ok then return saved end
	else
		-- A READ-MODIFY-WRITE OF THE WHOLE ROW, so it holds the offline ledger:
		-- an offline payment landing between the read and the save would be
		-- written back over with the balance read here. See `M.Ledger`.
		M.Ledger.Enter(citizenId)
		local fetched = M.Storage.FetchOne(citizenId)
		if not fetched.ok then
			M.Ledger.Leave(citizenId)
			return fetched
		end
		local entity = fetched.value
		entity.charInfo.firstName, entity.charInfo.lastName = first.value, last.value
		entity.name = full
		local written = M.Storage.Save(entity, false)
		M.Ledger.Leave(citizenId)
		if not written.ok then return written end
	end

	OPX.Audit.Log({
		event = 'character.rename',
		severity = 'warn',
		message = full,
		citizenId = citizenId,
		source = source,
	})
	Open77.log.info(('[character] %s was renamed to %s by staff'):format(citizenId, full))
	return Result.Ok({ citizenId = citizenId, firstName = first.value, lastName = last.value })
end

--- Soft-deletes ANY character, for staff who have passed the ACL.
-- @author dop42
--
-- THE OWNERSHIP CHECK IS DELIBERATELY ABSENT and `SELF_DELETE` is deliberately
-- not consulted: both of those answer "may this PLAYER delete this character",
-- and the answer here is the access list's instead. Nothing calls this without
-- having passed it -- which is the one thing a reader has to be able to take on
-- trust, so it is stated rather than re-checked: re-checking it here with the
-- wrong permission name would look like protection and be none.
--
-- A character nobody owns cannot be deleted by anybody, so the row is still read
-- first: it is what says which account's lock has to be cleared.
-- @param citizenId CitizenId
-- @param source Source|nil the staff member, for the audit trail
-- @return Result
function M.RemoveCharacter(citizenId, source)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end

	local fetched = M.Storage.FetchOne(parsed.value)
	if not fetched.ok then return fetched end

	return removeCharacter(parsed.value, fetched.value.userId, source)
end

--- Answers whether a life state is alive or dead, and not in transition.
local function isSettled(life)
	return type(life) == 'table' and (life.phase == 'alive' or life.phase == 'dead')
end

--- Lets the position sampler write this character's position.
local function allowSampling(player)
	player.MaySample = true
end

--- Places a loaded character by kill then respawn, never a raw transform.
-- The respawn transaction carries the fade, the streaming preload and the grace
-- window that a teleport skips. Every failing exit leaves `MaySample` false, so
-- the stored position survives for the next attempt.
-- @author dop42
-- @param player Player
-- @param target table|nil an explicit position to use instead of the row's
-- @return boolean, string|nil
function M.PlaceCharacter(player, target)
	local data = player.PlayerData
	local source = data.source
	if not source then return false, 'offline' end

	-- AN EXPLICIT TARGET WINS, and there is no fallback behind it. It is a
	-- position the caller has already decided on -- the spawn module's answer for
	-- a player who picked a place to start -- and quietly falling back to the row
	-- or to the default here would put somebody where they did not ask to go.
	target = type(target) == 'table' and target or data.position
	if not target then
		local spawn = M.Settings.DEFAULT_SPAWN
		if spawn.SET then
			target = { x = spawn.X, y = spawn.Y, z = spawn.Z, heading = spawn.HEADING }
		else
			local standing = Open77.players.position(source)
			if type(standing) ~= 'table' or not OPX.Math.IsFinite(tonumber(standing.x)) then
				-- Sampling is allowed on THIS failure alone: nothing was restored, so
				-- wherever the player is standing becomes their position.
				allowSampling(player)
				return false, 'no-default-spawn'
			end
			target = {
				x = standing.x,
				y = standing.y,
				z = standing.z,
				heading = data.reportedHeading or 0.0,
			}
		end
	end
	-- Never a selection bucket: that belongs to whoever holds a player id now, and
	-- never to a character.
	local bucket = OPX.Buckets.PlacementOf(target.bucket)

	-- The gate is not open yet, and this poll is all that separates placing a
	-- player from placing one mid-transition -- which lays a respawn on top of
	-- another.
	local life
	for _ = 1, 5 do
		life = Open77.players.getLifeState(source)
		if isSettled(life) then break end
		Wait(200)
	end
	if not isSettled(life) then
		return false, 'life-state-' .. tostring(life and life.phase or 'unknown')
	end

	-- Out of the selection bucket BEFORE the kill, as the platform's own modes
	-- move a player before placing them: the respawn names the same bucket, and
	-- nothing replicated from the selection bucket is left to carry over.
	OPX.Buckets.Move(source, bucket, 'placement')

	local killed, killError = Open77.players.kill(source, {
		cause = 'script',
		weapon = 'opx_infinity:placement',
	})
	if not killed then return false, tostring(killError) end

	-- THE POOL IS THE SERVER'S, AND IT IS APPLIED BEFORE THE BODY IS FILLED.
	-- `respawn` and `revive` both take a FRACTION, and the two conversions below
	-- divided stored points by a hard-coded 100 -- so the moment the pool stopped
	-- being 100 every character would have woken at the wrong depth, silently.
	-- `setMaxHealth` is the platform's canonical maximum and the client is told,
	-- never asked; it is set first so the fraction lands against the new pool.
	local maximum = healthMaximum()
	local applied, maxError = Open77.players.setMaxHealth(source, maximum)
	if applied == false then
		Open77.log.warn(('[character] %d keeps the engine default health pool: %s')
			:format(source, tostring(maxError)))
	end

	local health = healthPoints(data.metadata.health, maximum)
	local respawned, respawnError = Open77.players.respawn(source, {
		position = { x = target.x, y = target.y, z = target.z },
		heading = target.heading or 0.0,
		bucket = bucket,
		health = OPX.Math.Clamp(health / maximum, 0.15, 1.0),
		graceMs = 5000,
	})
	if not respawned then
		-- A revive picks the body up where it fell and not where the row says, so
		-- MaySample stays false and the stored position survives.
		local revived, reviveError = Open77.players.revive(source, {
			health = OPX.Math.Clamp(health / maximum, 0.15, 1.0),
			graceMs = 5000,
		})
		if not revived then
			Open77.log.error(('[character] %d was killed for placement and neither respawn (%s) ' ..
				'nor revive (%s) put them back')
				:format(source, tostring(respawnError), tostring(reviveError)))
		end
		return false, tostring(respawnError)
	end

	-- Armor goes on AFTER the transaction: it is not an option of the respawn, and
	-- the body was about to be replaced.
	local armor = tonumber(data.metadata.armor)
	if OPX.Math.IsFinite(armor) and armor > 0 then Open77.players.setArmor(source, armor) end

	-- The cyberware identity follows the body: the platform runs every implant
	-- transaction "on their own already-bound character" (wiki/cyberware.md),
	-- and this workflow is the character adapter on this server -- see the
	-- identity block in `server/player.lua`.
	M.BindCyberware(source, data.citizenId)

	allowSampling(player)
	return true
end

--- Characters loaded at a join, by player id, waiting for a body to be put on.
-- Written by `enterCharacter` and spent by `PlacePending`, once each. A slot that
-- changes hands leaves an entry behind, which is why the citizen id is recorded
-- and checked again rather than trusted.
M.AwaitingPlacement = {}

--- Places the character a join loaded, now that the gate has opened.
-- @author dop42
-- @param source Source
-- @return boolean whether the placement was taken care of -- which includes the
-- case where the spawn menu has taken it over and will place it itself
function M.PlacePending(source)
	local citizenId = M.AwaitingPlacement[source]
	if citizenId == nil then return false end
	M.AwaitingPlacement[source] = nil

	local player = M.GetPlayer(source)
	if not player or player.PlayerData.citizenId ~= citizenId then return false end

	-- EVERY JOIN IS PUT TO THE SPAWN MODULE, and WHICH of them turn into a menu is
	-- that module's decision and not this one's -- its `OFFER_POLICY` names three
	-- answers and this block is deliberately blind to all three. A player who is
	-- asked and picks a spot is placed there; one who is not asked, or who picks
	-- nothing, or who never opens the menu, falls through to `PlaceCharacter` with
	-- no explicit target, which resolves to the row's own position (see the target
	-- resolution above). Choosing is the exception; resuming is still the default.
	--
	-- `position` therefore does not gate this block, and must not: it used to,
	-- which meant a character that had ever stood anywhere was never asked again
	-- -- a policy, hard-wired into the wrong module, that no operator could turn
	-- off. It is a hint the spawn module reads for itself under `first`, and here
	-- it is only what the answer falls back to.
	--
	-- Read through `Get` and NOT declared in `requires`: this module is the one
	-- the spawn module depends on, so a declaration in both directions is a cycle,
	-- which the registry refuses at boot. Absent -- or switched off, or configured
	-- with nowhere to go -- it answers nil and everything past this block is
	-- exactly what happened before it existed.
	local spawn = OPX.Api.Get('spawn')
	if spawn ~= nil and type(spawn.Offer) == 'function' then
		-- `Offer` must not yield, which it does not: it records the choice and
		-- starts a thread. The pcall is here so that a spawn module that raises
		-- costs the player the MENU and not the body -- a raise falling out of
		-- here would kill this thread and leave the character unplaced for the
		-- session.
		local asked, taken = pcall(spawn.Offer, source, citizenId)
		if not asked then
			Open77.log.error(('[character] the spawn module raised for %s: %s')
				:format(citizenId, tostring(taken)))
		elseif taken == true then
			Open77.log.info(('[character] %s is choosing where to start'):format(citizenId))
			return true
		end
	end

	local placed, reason = M.PlaceCharacter(player)
	if placed then
		Open77.log.info(('[character] %s was placed once the gate opened'):format(citizenId))
		return true
	end
	-- Not fatal: the player is in the world, on the body the game gave them, and
	-- their position is sampled from where they stand instead.
	Open77.log.warn(('[character] %s could not be placed when the gate opened: %s')
		:format(citizenId, tostring(reason)))
	return false
end

--- Forgets a placement nobody is waiting for any more.
-- @author dop42
-- @param source Source
function M.ForgetPlacement(source)
	M.AwaitingPlacement[source] = nil
end

--- Logs in, places, then releases the gate for a chosen character.
-- THE ORDER IS THE CONTRACT: log in, place, then release the gate, last.
-- The cooldown sits here because the open command reaches this too.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
enterCharacter = function(source, citizenId)
	local parsed = OPX.CitizenId.Parse(citizenId)
	if not parsed.ok then return Result.Err('character.notFound', tostring(citizenId)) end

	local current = M.GetPlayer(source)

	-- Re-selecting the character already loaded answers early: on the SAME row the
	-- read below would outrun the write and answer pre-save values.
	if current ~= nil and current.PlayerData.citizenId == parsed.value then
		return Result.Ok(current)
	end

	-- THE ACCOUNT THIS ENTRY IS FOR, taken before the first database read. Every
	-- step from here yields, and a player who drops mid-read has their slot
	-- handed to the next connection. The bucket release and the gate release at
	-- the foot of this function are what admit somebody into the world; run on a
	-- recycled slot they admitted the wrong player, with nothing loaded.
	local entrant = OPX.Sessions[source]
	local entrantUserId = entrant and entrant.userId
	if entrantUserId == nil then return Result.Err('character.notFound', tostring(citizenId)) end

	-- On a switch the target is checked -- exists, owned, not already in play --
	-- BEFORE the current character is dismounted. Otherwise a refused switch would
	-- leave the player in the world with nothing loaded and nothing to save them.
	if current then
		local wanted = M.Storage.FetchOne(parsed.value)
		if not wanted.ok then return wanted end
		local session = OPX.Sessions[source]
		if not session or wanted.value.userId ~= session.userId then
			OPX.Audit.Security('character.notYours',
				('player %d asked to switch to %s'):format(source, parsed.value),
				{ userId = session and session.userId, owner = wanted.value.userId }, source)
			return Result.Err('character.notFound', parsed.value)
		end
		local already = M.GetPlayerByCitizenId(parsed.value)
		if already and already.PlayerData.source ~= source then
			return Result.Err('character.inUse', parsed.value)
		end
	end

	-- The dismount is AWAITED and not handed to a thread: the read of the next
	-- character would outrun a save started in parallel. If that save fails the
	-- switch is refused; the character is already unloaded, so the player chooses
	-- again and goes back to their selection bucket.
	if current then
		local saved = M.LogoutAndWait(source)
		if saved and saved.ok == false then
			Open77.log.error(('[character] refusing the switch: %s could not be saved (%s)')
				:format(current.PlayerData.citizenId, tostring(saved.error)))
			OPX.Buckets.Isolate(source, 'switch-refused')
			return Result.Err('error.unavailable', tostring(saved.error))
		end
	end

	-- A refused login does NOT release the gate: that would put the player in the
	-- world with no character. A switch that dismounted the last one leaves them
	-- choosing, and so out of the world too.
	local login = M.Login(source, parsed.value)
	if not login.ok then
		if current then OPX.Buckets.Isolate(source, 'switch-refused') end
		return login
	end

	-- NOTHING MAY PLACE A PLAYER BEFORE THEIR GATE HAS OPENED, and placement is a
	-- kill and a respawn -- that is how the platform puts a body somewhere. A kill
	-- aimed at a client that has not incarnated yet lands on nothing: the body
	-- that attaches afterwards is DEAD, the client never announces gameplay-ready
	-- because it has no living body, and nothing can revive it because the hold
	-- that would let anybody touch it never clears. Measured on 2026-09-17, when
	-- entry moved from a selection screen to a lock read at the connection: dead
	-- on arrival, "joining" for ever, every admin command refused `gate_closed`.
	--
	-- So a JOIN only loads the character here, and `onPlayerReady` places it once
	-- the platform says there is a body to place. A character taken up while the
	-- gate is already open -- a switch in the world -- is placed on the spot,
	-- because then there is a body right now.
	if OPX.Gate.IsReady(source) then
		local placed, reason = M.PlaceCharacter(login.value)
		if not placed then
			Open77.log.warn(('[character] %s logged in but was not placed: %s')
				:format(parsed.value, tostring(reason)))
		end
		OPX.Buckets.Release(source, placed and 'character-placed' or 'character-loaded',
			entrantUserId)
	else
		M.AwaitingPlacement[source] = parsed.value
		-- Out of the selection bucket either way: nobody plays alone in one.
		OPX.Buckets.Release(source, 'character-loaded', entrantUserId)
	end

	OPX.Gate.Release(source, 'character-loaded', entrantUserId)

	-- The lock follows what actually entered the world, so the next connection
	-- comes back to this character whatever moved it here.
	local session = OPX.Sessions[source]
	if session and session.userId == entrantUserId then
		local locked = M.Storage.SetActive(session.userId, parsed.value)
		if not locked.ok then
			Open77.log.error(('[character] %s entered but the account was not locked on it: %s')
				:format(parsed.value, tostring(locked.detail)))
		end
	end
	return login
end

--- Enters the world as one character the caller owns. Coroutine only.
-- @author dop42
-- @param source Source
-- @param citizenId CitizenId
-- @return Result
function M.SelectCharacter(source, citizenId)
	if OPX.Cooling(source, 'select', 1000) then
		return Result.Err('error.tooFast', tostring(source))
	end
	return enterCharacter(source, citizenId)
end

--- Brings a connection into the world, on the character it is locked on.
-- @author dop42
--
-- THE WHOLE OF ENTRY, and there is no screen in it. An account is locked on one
-- character; that is the one this loads. An account locked on nothing gets a new
-- row, locked to it on the spot -- which is what a player sees as "the creator
-- opened by itself": the row has no body and no name, so the client is handed to
-- the game's own character creator and then asked to type a name.
--
-- The lock is moved by a command. `opx.create` ALWAYS disconnects, because a new
-- character needs the game's own creator and that is drawn by the game's main
-- menu, for a bootstrap transaction spent before the world exists -- see
-- `M.Switch`. `opx.select` takes an EXISTING character, which needs no creator,
-- so `CHARACTERS.SWITCH` decides whether it is taken here in the world or at the
-- next connection. Coroutine only.
-- @param source Source
-- @return Result
function M.EnterSession(source)
	local session = OPX.EnsureSession(source)
	if not session then return Result.Err('entry.noIdentity', tostring(source)) end
	if OPX.BootError then return Result.Err('error.unavailable', OPX.BootError) end

	local account = M.Storage.UpsertAccount(session.userId, session.displayName)
	if not account.ok then return account end

	local locked = M.Storage.FetchActive(session.userId)
	if not locked.ok then return locked end

	if locked.value ~= nil then
		local entered = enterCharacter(source, locked.value)
		if entered.ok then return entered end
		-- The lock names something this account cannot enter -- deleted between two
		-- reads, or in play on another connection. It is dropped rather than
		-- retried, and the connection goes on to a new character.
		Open77.log.warn(('[character] %s is locked on %s and could not enter it (%s): ' ..
			'the lock is cleared'):format(session.displayName, locked.value,
				tostring(entered.error)))
		local cleared = M.Storage.ClearActive(session.userId)
		if not cleared.ok then return cleared end
	end

	local created = M.CreateCharacter(source)
	if not created.ok then return created end
	return enterCharacter(source, created.value.citizenId)
end
