--- Whether a player is on the floor, asked the same way by every door.
-- @author dop42
--
-- THE DOWN SCREEN IS DRAWN BY THE CLIENT, so closing it proves nothing about
-- what the connection can still send. `modules/inventory` learnt that first and
-- wrote it into `Players.MayAct`; `doorlock`, `teleports` and `elevators` each
-- grew a local `isDown`; and a bench, a dealer, a garage marker, an armoury
-- chest, a store and a car key asked nothing at all. A player knocked down at a
-- garage marker could put the car away from the floor, and one downed at a
-- dealer could buy one. This is the one question those doors now ask.
--
-- Two sources, either is enough. The `downed` contract, when it runs, is the
-- authority on who is down and waiting for help. The host's own `isDead` is
-- what the inventory has always read, and it still answers when the `downed`
-- module is switched off -- a server without that module still has bodies on
-- the floor.
--
-- A read that raises is NOT down. Every caller is a door that would otherwise
-- serve the player, and refusing everyone because one read failed would take
-- every shop on the server with it; the authoritative checks behind each door
-- (ownership, reach, money) are unchanged either way.

OPX.Life = {}

--- Whether the downed contract says this player is down.
local function downByContract(player)
	local api = OPX.Api and OPX.Api.Get('downed') or nil
	if type(api) ~= 'table' or type(api.IsDown) ~= 'function' then return false end
	local read, answer = pcall(api.IsDown, player)
	if not read or type(answer) ~= 'table' or answer.ok ~= true then return false end
	return type(answer.value) == 'table' and answer.value.down == true
end

--- Whether the host says this player's body is dead.
local function deadByHost(player)
	local players = Open77.players
	if type(players) ~= 'table' or type(players.isDead) ~= 'function' then return false end
	local read, dead = pcall(players.isDead, player)
	return read and dead == true
end

--- Whether a player is down: downed by the contract, or dead by the host.
-- @author dop42
-- @param player Source
-- @return boolean
function OPX.Life.Down(player)
	player = tonumber(player)
	if player == nil or player <= 0 then return false end
	return downByContract(player) or deadByHost(player)
end
