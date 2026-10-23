--- Job poses use the offered catalogue and keep progress ownership on fallback.
local Host = dofile('tests/host.lua')
local function boot(side)
	local env, control = Host.Environment(side)
	for _, file in ipairs(Host.LoadOrder('open77.lua', side)) do assert(loadfile(file, 't', env))() end
	control.Fire(side == 'client' and 'onClientResourceStart' or 'onResourceStart', 'opx_infinity')
	control.Pump(300)
	if side == 'client' then control.ReadyPages() end
	assert(env.OPX.Modules.IsRunning('progress'))
	return env, control
end
local env = boot('client')
local api = env.OPX.Api.Get
local progress = assert(api('progress'))
local offered, plays, stops = {}, {}, {}
local animations = {
	Get = function(name) return { ok = offered[name] == true } end,
	Play = function(name, options, owner)
		plays[#plays + 1] = { name = name, options = options, owner = owner }
		return { ok = offered[name] == true, error = 'unknown_animation' }
	end,
	Stop = function(owner) stops[#stops + 1] = owner; return { ok = true } end,
}
env.OPX.Api.Get = function(name) return name == 'animations' and animations or api(name) end
offered.repair, offered.examine = true, true
assert(progress.Start('mechanic', { label = 'Repair', durationMs = 5000,
	animation = { name = 'repair', variant = 2, fallback = 'examine' } }).ok)
assert(plays[1].name == 'repair' and plays[1].options.variant == 2)
assert(progress.Stop('mechanic').ok and stops[1] == 'mechanic')
offered.repair = false
assert(progress.Start('mechanic', { label = 'Repair', durationMs = 5000,
	animation = { name = 'repair', variant = 99, fallback = 'examine' } }).ok)
assert(plays[2].name == 'examine' and plays[2].options.variant == nil,
	'a variant from the unavailable tool pose leaked onto the fallback')
assert(not progress.Stop('other').ok and progress.State().value.open)
assert(progress.Stop('mechanic').ok and stops[2] == 'mechanic')
offered.examine = false
assert(progress.Start('technician', { label = 'Service', durationMs = 5000,
	animation = { name = 'repair', fallback = 'examine' } }).ok)
assert(progress.State().value.open, 'missing animations removed the authoritative timed action')
assert(progress.Stop('technician').ok and #stops == 2, 'a refused pose stopped somebody else\'s playback')
local server, control = boot('server')
local serverApi = server.OPX.Api.Get
local inventory = assert(serverApi('inventory'))
local catalogue = server.OPX.Modules.Get('inventory').Catalog
assert(catalogue.Get('burrito').use.animation.name == 'takeout'
	and catalogue.Get('burrito').use.animation.fallback == 'drink', 'static food pose lost its fallback')
assert(inventory.RegisterItem('test_meal_pose', { label = 'Meal', weight = 100,
	use = { animation = { name = 'takeout', fallback = 'drink', durationMs = 3000 } } }, 'test').ok)
assert(catalogue.Get('test_meal_pose').use.animation.fallback == 'drink', 'runtime recipe lost its fallback')
assert(not inventory.RegisterItem('test_bad_pose', { label = 'Meal', weight = 100,
	use = { animation = { name = 'takeout', fallback = {} } } }, 'test').ok,
	'inventory accepted an invalid fallback profile')
local serverProgress = assert(serverApi('progress'))
server.OPX.UserIdOf = function() return 'account' end
server.OPX.Sessions[7] = {}
server.OPX.Api.Get = function(name)
	if name == 'character' then return { GetPlayer = function() return { PlayerData = { citizenId = 'worker' } } end } end
	return serverApi(name)
end
assert(serverProgress.Start(7, 'mechanic', { label = 'Repair', durationMs = 5000,
	animation = { name = 'repair', fallback = {} } }).error == 'invalid_spec')
assert(serverProgress.Start(7, 'mechanic', { label = 'Repair', durationMs = 5000,
	animation = { name = 'repair', fallback = 'examine' } }).ok)
local packet = control.clientEvents[#control.clientEvents][1]
assert(packet.animation.name == 'repair' and packet.animation.fallback == 'examine')
assert(serverProgress.Stop(7, 'mechanic').ok)
print('progress job animation fallback and ownership passed')
