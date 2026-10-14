--- Staff name tags: the switch, and the name list only staff receive.
-- @author dop42
--
-- The list of who is who is the one piece of the staff tool a client could not
-- work out for itself, and it is exactly the piece that must not leak: it goes
-- ONLY to a player the ACL grants the switch command, it is re-checked on every
-- sweep, and a grant taken away mid-session turns the tags off on the next pass
-- rather than at the next login.

local M = OPX.Modules.Get('admin')

local Server = M.Server
local Text = OPX.Text
local Command = M.Command

local answer, refuse, audit = Server.Answer, Server.Refuse, Server.Audit

M.Tags = {}
local Tags = M.Tags

-- Rows per name list event. The host discards an event carrying more than 1024
-- value nodes and says nothing, so the list is always sent in pieces.
local CHUNK = 40

-- Players with tags on, to the signature of the last list they were sent.
local watching = {}

-- Whether the ACL grants the switch. Fails closed: an unreadable ACL sends the
-- roster to nobody rather than to everybody.
local function granted(playerId)
	return Server.Permitted(playerId, Command.SELF_TAGS) == true
end

-- Every connected player's id, verified account name, character name, citizen
-- id and staff mark.
--
-- THE CHARACTER AND THE CITIZEN ID TRAVEL HERE, AND ONLY HERE. A tag used to
-- read them off the player's replicated state bag, which every client in the
-- bucket holds -- so the staff tool was built on a list every stranger had too.
-- Never a name to a stranger is the owner's decision; the bag carries nothing
-- now (`modules/character/server/state.lua`) and the two fields ride on this
-- list, which reaches nobody the ACL has not granted `opx.admin.self.tags`.
local function nameRows()
	local rows = {}
	local badge = M.Section('TAGS').BADGE ~= false
	for _, id in ipairs(Server.PlayerIds()) do
		local name = Server.NameOf(id)
		if name then
			rows[#rows + 1] = { id = id, name = name,
				character = Server.CharacterOf(id),
				citizenId = Server.CitizenBagOf(id),
				staff = badge and Server.Permitted(id, M.OPENER) == true or nil }
		end
	end
	return rows
end

-- One string per list, so an unchanged list is not sent again. Every field the
-- tag draws: a rename or a character switch has to reach the operator.
local function signature(rows)
	local parts = {}
	for index, row in ipairs(rows) do
		parts[index] = ('%d\t%s\t%s\t%s\t%d'):format(row.id, row.name, row.character or '',
			row.citizenId or '', row.staff and 1 or 0)
	end
	return table.concat(parts, '\n')
end

-- Sends the name list to one staff member, in chunks, when it changed.
local function push(playerId, rows, sent)
	if watching[playerId] == sent then return end
	local offset = 0
	repeat
		local chunk = {}
		for index = offset + 1, math.min(offset + CHUNK, #rows) do chunk[#chunk + 1] = rows[index] end
		TriggerClientEvent(M.Event.TAG_ROWS, playerId, { rows = chunk, offset = offset,
			done = offset + #chunk >= #rows })
		offset = offset + #chunk
	until offset >= #rows
	watching[playerId] = sent
end

-- Switches a player's tags and tells the client half.
local function setShown(playerId, on, persist)
	if on then watching[playerId] = false else watching[playerId] = nil end
	TriggerClientEvent(M.Event.TAGS_STATE, playerId, on == true, persist == true)
	if on then
		local rows = nameRows()
		push(playerId, rows, signature(rows))
	end
end

--- Whether a player has name tags on, for the eye's checkbox.
-- @author dop42
-- @param playerId Source
-- @return boolean
function Tags.IsShown(playerId)
	return watching[playerId] ~= nil
end

--- Registers the switch command, the restore event and the list sweep.
-- @author dop42
function Tags.Register()
	Server.Command(Command.SELF_TAGS, {
		help = 'admin.help.tags',
		params = { { name = 'on|off', help = 'admin.help.toggle', optional = true } },
		inGame = true,
		handler = function(source, args, raw)
			local wanted, invalid = Text.Switch(args[1])
			if invalid then return refuse(source, raw, 'bad_switch') end
			if wanted == nil then wanted = watching[source] == nil end
			-- The host already resolved the ACL to get here; this catches the one
			-- case it cannot, a host with no ACL reader at all, and fails closed.
			if wanted and not granted(source) then
				return refuse(source, raw, 'refused', { reason = 'acl_unreadable' })
			end
			setShown(source, wanted, true)
			audit(source, 'admin.self.tags', true, nil, wanted and 'on' or 'off')
			answer(source, raw, true, wanted and 'admin.done.tagsOn' or 'admin.done.tagsOff')
		end,
	})

	-- A client whose store remembers the switch asks for it back. The grant is
	-- re-checked here: the stored preference is a client's word, not an authority.
	RegisterNetEvent(M.Event.TAGS_RESTORE, function()
		local player = tonumber(source) or 0
		if player <= 0 or Server.Cooled(player, 'tags:restore', 2000) then return end
		if not granted(player) then
			return TriggerClientEvent(M.Event.TAGS_STATE, player, false, false)
		end
		if watching[player] == nil then audit(player, 'admin.self.tags', true, nil, 'restored') end
		setShown(player, true, false)
	end)

	AddEventHandler(OPX.Host.PLAYER_DISCONNECTED, function(playerId)
		watching[tonumber(playerId) or 0] = nil
	end)

	-- The cadence is a live tunable, so the scheduler is handed the read rather
	-- than its answer: a number resolved here would be frozen for the life of
	-- the resource and `/opx.tune ADMIN_TAGS_REFRESH_MS` would change nothing.
	OPX.Scheduler.Every('admin:tag-sweep',
		function() return OPX.Tune.Number('ADMIN_TAGS_REFRESH_MS', 500) end,
		function()
			local rows, sent
			for playerId in pairs(watching) do
				if not granted(playerId) then
					watching[playerId] = nil
					TriggerClientEvent(M.Event.TAGS_STATE, playerId, false, false)
					Open77.log.info(('[admin] name tags off for player %d: %s is no longer granted')
						:format(playerId, Command.SELF_TAGS))
				else
					if rows == nil then
						rows = nameRows()
						sent = signature(rows)
					end
					push(playerId, rows, sent)
				end
			end
		end)
end

--- Turns every operator's tags off, so a stop leaves no stale list drawn.
-- @author dop42
function Tags.Release()
	for playerId in pairs(watching) do
		pcall(TriggerClientEvent, M.Event.TAGS_STATE, playerId, false, false)
	end
	watching = {}
end
