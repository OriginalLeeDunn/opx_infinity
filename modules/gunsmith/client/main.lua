--- Two rows on the eye per armoury: the bench, and the chest beside it.
-- @author dop42
--
-- THIS HALF POINTS AND NOTHING ELSE. It puts a sphere where the config says the
-- bench is and another where the chest is, and each row does one thing: ask. The
-- bench row asks the crafting module's client half to open its screen, which
-- asks the server, which re-reads the job and re-measures the distance; the
-- chest row sends one event and the server does the same. Nothing here is
-- believed.
--
-- IT DOES NOT DRAW THE GATE, and that is deliberate rather than lazy. It would
-- be easy to read the character's job on this side and grey the row out -- the
-- snapshot is right there -- and it would be wrong twice: the row would lie
-- whenever the snapshot was stale, and hiding an armoury from somebody who is
-- not staff removes the one thing that tells them it exists. A row anybody can
-- press and a refusal in words is a better screen than a row that is not there.

local M = OPX.Modules.Get('gunsmith')

local Access = M.Access

-- What the eye owns, so the rows can be taken down on stop.
local OWNER = 'gunsmith'
local BENCH_ROW = 'gunsmith.bench'
local CHEST_ROW = 'gunsmith.chest'

-- The contracts, resolved at Start.
local target, crafting = nil, nil

-- The armouries this file registered spheres for.
local placed = {}

--- The armoury whose bench or chest the eye landed on, or nil.
-- @author dop42
--
-- THE EYE NEVER ANSWERS WITH A SPHERE INDEX, and both rows used to read one:
-- `payload.index` was always nil, so pressing Workbench or the armoury stock did
-- nothing at all -- no screen, no toast, no log line. The shops module found the
-- same bug in its own row and fixed it the same way: the eye says WHERE it
-- landed (`context.position`), and the nearest spot of the right kind within
-- the row's radius is the one pressed. Two overlapping armouries resolve to the
-- one under the crosshair.
-- @param context table what the eye sent
-- @param part string 'bench' or 'chest'
-- @param radius number
-- @return table|nil
local function nearest(context, part, radius)
	local at = type(context) == 'table' and context.position or nil
	if type(at) ~= 'table' or not (OPX.Math.IsFinite(at.x) and OPX.Math.IsFinite(at.y)
		and OPX.Math.IsFinite(at.z)) then
		return nil
	end
	local best, bestGap = nil, radius
	for index = 1, #placed do
		local spot = placed[index][part]
		if spot ~= nil then
			local dx, dy, dz = at.x - spot.x, at.y - spot.y, at.z - spot.z
			local away = math.sqrt(dx * dx + dy * dy + dz * dz)
			if away <= bestGap then best, bestGap = placed[index], away end
		end
	end
	return best
end

--- Puts the two rows on every armoury that has a bench.
local function placeRows()
	placed = Access.List()
	if #placed == 0 then return end

	local radius = Access.PROMPT_RADIUS

	local benches, chests = {}, {}
	for index = 1, #placed do
		local armoury = placed[index]
		benches[index] = { x = armoury.bench.x, y = armoury.bench.y, z = armoury.bench.z,
			radius = radius }
		-- A chest is optional, so its sphere list is not the bench list; neither
		-- list is read back by index (see `nearest`), so a hole costs nothing.
		if armoury.chest ~= nil then
			chests[#chests + 1] = { x = armoury.chest.x, y = armoury.chest.y,
				z = armoury.chest.z, radius = radius }
		end
	end

	local rows = target.RegisterSpheres(OWNER, benches, {
		id = BENCH_ROW,
		label = locale('gunsmith.bench'),
		icon = 'tool',
		distance = radius,
		order = 20,
		onSelect = function(context)
			local armoury = nearest(context, 'bench', radius)
			if armoury == nil then return end
			if crafting == nil then
				return OPX.Toast.Locale('gunsmith.unavailable', nil, 'error')
			end
			crafting.Open(M.BENCH_PREFIX .. armoury.key)
		end,
	})
	if not rows.ok then
		Open77.log.warn(('[gunsmith] the bench rows were refused: %s'):format(tostring(rows.error)))
	end

	if #chests == 0 then return end

	-- THE CHESTS ON A FRESH RESUME. The eye checks every sphere and the row it
	-- carries field by field, ~2,000 VM instructions a registration, and this
	-- runs inside `Start` on the client boot thread: the two together were the
	-- dearest resume of the boot (6,500 on the budget meter) against a budget
	-- of ~10,000 that unwinds the thread, and every module after this one with
	-- it. `Start` may yield; under pcall for a caller that is not on a thread.
	pcall(Wait, 0)

	rows = target.RegisterSpheres(OWNER, chests, {
		id = CHEST_ROW,
		label = locale('gunsmith.chest'),
		icon = 'box',
		distance = radius,
		order = 21,
		onSelect = function(context)
			local armoury = nearest(context, 'chest', radius)
			if armoury == nil then return end
			TriggerServerEvent(M.Event.CHEST, armoury.key)
		end,
	})
	if not rows.ok then
		Open77.log.warn(('[gunsmith] the chest rows were refused: %s'):format(tostring(rows.error)))
	end
end

--- Resets the state. Never yields.
-- @author dop42
function M.Init()
	target, crafting, placed = nil, nil, {}
end

--- Puts the rows on the world.
-- @author dop42
function M.Start()
	target = OPX.Api.Get('target')
	crafting = OPX.Api.Get('crafting')

	if crafting == nil then
		Open77.log.warn('[gunsmith] no crafting contract: a bench row would open nothing')
	end
	if target == nil then
		Open77.log.warn('[gunsmith] no target contract: the armouries are there and unreachable')
		return
	end

	placeRows()

	RegisterNetEvent(M.Event.REFUSED, function(_, code)
		if type(code) ~= 'string' then return end
		OPX.Toast.Locale('gunsmith.' .. code, nil, 'error')
	end)
end

--- Takes the rows down.
-- @author dop42
function M.Stop()
	if target ~= nil then pcall(target.Clear, OWNER) end
	placed = {}
end
