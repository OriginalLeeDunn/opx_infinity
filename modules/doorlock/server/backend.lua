--- Who actually holds a lock: the platform's door service, or every client.
-- @author dop42
--
-- TWO BACKENDS, ONE DECISION. Whatever turns a lock, `server/main.lua` has
-- already decided that it may turn; this file only knows how to make the world
-- agree.
--
-- NETWORKED. `open77_doors` keeps a server-owned registry of every world door
-- (devkit guide `doors`). A door registered by this resource is ours until the
-- resource stops, and its lock is one the platform's own authority enforces: a
-- locked door refuses every player's open request, and the client bridge
-- projects it onto the native door for everybody in the bucket. That is the
-- strong form, and the one an operator should run when they can.
--
-- LOCAL. Without the service there is no server-side door at all -- door state
-- is client-side -- so the server holds the state, `main.lua` broadcasts it, and
-- `client/main.lua` puts every streamed managed door into it with
-- `Open77.doors.setLocked` and `setInteractionAllowed`. It is what the test
-- server runs today: `open77_doors` depends on `open77_elevators`, and that
-- package would take the cabins away from the job-gated `elevators` module.
-- The lock is then each client's, which is a weaker promise -- a modified
-- client can open its own copy of a door -- and docs/MANUAL.md says so.
--
-- Every call into the service is an export through `Open77.exports.call`, so it
-- yields: everything here runs on a thread.

local M = OPX.Modules.Get('doorlock')

M.Backend = {}
local Backend = M.Backend

-- 'networked' or 'local', settled in `Decide`.
local mode = 'local'

-- Door id to why the service refused to give it to us, for the list command.
local refusals = {}

--- Whether the platform's door service is running now.
local function serviceRunning()
	if type(GetResourceState) ~= 'function' then return false end
	local read, state = pcall(GetResourceState, M.NETWORKED)
	return read and state == 'running'
end

--- Calls one export of the door service and waits for its answer.
-- @return any first value, or nil
-- @return any second value, or the reason the call failed
local function call(method, ...)
	local exportsApi = Open77.exports
	if type(exportsApi) ~= 'table' or type(exportsApi.call) ~= 'function' then
		return nil, 'no_exports'
	end
	local made, pending, reason = pcall(exportsApi.call, M.NETWORKED, method, ...)
	if not made then return nil, tostring(pending) end
	if type(pending) ~= 'table' or type(pending.await) ~= 'function' then
		return nil, tostring(reason or 'not_called')
	end
	local waited, first, second = pcall(pending.await, pending)
	if not waited then return nil, tostring(first) end
	return first, second
end

Backend.Call = call

--- The patch one leaf takes for a state: its lock and, for ox's `holdOpen`,
--- whether it stays open.
-- @author dop42
--
-- An unlocked hold-open door is opened and told not to close itself -- ox's
-- `DoorSystemSetHoldOpen` -- and an automatic one also leaves proximity control,
-- which the service says a persistent manual open needs. Locking closes a door
-- on the service's side whatever else is set, so a locked door only needs its
-- self-closing and its automatic mode back.
-- @param door table
-- @param locked boolean
-- @return table
function Backend.Patch(door, locked)
	local held = door.holdOpen == true and not locked
	local patch = { locked = locked == true, autoClose = not held }
	if held then
		patch.open = true
		if door.auto then patch.automatic = false end
	elseif door.auto then
		patch.automatic = true
	end
	return patch
end

--- Settles which backend this boot runs, and says so.
-- @author dop42
-- @return string the mode
function Backend.Decide()
	local wanted = M.Settings.BACKEND
	local running = serviceRunning()
	if wanted == 'local' then
		mode = 'local'
	elseif wanted == 'networked' and not running then
		-- Asked for and not there. A lock nobody enforces is worse than one each
		-- client enforces, so the module falls back rather than standing down.
		Open77.log.error(('[doorlock] BACKEND = \'networked\' but %s is not running: every lock ' ..
			'falls back to the local backend. Add %s to resources.load.')
			:format(M.NETWORKED, M.NETWORKED))
		mode = 'local'
	else
		mode = running and 'networked' or 'local'
	end
	refusals = {}
	return mode
end

--- The backend this boot runs.
-- @author dop42
-- @return string 'networked' or 'local'
function Backend.Mode()
	return mode
end

--- Why the service refused to hand over a door, by door id.
-- @author dop42
-- @return table<integer, string>
function Backend.Refusals()
	return refusals
end

--- Takes every native door of one managed door, and sets its state. Yields.
-- @author dop42
--
-- A door the service has discovered keeps the position the service measured,
-- which is the one the platform will check proximity against; one it has not
-- seen yet is registered at the position the panel captured, and discovery
-- confirms it within four metres or refuses it as a topology conflict.
-- @param door table
-- @param locked boolean
-- @return boolean whether every leaf is ours
function Backend.Adopt(door, locked)
	if mode ~= 'networked' then return true end
	local all = true
	for index, id in ipairs(door.ids) do
		local known = call('get', id, door.bucket)
		local leaf = door.doors and door.doors[index] or nil
		local at = leaf and leaf.coords or door.coords
		local position = type(known) == 'table' and type(known.position) == 'table' and known.position
			or { x = at.x, y = at.y, z = at.z }
		local owned, why = call('register', {
			id = id, bucket = door.bucket, position = position, automatic = door.auto,
		})
		if not owned then
			all = false
			refusals[door.id] = tostring(why)
			Open77.log.warn(('[doorlock] door %s: %s refused native %s: %s')
				:format(tostring(door.id), M.NETWORKED, id, tostring(why)))
		else
			local set, reason = call('configure', id, door.bucket, Backend.Patch(door, locked))
			if set ~= true then
				all = false
				refusals[door.id] = tostring(reason)
				Open77.log.warn(('[doorlock] door %s: native %s took no lock: %s')
					:format(tostring(door.id), id, tostring(reason)))
			end
		end
	end
	if all then refusals[door.id] = nil end
	return all
end

--- Moves the state of every native door of one managed door. Yields on the
--- networked backend; the local one has nothing to do here, because the
--- broadcast in `main.lua` IS its lock.
-- @author dop42
-- @param door table
-- @param locked boolean
-- @return boolean
function Backend.Apply(door, locked)
	if mode ~= 'networked' then return true end
	local all = true
	for _, id in ipairs(door.ids) do
		-- One atomic patch rather than `setLocked` and `setOpen`: a hold-open
		-- door changes its lock and its open state together, and two calls would
		-- leave a window where the second was refused and the first had landed.
		local set, reason = call('configure', id, door.bucket, Backend.Patch(door, locked))
		if set ~= true then
			all = false
			Open77.log.warn(('[doorlock] door %s: native %s did not %s: %s')
				:format(tostring(door.id), id, locked and 'lock' or 'unlock', tostring(reason)))
			-- A door the service no longer gives us -- it restarted -- is taken
			-- back once and set again, rather than left in whatever state it woke in.
			if reason == 'not_owner' then
				Backend.Adopt(door, locked)
				all = true
			end
		end
	end
	return all
end

--- Hands every native door of one managed door back to the service. Yields.
-- @author dop42
-- @param door table anything with `id`, `bucket` and `ids`
function Backend.Release(door)
	refusals[door.id] = nil
	if mode ~= 'networked' then return end
	for _, id in ipairs(door.ids) do
		-- Unlocked first: a released door keeps its state, and a door nobody
		-- manages any more must not stay shut for good.
		call('configure', id, door.bucket, { locked = false, autoClose = true })
		call('remove', id, door.bucket)
	end
end

--- Takes back every door the service no longer says is ours. Yields.
-- @author dop42
--
-- `open77_doors` forgets an owner when it restarts, and nothing tells this
-- resource that it did. So the sweep asks, a door at a time, and re-adopts
-- whatever answers with another owner or none.
-- @param doors table<integer, table>
-- @param lockedOf fun(id: integer): boolean
-- @return integer how many were taken back
function Backend.Sweep(doors, lockedOf)
	if mode ~= 'networked' then return 0 end
	local mine = GetCurrentResourceName()
	-- Collected first: every call below yields, and a save landing in that
	-- yield rebuilds the table this would be walking.
	local list = {}
	for _, door in pairs(doors) do list[#list + 1] = door end
	local taken = 0
	for _, door in ipairs(list) do
		for _, id in ipairs(door.ids) do
			local known = call('get', id, door.bucket)
			if type(known) ~= 'table' or known.owner ~= mine then
				if Backend.Adopt(door, lockedOf(door.id)) then taken = taken + 1 end
				break
			end
		end
	end
	return taken
end
