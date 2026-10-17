-- A delayed face save must still own the exact transaction and character.
local threads, sent, now = {}, 0, 0
local state = { citizenId = 'old' }
local module = {
 Face = state, Settings = {}, ConfigMs = function(value) return value end,
 Snapshot = { ForNetwork = function(value) return value end, Same = function() return false end },
 BuildAccepted = function() return true end,
 Runtime = { NowMs = function() return now end, Publish = function() end },
}
OPX = { Modules = { Get = function() return module end } }
function CreateThread(fn) threads[#threads + 1] = coroutine.create(fn) end
function Wait() coroutine.yield() end
function TriggerServerEvent() sent = sent + 1; return true end
dofile('modules/appearance/client/editor.lua')
assert(module.Editor.Save({ gameBuild = 1 }))
assert(coroutine.resume(threads[1])) -- waiting for save cooldown
local nextCommit = { deadlineMs = 77 }
state.citizenId, state.commit = 'new', nextCommit
now = 5000
assert(coroutine.resume(threads[1]))
assert(sent == 0, 'old character face was sent after switch')
assert(state.commit == nextCommit and nextCommit.deadlineMs == 77)
print('appearance editor: stale transaction checks passed')
-- Rollback keeps its original snapshot and drops stale result notifications.
module.Operation = { SAVE_FACE = 'save' }
state.citizenId, state.restoreToken, state.canonical = 'old', 1, { old = true }
state.Current = function(token) return token == state.restoreToken end
state.commit = { kind = 'edit' }
local notices, rollbackSnapshot = 0, nil
module.Runtime.FinishMutation = function() end
module.Runtime.Notify = function() notices = notices + 1 end
module.Runtime.ApplySnapshot = function(snapshot, _, token)
 rollbackSnapshot = snapshot
 assert(token == 1)
 Wait()
 return false, 'superseded'
end
module.Runtime.Publish = function() end
module.Editor.OnRefused('appearance.invalid', 'save')
assert(coroutine.resume(threads[2]))
assert(rollbackSnapshot.old == true)
state.citizenId, state.restoreToken, state.canonical = 'new', 2, { new = true }
assert(coroutine.resume(threads[2]))
assert(notices == 0, 'stale rollback notified the next character')
-- Real ApplySnapshot retries stop before applying the old face on a new character.
OPX.Event = function(_, name, action) return name .. action end
OPX.Channel = { LOCAL = 'local' }
OPX.Result = { Ok = function(value) return { ok = true, value = value } end,
 Err = function(code) return { ok = false, error = code } end }
state.citizenId, state.restoreToken = 'old', 3
module.HostEvent = {}
dofile('modules/appearance/client/main.lua')
local applied, published = 0, 0
Open77 = { appearance = { apply = function()
 applied = applied + 1
 return false, 'player_unavailable'
end } }
module.Runtime.Publish = function() published = published + 1 end
assert(module.Contract.SetSkin({ gameBuild = 1 }).ok)
assert(coroutine.resume(threads[3]))
assert(applied == 1)
state.citizenId, state.restoreToken = 'new', 4
assert(coroutine.resume(threads[3]))
assert(applied == 1 and published == 0, 'old SetSkin retried on the next character')
print('appearance rollback and SetSkin character isolation passed')
-- The appearance panel's Wear action has the same generation isolation.
module.Event = { ON_VIEW = 'view' }
module.Clothing = { OUTFIT_SLOTS = {}, SLOTS = {} }
module.Garments = {}
state.citizenId, state.restoreToken, state.canonical, state.commit = 'old', 5, { gameBuild = 1 }, nil
state.Wearing = function() return false end
module.Runtime.ModalOnScreen = function() return false end
function TriggerEvent() end
function locale(key) return key end
dofile('modules/appearance/client/wardrobe.lua')
for index = 1, 100 do
 local name = debug.getupvalue(module.FromView, index)
 if not name then break end
 if name == 'panelOwner' then debug.setupvalue(module.FromView, index, 'appearance'); break end
end
module.FromView('panel.select', { item = 'wear' })
assert(coroutine.resume(threads[4]))
assert(applied == 2)
state.citizenId, state.restoreToken = 'new', 6
assert(coroutine.resume(threads[4]))
assert(applied == 2, 'old panel Wear retried on the next character')
print('appearance panel Wear character isolation passed')
