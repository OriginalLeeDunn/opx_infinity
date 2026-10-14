--- The staff door onto the characters of people who are NOT HERE.
-- @author dop42
--
-- WHAT "OFFLINE" TURNS OUT TO MEAN, because the schema decides it and not the
-- menu. There is no column that says a character is offline. `last_logged_out`
-- is the last time one STOPPED being played and is just as stale for a character
-- somebody is holding right now; `opx77_active_characters` says which character
-- an account ENTERS on, whether or not that account has a session. So the only
-- persisted thing to list is the character row, and whether anybody is holding
-- it is a fact about this process, in memory, for the handful of slots that are
-- occupied.
--
-- SO THIS LISTS CHARACTERS AND TAGS THE ONES THAT ARE NOT OFFLINE, rather than
-- filtering them out, and the honesty is the point:
--
--   * a WHERE clause on who is connected is stale before the payload lands. An
--     operator reading a list built a tick ago is reading the past either way;
--     the difference is that a filtered list hides the row and a tagged one says
--     `playing` next to it.
--   * removing rows after the SQL breaks the count without breaking the seek. It
--     is survivable -- the cursor is the last row the DATABASE answered, not the
--     last one shown -- but a page of 25 that draws 22, with no way to say which
--     three went or why, reads as a list with holes in it.
--   * a small server where everybody is on would answer nothing but empty pages
--     while staff paged through them looking for somebody who was right there.
--
-- Two tags, and they are different questions. `live` is a session holding THAT
-- citizen id. `online` is a session on that ACCOUNT -- the person is here,
-- playing one of their others -- and that one is reachable the short way, under
-- `Players > them > Characters`.
--
-- NO SQL AND NO CHARACTER DATA LIVES HERE, the same standing rule the rest of
-- this module keeps: the query belongs to `character/server/storage.lua` and the
-- decision to `character`, and this file is one call into the contract plus the
-- two things only the staff module knows -- who is connected, and who is allowed
-- to ask.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit

M.Offline = {}
local Offline = M.Offline

-- The contract's refusal codes in this module's own words, as `characters.lua`
-- keeps its own. A code that is not here reads as a plain refusal.
local CODES = {
	['character.searchShort'] = 'search_short',
	['error.badRequest'] = 'bad_request',
	['error.unavailable'] = 'characters_unavailable',
}

-- The one suggestion the typed form takes. A find takes a TERM and never a
-- player id: there is no player to name -- that is the whole reason to be here.
local TERM = { name = 'name|citizenId', help = 'admin.help.findTerm' }

--- This module's word for a contract refusal.
local function codeOf(error)
	return CODES[tostring(error)] or 'refused'
end

--- One page of the find, with the runtime tags stamped on it. Coroutine only.
-- @author dop42
--
-- The request is whatever came off the wire and every field of it is checked by
-- the contract rather than here: the floor on a term, the caps on a cursor and
-- the ceiling on a page are all properties of the query, and a second copy of
-- them in this file would be a second copy to drift.
--
-- What IS this file's is the last loop. The live and online sets are built once
-- per page out of the connected slots -- at most the server's player cap, never
-- the table -- and nothing is read from the database to build them.
-- @param request table `{ mode, term, seenAt, cursor }`
-- @return table|nil rows
-- @return string|nil the refusal code, or the page state when rows came back
-- @return table|nil `{ mode, more, cursor, seenAt }`
function Offline.Page(request)
	local contract = Server.Contract('character')
	if contract == nil then return nil, 'characters_unavailable' end
	if type(contract.FindCharacters) ~= 'function' then
		return nil, 'characters_unavailable'
	end

	local read, found = pcall(contract.FindCharacters, request)
	if not read or type(found) ~= 'table' then return nil, 'failed' end
	if not found.ok then return nil, codeOf(found.error) end

	-- WHO IS HERE, from memory. Two maps rather than a scan per row: a page is 25
	-- rows and the roster is up to the player cap, and a nested loop over both is
	-- the kind of thing that is free until the day it is not.
	local live, online = {}, {}
	for _, id in ipairs(Server.PlayerIds()) do
		local citizenId = Server.CitizenOf(id)
		if citizenId ~= nil then live[citizenId] = id end
		local userId = OPX.UserIdOf(id)
		if userId ~= nil then online[userId] = id end
	end

	local rows = {}
	for _, entry in ipairs(found.value.characters or {}) do
		rows[#rows + 1] = {
			citizenId = entry.citizenId,
			cid = entry.cid,
			account = entry.account,
			firstName = entry.firstName,
			lastName = entry.lastName,
			gender = entry.gender,
			job = entry.job,
			gang = entry.gang,
			createdAt = entry.createdAt and tostring(entry.createdAt) or nil,
			lastLoggedOut = entry.lastLoggedOut and tostring(entry.lastLoggedOut) or nil,
			-- The player id and not just a flag: the menu draws it, so an operator
			-- who finds somebody who turns out to be connected is told the slot to
			-- go and deal with rather than sent back to the roster to look.
			live = entry.citizenId ~= nil and live[entry.citizenId] or nil,
			online = entry.userId ~= nil and online[entry.userId] or nil,
		}
	end

	return rows, nil, {
		mode = found.value.mode,
		more = found.value.more == true,
		cursor = found.value.cursor,
		seenAt = found.value.seenAt,
	}
end

--- Registers the one find command.
-- @author dop42
function Offline.Register()
	-- READ, so it sits on the gentler floor with every other listing -- and that
	-- floor is load-bearing here in a way it is not for a roster read. A search
	-- box wired straight to a database is a denial of service with a nice UI, so
	-- there are three things between a keystroke and a query and this is the
	-- first: `Server.Command` refuses a second run inside ADMIN_RATE_READ_MS
	-- before the handler is entered at all. The second is the per-topic cooldown
	-- on the menu refresh in `menu.lua`. The third is that the menu has no
	-- keystroke to fire on -- its search box is a FORM, so a query is sent once,
	-- on confirm, and never per letter.
	Server.Command(Command.CHARACTER_FIND, {
		help = 'admin.help.charFind', params = { TERM }, inGame = true, read = true,
		handler = function(source, args, raw)
			-- Before the thread: an argument that is not there is not worth a
			-- database round trip. The FLOOR on its length is the contract's, so
			-- that the typed line and the menu are refused by the same rule.
			local term = M.Trimmed(args[1], 64)
			if term == nil then return refuse(source, raw, 'search_short') end

			Server.Heavy(source, raw, function()
				local rows, code, page = Offline.Page({ mode = 'search', term = term })
				if rows == nil then return refuse(source, raw, code) end

				local lines = { locale('admin.find.header',
					{ term = term, count = #rows }) }
				for _, entry in ipairs(rows) do
					local name = entry.firstName ~= nil
						and ('%s %s'):format(entry.firstName, entry.lastName or '')
						or locale('admin.find.unnamed')
					lines[#lines + 1] = ('  %s %-10s %-26s %-18s %s'):format(
						entry.live and '*' or (entry.online and '+' or ' '),
						entry.citizenId, name, entry.account or '-',
						entry.lastLoggedOut or locale('admin.find.never'))
				end
				if #rows == 0 then lines[#lines + 1] = locale('admin.find.none') end
				-- Said in the line rather than left for the operator to wonder about:
				-- a typed find has no next page to press, so a truncated answer that
				-- did not say so would read as "that is everybody".
				if page ~= nil and page.more then
					lines[#lines + 1] = locale('admin.find.more')
				end

				audit(source, 'admin.character.find', true, nil,
					('%s: %d row(s)'):format(term, #rows))
				answer(source, raw, true, 'admin.text.lines',
					{ lines = table.concat(lines, '\n') })
			end)
		end,
	})
end
