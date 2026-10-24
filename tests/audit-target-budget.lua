--- A dense interaction registry must gather and sort across bounded resumes.
-- @author dop42
local M = {}
local env = setmetatable({ OPX = { Modules = { Get = function() return M end }, Glyphs = {},
	Math = { IsFinite = function(v) return type(v) == 'number' and v == v and v > -math.huge and v < math.huge end } } }, { __index = _G })
assert(loadfile('modules/target/shared/model.lua', 't', env))()
local registry = M.Model.New(function() return true end)
for index = 1, M.Model.MAX_TOTAL do
	assert(registry.Register('owner_' .. math.floor((index - 1) / 40), 1,
		{ id = 'row_' .. index, label = ('Option %03d'):format(index), group = 'group_' .. (index % 4),
			types = { 'world' }, distance = 10, order = (index * 19) % 97, onSelect = function() end }))
end
local context = { target = { kind = 'world', networked = false }, playerDistance = 1, position = { x = 0, y = 0, z = 0 } }
local expected = registry.Candidates(context)
local result, checkpoints = nil, 0
local worker = coroutine.create(function()
	result = registry.Candidates(context, function() checkpoints = checkpoints + 1; coroutine.yield(); return true end)
end)
local worst, total, resumes = 0, 0, 0
while coroutine.status(worker) ~= 'dead' do
	local spent = 0
	debug.sethook(worker, function() spent = spent + 1 end, '', 1)
	local ok, err = coroutine.resume(worker)
	debug.sethook(worker)
	assert(ok, err)
	worst = math.max(worst, spent); total = total + spent; resumes = resumes + 1
end
assert(#result == #expected and #result == M.Model.MAX_TOTAL, 'paced collection dropped rows')
for index, row in ipairs(expected) do assert(result[index] == row, 'paced sorting changed group or display order') end
assert(total > 10000 and worst < 4500, ('dense work total=%d worst=%d'):format(total, worst))
assert(checkpoints > 10, 'candidate work was not split across resumes')
local stops = 0
assert(registry.Candidates(context, function() stops = stops + 1; return stops < 3 end) == nil,
	'a cancelled pick continued gathering')
print(('target candidates: %d rows, %d resumes, %d total instructions, %d worst'):format(#result, resumes, total, worst))
