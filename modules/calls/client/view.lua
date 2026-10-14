--- The other half of the seam: the state machine on one side, the page on the
--- other.
-- @author dop42
--
-- `client/main.lua` owns the call state and draws nothing. It says everything
-- it has to say on the local `calls:view` event and takes everything back
-- through `M.FromView`. This file is the only thing that knows those two ends
-- are a CEF page, which is what lets the state half stay testable without one.
--
-- ONE CHANNEL, NOT ONE PER VERB, for the reason `modules/downed/client/view.lua`
-- gives at length: the seam is already a single event carrying a `kind`, and
-- splitting it would mean a switch in this file and a second switch on the
-- page, both kept in step with a list that lives in a third.
--
-- ── one screen, and the layer it lives on ────────────────────────────────────
--
-- THE OWNER: "retire l'ui a gauche d'appel". There used to be two surfaces: an
-- incoming card and a live chip on `overlay`, and the hologram on
-- `interactive`. The card and the chip are gone -- the sphere says everything,
-- a call arriving included -- and with them went the dwell clock, the
-- dismiss/re-pop pair and the `calls:view` overlay payload nobody listened to.
--
-- THE HOLOGRAM IS ON `interactive` AND STILL TAKES NOTHING UNBIDDEN. A call
-- arriving pops the sphere with `open = false`: no panel, nothing pressable,
-- no focus, and the page itself keeps that part `pointer-events: none`. Focus
-- is acquired only when the player opened it on the key, and given back the
-- moment it closes -- which is why `focus:set` is not answered here: this
-- module claims focus on its own key and on nothing else.

local M = OPX.Modules.Get('calls')

M.View = {}
local View = M.View

-- The layer and the channel the hologram is drawn on.
local SURFACE = 'interactive'
local CHANNEL = 'calls:holo'

-- What the state half publishes, and the local event it travels on.
local EVENT_VIEW = M.Event.VIEW

-- Every action the page may send. `close` and `toggle` are about the screen;
-- `ready` is the page's mount handshake; the rest name a call or a player the
-- server judges again. An unknown one reaching `FromView` is ignored there, so
-- nothing here filters a second time.
--
-- `share` is not pressed on the page any more -- handing over a contact is the
-- one row on the target eye -- and stays in the seam's vocabulary because the
-- verb is still the module's, reached in process from that row.
local ACTIONS = { 'ready', 'close', 'toggle', 'call', 'share',
	'accept', 'decline', 'hangUp', 'withdraw', 'forget', 'diag' }

--- Wires the page to the seam.
-- @author dop42
function View.Start()
	-- The state half to the page, FIRST. The first payload this module ever
	-- causes is the one `FromView('ready')` draws straight back, and a page that
	-- mounted before this module started had its `calls:ready` held by the
	-- surface and REPLAYED, synchronously, to the first handler registered on it
	-- below -- so with this handler registered after the wiring the replayed
	-- ready drew into nothing (the same fault `modules/downed` shipped).
	AddEventHandler(EVENT_VIEW, function(payload)
		if type(payload) ~= 'table' or payload.kind ~= 'holo' then return end
		OPX.UI.Send(SURFACE, CHANNEL, payload)
		-- FOCUS FOLLOWS THE SCREEN. A hologram the player cannot type into or
		-- click is not a menu, and one that kept focus after closing would be a
		-- player who cannot move.
		-- `(owner, wants)`, and the cursor is asked for explicitly: it defaults
		-- to false, and a hologram whose rows cannot be clicked is a picture.
		-- The stack is what gives focus back to whatever was under this when it
		-- closes, rather than dropping it to nothing.
		if payload.open == true then
			OPX.UI.AcquireFocus('calls', { keyboard = true, cursor = true })
		else
			OPX.UI.ReleaseFocus('calls')
		end
	end)

	-- The page to the state half. EACH ACTION ONCE: `overlay` and `interactive`
	-- are two names for one page (`core/client/ui.lua`), and every handler on a
	-- channel runs. Wired twice, one hologram button asked the server twice and
	-- the second answer was a `tooFast` refusal on the player's screen.
	local wired = {}
	for _, action in ipairs(ACTIONS) do
		if not wired[action] then
			wired[action] = true
			OPX.UI.On(SURFACE, 'calls:' .. action, function(payload)
				M.FromView(action, payload)
			end)
		end
	end
end
