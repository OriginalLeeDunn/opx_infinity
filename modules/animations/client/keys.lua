--- Declares rebindable key mappings and follows a player's rebinds.
-- @author dop42
--
-- Nothing here reads a key itself: the host lists each mapping in the pause
-- menu's key tab under its translated name and a player rebinds it there. The
-- mapping ids are stable, because a player's rebind is stored under them.

local M = OPX.Modules.Get('animations')

M.Keys = {}
local Keys = M.Keys

-- The key the host answered per registered mapping id.
local registered = {}

-- Functions run when a player rebinds or resets a mapping.
local listeners = {}

-- Whether another surface holds the keyboard: the chat box, a form, the pause
-- menu. Kept module-local rather than folded into `OPX.Lib.Input.IsCaptured`, which
-- answers captured when the read itself raises where this answers free.
local function captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- Declares one key mapping, logging a refusal once.
-- Two answer shapes are documented for `RegisterKeyMapping`: the effective key,
-- or `true, key`. Reading only the second logged a working mapping as refused.
-- A refusal is a log line and nothing more: the command the key stands in for
-- still works.
-- @author dop42
-- @param id string stable mapping id a rebind is stored under
-- @param nameKey string catalogue key of the pause menu name
-- @param key string|false
-- @param onPressed function
-- @param wants function|nil enters the mapping into the contest for its key;
--   see `OPX.Spots.Key.Owns`
-- @return boolean
function Keys.Register(id, nameKey, key, onPressed, wants)
	if key == false then return false end
	local function pressed()
		if captured() then return end
		if not OPX.Spots.Key.Owns(id) then return end
		local ran, failure = pcall(onPressed)
		if not ran then
			Open77.log.error(('[animations] key %s: %s'):format(id, tostring(failure)))
		end
	end
	local called, ok, answer = pcall(RegisterKeyMapping, id, locale(nameKey), key, pressed)
	local effective = nil
	if called then
		effective = type(ok) == 'string' and ok ~= '' and ok
			or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	end
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[animations] key mapping %s (%s) not registered: %s')
			:format(id, key, tostring(called and answer or ok)))
		return false
	end
	registered[id] = effective or key
	if wants ~= nil then
		OPX.Spots.Key.Contend({ tag = 'animations', id = id, default = key, wants = wants })
	end
	return true
end

--- Answers the key a mapping answers to now, or nil when it is off or refused.
-- Nil rather than a guess, so a hint with no key to name says nothing.
-- @author dop42
-- @param id string
-- @return string|nil
function Keys.Effective(id)
	local known = registered[id]
	if known == nil then return nil end
	return OPX.Lib.Input.KeyFor(id) or known
end

--- Runs a function whenever a player rebinds or resets a mapping.
-- @author dop42
-- @param listener function
function Keys.OnChanged(listener)
	listeners[#listeners + 1] = listener
end

--- Wires the host's rebind event, each listener under its own pcall.
-- @author dop42
function Keys.Start()
	AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function()
		for index = 1, #listeners do
			local ran, failure = pcall(listeners[index])
			if not ran then
				Open77.log.error('[animations] keybinds changed: ' .. tostring(failure))
			end
		end
	end)
end
