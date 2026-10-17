--- Checks fitting-room grants across character changes and keepalive pings.
-- @author dop42
-- Run with `lua tests/audit-appearance.lua`.

local now, events, api, threads = 0, {}, nil, 0
local player = { PlayerData = { citizenId = 'first' } }
local character = { GetPlayer = function() return player end }
local M = { Settings = { PRESENT_BODIES = false }, Event = {}, Operation = {},
	HostEvent = { BUCKET_CHANGE = 'bucket' }, WardrobePolicy = {}, Catalogs = {} }
for _, event in ipairs({ 'SAVE_FACE', 'ROOM_ALIVE', 'SAVE_CLOTHING', 'PRESENT', 'REPLAY', 'ABSENT' }) do
	M.Event[event] = event
end
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Result = {}, Now = function() return now end,
	Cooling = function() return false end,
	Api = { Get = function() return character end, Provide = function(_, _, value) api = value end },
	Host = { PLAYER_DISCONNECTED = 'disconnect' }, Channel = { INTERNAL = 'internal' },
	Event = function(_, area, event) return area .. ':' .. event end,
	Hooks = { Register = function() end },
	Command = { Register = function() end },
}, Open77 = { log = { info = function() end, debug = function() end } },
	RegisterNetEvent = function(event, fn) events[event] = fn end,
	AddEventHandler = function() end,
	CreateThread = function() threads = threads + 1 end,
}, { __index = _G })
assert(loadfile('modules/appearance/server/main.lua', 't', env))()
M.Api()
M.Start()
assert(api.AllowClothingSave(7, 'test'))
now = 500000
env.source = 7
events.ROOM_ALIVE()
now = 700000
M.RefuseSave = function() error('live room keepalive failed to preserve its grant') end
events.SAVE_CLOTHING({ citizenId = 'first', clothing = {} })
assert(threads == 1, 'the free room keepalive stopped at the absent priced grant')
assert(api.AllowClothingSave(7, 'priced', { charge = function() return true end }))
assert(api.PricedRoom(7) == 'priced')
player = { PlayerData = { citizenId = 'second' } }
assert(api.PricedRoom(7) == nil, 'another character inherited a fitting-room grant')
assert(api.AllowClothingSave(7, 'new-room', { charge = function() return true end }))
assert(api.PricedRoom(7) == 'new-room')
player = nil
assert(not api.AllowClothingSave(7, 'nobody'), 'a room was granted without a loaded character')
assert(api.PricedRoom(7) == nil)
print('appearance grant audit regression checks passed')
