--- The camera styles: validated from config, applied through the platform's rig,
--- offered on the eye, remembered on this machine.
-- @author dop42
--
-- THE NATIVES, all client, all op77.78 (devkit `third-person-camera`):
--
--   Open77.camera.configureThirdPerson(options)   camera.style
--   Open77.camera.resetThirdPerson()              camera.style
--   Open77.perspective.setThirdPerson(true)       none, when not forced
--
-- A STYLE DOES NOT TURN THIRD PERSON ON. The platform keeps the two apart, so
-- choosing a style on the eye also asks for third person -- unforced, so F7
-- still flips back -- because a player who picks "over the shoulder" while in
-- first person and sees nothing change has been told the row is broken. A
-- style RESTORED at start does not ask: the player's last F7 choice stands, and
-- the style waits for the rig.
--
-- REFUSED WHOLE, NEVER HALF-APPLIED. The platform rejects an unknown field or
-- an out-of-range number atomically, and this file holds every value to the
-- same bounds first, so a bad style in config is dropped at start with one line
-- the operator can read (`OPX.Note`) instead of a row that does nothing.

local M = OPX.Modules.Get('camera')

M.Styles = {}
local Styles = M.Styles

local TAG = 'camera'

-- What is kept on this machine, per server. A style id and a shoulder.
local KEY_STYLE = 'opx.camera.style'
local KEY_SHOULDER = 'opx.camera.shoulder'

-- The game's own camera: no style held at all.
local DEFAULT = 'default'

local BASES = { classic = true, shoulder = true, centered = true }
local FRAMINGS = { HIP = 'hip', AIM = 'aim', EXPLORE = 'explore' }

-- The validated styles, in config order, and the one held now.
local styles = {}
local current = DEFAULT
local shoulder = 'right'

local function settings()
	local block = M.Settings
	if type(block) ~= 'table' or next(block) == nil then block = OPX.Config.MODULES.camera end
	return type(block) == 'table' and block or {}
end

--- A finite number inside [low, high], or nil.
local function within(value, low, high)
	local number = tonumber(value)
	if number == nil or number ~= number or number < low or number > high then return nil end
	return number
end

--- A lens: 0 (keep the game's) or 40..110.
local function lens(value)
	local number = tonumber(value)
	if number == 0 then return 0 end
	return within(number, 40, 110)
end

--- One framing table as the native spells it, or nil and why.
local function framing(row, name)
	if type(row) ~= 'table' then return nil, name .. ' is not a table' end
	local distance = within(row.DISTANCE, 0.8, 8)
	if distance == nil then return nil, name .. '.DISTANCE is not 0.8..8' end
	local offset = row.OFFSET
	if type(offset) ~= 'table' then return nil, name .. '.OFFSET is not { X, Y, Z }' end
	local x, y, z = within(offset.X, -2, 2), within(offset.Y, -1, 1), within(offset.Z, -1.5, 3)
	if x == nil or y == nil or z == nil then return nil, name .. '.OFFSET is out of range' end
	local fov = lens(row.FOV)
	if fov == nil then return nil, name .. '.FOV is not 0 or 40..110' end
	return { distance = distance, offset = { x = x, y = y, z = z }, fov = fov }
end

--- One config row as native options, or nil and why. The shoulder is added at
--- apply time: it is the player's, not the style's.
-- @author dop42
-- @param row table
-- @return table|nil { id, options }
-- @return string|nil
function Styles.Build(row)
	if type(row) ~= 'table' then return nil, 'a style is not a table' end
	local id = row.ID
	if type(id) ~= 'string' or not id:match('^[%w_]+$') or id == DEFAULT then
		return nil, ('style %s has no usable ID'):format(tostring(id))
	end
	if not BASES[row.BASE] then
		return nil, ('style %s: BASE is not classic, shoulder or centered'):format(id)
	end

	local options = { style = row.BASE }
	for key, field in pairs(FRAMINGS) do
		if row[key] ~= nil then
			local framed, why = framing(row[key], key)
			if framed == nil then return nil, ('style %s: %s'):format(id, why) end
			options[field] = framed
		end
	end

	local scalars = {
		{ 'TRANSITION', 'transition', function(v) return within(v, 0, 3) end },
		{ 'RUN_SPEED', 'runSpeed', function(v) return within(v, 0.5, 15) end },
		{ 'RUN_FOV', 'runFov', lens },
		{ 'SPRINT_FOV', 'sprintFov', lens },
	}
	for index = 1, #scalars do
		local key, field, check = scalars[index][1], scalars[index][2], scalars[index][3]
		if row[key] ~= nil then
			local value = check(row[key])
			if value == nil then return nil, ('style %s: %s is out of range'):format(id, key) end
			options[field] = value
		end
	end

	return { id = id, options = options }
end

--- Re-reads the configured styles, dropping and naming every bad one.
-- @author dop42
-- @return table[] the usable styles
function Styles.Load()
	styles = {}
	local list = settings().STYLES
	if type(list) ~= 'table' then return styles end
	local seen = {}
	for index = 1, #list do
		local built, why = Styles.Build(list[index])
		if built == nil then
			OPX.Note(TAG, 'a camera style was dropped: ' .. tostring(why))
		elseif seen[built.id] then
			OPX.Note(TAG, ('camera style %s is listed twice; the first is kept'):format(built.id))
		else
			seen[built.id] = true
			styles[#styles + 1] = built
		end
	end
	return styles
end

--- The usable styles, as built.
function Styles.List()
	return styles
end

local function find(id)
	for index = 1, #styles do
		if styles[index].id == id then return styles[index] end
	end
	return nil
end

--- Whether this client has the style rig at all. Asked by name at call time,
--- like every other native this runtime reaches for: a client older than
--- op77.78 is not broken, it simply has no styles to offer.
-- @author dop42
-- @return boolean
function Styles.Available()
	local camera = Open77.camera
	return type(camera) == 'table' and type(camera.configureThirdPerson) == 'function'
		and type(camera.resetThirdPerson) == 'function'
end

--- The style held now, 'default' for none, and the shoulder.
-- @author dop42
-- @return string
-- @return string
function Styles.Current()
	return current, shoulder
end

local function call(name, ...)
	local ok, answered, reason = pcall(Open77.camera[name], ...)
	if not ok then return false, tostring(answered) end
	if answered ~= true then return false, tostring(reason or 'refused') end
	return true
end

--- Asks for third person, unforced, when this client can.
local function enterThirdPerson()
	local perspective = Open77.perspective
	if type(perspective) ~= 'table' or type(perspective.setThirdPerson) ~= 'function' then return end
	local ok, accepted, reason = pcall(perspective.setThirdPerson, true)
	if not ok or accepted ~= true then
		-- Not a failure of the style: a server policy or a vehicle camera owns
		-- the view, and the style resumes when the playable rig returns.
		OPX.Note(TAG, 'third person was not granted: ' .. tostring(ok and reason or accepted))
	end
end

--- Holds one style, or releases ours for 'default'.
-- @author dop42
-- @param id string
-- @param enter boolean also ask for third person
-- @return boolean
-- @return string|nil why not
function Styles.Apply(id, enter)
	if not Styles.Available() then return false, 'camera_style_unavailable' end

	if id == DEFAULT then
		if current == DEFAULT then return true end
		local ok, why = call('resetThirdPerson')
		if not ok then return false, why end
		current = DEFAULT
		return true
	end

	local style = find(id)
	if style == nil then return false, 'unknown_style' end

	local options = {}
	for key, value in pairs(style.options) do options[key] = value end
	options.shoulder = shoulder

	local ok, why = call('configureThirdPerson', options)
	if not ok then return false, why end
	current = id
	if enter then enterThirdPerson() end
	return true
end

local function remember(key, value)
	local saved = OPX.Lib.Store.Set(key, value)
	if not saved.ok then
		OPX.Note(TAG, ('the camera choice was not saved: %s'):format(tostring(saved.detail)))
	end
end

local function refused(why)
	-- Said to the operator AND to the player: the operator learns which reason,
	-- the player learns that the row did not take rather than reading nothing.
	OPX.Note(TAG, 'a camera style was refused: ' .. tostring(why))
	local key = why == 'camera_style_owned' and 'camera.owned' or 'camera.refused'
	OPX.Toast.Locale(key, nil, 'warning')
end

--- What the eye's row does: hold a style, enter third person, remember it.
-- @author dop42
-- @param id string
-- @return boolean
function Styles.Choose(id)
	local ok, why = Styles.Apply(id, true)
	if not ok then
		refused(why)
		return false
	end
	remember(KEY_STYLE, id)
	return true
end

--- Moves the held style to the other shoulder, with the rig's own blend.
-- @author dop42
-- @return boolean
function Styles.Swap()
	if current == DEFAULT or not Styles.Available() then return false end
	local other = shoulder == 'right' and 'left' or 'right'
	local ok, why = call('configureThirdPerson', { shoulder = other })
	if not ok then
		refused(why)
		return false
	end
	shoulder = other
	remember(KEY_SHOULDER, other)
	return true
end

local function label(key, fallback)
	if OPX.Locale.Exists(key) then return locale(key) end
	return fallback
end

--- The rows the eye shows on the player's own body, under one folder.
---
--- In the registry's vocabulary -- `onSelect`, `canInteract`, `checked` -- and
--- with labels resolved here, for the reasons `animations/client/walk.lua`
--- spells out: the registry refuses a batch whole, and draws a raw key as text.
--- A style an operator added without a catalogue entry is labelled by its ID.
-- @author dop42
-- @return table[]
function Styles.Rows()
	local group = locale('camera.group')
	local function row(id, text, onSelect, checked, canInteract)
		return {
			id = id,
			label = text,
			icon = 'person',
			group = group,
			-- Beside the walking paces, above the staff band at 100.
			order = 11,
			canInteract = canInteract or function() return Styles.Available() end,
			checked = checked,
			onSelect = onSelect,
		}
	end

	local rows = {
		row('camera_default', label('camera.style.default', DEFAULT),
			function() return Styles.Choose(DEFAULT) end,
			function() return current == DEFAULT end),
	}
	for index = 1, #styles do
		local id = styles[index].id
		rows[#rows + 1] = row('camera_' .. id, label('camera.style.' .. id, id),
			function() return Styles.Choose(id) end,
			function() return current == id end)
	end
	rows[#rows + 1] = row('camera_swap', locale('camera.swap'),
		function() return Styles.Swap() end, nil,
		function() return Styles.Available() and current ~= DEFAULT end)
	return rows
end

-- ── the phases ───────────────────────────────────────────────────────────────

--- Builds the styles and restores this machine's last choice. Never yields.
-- @author dop42
function M.Start()
	current = DEFAULT
	Styles.Load()

	local remembered = OPX.Lib.Store.Get(KEY_SHOULDER, 'right')
	shoulder = remembered == 'left' and 'left' or 'right'

	if not Styles.Available() then
		Open77.log.info('[camera] this client has no camera styles (op77.78): none are offered')
	else
		local wanted = OPX.Lib.Store.Get(KEY_STYLE, settings().DEFAULT or DEFAULT)
		if type(wanted) == 'string' and wanted ~= DEFAULT then
			-- Restored without entering third person: the player's F7 stands.
			local ok, why = Styles.Apply(wanted, false)
			if not ok then OPX.Note(TAG, ('style %s was not restored: %s'):format(wanted, tostring(why))) end
		end
	end

	local contract = OPX.Api.Get('target')
	if contract == nil or type(contract.RegisterSelf) ~= 'function' then return end
	if not Styles.Available() then return end
	local answer = contract.RegisterSelf('camera', Styles.Rows())
	if answer == nil or answer.ok ~= true then
		OPX.Note(TAG, ('the camera rows were refused: %s'):format(tostring(answer and answer.error)))
	end
end

--- Gives the style back. The platform also releases it when the resource
--- stops; this is the same thing said in order, before the page goes.
-- @author dop42
function M.Stop()
	if current ~= DEFAULT and Styles.Available() then call('resetThirdPerson') end
	current = DEFAULT
end
