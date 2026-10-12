--- The board: open calls for a mechanic or a tow, who holds them, when they lapse.
-- @author dop42
--
-- THE MEDICAL BOARD'S SHAPE (`modules/medical/server/dispatch.lua`), cut to one
-- service: table arithmetic and nothing else. No host call, no yield, no event,
-- so a take is atomic -- two mechanics pressing the same call in one tick are
-- serialised by the runtime -- and the whole board is testable off-platform.
--
-- ONE CALL PER CALLER. Calling again while a call is open refreshes it (a new
-- position, a new note, a fresh lapse) instead of stacking a second pin on every
-- mechanic's map.

local M = OPX.Modules.Get('mechanic')

M.Dispatch = {}
local Dispatch = M.Dispatch

-- callId -> call. A call: { id, caller, citizenId, kind, note, position,
-- openedMs, expiresMs, responders = { [id] = atMs } }
local calls = {}
-- caller -> callId.
local byCaller = {}
local nextId = 0

--- Forgets every call. The phases call it; tests call it between cases.
-- @author dop42
function Dispatch.Reset()
	calls, byCaller, nextId = {}, {}, 0
end

--- Opens a call, or refreshes the one this caller already holds.
-- @author dop42
-- @param spec table { caller, citizenId, kind, note, position, ttlMs, nowMs }
-- @return table call
-- @return boolean whether it is new
function Dispatch.Open(spec)
	local existing = byCaller[spec.caller] and calls[byCaller[spec.caller]] or nil
	if existing ~= nil then
		existing.kind = spec.kind or existing.kind
		existing.note = spec.note
		existing.position = spec.position or existing.position
		existing.expiresMs = math.max(existing.expiresMs, spec.nowMs + spec.ttlMs)
		return existing, false
	end
	nextId = nextId % 2147483646 + 1
	local call = {
		id = nextId,
		caller = spec.caller,
		citizenId = spec.citizenId,
		kind = spec.kind,
		note = spec.note,
		position = spec.position,
		openedMs = spec.nowMs,
		expiresMs = spec.nowMs + spec.ttlMs,
		responders = {},
	}
	calls[call.id] = call
	byCaller[spec.caller] = call.id
	return call, true
end

--- One call by id, or nil.
-- @author dop42
function Dispatch.Get(id)
	return calls[math.tointeger(tonumber(id)) or -1]
end

--- The call one caller holds, or nil.
-- @author dop42
function Dispatch.Of(caller)
	local id = byCaller[caller]
	return id and calls[id] or nil
end

--- How many responders hold a call.
-- @author dop42
function Dispatch.Count(call)
	local n = 0
	for _ in pairs(call.responders) do n = n + 1 end
	return n
end

--- Puts a responder on a call, if there is room. Answers a code on refusal.
-- @author dop42
-- @return table|nil call
-- @return string|nil no_such_call, already_on_call, call_full
function Dispatch.Take(id, responder, limit, nowMs)
	local call = Dispatch.Get(id)
	if call == nil then return nil, 'no_such_call' end
	if call.responders[responder] ~= nil then return nil, 'already_on_call' end
	if Dispatch.Count(call) >= limit then return nil, 'call_full' end
	call.responders[responder] = nowMs
	return call, nil
end

--- Takes a responder off a call.
-- @author dop42
-- @return boolean whether they were on it
function Dispatch.Drop(id, responder)
	local call = Dispatch.Get(id)
	if call == nil or call.responders[responder] == nil then return false end
	call.responders[responder] = nil
	return true
end

--- Closes one call and answers it, or nil.
-- @author dop42
function Dispatch.Close(id)
	local call = Dispatch.Get(id)
	if call == nil then return nil end
	calls[call.id] = nil
	if byCaller[call.caller] == call.id then byCaller[call.caller] = nil end
	return call
end

--- Takes a departed player off everything: the calls they held as a responder,
--- and answers the call they had open as a caller (closed), or nil.
-- @author dop42
function Dispatch.Forget(player)
	for _, call in pairs(calls) do call.responders[player] = nil end
	local own = byCaller[player]
	return own and Dispatch.Close(own) or nil
end

--- Closes and answers the calls nobody took before they lapsed. A call somebody
--- is on does not lapse: the mechanic is on the way.
-- @author dop42
-- @param nowMs integer
-- @return table[]
function Dispatch.Expire(nowMs)
	local lapsed = {}
	for _, call in pairs(calls) do
		if nowMs >= call.expiresMs and next(call.responders) == nil then lapsed[#lapsed + 1] = call end
	end
	for _, call in ipairs(lapsed) do Dispatch.Close(call.id) end
	return lapsed
end

--- Every open call, oldest first.
-- @author dop42
-- @return table[]
function Dispatch.List()
	local out = {}
	for _, call in pairs(calls) do out[#out + 1] = call end
	table.sort(out, function(a, b)
		if a.openedMs ~= b.openedMs then return a.openedMs < b.openedMs end
		return a.id < b.id
	end)
	return out
end
