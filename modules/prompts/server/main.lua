--- The server's door onto one player's key strip.
-- @author dop42
--
-- The strip itself lives on the client: only the client knows what a mapping is
-- bound to, whether the keyboard is taken, and whether the HUD is off. This half
-- exists so that a server module can put a row in front of one player without
-- naming an event, and it does exactly one thing with what it is given -- send
-- it to that player.
--
-- IT VALIDATES ALMOST NOTHING ON PURPOSE. The spec is checked by the client,
-- once, against the ceilings that actually bound the strip; checking it twice
-- would mean two sets of rules to keep in step, and the second set would be the
-- one that drifted. What is checked here is what cannot be checked there: that
-- there is a player to send to, and that the owner name is a name.
--
-- A group sent from here outlives its sender. A client cannot see a server
-- module stop, so a module that restarts should `HideAll` before it puts
-- anything up again, or reuse its ids so the new groups replace the old.

local M = OPX.Modules.Get('prompts')

local Result = OPX.Result

-- Same ceiling as the client's owner name, less the `@server:` the client adds.
local MAX_OWNER = 64 - #M.SERVER_PREFIX

--- Whether a value is a bounded name of word characters.
local function validName(value, maximum)
	return type(value) == 'string' and #value > 0 and #value <= maximum
		and value:match('^[%w_:%-%.]+$') ~= nil
end

--- Checks the two things this half can check: answers the player id to send to,
--- or nil and the refusal.
--
-- ONE CONNECTED PLAYER, NEVER A BROADCAST. This used to ask only that the id be
-- a finite number, and -1 is one: `TriggerClientEvent(..., -1, ...)` is every
-- client, so any module's prompt for "player -1" went up on the whole server's
-- strip, answered Ok. A 0, a fraction or the id of a slot nobody holds passed
-- too, reached nobody, and was still answered Ok. Checked the way the chat
-- module checks its target.
local function addressed(source, owner)
	local id = math.tointeger(tonumber(source))
	if id == nil or id < 1 or id > 2147483647 or OPX.UserIdOf(id) == nil then
		return nil, Result.Err('prompts.invalidPlayer')
	end
	if not validName(owner, MAX_OWNER) then return nil, Result.Err('prompts.invalidOwner') end
	return id
end

--- Puts a group up on one player's strip, or replaces the one that owner already
--- sent under that id.
-- @author dop42
-- @param source Source
-- @param owner string the sending module's own name
-- @param id string
-- @param spec table title, priority and rows
-- @return Result
local function show(source, owner, id, spec)
	local player, refused = addressed(source, owner)
	if player == nil then return refused end
	TriggerClientEvent(M.Event.SHOW, player, { owner = owner, id = id, spec = spec })
	return Result.Ok({ id = id })
end

--- Patches a group that owner already sent to that player.
-- @author dop42
-- @param source Source
-- @param owner string
-- @param id string
-- @param patch table
-- @return Result
local function update(source, owner, id, patch)
	local player, refused = addressed(source, owner)
	if player == nil then return refused end
	TriggerClientEvent(M.Event.UPDATE, player, { owner = owner, id = id, patch = patch })
	return Result.Ok({ id = id })
end

--- Takes one of that owner's groups down on one player's strip.
-- @author dop42
-- @param source Source
-- @param owner string
-- @param id string
-- @return Result
local function hide(source, owner, id)
	local player, refused = addressed(source, owner)
	if player == nil then return refused end
	TriggerClientEvent(M.Event.HIDE, player, { owner = owner, id = id })
	return Result.Ok({ id = id })
end

--- Takes every one of that owner's groups down on one player's strip.
-- @author dop42
-- @param source Source
-- @param owner string
-- @return Result
local function hideAll(source, owner)
	local player, refused = addressed(source, owner)
	if player == nil then return refused end
	-- The whole payload is the owner name; this one is not a table.
	TriggerClientEvent(M.Event.HIDE_ALL, player, owner)
	return Result.Ok(true)
end

--- Nothing to build: this half holds no state, because the strip is the client's.
-- @author dop42
function M.Init()
end

--- Publishes the four operations addressed at one player.
-- @author dop42
function M.Api()
	OPX.Api.Provide('prompts', 1, {
		Show = show,
		Update = update,
		Hide = hide,
		HideAll = hideAll,
	})
end
