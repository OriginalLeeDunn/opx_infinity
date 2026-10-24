--- Module-owned leases over the platform's RESOURCE-owned control restrictions.
-- @author dop42
-- Closing the eye or a pool aim must not release cuffs or a carried crate.
OPX.Controls = {}
local claims = {}
local known = { allowAim = true, allowShoot = true, allowInteraction = true,
	allowWeapons = true, allowDodge = true, allowJump = true, freezeRotation = true, freezePosition = true }
local function held(name, except)
	for owner, names in pairs(claims) do if owner ~= except and names[name] then return true end end
	return false
end
function OPX.Controls.Set(owner, names, take)
	if type(owner) ~= 'string' or type(names) ~= 'table' or type(take) ~= 'boolean' then return false end
	local players, wanted = Open77.players, {}
	if type(players) ~= 'table' then return false end
	for _, name in ipairs(names) do
		if not known[name] or type(players[name]) ~= 'function' then return false end
		wanted[name] = true
	end
	local previous, changed = claims[owner] or {}, {}
	local function apply(name, on)
		local freeze = name == 'freezeRotation' or name == 'freezePosition'
		local value = freeze and on or not freeze and not on
		local ran, ok = pcall(players[name], value)
		return ran and ok == true
	end
	local seen, ordered = {}, {}
	for _, name in ipairs(names) do if not seen[name] then seen[name] = true; ordered[#ordered+1] = name end end
	local retired = {}
	for name in pairs(previous) do if not seen[name] then retired[#retired+1] = name end end
	table.sort(retired)
	for _, name in ipairs(retired) do ordered[#ordered+1] = name end
	for _, name in ipairs(ordered) do
		local before, after = held(name, owner) or previous[name] == true, held(name, owner) or (take and wanted[name] == true)
		if not apply(name, after) then
			apply(name, before)
			for index = #changed, 1, -1 do apply(changed[index].name, changed[index].before) end
			return false
		end
		changed[#changed+1] = { name = name, before = before }
	end
	claims[owner] = take and wanted or nil
	return true
end
