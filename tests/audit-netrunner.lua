--- Checks shared-node cooldown reservation across concurrent datamine payouts.
-- @author dop42
-- Run with `lua tests/audit-netrunner.lua`.

local file = assert(io.open('modules/netrunner/server/main.lua'))
local code = file:read('a'); file:close()
local players = { [1] = { PlayerData = { citizenId = 'one' } }, [2] = { PlayerData = { citizenId = 'two' } } }
local added, refunds, answers, failAdd = {}, {}, {}, false
local M = { Access = { Loot = function() return { kind = 'corp', label = 'Shard', value = 10 } end },
	Command = {}, Effect = {}, Kind = { ACCESS_POINT = 'access' }, Event = {} }
local character = { GetPlayer = function(player) return players[player] end }
local inventory = { AddItem = function(target)
	added[#added + 1] = target
	coroutine.yield()
	return { ok = not failAdd }
end }
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Result = {},
	Api = { Get = function(name) return name == 'character' and character or name == 'inventory' and inventory or nil end },
	Life = { Down = function() return false end }, Math = { Finite = tonumber },
	Now = function() return 1000 end, Spots = { ServerReach = function(radius) return radius end },
	Locale = { Money = tostring }, Audit = { Log = function() end }, Publish = function() end,
}, Open77 = { players = { position = function() return { x = 0, y = 0, z = 0, bucket = 0 } end },
	time = { unix = function() return 100 end }, log = { debug = function() end } },
}, { __index = _G })
-- Expose the real completion callback while replacing only presentation and RAM
-- bookkeeping. Its world check, cooldown and inventory await remain unchanged.
env.answerForTest = function(player, _, answer) answers[player] = answer end
env.refundForTest = function(_, session) refunds[#refunds + 1] = session.citizenId; return true end
local seam = [[
answer = answerForTest
sendState = function() end
spendRam = refundForTest
return { complete = onMined, configure = function(config) built = config end,
 session = function(player, value) sessions[player] = value end,
 getSession = function(player) return sessions[player] end }
]]
local testing = assert(load(code .. '\n' .. seam, '@modules/netrunner/server/main.lua', 't', env))()
testing.configure({ networks = { n = { key = 'n', label = 'Network', bucket = 0, ice = { tier = 1 },
	nodes = { access = { x = 0, y = 0, z = 0, radius = 2 }, terminal = { key = 'terminal', cooldownMs = 60000, table = 'loot' } } } },
	daemons = { mine = {} }, shards = { loot = {} }, shardItem = { name = 'shard' } })
local function session(citizen, id)
	return { citizenId = citizen, network = 'n', node = 'access', barId = id, trace = 0,
		busy = { node = 'terminal', daemon = 'mine', ram = 3 } }
end
local function complete(player, id)
	local co = coroutine.create(function() testing.complete(player, { id = id, completed = true }) end)
	local ok, why = coroutine.resume(co); assert(ok, why)
	return co
end
testing.session(1, session('one', 10)); testing.session(2, session('two', 20))
local first = complete(1, 10)
assert(coroutine.status(first) == 'suspended')
local second = complete(2, 20)
assert(coroutine.status(second) == 'dead')
assert(#added == 1 and added[1] == 'one', 'concurrent completions bypassed the shared node cooldown')
assert(answers[2] == 'node_dry', 'the second runner was not told the node is dry')
assert(refunds[1] == 'two', 'the refused runner did not get their reserved RAM back')
assert(coroutine.resume(first))
assert(answers[1] == 'shard_mined')
-- A completed bar from a previous character creates no shard on its successor.
testing.session(1, session('previous-character', 30))
complete(1, 30)
assert(#added == 1, 'a replacement character inherited a datamine payout')
assert(testing.getSession(1) == nil)
print('netrunner audit regression checks passed')
