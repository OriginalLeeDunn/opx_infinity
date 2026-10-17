-- Real tags view: replacing a peer at the 32-anchor limit must draw immediately.
local handlers, live, published = {}, {}, nil
local count, nextId = 0, 0
local module = { Event = { ON_TAGS = 'tags' }, Client = { Journal = function() end } }
OPX = {
 Modules = { Get = function() return module end },
 UI = { Surface = function() return { page = 1 } end,
  Send = function(_, _, payload) published = payload; return true end },
 Scheduler = { Every = function() return 1 end, Cancel = function() end },
}
Open77 = { anchors = {
 create = function(spec)
  assert(count < 32, 'host anchor quota exceeded')
  nextId = nextId + 1; count = count + 1; live[nextId] = spec; return nextId
 end,
 update = function(id, patch) return live[id] ~= nil end,
 remove = function(id) if live[id] then live[id] = nil; count = count - 1 end; return true end,
 list = function() return {} end,
} }
function AddEventHandler(event, callback) handlers[event] = callback end
dofile('modules/admin/client/tagsview.lua')
module.TagsView.Start()
local function frame(first)
 local rows = {}
 for id = first, first + 31 do rows[#rows + 1] = {
  playerId = id, entity = id + 100, offsetZ = 2, name = tostring(id), alpha = 1,
 } end
 handlers.tags({ kind = 'rows', rows = rows })
 return published
end
assert(#frame(1).rows == 32)
live[1] = nil; count = count - 1
assert(#frame(1).rows == 32, 'host-forgotten anchor was not recreated after false update')
assert(count == 32)
local replacement = frame(2)
assert(#replacement.rows == 32, 'replacement tag lost while quota is full')
assert(replacement.rows[32].playerId == 33, 'new peer was not drawn')
assert(count == 32)
module.TagsView.Stop()
assert(count == 0, 'anchors leaked on stop')
print('tags client: quota turnover and refused-update checks passed')
