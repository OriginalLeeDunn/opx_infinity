--- The shared table menu; every game-changing row carries its viewed revision.
-- @author dop42
local M = OPX.Modules.Get('pool')
local G = M.Match
M.TableMenu = {}
local T = M.TableMenu
local handle, menu
local icons = { practice = 'interact', challenge = 'flag', duel = 'person', join = 'plus',
	resume = 'eye', acceptReset = 'refresh', declineReset = 'back', requestReset = 'refresh',
	rack = 'refresh', finish = 'flag', leave = 'door' }
function T.Close()
	if handle and menu then menu.Close(handle, 'pool') end
	handle = nil
end
function T.Rows(state, me)
	local game = state.game or G.New('practice', state.owner ~= 0 and state.owner or nil)
	local slot, rows = G.Slot(game, me), {}
	local function row(action, key, extra, confirm, disabled)
		local data = { action = action, epoch = state.epoch, revision = state.revision }
		for k,v in pairs(extra or {}) do data[k] = v end
		rows[#rows+1] = { id = action .. (data.mode or ''), label = locale('pool.' .. key), icon = icons[key] or 'info',
			description = locale('pool.' .. key .. 'Info', { shots = game.limit, target = game.target }),
			data = data, confirm = confirm, disabled = disabled }
	end
	if game.status == 'idle' then
		row('create', 'practice', { mode = 'practice' })
		row('create', 'challenge', { mode = 'challenge' })
		row('create', 'duel', { mode = 'duel' })
	elseif not slot then
		if game.mode == 'duel' and game.status == 'waiting' then row('join', 'join')
		else rows[1] = { id = 'occupied', label = locale('pool.busy'), icon = 'lock', disabled = true } end
	else
		if state.owner == me and state.phase == 'ready' then row('resume', 'resume') end
		if game.resetBy > 0 then
			if game.resetBy ~= slot then row('acceptReset', 'acceptReset', nil, true)
			else rows[#rows+1] = { id = 'pending', label = locale('pool.resetPending'), icon = 'clock', disabled = true } end
			row('declineReset', 'declineReset')
		else row('reset', game.mode == 'duel' and game.status ~= 'waiting' and 'requestReset' or 'rack', nil, true, state.phase ~= 'ready') end
		if game.mode ~= 'duel' or game.status == 'waiting' or game.status == 'finished' then row('finish', 'finish', nil, game.status == 'playing') end
		row('leave', 'leave', nil, game.mode == 'duel' and game.status == 'playing')
	end
	return rows
end
function T.Open(state, spec, send)
	menu = OPX.Api.Get('menu')
	if not menu then OPX.Toast.Locale('pool.menuUnavailable', nil, 'error');return false end
	T.Close()
	local snapshot = { epoch = state.epoch, revision = state.revision }
	local opened = menu.Open({ owner = 'pool', id = 'pool.table', title = spec.label, closeOnSelect = true,
		items = T.Rows(state, Open77.players.localId()),
		on = function(message)
			if type(message) ~= 'table' or message.action ~= 'select' then return end
			local data = message.data
			if type(data) ~= 'table' then return end
			handle = nil
			send(data.action, { mode = data.mode }, snapshot)
		end,
	})
	if not opened.ok then OPX.Note('pool', 'table menu: ' .. tostring(opened.error));OPX.Toast.Locale('pool.menuUnavailable', nil, 'error');return false end
	handle = opened.value.handle
	return true
end
