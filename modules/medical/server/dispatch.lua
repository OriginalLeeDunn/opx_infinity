--- The board: open calls, who holds them, and when they lapse.
-- @author dop42
--
-- TABLE ARITHMETIC AND NOTHING ELSE. No host call, no yield, no event: every
-- function here reads and writes Lua tables and answers. Two consequences, both
-- deliberate. A take is atomic -- two medics pressing the same call in the same
-- tick are serialised by the runtime, and nothing in between can yield and let
-- the second one in (the rule `modules/hauling/server/claim.lua` is built on).
-- And this file is the whole of a dispatch board with no medicine in it, which
-- is what lets the police lift it into a shared module without a rewrite.
--
-- A CALL IS ONE SERVICE, ONE PATIENT. A body Trauma Team and a street doc both
-- answer is two calls; the first service to stand the patient up closes both.

local M = OPX.Modules.Get('medical')

M.Dispatch = {}
local Dispatch = M.Dispatch

-- callId -> call. A call: { id, service, patient, citizenId, reason, tier,
-- priority, offContract, openedMs, expiresMs, position, responders = { [id] = atMs } }
local calls = {}
-- "service:patient" -> callId, so one service never opens two calls on one body.
local byKey = {}
local nextId = 0

local function keyOf(service, patient) return service .. ':' .. tostring(patient) end

--- Forgets every call. The phases call it; tests call it between cases.
-- @author dop42
function Dispatch.Reset()
	calls, byKey, nextId = {}, {}, 0
end

--- Opens a call, or answers the one this service already holds on this patient.
-- @author dop42
-- @param spec table { service, patient, citizenId, reason, tier, priority, offContract, position, ttlMs, nowMs }
-- @return table call
-- @return boolean whether it is new
function Dispatch.Open(spec)
	local key = keyOf(spec.service, spec.patient)
	local existing = byKey[key] and calls[byKey[key]] or nil
	if existing ~= nil then
		-- A biomonitor call later confirmed by the patient keeps its place on the
		-- board; a better footing (a tier, on contract) is never lost to a worse one.
		if spec.priority ~= nil and spec.priority > existing.priority then
			existing.priority, existing.tier = spec.priority, spec.tier
		end
		if spec.offContract == false then existing.offContract = false end
		existing.expiresMs = math.max(existing.expiresMs, spec.nowMs + spec.ttlMs)
		return existing, false
	end
	nextId = nextId % 2147483646 + 1
	local call = {
		id = nextId,
		service = spec.service,
		patient = spec.patient,
		citizenId = spec.citizenId,
		reason = spec.reason,
		tier = spec.tier,
		priority = spec.priority or 0,
		offContract = spec.offContract == true,
		position = spec.position,
		openedMs = spec.nowMs,
		expiresMs = spec.nowMs + spec.ttlMs,
		responders = {},
	}
	calls[call.id] = call
	byKey[key] = call.id
	return call, true
end

--- One call by id, or nil.
-- @author dop42
-- @param id any
-- @return table|nil
function Dispatch.Get(id)
	return calls[math.tointeger(tonumber(id)) or -1]
end

--- The call one service holds on one patient, or nil.
-- @author dop42
function Dispatch.Of(service, patient)
	local id = byKey[keyOf(service, patient)]
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
-- @param id any
-- @param responder integer
-- @param limit integer responders a call may hold
-- @param nowMs integer
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

--- The calls one responder holds.
-- @author dop42
-- @return table[]
function Dispatch.HeldBy(responder)
	local out = {}
	for _, call in pairs(calls) do
		if call.responders[responder] ~= nil then out[#out + 1] = call end
	end
	table.sort(out, function(a, b) return a.id < b.id end)
	return out
end

--- Closes one call and answers it, or nil.
-- @author dop42
function Dispatch.Close(id)
	local call = Dispatch.Get(id)
	if call == nil then return nil end
	calls[call.id] = nil
	if byKey[keyOf(call.service, call.patient)] == call.id then
		byKey[keyOf(call.service, call.patient)] = nil
	end
	return call
end

--- Closes every call on one patient and answers them.
-- @author dop42
-- @return table[]
function Dispatch.CloseFor(patient)
	local closed = {}
	for id, call in pairs(calls) do
		if call.patient == patient then closed[#closed + 1] = call end
	end
	for _, call in ipairs(closed) do Dispatch.Close(call.id) end
	return closed
end

--- Takes a departed responder off everything they held.
-- @author dop42
function Dispatch.Forget(responder)
	for _, call in pairs(calls) do call.responders[responder] = nil end
end

--- Closes and answers the calls nobody took before they lapsed. A call somebody
--- is on does not lapse: the responder is on the way.
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

--- Every open call of the given services, best first: priority, then oldest.
-- @author dop42
-- @param services table set of service keys, or nil for all
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
