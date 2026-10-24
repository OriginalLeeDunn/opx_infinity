--- Ripperdoc: chrome in, chrome out, at a clinic, for a price and a piece of soul.
-- @author dop42
--
-- WHAT THIS MODULE OWNS: the clinics (chairs, a parts stash, a wholesale
-- terminal), the chrome catalogue, the operation itself -- quote, the patient's
-- consent, escrow, the bar, the dice, the native install, the settlement -- and
-- two metadata keys on the character, `humanity` and `cyberware`. Everything
-- else is reached through a contract:
--
--   character   who works where (job, grade, duty), the purse, the metadata
--   inventory   the parts: items registered at boot, a stash per clinic
--   progress    the server-timed bar the doc works under (no bar, no surgery)
--   target      the eye rows (the patient, the stash, the terminal)
--   menu        the chart, the consent prompt, the terminal's catalogue
--
-- SERVER AUTHORITATIVE. A client asks "chart this patient", "propose this
-- part", "I consent"; the server re-reads the job, the distance, the stock, the
-- bag and the purse at every step, and holds the money and the part in escrow
-- (with a receipt row in `opx77_ripperdoc_operations`) from the consent to the
-- end. A crash between the two is resumed at boot from the receipt.
--
-- THE NATIVE LINK. Gorilla Arms and Reinforced Tendons are real implants: the
-- platform's `Open77.cyberware` installs them asynchronously and answers on
-- `onCyberwareOperationCompleted`. The platform needs the player BOUND to a
-- character; `open77_appearance` does it when it runs, and `server/identity.lua`
-- does it otherwise. With no native link at all the module still runs,
-- roleplay-only, and says so once at boot.
--
-- NOT THE MEDIC. Reviving and healing belong to `medical`.

local M = OPX.Modules.Declare{
	id = 'ripperdoc',
	side = 'both',
	fatal = false,
	requires = { 'character', 'inventory' },
	-- Only what is really called. `medical` is deliberately absent: it may come
	-- to name this module one day, and two optionals naming each other are a
	-- cycle the dependency walk refuses by name.
	optional = { 'progress', 'target', 'menu', 'form', 'downed' },
}

local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

M.Event = {
	STYLE = OPX.Event(NET, 'ripperdoc', 'style'),
	STYLE_DATA = OPX.Event(NET, 'ripperdoc', 'styleData'),
	STYLE_APPLY = OPX.Event(NET, 'ripperdoc', 'styleApply'),
	STYLE_RESULT = OPX.Event(NET, 'ripperdoc', 'styleResult'),
	STYLE_RESTORE = OPX.Event(NET, 'ripperdoc', 'styleRestore'),
	-- Client to server. Every field is re-read; `source` is the only truth.
	-- `(patientId)`: the doc asks for the chart of a patient in a chair.
	CHART = OPX.Event(NET, 'ripperdoc', 'chart'),
	-- `{ patient, action, chrome, tier, origin, source, slot, serial }`.
	PROPOSE = OPX.Event(NET, 'ripperdoc', 'propose'),
	-- `(operationId, accepted)`: the patient's answer to an invite.
	CONSENT = OPX.Event(NET, 'ripperdoc', 'consent'),
	-- `(clinicKey)`: open a clinic's parts stash.
	STASH = OPX.Event(NET, 'ripperdoc', 'stash'),
	-- `(clinicKey, row)`: buy one catalogue row at a clinic's terminal.
	SUPPLY = OPX.Event(NET, 'ripperdoc', 'supply'),

	-- Server to client.
	-- `{ patient, clinic, humanity, capacity, installed, installs, removals }`.
	CHART_DATA = OPX.Event(NET, 'ripperdoc', 'chartData'),
	-- `{ id, clinic, action, chrome, tier, price, method, humanity, risk, ms }`.
	INVITE = OPX.Event(NET, 'ripperdoc', 'invite'),
	-- `(operationId)`: the invite is gone (withdrawn, expired, answered).
	UNINVITE = OPX.Event(NET, 'ripperdoc', 'uninvite'),
	-- `{ ok, code, ... }`: the answer to every request, and every outcome.
	ANSWER = OPX.Event(NET, 'ripperdoc', 'answer'),

	-- The public server bus: an operation ended. `(patient, { id, clinic,
	-- action, chrome, tier, outcome, applied, doc, native })`.
	ON_OPERATED = OPX.Event(LOCAL, 'ripperdoc', 'operated'),
}

--- The two character metadata keys this module owns.
M.HUMANITY_KEY = 'humanity'
M.CYBERWARE_KEY = 'cyberware'

--- The platform's appearance package; it binds the cyberware identity itself.
M.OFFICIAL_IDENTITY = 'open77_appearance'

--- The platform's completion event for an install, removal or lease.
M.NATIVE_COMPLETED = 'onCyberwareOperationCompleted'

--- The ACL entries.
M.Command = {
	CLINICS = 'opx.ripperdoc.clinics',
	HUMANITY = 'opx.ripperdoc.humanity',
}

--- The receipt phases, in order.
M.Phase = {
	RESERVED = 'reserved',
	SUBMITTED = 'submitted',
	COMMITTED = 'committed',
	CANCELLED = 'cancelled',
}
