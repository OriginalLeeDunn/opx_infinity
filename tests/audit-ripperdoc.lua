--- Clinic work and recovery must remain bound to the original bodies.
-- @author dop42
local function upvalue(fn, wanted)
	for i = 1, 100 do
		local name, value = debug.getupvalue(fn, i)
		if name == nil then break end
		if name == wanted then return value, i end
	end
	error('missing upvalue ' .. wanted)
end
local data = { [1] = { citizenId = 'doc' }, [2] = { citizenId = 'patient' } }
local charges, nativeCalls, chartEvents = 0, 0, 0
local clinic = { key = 'clinic', label = 'Clinic', jobs = nil, bucket = 0, money = 'BANK',
	services = { install = true, remove = false } }
local settings = { clinics = { clinic = clinic }, clinicList = { clinic }, chromeList = {},
	docReach = 3, membership = 'primary', jobMaxAgeMs = 1000, maxCapacity = 10,
	chrome = { arm = { slot = 'arms', native = { id = 'arm' } } }, humanity = { start = 100 } }
local api = { GetPlayer = function(p) return data[p] and { PlayerData = data[p] } end,
	GetPlayerByCitizenId = function(cid)
		for p, row in pairs(data) do if row.citizenId == cid then row.source = p; return { PlayerData = row } end end
	end,
	GetMetadata = function(_, key) return key == 'humanity' and 100 or {} end,
	RemoveMoney = function() charges = charges + 1; return true end }
local native = { current = function() coroutine.yield(); return nil end,
	install = function() nativeCalls = nativeCalls + 1; return {} end }
local M = { Model = { Read = function() return settings end, ChairAt = function() return clinic end,
	Humanity = function(_, h) return h end, Installed = function(v) return v end,
	CapacityUsed = function() return 0 end }, Storage = { SCHEMA = {} },
	Native = { Api = function() return native end }, Phase = { RESERVED = 'reserved', SUBMITTED = 'submitted' },
	Event = { CHART_DATA = 'chart' }, HUMANITY_KEY = 'humanity', CYBERWARE_KEY = 'chrome' }
local env = setmetatable({ OPX = { Modules = { Get = function() return M end },
	Api = { Get = function() return {} end }, Schema = { Add = function() end },
	Cooling = function() return false end, Math = { Finite = tonumber },
	Now = function() return 0 end, JobGate = { Evaluate = function() return true end },
	Spots = { ServerReach = function(r) return r end } },
	Open77 = { players = { position = function() return { x = 1, y = 1, z = 1 } end },
		log = { warn = function() end } },
	TriggerClientEvent = function(event) if event == 'chart' then chartEvents = chartEvents + 1 end end }, { __index = _G })
assert(loadfile('modules/ripperdoc/server/main.lua', 't', env))()
M.Init()
local locate = upvalue(M.Chart, 'locate')
local dataOf = upvalue(locate, 'dataOf')
local _, characterIndex = upvalue(dataOf, 'character')
debug.setupvalue(dataOf, characterIndex, api)
local reserve = upvalue(M.Consent, 'reserve')
local original = { id = 'op', doc = 1, patient = 2, clinic = 'clinic', docCid = 'doc', patientCid = 'patient',
	docData = data[1], patientData = data[2], total = 10, method = 'BANK' }
data[2] = { citizenId = 'replacement' }
reserve(original)
assert(charges == 0, 'replacement patient was charged for old consent')
local recover = M.Recover
local replay = upvalue(recover, 'replay')
data[2] = { citizenId = 'patient' }
local task = coroutine.create(function() replay({ id = 'replay', patientCid = 'patient', chrome = 'arm',
	action = 'install', phase = 'submitted', part = {}, total = 10 }, 2) end)
assert(coroutine.resume(task))
data[2] = { citizenId = 'replacement' }
-- Native lookup is suspended, then returns nil; the next polling iteration must stop.
env.Wait = function() end
assert(coroutine.resume(task))
assert(coroutine.status(task) == 'dead', 'recovery kept polling a replacement body')
assert(nativeCalls == 0, 'recovery installed chrome on a replacement body')
data[2] = { citizenId = 'patient' }
api.GetMetadata = function(_, key)
	if key == 'humanity' then data[1] = { citizenId = 'new-doc' }; return 100 end
	return {}
end
assert(M.Chart(1, 2) == false, 'a chart reached the replacement doc')
assert(chartEvents == 0, 'private chart crossed a character switch')
print('ripperdoc identity audit: PASS')
