--- The police board: open calls, who holds them, and when they lapse.
-- @author dop42
--
-- THE SHAPE OF `modules/medical/server/dispatch.lua`, AND ONLY THE SHAPE.
-- Table arithmetic and nothing else: no host call, no yield, no event. A take
-- is therefore atomic -- two officers pressing the same call in the same tick
-- are serialised by the runtime -- and the whole board can be tested off-platform.
--
-- WHAT DIFFERS FROM THE MEDICAL BOARD. A medical call is one body; a police
-- call is one INCIDENT, which may have no body at all (an alarm at a store
-- nobody is standing in) and no position either (an alarm nobody witnessed).
-- A call is keyed by an optional `dedupe` word instead -- `911:<player>`,
-- `down:<player>`, `alarm:<label>` -- so one caller hammering 911 or one store
-- ringing twice is one call that keeps its place, not a flooded board.

local M = OPX.Modules.Get('police')

M.Dispatch = {}
local Dispatch = M.Dispatch

-- callId -> call. A call: { id, service, crime, label, description, position,
-- radius, priority, source, caller, dedupe, openedMs, expiresMs, responders = { [id] = atMs } }
local calls = {}
-- "service:dedupe" -> callId.
local byKey = {}
local nextId = 0
-- A ceiling on open calls per service, so a flood of distinct reports cannot
-- grow the board without bound; the oldest lowest-priority call gives way.
local MAX_PER_SERVICE = 64

local function keyOf(service, dedupe)
	return dedupe and (service .. ':' .. dedupe) or nil
end

--- Forgets every call. The phases call it; tests call it between cases.
-- @author dop42
function Dispatch.Reset()
	calls, byKey, nextId = {}, {}, 0
end

local function count(service)
	local n, worst = 0, nil
	for _, call in pairs(calls) do
		if call.service == service then
			n = n + 1
			if next(call.responders) == nil and (worst == nil or call.priority < worst.priority
				or (call.priority == worst.priority and call.openedMs < worst.openedMs)) then
				worst = call
			end
		end
	end
	return n, worst
end

--- Opens a call, or refreshes the one this service already holds under the
--- same dedupe word. Answers the call, whether it is new, and the call it
--- pushed off a full board, if any.
-- @author dop42
-- @param spec table { service, crime, label, description, position, radius, priority, source, caller, dedupe, ttlMs, nowMs }
-- @return table call
-- @return boolean fresh
-- @return table|nil evicted
function Dispatch.Open(spec)
	local key = keyOf(spec.service, spec.dedupe)
	local existing = key and byKey[key] and calls[byKey[key]] or nil
	if existing ~= nil then
		if (spec.priority or 0) > existing.priority then existing.priority = spec.priority end
		if spec.position ~= nil then existing.position = spec.position end
		if spec.description ~= nil then existing.description = spec.description end
		existing.expiresMs = math.max(existing.expiresMs, spec.nowMs + spec.ttlMs)
		return existing, false, nil
	end
	local evicted
	local open, worst = count(spec.service)
	if open >= MAX_PER_SERVICE and worst ~= nil then evicted = Dispatch.Close(worst.id) end
	nextId = nextId % 2147483646 + 1
	local call = {
		id = nextId,
		service = spec.service,
		crime = spec.crime,
		label = spec.label,
		description = spec.description,
		position = spec.position,
		radius = spec.radius,
		priority = spec.priority or 0,
		source = spec.source,
		caller = spec.caller,
		dedupe = spec.dedupe,
		openedMs = spec.nowMs,
		expiresMs = spec.nowMs + spec.ttlMs,
		responders = {},
	}
	calls[call.id] = call
	if key then byKey[key] = call.id end
	return call, true, evicted
end

--- One call by id, or nil.
-- @author dop42
function Dispatch.Get(id)
	return calls[math.tointeger(tonumber(id)) or -1]
end

--- The call one service holds under one dedupe word, or nil.
-- @author dop42
function Dispatch.Of(service, dedupe)
	local id = byKey[keyOf(service, dedupe) or '']
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
	local key = keyOf(call.service, call.dedupe)
	if key and byKey[key] == call.id then byKey[key] = nil end
	return call
end

--- Closes every call carrying one dedupe word, on every service.
-- @author dop42
-- @return table[]
function Dispatch.CloseKey(dedupe)
	local closed = {}
	for _, call in pairs(calls) do
		if call.dedupe == dedupe then closed[#closed + 1] = call end
	end
	for _, call in ipairs(closed) do Dispatch.Close(call.id) end
	return closed
end

--- Takes a departed responder off everything they held.
-- @author dop42
function Dispatch.Forget(responder)
	for _, call in pairs(calls) do call.responders[responder] = nil end
end

--- Closes and answers the calls nobody took before they lapsed. A call
--- somebody is on does not lapse: the officer is on the way.
-- @author dop42
-- @return table[]
function Dispatch.Expire(nowMs)
	local lapsed = {}
	for _, call in pairs(calls) do
		if nowMs >= call.expiresMs and next(call.responders) == nil then lapsed[#lapsed + 1] = call end
	end
	for _, call in ipairs(lapsed) do Dispatch.Close(call.id) end
	return lapsed
end

--- Every open call of the given services, best first: priority, then oldest.
-- @author dop42
-- @param services table|nil set of service keys, nil for all
-- @return table[]
function Dispatch.List(services)
	local out = {}
	for _, call in pairs(calls) do
		if services == nil or services[call.service] then out[#out + 1] = call end
	end
	table.sort(out, function(a, b)
		if a.priority ~= b.priority then return a.priority > b.priority end
		if a.openedMs ~= b.openedMs then return a.openedMs < b.openedMs end
		return a.id < b.id
	end)
	return out
end
