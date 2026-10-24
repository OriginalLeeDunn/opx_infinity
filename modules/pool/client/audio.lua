--- Queue authoritative contacts onto the same delayed timeline as the balls.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Number = M.Model.Number
M.Audio = {}
local A = M.Audio
local epoch, seen, queue, warned = nil, 0, {}, false
local kinds = { cue = true, ball = true, rail = true, pocket = true }
local function call(name, ...)
	local api = Open77.exports
	if type(api) ~= 'table' or type(api.callSync) ~= 'function' then return false end
	local ok, value, why = pcall(api.callSync, 'opx_pool_assets', name, ...)
	if not ok or value ~= true then
		if not warned then OPX.Note('pool', 'recorded audio unavailable: ' .. tostring(ok and why or value));warned = true end
		return false
	end
	return true
end
function A.Clear()
	if epoch ~= nil then call('pool_audio_clear') end
	epoch, seen, queue = nil, 0, {}
end
function A.Queue(packet, buffer)
	local raw = packet.sounds
	if raw == nil then return end
	if type(raw) ~= 'table' or #raw > 12 then return end
	local entries, highest, prior = {}, epoch == packet.epoch and seen or 0, 0
	for _, event in ipairs(raw) do
		if type(event) ~= 'table' or not Number(event.id, 1, 1e12) or event.id%1 ~= 0 or not kinds[event.kind]
			or not Number(event.x, -3, 3) or not Number(event.y, -2, 2) or not Number(event.time, 0, 1e12)
			or not Number(event.volume, 0, 1) or event.id <= prior or event.time > buffer.lastTime then return end
		prior = event.id
		highest = math.max(highest, event.id)
		entries[#entries+1] = event
	end
	if epoch ~= packet.epoch then
		A.Clear();epoch, seen = packet.epoch, highest
		return -- joining/reracking never replays past contacts
	end
	for _, event in ipairs(entries) do
		if event.id > seen then
			queue[#queue+1] = { at = event.time+buffer.offset+M.Model.DELAY,
				kind = event.kind, x = event.x, y = event.y, volume = event.volume }
		end
	end
	seen = highest
	while #queue > 16 do table.remove(queue, 1) end
end
function A.Frame(spec, now)
	local events = {}
	local volume = Number((M.Settings or {}).AUDIO_VOLUME, 0, 1) or 0.65
	while queue[1] and queue[1].at <= now and #events < 4 do
		local event = table.remove(queue, 1)
		if now-event.at < 500 and volume > 0 then
			events[#events+1] = { kind = event.kind, position = M.Model.World(spec, event.x, event.y), volume = event.volume*volume }
		end
	end
	if #events > 0 then call('pool_audio', events) end
end
