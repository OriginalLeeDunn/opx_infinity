--- Lists account images on the server; only public names and URLs leave it.
-- @author dop42
-- A refresh is published only when every API page succeeds. Duplicate names are
-- resolved by uploader timestamps, not by undocumented API ordering. Eight rows
-- per network message keep both the CEF payload and client resume bounded.
local M = OPX.Modules.Get('images')
local key, active, fetching = '', false, false
local revision, packets, recipients = 0, {}, {}
local generation, signature = 0, nil
local PAGE_SIZE, MAX_FILES = 8, 50000

local function nameOf(value)
	if type(value) ~= 'string' or #value == 0 or #value > 192 then return nil end
	if value:find('[^%w_%.%-%/]') or value:sub(1, 1) == '/' or value:sub(-1) == '/' or value:find('//', 1, true) then return nil end
	for part in value:gmatch('[^/]+') do if part == '.' or part == '..' then return nil end end
	return value
end

local function urlOf(value)
	if type(value) ~= 'string' or #value > 1024 or value:find('%s') then return nil end
	local host = value:match('^https://([^/]+)/')
	if not host or host:find('[^%w%.%-]') or value:find(key, 1, true) then return nil end
	return value
end

local function send(player)
	local snapshot, version = packets, revision
	CreateThread(function()
		if #snapshot == 0 then
			TriggerClientEvent(M.Event.SET, player, { revision = version, index = 1, total = 1, entries = {} })
			return
		end
		for index = 1, #snapshot do
			if not active or not recipients[player] then return end
			TriggerClientEvent(M.Event.SET, player, {
				revision = version, index = index, total = #snapshot, entries = snapshot[index],
			})
			Wait(20)
		end
	end)
end

local function refresh()
	if not active or fetching or key == '' then return end
	if not Open77.http or type(Open77.http.request) ~= 'function' then
		Open77.log.warn('[images] HTTP bridge unavailable; no pictures loaded')
		return
	end
	fetching = true
	generation = generation + 1
	local currentGeneration = generation
	local chosen, count = {}, 0
	local function fail(status)
		if not fetching then return end
		fetching = false
		-- No response bodies, headers, URLs or keys in the journal.
		Open77.log.warn(('[images] catalogue refresh refused (HTTP %s); check key and HTTP host allow-list'):format(tostring(status)))
	end
	local function publish()
		local names, fresh = {}, {}
		for name in pairs(chosen) do names[#names + 1] = name end
		table.sort(names)
		local fingerprint = {}
		for index = 1, #names do
			fingerprint[index] = names[index] .. '\n' .. chosen[names[index]].url
		end
		local nextSignature = table.concat(fingerprint, '\n')
		if signature == nextSignature then fetching = false; return end
		for index = 1, #names do
			local batch = math.floor((index - 1) / PAGE_SIZE) + 1
			fresh[batch] = fresh[batch] or {}
			local name = names[index]
			fresh[batch][#fresh[batch] + 1] = { name = name, url = chosen[name].url }
		end
		packets, revision, fetching = fresh, revision + 1, false
		signature = nextSignature
		Open77.log.info(('[images] %d public image URLs loaded'):format(#names))
		for player in pairs(recipients) do send(player) end
	end
	local request
	request = function(page)
		local done = false
		local called, accepted = pcall(Open77.http.request,
			('https://api.fivemanage.com/api/v3/file?path=opx_images&limit=100&page=%d'):format(page),
			function(status, body)
				if done or not active or not fetching or generation ~= currentGeneration then return end
				done = true
				if status ~= 200 then fail(status); return end
				local decoded, result = pcall(json.decode, body)
				if not decoded or type(result) ~= 'table' or result.status ~= 'ok'
					or type(result.data) ~= 'table' or type(result.pagination) ~= 'table' then fail('invalid_response'); return end
				local limit, total = result.pagination.limit, result.pagination.total
				if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > 100
					or type(total) ~= 'number' or total % 1 ~= 0 or total < 0 or total > MAX_FILES
					or #result.data > 100 then fail('invalid_pagination'); return end
				for index = 1, #result.data do
					local row = result.data[index]
					if type(row) == 'table' and type(row.metadata) == 'table' then
						local name, url = nameOf(row.metadata.opx_name), urlOf(row.url)
						local stamp = tonumber(row.metadata.opx_uploaded_at) or 0
						local id = type(row.id) == 'string' and row.id or ''
						if name and url and stamp >= 0 and stamp < 9007199254740991 and stamp % 1 == 0 then
							local old = chosen[name]
							if not old then count = count + 1 end
							if not old or stamp > old.stamp or (stamp == old.stamp and id > old.id) then
								chosen[name] = { url = url, stamp = stamp, id = id }
							end
						end
					end
				end
				if count > MAX_FILES then fail('too_many_images'); return end
				if page * limit >= total then publish()
				elseif #result.data == 0 or page >= 500 then fail('incomplete_response')
				else request(page + 1) end
			end, 'GET', '', { Authorization = key, Accept = 'application/json' })
		if not called or accepted == false then fail('request_unavailable') end
	end
	request(1)
end

function M.Init()
	local block = OPX.Config.MODULES.images or {}
	key = type(block.API_KEY) == 'string' and block.API_KEY or ''
	if #key > 4096 or key:find('[\r\n]') then key = '' end
end

function M.Start()
	active = true
	RegisterNetEvent(M.Event.REQUEST, function()
		local player = tonumber(source) or 0
		if player <= 0 or OPX.Cooling(player, 'images.request', 5000) then return end
		recipients[player] = true
		send(player)
	end)
	AddEventHandler('playerDropped', function() recipients[tonumber(source) or 0] = nil end)
	if key == '' then
		Open77.log.info('[images] Fivemanage key missing; pictures disabled')
		return
	end
	refresh()
	OPX.Scheduler.Every('images:refresh', 300000, refresh)
end

function M.Stop()
	active, fetching = false, false
	generation = generation + 1
	recipients = {}
end
