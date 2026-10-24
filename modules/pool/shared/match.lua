--- Closed full-rack modes and pure scoring; the server alone applies them.
-- @author dop42
local M = OPX.Modules.Get('pool')
local Number = M.Model.Number
M.Match = {}
local G = M.Match
G.MODES = { practice = true, challenge = true, duel = true }
local statuses = { idle = true, waiting = true, playing = true, finished = true }
local reasons = { [''] = true, clear = true, limit = true, scratch = true, score = true, forfeit = true, simulation = true }
local function integer(value, low, high) return Number(value, low, high) and value%1 == 0 end
function G.New(mode, player, settings)
	settings = settings or {}
	local limit = integer(settings.SOLO_SHOTS, 1, 50) and settings.SOLO_SHOTS or 10
	local target = integer(settings.DUEL_TARGET, 1, 30) and settings.DUEL_TARGET or 5
	return { mode = mode, status = not player and 'idle' or mode == 'duel' and 'waiting' or 'playing',
		players = player and { player } or {}, scores = { 0, 0 }, turn = player and 1 or 0,
		shots = 0, limit = limit, target = target, winner = 0, resetBy = 0, reason = '' }
end
function G.Slot(game, player)
	for index, id in ipairs(game.players) do if id == player then return index end end
end
function G.Owner(game)
	if game.status ~= 'playing' or game.resetBy ~= 0 then return 0 end
	return game.players[game.turn] or 0
end
function G.Join(game, player)
	if game.mode ~= 'duel' or game.status ~= 'waiting' or #game.players ~= 1 or game.players[1] == player then return false end
	game.players[2], game.status, game.turn = player, 'playing', 1
	return true
end
function G.Forfeit(game, slot)
	game.status, game.resetBy, game.reason = 'finished', 0, 'forfeit'
	game.winner = game.mode == 'duel' and game.players[3-slot] and 3-slot or 0
end
function G.Resolve(game, before, balls)
	if game.status ~= 'playing' then return false end
	local made, remaining = 0, 0
	for index = 2, #balls do
		if before[index] and not balls[index].alive then made = made+1 end
		if balls[index].alive then remaining = remaining+1 end
	end
	local scratch = before[1] and not balls[1].alive
	local slot = game.turn
	game.shots = math.min(1000000, game.shots+1)
	game.scores[slot] = math.min(1000000, math.max(0, game.scores[slot]+made-(scratch and 1 or 0)))
	if game.mode == 'challenge' then
		if remaining == 0 or game.shots >= game.limit then
			game.status, game.winner = 'finished', remaining == 0 and not scratch and 1 or 0
			game.reason = remaining == 0 and (scratch and 'scratch' or 'clear') or 'limit'
		end
	elseif game.mode == 'duel' then
		if game.scores[slot] >= game.target then
			game.status, game.winner, game.reason = 'finished', slot, 'score'
		elseif made == 0 or scratch then game.turn = 3-slot end
	end
	return remaining == 0 and game.status == 'playing'
end
-- Every nested field is copied: malformed public packets cannot partly replace state.
function G.Read(raw)
	if type(raw) ~= 'table' or not G.MODES[raw.mode] or not statuses[raw.status]
		or type(raw.players) ~= 'table' or #raw.players > 2 or type(raw.scores) ~= 'table' or #raw.scores ~= 2
		or not integer(raw.turn, 0, 2) or not integer(raw.shots, 0, 1000000)
		or not integer(raw.limit, 1, 50) or not integer(raw.target, 1, 30)
		or not integer(raw.winner, 0, 2) or not integer(raw.resetBy, 0, 2) or not reasons[raw.reason] then return nil end
	local game = { mode = raw.mode, status = raw.status, players = {}, scores = {}, turn = raw.turn,
		shots = raw.shots, limit = raw.limit, target = raw.target, winner = raw.winner, resetBy = raw.resetBy, reason = raw.reason }
	for index, id in ipairs(raw.players) do
		if not integer(id, 1, 1000000000) or (index == 2 and id == raw.players[1]) then return nil end
		game.players[index] = id
	end
	for index = 1, 2 do if not integer(raw.scores[index], 0, 1000000) then return nil end;game.scores[index] = raw.scores[index] end
	if raw.status == 'idle' then
		if #game.players ~= 0 or game.turn ~= 0 or game.winner ~= 0 or game.resetBy ~= 0 then return nil end
	else
		if #game.players < 1 or game.turn < 1 or not game.players[game.turn]
			or (game.winner > 0 and not game.players[game.winner]) or (game.resetBy > 0 and not game.players[game.resetBy]) then return nil end
		if raw.mode ~= 'duel' and #game.players ~= 1 then return nil end
		if raw.status == 'waiting' and (raw.mode ~= 'duel' or #game.players ~= 1) then return nil end
		if raw.status == 'playing' and raw.mode == 'duel' and #game.players ~= 2 then return nil end
	end
	return game
end
