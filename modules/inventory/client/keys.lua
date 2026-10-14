--- The rebindable open and hotbar mappings.
-- @author dop42
--
-- Each key is declared to the host with `RegisterKeyMapping`, so that the pause
-- menu's shortcuts tab lists it under the localised name given here and a player
-- rebinds it there. The mapping id is namespaced by this module and is stable: a
-- rebind is stored under it, and renaming one loses every player's rebind.

local M = OPX.Modules.Get('inventory')

local Options = M.Options

M.Keys = {}
local Keys = M.Keys

-- Mapping id to the key the host answered with at registration.
local registered = {}

--- Declares one key mapping. A refusal costs one log line and nothing else.
-- Two answer shapes are documented for `RegisterKeyMapping` -- the key guide
-- answers `true, key` and the API reference answers the key alone -- and either
-- is a registration. `false` or nil with a reason is a refusal.
local function register(id, name, key, onPressed, wants)
	if key == false then return false end
	if type(RegisterKeyMapping) ~= 'function' then
		Open77.log.warn(('[inventory] key mapping %s not registered: this client build has no ' ..
			'RegisterKeyMapping'):format(id))
		return false
	end

	local function pressed()
		-- A key pressed while another surface holds the keyboard -- the chat box, a
		-- form, the pause menu -- does nothing here, so that typing an `I` into a
		-- text field does not open a screen behind it.
		if OPX.Lib.Input.IsCaptured() then return end
		if not OPX.Spots.Key.Owns(id) then return end
		local ran, failure = pcall(onPressed)
		if not ran then Open77.log.error(('[inventory] key %s: %s'):format(id, tostring(failure))) end
	end

	local called, ok, answer = pcall(RegisterKeyMapping, id, name, key, pressed)
	local effective = type(ok) == 'string' and ok ~= '' and ok or
		(ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	if not called or (ok ~= true and effective == nil) then
		local why = ('[inventory] key mapping %s (%s) not registered: %s')
			:format(id, tostring(key), tostring(called and answer or ok))
		Open77.log.warn(why)
		-- AND TO THE OPERATOR, because the client log is on the PLAYER'S machine.
		-- A mapping the host refused is a key that silently does nothing for
		-- everyone, and the only person able to change the default is the one
		-- reading the server journal.
		OPX.Note('inventory', why)
		return false
	end
	registered[id] = effective or key
	if wants ~= nil then
		OPX.Spots.Key.Contend({ tag = 'inventory', id = id, default = key, wants = wants })
	end
	return true
end

--- The key a mapping answers to now, rebinds included, or nil.
-- The page holds the keyboard while the screen is up, so it is the page that
-- reads the close key; it therefore has to be told the key the player actually
-- has, not the one the configuration asked for.
-- @author dop42
-- @param id string
-- @return string|nil
function Keys.Effective(id)
	local known = registered[id]
	if known == nil then return nil end
	return OPX.Lib.Input.KeyFor(id) or known
end

--- Toggles the screen: a glovebox first from a seat, the bag everywhere else.
--
-- NEVER A PILE. Beside a pile this key used to TAKE it -- the whole pile, into
-- the bag, with the screen left closed -- and the owner's report was exactly
-- that: drop something, open the inventory again to look at it, and the drop
-- is back in the bag. Opening the inventory is a look, never a take. A pile is
-- picked up by its own row on the key strip or on the eye, which say so.
local function pressOpen()
	local Screen = M.Screen
	if Screen.IsOpen() then return Screen.Close() end
	if Screen.IsDown() then return end
	if M.World.Seated() then return Screen.Open('openGlovebox') end
	Screen.Open()
end

--- Uses the item in one bag slot, with the screen closed and the player up.
--- Shows the hotbar row for a few seconds. It uses nothing: a player who wants
--- to know what slot three holds should not have to eat it to find out.
local function pressPeek()
	M.Slotbar.Peek()
end

local function pressHotbar(index)
	local Screen = M.Screen
	if Screen.IsOpen() or Screen.IsDown() or Screen.Own() == nil then return end

	-- AN EMPTY SLOT IS NOT A REQUEST. Pressing a hotbar key over nothing sent a
	-- `use` anyway, the server refused it -- correctly, it is the authority on
	-- what a slot holds -- and the refusal came back as a toast. So a player
	-- reaching for the wrong number was told off for it, every time, for a
	-- keypress that could not have done anything.
	--
	-- The client already knows: `Screen.Own()` is the mirror the server pushes
	-- on every change, and it is what the peek row is drawn from. Asking it here
	-- costs one walk of a five-entry list and saves a round trip. The server
	-- still refuses an empty slot, so a crafted client gains nothing.
	if not M.Slotbar.Holds(index) then return end

	Screen.Request('use', { slot = index })
end

--- Declares every mapping, then sends the page the keys it should draw.
-- @author dop42
function Keys.Register()
	register('opx.inventory.open', locale('inventory.key.open'), Options.KEY_OPEN, pressOpen)
	for index = 1, Options.HOTBAR_SLOTS do
		register('opx.inventory.hotbar' .. index,
			locale('inventory.key.hotbar', { slot = index }),
			Options.KEYS_HOTBAR[index], function() pressHotbar(index) end)
	end

	-- IN THE CONTEST FOR Y, AND NEVER WANTING IT: the peek has nothing to win
	-- a press with, so it acts only when nobody else on its key does -- and a
	-- call ringing (Y answers) is somebody. The owner: the peek stays silent
	-- while a call rings.
	register('opx.inventory.peek', locale('inventory.key.peek'), Options.KEY_PEEK, pressPeek,
		function() return nil end)

	-- Nothing in the catalogue depends on a key, so a rebind only resends the
	-- configuration.
	AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function() M.Screen.SendConfig() end)
	M.Screen.SendConfig()
end
