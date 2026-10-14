--- The chat box: what players say to each other, and the only path a typed
--- slash command takes to the host dispatcher.
-- @author dop42
--
-- Without the client half below, every `RegisterCommand` in this runtime is
-- reachable only from the developer terminal: the host has no in-game command
-- line of its own, and a line typed into a chat box is the only thing that ever
-- reaches `open77:command:execute`.
--
-- The module implements no command, checks no permission (the host resolves the
-- ACL before a handler runs) and persists nothing.
--
-- It draws nothing either. The client half owns the state and hands it to
-- whatever draws it, over the seam marked in `client/main.lua`. The log and the
-- input line are two concerns on two different surfaces -- the log on the
-- always-on overlay, the input line on the interactive layer that takes the
-- keyboard -- so every payload names the surface it belongs to.

local M = OPX.Modules.Declare{
	id = 'chat',
	side = 'both',
	fatal = false,
	-- Not a requirement: without it the box simply never hides. With it, the box
	-- gives the keyboard back while a player is down, instead of fighting the
	-- down screen for it.
	-- `downed` is not a requirement: without it the box simply never hides. With
	-- it, the box gives the keyboard back while a player is down.
	-- `character` is not one either: a runtime without it is one where the
	-- gamertag IS the only name there is, and the box must still work there --
	-- but with it, a message is attributed to the person, not to the account.
	optional = { 'downed', 'character' },
}

-- The three prefixes are disjoint by construction (see core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local `TriggerEvent` on a
-- NET name would re-enter the handler registered for the wire.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

M.Event = {
	-- Client to server.
	SAY = OPX.Event(NET, 'chat', 'say'),
	READY = OPX.Event(NET, 'chat', 'ready'),

	-- Server to client.
	MESSAGE = OPX.Event(NET, 'chat', 'message'),
	SUGGESTIONS = OPX.Event(NET, 'chat', 'suggestions'),

	-- The client's own bus. `view` is the seam a view module attaches to;
	VIEW = OPX.Event(LOCAL, 'chat', 'view'),
}

--- Names the host owns, listed once so there is one place to change them.
-- None of these may be renamed here: the first two are the dispatcher's own
-- contract, and the last two are raised by the host when the player presses a
-- key this runtime has no binding for.
M.Host = {
	COMMAND_EXECUTE = 'open77:command:execute',
	COMMAND_RESULT = 'open77:command:result',
	CHAT_KEY = 'open77:chat:open',
	PAUSE_KEY = 'open77:pauseKey',
}

--- The name core sends a command's own read-back answer on.
-- `OPX.CommandResult` writes on the runtime channel rather than a chat one,
-- because core must not name a module. Anything may listen; this module does,
-- and if nothing did the answer would simply not be drawn.
M.CORE_MESSAGE = OPX.Event(OPX.Channel.NET, 'runtime', 'commandResult')
