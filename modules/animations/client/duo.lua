--- The invitation to an emote with a nearby player, on the invited screen.
-- @author dop42
--
-- The server chose this player as the nearest one in range and asks them; the
-- answer goes back to the server, which measures the distance again and only
-- then hands the pair to the platform's coordinator. Nothing here plays.
--
-- Two ways to answer, because one of them can be unavailable: a two-row menu,
-- and the toast that names the typed command (`/e accept`). The menu is refused
-- while another one is up -- the inventory, a shop -- and the toast still says
-- how to answer. An invitation nobody answers is withdrawn by the server.

local M = OPX.Modules.Get('animations')
local Catalogue = M.Catalogue
local Common = M.Common
local Opt = M.Opt
local Runtime = M.Runtime

M.Invite = {}
local Invite = M.Invite

local OWNER = 'animations'
local SPEC_ID = 'animations.invite'

-- The invitation on screen: id, what it reads, inviter's name and the menu handle.
local current = nil

-- Calls one function of the menu contract, answering its value or nil.
local function call(name, ...)
	local api = OPX.Api.Get('menu')
	if api == nil or type(api[name]) ~= 'function' then return nil end
	local ran, answer = pcall(api[name], ...)
	if not ran or type(answer) ~= 'table' or answer.ok ~= true then return nil end
	return answer.value or answer
end

-- Takes the invitation's menu down, if it is up.
local function closeMenu()
	local shown = current and current.handle or nil
	if current ~= nil then current.handle = nil end
	if shown ~= nil then call('Close', shown, 'invite') end
end

-- Sends the answer once and forgets the invitation.
local function answer(accepted)
	if current == nil then return end
	local id = current.id
	closeMenu()
	current = nil
	local sent = Runtime.Reply(id, accepted)
	if not sent.ok then Runtime.Refuse(sent.error) end
end

--- Whether an invitation is waiting for this player's answer.
-- @author dop42
-- @return boolean
function Invite.Pending()
	return current ~= nil
end

-- The menu's rows. Shape-checked: the menu also raises every action on its
-- public bus.
local function onMenu(payload)
	if type(payload) ~= 'table' or payload.owner ~= OWNER or payload.menu ~= SPEC_ID then return end
	if current == nil or payload.handle ~= current.handle then return end
	if payload.action == 'close' then
		-- Closed without a choice: the invitation still stands until it
		-- expires, and the typed command still answers it.
		current.handle = nil
		return
	end
	if payload.action ~= 'select' or type(payload.data) ~= 'table' then return end
	answer(payload.data.accept == true)
end

-- A profile's label, or its name when this client lacks the profile.
local function profileLabel(name)
	local entry = Catalogue.Entry(name)
	return entry and Catalogue.Label(entry) or name
end

-- A short lower-case word off the wire, or nil.
local function word(value)
	return Common.Text(value, 64) and value:match('^[%l%d_]+$') and value or nil
end

-- What the invitation reads, FROM THE INVITED BODY'S SIDE: a paired kind reads
-- its mirror ("be carried" for an asker who carries), two profiles read which
-- one is yours. Nil for a shape this client cannot read.
local function described(what)
	if type(what) ~= 'table' then return nil end
	local kind = Catalogue.DuoKind(what.kind)
	if kind ~= nil then return locale('animations.duo.kind.' .. kind.mirror) end
	local actor, target = word(what.actor), word(what.target)
	if actor == nil or target == nil then return nil end
	local pair = word(what.pair)
	if pair ~= nil and OPX.Locale.Exists('animations.duo.name.' .. pair) then
		return locale('animations.duo.name.' .. pair)
	end
	if actor == target then return locale('animations.duo.together', { name = profileLabel(actor) }) end
	return locale('animations.duo.yours', { mine = profileLabel(target), theirs = profileLabel(actor) })
end

-- Takes an invitation from the server and puts it in front of the player.
-- No name comes with it: never a name to a stranger. The person inviting is the
-- one standing next to you, and the words say that instead.
local function onInvite(inviteId, what)
	inviteId = Common.Integer(inviteId, 1, M.MAX_REQUEST_ID)
	local emote = described(what)
	if inviteId == nil or emote == nil then return end
	-- A newer invitation replaces an unanswered one; the server withdrew it.
	closeMenu()
	current = { id = inviteId, emote = emote }

	local command = Opt.PlayCommand()
	if command then
		Runtime.Notify('info', 'animations.duo.invited',
			{ emote = emote, command = '/' .. command })
	else
		Runtime.Notify('info', 'animations.duo.invitedMenu', { emote = emote })
	end

	local opened = call('Open', {
		owner = OWNER,
		id = SPEC_ID,
		title = locale('animations.duo.title'),
		on = onMenu,
		cursor = 'accept',
		items = {
			{ id = 'what', label = emote, icon = 'person', disabled = true,
				description = locale('animations.duo.from') },
			{ id = 'accept', label = locale('animations.duo.accept'), icon = 'emote',
				data = { accept = true } },
			{ id = 'decline', label = locale('animations.duo.decline'), icon = 'ban',
				data = { accept = false } },
		},
	})
	if opened ~= nil and current ~= nil and current.id == inviteId then
		current.handle = opened.handle
	end
end

-- The server withdrew an invitation: expired, or the inviter stopped.
local function onUninvite(inviteId)
	inviteId = Common.Integer(inviteId, 1, M.MAX_REQUEST_ID)
	if current == nil or current.id ~= inviteId then return end
	closeMenu()
	current = nil
	Runtime.Notify('info', 'animations.duo.withdrawn')
end

--- Forgets any invitation.
-- @author dop42
function Invite.Init()
	current = nil
end

--- Wires the two invitation channels.
-- @author dop42
function Invite.Start()
	RegisterNetEvent(M.Event.INVITE, onInvite)
	RegisterNetEvent(M.Event.UNINVITE, onUninvite)
end

--- Takes the invitation's menu down.
-- @author dop42
function Invite.Shutdown()
	closeMenu()
	current = nil
end
