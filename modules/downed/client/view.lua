--- The other half of the seam: the state machine on one side, the page on the other.
-- @author dop42
--
-- `client/main.lua` owns being down and draws nothing. It says everything it has
-- to say on the local `downed:view` event and takes everything back through
-- `M.FromView`. This file is the only thing that knows those two ends are a CEF
-- page, which is what lets the state half stay testable without one -- and it is
-- the file that was missing: the Lua half shipped complete, publishing `config`,
-- `show`, `hide`, `notice` and `focus` at a seam nothing was listening to, so a
-- player who died got the input taken away, the stock HUD hidden, and a black
-- screen with nothing on it.
--
-- ONE CHANNEL, NOT ONE PER VERB, for the reason `modules/chat/client/view.lua`
-- gives: the seam is already a single event carrying a `kind`, and splitting it
-- here would mean a switch in this file and a second switch on the page, both
-- kept in step with a list that lives in a third.
--
-- THE EVENT NAME IS DERIVED, NOT IMPORTED. `client/main.lua` keeps its channels
-- as locals and exports none of them; `OPX.Event` is a pure function of three
-- constants, so both halves spell the same name from the same three parts. That
-- is a weaker join than chat's `M.Event.VIEW` table and it is the one the state
-- half's own comment asks for -- "a view module attaches by listening to the
-- first and calling the second" -- so main.lua is left as it was written.

local M = OPX.Modules.Get('downed')

M.View = {}
local View = M.View

-- The layer. A death screen with two buttons the player presses is `modal` on the
-- page: the overlay layer is `pointer-events: none` for its whole height, so a
-- view registered there would draw perfectly and refuse every click.
local SURFACE = 'interactive'

-- What a published payload travels on, and the local event it is published from.
local CHANNEL = 'downed:view'
local EVENT_VIEW = OPX.Event(OPX.Channel.LOCAL, 'downed', 'view')

-- Every action the seam documents. An unknown one reaching `FromView` is ignored
-- there, so nothing here filters a second time.
local ACTIONS = { 'ready', 'wait', 'giveUp', 'key', 'diag' }

-- What this module answers for on `focus:set`, and what it asks for when it does.
--
-- THE KEYBOARD IS NOT HANDED OVER BY ASKING THE PAGE. `focus:set` is a BROADCAST:
-- the page announces that its own focus stack changed, and every view module on
-- the surface answers for ITS OWN owner by calling `OPX.UI.AcquireFocus`. An
-- owner no module claims is an owner nobody acquires -- `OPX.Surface.Focus` is
-- never applied and the game keeps the keyboard, which is the bug the chat box
-- shipped with and the one a down screen cannot have: the whole point of the
-- screen is that a downed player's keys do nothing until they choose.
--
-- `cursor = true`, unlike the chat line and like the menu: there are two buttons
-- to press and one of them has to be held down.
local FOCUS = {
	downed = { keyboard = true, cursor = true },
}

-- Answers the surface-wide focus broadcast for this module's own owners.
--
-- THE BROADCAST NAMES THE WHOLE STACK'S TOP, NOT JUST "EMPTY OR NOT", and
-- reading only the empty case was the incomplete half of this idiom.
-- `ui/src/bridge/focus.ts` announces on EVERY change to the page's focus stack,
-- carrying the one owner now on top -- so a top that moved from one of OURS to
-- somebody else's arrives here as `focus = true` with an owner this module does
-- not know, and the old shape did nothing at all with that. The stale Lua entry
-- then sat above the module actually on screen and `applyFocus` applied ITS
-- wants: the chat line's `cursor = false` over the inventory's `cursor = true`,
-- with the inventory drawn and the cursor gone.
--
-- The answer is the same in all six copies: release every owner of mine that is
-- NOT the announced one, then acquire the announced one if it is mine. `form`,
-- `menu` and `panel` are saved from the worst of it by an explicit
-- `ReleaseFocus` on their close paths; `chat` and `downed` have none, so for
-- those two this handler is the only release there is.
local function onFocus(payload)
	if type(payload) ~= 'table' then return end
	local owner = payload.owner
	local held = (payload.focus == true and type(owner) == 'string') and owner or nil
	for name in pairs(FOCUS) do
		if name ~= held then OPX.UI.ReleaseFocus(name) end
	end
	local wants = held ~= nil and FOCUS[held] or nil
	if wants == nil then return end
	OPX.UI.AcquireFocus(held, wants)
end

--- Wires the page to the seam.
-- @author dop42
function View.Start()
	-- Before the seam: the page announces its focus during the same burst that
	-- raises the screen, and an announcement with no handler is dropped.
	OPX.UI.On(SURFACE, 'focus:set', onFocus)

	-- Attach the seam before page handlers: On can synchronously replay a
	-- ready received during boot, and its config must already have a route out.
	AddEventHandler(EVENT_VIEW, function(payload)
		if type(payload) ~= 'table' then return end
		OPX.UI.Send(SURFACE, CHANNEL, payload)
	end)

	-- The page to the state half.
	for _, action in ipairs(ACTIONS) do
		OPX.UI.On(SURFACE, 'downed:' .. action, function(payload)
			M.FromView(action, payload)
		end)
	end

end

--- Gives the focus back on the way out.
-- @author dop42
--
-- A focus held across a stop leaves a player who is no longer down unable to
-- move, which is worse than any state this module could be leaving behind.
function View.Shutdown()
	for owner in pairs(FOCUS) do OPX.UI.ReleaseFocus(owner) end
end
