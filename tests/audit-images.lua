--- Fivemanage pagination publishes complete public snapshots and never secrets.
-- @author dop42
local function boot(key)
	local M = { Event = { REQUEST = 'request', SET = 'set' } }
	local requests, sent, logs, events, refresh = {}, {}, {}, {}, nil
	local env
	env = setmetatable({
		OPX = {
			Modules = { Get = function() return M end },
			Config = { MODULES = { images = { API_KEY = key } } },
			Cooling = function() return false end,
			Scheduler = { Every = function(_, _, fn) refresh = fn end },
		},
		Open77 = { http = { request = function(url, callback, method, _, headers)
			assert(method == 'GET' and headers.Authorization == key)
			requests[#requests + 1] = { url = url, callback = callback }
			return true
		end }, log = {
			warn = function(message) logs[#logs + 1] = message end,
			info = function(message) logs[#logs + 1] = message end,
		} },
		json = { decode = function(body) return body end },
		CreateThread = function(fn) fn() end,
		Wait = function() end,
		RegisterNetEvent = function(name, fn) events[name] = fn end,
		AddEventHandler = function() end,
		TriggerClientEvent = function(_, player, packet)
			assert(player == 7 and #packet.entries <= 8)
			for _, entry in ipairs(packet.entries) do
				assert(entry.url:find(key, 1, true) == nil, 'credential leaked in URL')
				assert(entry.opx_uploaded_at == nil and entry.metadata == nil, 'raw metadata leaked')
			end
			sent[#sent + 1] = packet
		end,
		source = 7,
	}, { __index = _G })
	assert(loadfile('modules/images/server/main.lua', 't', env))()
	M.Init(); M.Start()
	return M, requests, sent, logs, events, function() refresh() end
end
local secret = 'test-secret-never-sent'
local M, requests, sent, logs, events, refresh = boot(secret)
events.request()
assert(#sent == 1 and #sent[1].entries == 0, 'initial snapshot must contain no images')
local function row(name, url, stamp, id)
	return { id = id or name, url = url, metadata = { opx_name = name, opx_uploaded_at = stamp } }
end
local function reply(index, rows, limit, total)
	requests[index].callback(200, { status = 'ok', data = rows, pagination = { limit = limit, total = total } })
end
local rows = { row('water.png', 'https://cdn.example/new', 20), row('../bad.png', 'https://cdn.example/bad', 1) }
for index = 1, 7 do rows[#rows + 1] = row('clothing/' .. index .. '.webp', 'https://cdn.example/' .. index, 1) end
reply(1, rows, 9, 10)
assert(#sent == 1, 'partial HTTP pagination was published')
assert(requests[2].url:find('page=2', 1, true))
reply(2, { row('water.png', 'https://cdn.example/old', 10) }, 9, 10)
assert(#sent == 2 and #sent[2].entries == 8, 'complete catalogue was not published')
local found
for _, entry in ipairs(sent[2].entries) do if entry.name == 'water.png' then found = entry.url end end
assert(found == 'https://cdn.example/new', 'duplicate names depended on API ordering')
refresh()
requests[3].callback(500, 'secret response must not be logged')
events.request()
assert(sent[#sent].revision == 1 and #sent[#sent].entries == 8, 'failed refresh destroyed working images')
for _, message in ipairs(logs) do
	assert(not message:find(secret, 1, true) and not message:find('secret response', 1, true), 'secret leaked to logs')
end
M.Stop()
local _, missing = boot('')
assert(#missing == 0, 'missing key must not call Fivemanage')
print('images: pagination, bounded packets, newest upload, failed refresh and secret isolation passed')

-- The relay retains packets before CEF exists, then yields between replay pages.
do
	local module = { Event = { SET = 'set', REQUEST = 'request' }, Page = { SET = 'images:set', READY = 'images:ready' } }
	local net, ready, threads, forwarded, requests = {}, nil, {}, {}, 0
	local env = setmetatable({
		OPX = { Modules = { Get = function() return module end }, UI = {
			On = function(_, _, fn) ready = fn end,
			Send = function(_, _, packet) forwarded[#forwarded + 1] = packet end,
		} },
		RegisterNetEvent = function(name, fn) net[name] = fn end,
		TriggerServerEvent = function() requests = requests + 1 end,
		CreateThread = function(fn) threads[#threads + 1] = coroutine.create(fn) end,
		Wait = coroutine.yield,
	}, { __index = _G })
	assert(loadfile('modules/images/client/main.lua', 't', env))()
	module.Init(); module.Start()
	assert(requests == 1, 'catalogue was requested per item instead of once')
	local first = { revision = 1, index = 1, total = 2, entries = {} }
	local second = { revision = 1, index = 2, total = 2, entries = {} }
	net.set(first); net.set(second)
	assert(#forwarded == 0, 'packets were lost into an unready page')
	ready()
	assert(coroutine.resume(threads[1]))
	assert(#forwarded == 1, 'page replay did not yield after one packet')
	assert(coroutine.resume(threads[1]))
	assert(#forwarded == 2, 'page replay lost a cached packet')
	net.set({ revision = 0, index = 1, total = 1, entries = {} })
	assert(#forwarded == 2, 'stale revision reached the page')
	local oversized = { revision = 2, index = 1, total = 1, entries = {} }
	for index = 1, 9 do oversized.entries[index] = {} end
	net.set(oversized)
	assert(#forwarded == 2, 'oversized packet reached the page')
	assert(requests == 1, 'receiving images made more API catalogue requests')
end
print('images client: readiness, bounded replay and stale packets passed')
