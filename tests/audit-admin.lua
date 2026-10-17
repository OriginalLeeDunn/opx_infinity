--- Deferred staff loadouts must not reach a replacement or revoked recipient.
local commands, replies = {}, {}
local user, session, granted = 'operator', {}, true
local M = { Command = {}, Server = {}, Inventory = {} }
M.Trimmed = function(value) return value end
for _, name in ipairs({ 'WEAPON_GIVE', 'WEAPON_GIVEAMMO', 'WEAPON_AMMO',
	'WEAPON_REMOVE', 'WEAPON_HOLSTER', 'WEAPON_READ' }) do M.Command[name] = name end
local env = setmetatable({
	OPX = { Modules = { Get = function() return M end }, Text = {},
		UserIdOf = function() return user end, Sessions = { [7] = session } },
	GetCurrentResourceName = function() return 'audit' end,
	locale = function(key) return key end,
}, { __index = _G })
assert(loadfile('modules/admin/server/main.lua', 't', env))()
local S, I = M.Server, M.Inventory
S.Permitted = function() return granted end
S.Command = function(name, spec) commands[name] = spec.handler end
S.Heavy = function(_, _, fn) fn() end
S.Answer = function(...) replies[#replies + 1] = { ... } end
S.Refuse = S.Answer
S.Audit = function() end
S.Contract = function() return { GetHeldWeapon = function() return nil end } end
I.Resolve = function() return 'citizen', 'private player', 8 end
I.Catalog = function() return { byName = { pistol = { weapon = true } } } end
I.Bag = function()
	coroutine.yield()
	return { items = { { name = 'pistol', slot = 1, metadata = { serial = 'PRIVATE' } } } }
end
assert(loadfile('modules/admin/server/weapons.lua', 't', env))()
M.Weapons.Register()
local function run(change)
	user, granted = 'operator', true
	env.OPX.Sessions[7] = session
	local before = #replies
	local task = coroutine.create(function() commands.WEAPON_READ(7, {}, 'loadout') end)
	assert(coroutine.resume(task))
	assert(coroutine.status(task) == 'suspended')
	change()
	assert(coroutine.resume(task))
	return #replies - before
end
assert(run(function() end) == 1, 'legitimate loadout was dropped')
assert(run(function() user = 'stranger' end) == 0, 'loadout leaked to another account')
assert(run(function() env.OPX.Sessions[7] = {} end) == 0, 'loadout leaked after reconnect')
assert(run(function() granted = false end) == 0, 'loadout survived ACL revocation')

-- The command resolves its target before the worker runs. A later character
-- switch must not change the holder that the worker sends to the contract.
local citizen = 'FIRST-CHARACTER'
S.CitizenOf = function() return citizen end
S.LabelOf = function() return 'holder' end
S.NameOf = S.LabelOf
S.Contract = function() return {} end
env.OPX.Text.Integer = function(value) return tonumber(value) end
assert(loadfile('modules/admin/server/inventory.lua', 't', env))()
local target, _, player = M.Inventory.Resolve(7, 'give', '8')
assert(target == 'FIRST-CHARACTER' and player == 8, 'target was not pinned to its character')
citizen = 'SECOND-CHARACTER'
assert(target == 'FIRST-CHARACTER', 'deferred target followed a character switch')
citizen = nil
assert(M.Inventory.Resolve(7, 'give', '8') == nil, 'unloaded slot was accepted for a deferred bag write')
print('audit-admin: PASS')
