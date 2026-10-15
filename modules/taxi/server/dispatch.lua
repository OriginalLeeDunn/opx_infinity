--- The cab board: open calls, who took them, and when they lapse.
-- @author dop42
--
-- THE MEDICAL BOARD'S PATTERN, COPIED, NOT IMPORTED. `modules/medical/server/
-- dispatch.lua` is plain table arithmetic and says it may one day be lifted
-- into a shared `dispatch` module; until that day a cab company does not reach
-- into a medical module's internals, so the shape is copied here and trimmed to
-- what a cab needs: ONE driver per call (a cab does not send two cars), and a
-- call that may be restricted to one company or open to all of them.
--
-- TABLE ARITHMETIC AND NOTHING ELSE. No host call, no yield: a take is atomic,
-- two drivers pressing the same call in the same tick are serialised by the
-- runtime and the second one reads `taken`.

local M = OPX.Modules.Get('taxi')

M.Dispatch = {}
local Dispatch = M.Dispatch

-- callId -> call: { id, company|nil, passenger, citizenId, position, openedMs,
-- expiresMs, driver|nil, takenBy|nil (company key) }
local calls = {}
-- passenger -> callId: one open call per customer.
local byPassenger = {}
local nextId = 0

--- Forgets every call. The phases call it; tests call it between cases.
-- @author dop42
function Dispatch.Reset()
	calls, byPassenger, nextId = {}, {}, 0
end

--- Opens a call, or answers the one this customer already has.
-- @author dop42
-- @param spec table { company|nil, passenger, citizenId, position, ttlMs, nowMs }
-- @return table call
-- @return boolean whether it is new
function Dispatch.Open(spec)
	local existing = byPassenger[spec.passenger] and calls[byPassenger[spec.passenger]] or nil
	if existing ~= nil then return existing, false end
	nextId = nextId % 2147483646 + 1
	local call = {
		id = nextId,
		company = spec.company,
		passenger = spec.passenger,
		citizenId = spec.citizenId,
		position = spec.position,
		openedMs = spec.nowMs,
		expiresMs = spec.nowMs + spec.ttlMs,
	}
	calls[call.id] = call
	byPassenger[spec.passenger] = call.id
	return call, true
end

--- One call by id, or nil.
-- @author dop42
function Dispatch.Get(id)
	return calls[math.tointeger(tonumber(id)) or -1]
end

--- The call a customer holds, or nil.
-- @author dop42
function Dispatch.Of(passenger)
	local id = byPassenger[passenger]
	return id and calls[id] or nil
end

--- Whether a company may see and take a call.
-- @author dop42
function Dispatch.Visible(call, companies)
	if companies == nil then return true end
	if call.company ~= nil then return companies[call.company] == true end
	return next(companies) ~= nil
end

--- Puts a driver on a call for a company. Answers a code on refusal.
-- @author dop42
-- @return table|nil call
-- @return string|nil no_such_call, taken, wrong_company
function Dispatch.Take(id, driver, companyKey)
	local call = Dispatch.Get(id)
	if call == nil then return nil, 'no_such_call' end
	if call.driver ~= nil then return nil, call.driver == driver and 'already_yours' or 'taken' end
	if call.company ~= nil and call.company ~= companyKey then return nil, 'wrong_company' end
	call.driver, call.takenBy = driver, companyKey
	return call, nil
end

--- Takes the driver off a call, which goes back on the board.
-- @author dop42
-- @return table|nil the call, back open
function Dispatch.Release(id, driver, nowMs, ttlMs)
	local call = Dispatch.Get(id)
	if call == nil or call.driver ~= driver then return nil end
	call.driver, call.takenBy = nil, nil
	call.expiresMs = math.max(call.expiresMs, nowMs + (ttlMs or 0))
	return call
end

--- The call one driver holds, or nil.
-- @author dop42
function Dispatch.HeldBy(driver)
	for _, call in pairs(calls) do
		if call.driver == driver then return call end
	end
	return nil
end

--- Closes one call and answers it, or nil.
-- @author dop42
function Dispatch.Close(id)
	local call = Dispatch.Get(id)
	if call == nil then return nil end
	calls[call.id] = nil
	if byPassenger[call.passenger] == call.id then byPassenger[call.passenger] = nil end
	return call
end

--- Closes and answers the calls nobody took before they lapsed. A taken call
--- does not lapse: the cab is on its way.
-- @author dop42
-- @param nowMs integer
-- @return table[]
function Dispatch.Expire(nowMs)
	local lapsed = {}
	for _, call in pairs(calls) do
		if nowMs >= call.expiresMs and call.driver == nil then lapsed[#lapsed + 1] = call end
	end
	table.sort(lapsed, function(a, b) return a.id < b.id end)
	for _, call in ipairs(lapsed) do Dispatch.Close(call.id) end
	return lapsed
end

--- Every open (untaken) call a set of companies may see, oldest first. With
--- `all`, taken calls are listed too.
-- @author dop42
-- @param companies table|nil set of company keys, nil for every call
-- @param all boolean|nil
-- @return table[]
function Dispatch.List(companies, all)
	local out = {}
	for _, call in pairs(calls) do
		if (all or call.driver == nil) and Dispatch.Visible(call, companies) then out[#out + 1] = call end
	end
	table.sort(out, function(a, b)
		if a.openedMs ~= b.openedMs then return a.openedMs < b.openedMs end
		return a.id < b.id
	end)
	return out
end
