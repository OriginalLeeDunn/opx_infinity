--- The staff door onto an account's CHARACTERS: read them, rename one, delete one.
-- @author dop42
--
-- WHAT THIS IS NOT. `opx.admin.player.*` is the session and the puppet -- freeze
-- it, heal it, move it, kill it -- and every one of those dies with the
-- connection. This file reaches the ROWS behind that connection, which outlive
-- it: a character an operator renames or deletes here is one the player will
-- still own tomorrow, or will not. That is why the three commands are their own
-- ACL namespace rather than more `player.*` grants -- an operator trusted to
-- unfreeze somebody is not automatically trusted to delete what they have played
-- for a month.
--
-- NO CHARACTER DATA LIVES HERE, which is this module's standing rule. What a
-- character IS belongs to `character`, and all three commands are one call into
-- its contract: `ListCharactersFor`, `RenameCharacter`, `RemoveCharacter`. Those
-- three exist beside the self-service ones (`ListCharacters`, `SetName`,
-- `DeleteCharacter`) and deliberately do NOT check ownership, because the check
-- is the access list and it has already happened -- `Server.Command` registers
-- every one of these as restricted and the host refuses the line before a
-- handler ever runs. Read from the SERVER, never from a client: a contract call
-- made on a client is no permission check at all.
--
-- EVERY READER HERE YIELDS. An account's characters come out of the database and
-- a rename writes back to it, so each handler answers everything it can answer
-- without a thread first and hands the rest to a `CreateThread`.
--
-- WHY THERE IS NO "EDIT EVERYTHING" FORM. The editable identity of a character
-- is its name. The other things staff reach for are already commands that belong
-- to the modules that own them -- job, gang and money are `LINKS` on the
-- character screen -- and the rest of the row is a RECORD rather than a setting:
-- `created_at` and `last_logged_out` are what happened, and a date this module
-- could rewrite is an audit trail that cannot be trusted. There is no birth date
-- to edit; lifepath, origin and date of birth were dropped from the schema.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit
local inform = Server.Inform

M.Characters = {}
local Characters = M.Characters

-- The contract's refusal codes in this module's own words. A code that is not
-- here reads as a plain refusal and the original is kept in the audit.
local CODES = {
	['character.notFound'] = 'unknown_citizen',
	['character.badName'] = 'bad_name',
	['character.nameSet'] = 'bad_name',
	['entry.noIdentity'] = 'not_connected',
	['error.unavailable'] = 'characters_unavailable',
}

-- Suggestion parameters. A rename and a delete take a CITIZEN ID and never a
-- player id: the character being acted on is very often not the one its account
-- is standing in, and an operator who has just read the list is holding the id.
local WHO = { name = 'playerId|me', help = 'admin.help.playerId' }
local CITIZEN = { name = 'citizenId', help = 'admin.help.citizenId' }
local FIRST = { name = 'firstName', help = 'admin.help.firstName' }
local LAST = { name = 'lastName', help = 'admin.help.lastName' }

--- This module's word for a contract refusal.
local function codeOf(error)
	return CODES[tostring(error)] or 'refused'
end

--- The account behind a connected player, or nil.
-- The ACCOUNT and not the character: what is listed is every character the
-- person owns, which is a question about the account and answers the same
-- whichever of them they happen to be standing in.
local function accountOf(playerId)
	local id = tonumber(playerId) or 0
	if id <= 0 then return nil end
	return OPX.UserIdOf(id)
end

--- One account's characters, as the menu draws them. Coroutine only.
-- @author dop42
--
-- Answers the rows and nothing else; who may see them is the caller's question.
-- A row carries no money, no position and no metadata -- `toSummary` on the
-- character side decides that, and this does not widen it.
-- @param playerId Source the player whose account is read
-- @return table[]|nil
-- @return string|nil the refusal code
function Characters.Rows(playerId)
	local contract = Server.Contract('character')
	if contract == nil then return nil, 'characters_unavailable' end

	local userId = accountOf(playerId)
	if userId == nil then return nil, 'not_connected' end

	local read, listed = pcall(contract.ListCharactersFor, userId)
	if not read or type(listed) ~= 'table' then return nil, 'failed' end
	if not listed.ok then return nil, codeOf(listed.error) end

	local live = Server.CitizenOf(playerId)
	local rows = {}
	for _, entry in ipairs(listed.value.characters or {}) do
		rows[#rows + 1] = {
			citizenId = entry.citizenId,
			cid = entry.cid,
			firstName = entry.firstName,
			lastName = entry.lastName,
			gender = entry.gender,
			job = entry.job,
			gang = entry.gang,
			createdAt = entry.createdAt and tostring(entry.createdAt) or nil,
			lastLoggedOut = entry.lastLoggedOut and tostring(entry.lastLoggedOut) or nil,
			-- Two different things, and the menu draws them differently: `active`
			-- is the character the ACCOUNT is locked on and enters the world as,
			-- `live` is the one being played right now. They are usually the same
			-- and are not while a switch is in flight.
			active = entry.citizenId == listed.value.active or nil,
			live = entry.citizenId == live or nil,
		}
	end
	return rows
end

--- Registers the three staff character commands.
-- @author dop42
function Characters.Register()
	-- READ. `read = true` puts it on the gentler of the two rate floors, like
	-- every other listing: an operator paging through a roster is not an attack.
	Server.Command(Command.CHARACTER_LIST, {
		help = 'admin.help.charList', params = { WHO }, inGame = true, read = true,
		handler = function(source, args, raw)
			local playerId = Server.Target(source, raw, args[1])
			if playerId == nil then return end
			Server.Heavy(source, raw, function()
				local rows, code = Characters.Rows(playerId)
				if rows == nil then return refuse(source, raw, code) end

				local lines = { locale('admin.char.header',
					{ who = Server.LabelOf(playerId) or tostring(playerId), count = #rows }) }
				for _, entry in ipairs(rows) do
					local name = entry.firstName ~= nil
						and ('%s %s'):format(entry.firstName, entry.lastName or '')
						or locale('admin.char.unnamed')
					lines[#lines + 1] = ('  %s %-10s %-26s %s%s'):format(
						entry.live and '*' or (entry.active and '>' or ' '),
						entry.citizenId, name, entry.gender or '-',
						entry.createdAt and ('  ' .. entry.createdAt) or '')
				end
				if #rows == 0 then lines[#lines + 1] = locale('admin.char.none') end
				audit(source, 'admin.character.list', true, playerId, ('%d row(s)'):format(#rows))
				answer(source, raw, true, 'admin.text.lines',
					{ lines = table.concat(lines, '\n') })
			end)
		end,
	})

	-- RENAME. Write-once is the rule for the PLAYER who made the character; this
	-- is the other door, and it is the reason one has to exist -- a slur, or a
	-- typo the player cannot fix because their own door shut behind them.
	Server.Command(Command.CHARACTER_RENAME, {
		help = 'admin.help.charRename', params = { CITIZEN, FIRST, LAST }, inGame = true,
		handler = function(source, args, raw)
			local citizenId = M.Trimmed(args[1], 32)
			-- `{who}` is in the sentence; without it the operator read the braces.
			if citizenId == nil then return refuse(source, raw, 'unknown_citizen', { who = '?' }) end
			-- Both halves before the thread: a missing argument is not worth a
			-- database round trip, and the refusal reads the same either way.
			if M.Trimmed(args[2], 32) == nil or M.Trimmed(args[3], 32) == nil then
				return refuse(source, raw, 'bad_name')
			end

			local contract = Server.Contract('character')
			if contract == nil then return refuse(source, raw, 'characters_unavailable') end

			-- A character being played by a protected player is theirs to keep.
			for _, id in ipairs(Server.PlayerIds()) do
				if Server.CitizenOf(id) == citizenId then
					if Server.Shielded(source, raw, id, 'admin.character.rename') then return end
					break
				end
			end

			Server.Heavy(source, raw, function()
				local renamed, result = pcall(contract.RenameCharacter, citizenId,
					args[2], args[3], source)
				if not renamed or type(result) ~= 'table' then
					audit(source, 'admin.character.rename', false, nil, citizenId)
					return refuse(source, raw, 'failed')
				end
				if not result.ok then
					audit(source, 'admin.character.rename', false, nil,
						('%s: %s'):format(citizenId, tostring(result.error)))
					return refuse(source, raw, codeOf(result.error), { who = citizenId })
				end

				-- Read defensively: this runs on a bare thread, where a raise is no
				-- answer and no audit line at all, after the rename has happened.
				local value = type(result.value) == 'table' and result.value or {}
				local full = ('%s %s'):format(tostring(value.firstName or '?'), tostring(value.lastName or '?'))
				audit(source, 'admin.character.rename', true, nil,
					('%s -> %s'):format(citizenId, full))
				answer(source, raw, true, 'admin.done.charRenamed',
					{ citizenId = citizenId, name = full })
			end)
		end,
	})

	-- DELETE. The heaviest thing in this file: it takes the character's clothes,
	-- needs, containers and cars with it, and ends the session of whoever is
	-- playing it. The menu puts it behind a confirmation screen; the typed line
	-- does not, because a typed line IS the confirmation.
	Server.Command(Command.CHARACTER_DELETE, {
		help = 'admin.help.charDelete', params = { CITIZEN }, inGame = true,
		handler = function(source, args, raw)
			local citizenId = M.Trimmed(args[1], 32)
			if citizenId == nil then return refuse(source, raw, 'unknown_citizen', { who = '?' }) end

			local contract = Server.Contract('character')
			if contract == nil then return refuse(source, raw, 'characters_unavailable') end

			Server.Heavy(source, raw, function()
				-- Read BEFORE the delete, and only for the message: afterwards the
				-- player holding it has been logged out and there is nobody left to
				-- tell. A read that fails costs the toast and not the delete.
				local holder = nil
				for _, id in ipairs(Server.PlayerIds()) do
					if Server.CitizenOf(id) == citizenId then holder = id break end
				end
				if holder ~= nil and Server.Shielded(source, raw, holder, 'admin.character.delete') then
					return
				end

				local removed, result = pcall(contract.RemoveCharacter, citizenId, source)
				if not removed or type(result) ~= 'table' then
					audit(source, 'admin.character.delete', false, holder, citizenId)
					return refuse(source, raw, 'failed')
				end
				if not result.ok then
					audit(source, 'admin.character.delete', false, holder,
						('%s: %s'):format(citizenId, tostring(result.error)))
					return refuse(source, raw, codeOf(result.error), { who = citizenId })
				end

				audit(source, 'admin.character.delete', true, holder, citizenId)
				-- The holder is disconnected by the delete itself, so this races the
				-- kick and is sent rather than waited on -- exactly as the character
				-- module's own switch notice is.
				inform(source, holder, 'admin.toast.charDeleted', nil, 'warning')
				answer(source, raw, true, 'admin.done.charDeleted', { citizenId = citizenId })
			end)
		end,
	})
end
