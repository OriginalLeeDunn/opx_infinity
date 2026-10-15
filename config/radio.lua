--- Radio: the service channels a crew talks on, and the handset it needs.
-- @author dop42
--
-- A CHANNEL IS A CONFIG ENTRY, and the voice channel behind it is the
-- platform's (`Open77.voice.createChannel`, mode `radio`, with the band-pass
-- and the hiss below). Who may be on it is a JOBS block and/or a GANGS block,
-- read by `OPX.JobGate.EvaluateGroups` exactly like a door or a lab: either list
-- lets in, `ON_DUTY` applies to the jobs only (a gang has no shift).
--
-- AUTO channels are joined by themselves the moment the character qualifies --
-- clocking in, being hired -- and every channel is left the moment they stop
-- qualifying: clocking out, a job change, a firing, the handset leaving the bag.
-- A channel that is not AUTO is offered on the handset (`/opx.radio`, or
-- using the item) and joined only on request.
--
-- PUSH-TO-TALK is a key of its own (TALK_KEY, CAPSLOCK by default, rebindable in
-- Pause -> Settings -> KEY BINDINGS). The platform's own voice key (N) keeps
-- talking to the people around you only: a radio member is a LISTENER until the
-- radio key is held, and the server grants the right to speak on the selected
-- channel for exactly as long as it is held. See modules/radio/module.lua.
--
-- Job and gang names are config/character.lua's. A name it does not know is
-- named at boot and the channel simply never lets anybody in.

OPX.Config.MODULES.radio = {
	enabled = true,

	-- ── the handset ────────────────────────────────────────────────────────

	-- Whether the radio item must be in the bag to be on any channel. Off, every
	-- qualifying character has a radio built in (cyberware comms, in the lore).
	REQUIRE_ITEM = true,
	-- Registered at boot through the inventory contract (not in items.lua).
	-- Using it from the bag takes the handset out (the hologram on screen).
	ITEM = {
		NAME = 'radio',
		LABEL = 'Service radio',
		DESCRIPTION = 'Encrypted handheld. Tuned to whatever your badge allows.',
		WEIGHT = 350,
		MODEL = 'electronics.monitor.device',
	},

	-- Where the handset hologram pops: one of the nine names in
	-- `lib/shared/anchors.lua` ('right', 'left', 'bottom-right'...).
	ANCHOR = 'right',

	-- ── talking ────────────────────────────────────────────────────────────

	-- The hold-to-talk mapping. `false` registers no key (the channels are then
	-- listen-only for everybody).
	TALK_KEY = { ID = 'opx.radio.talk', NAME = 'radio.key.talk', DEFAULT = 'CAPSLOCK' },
	-- The route a transmission takes while the key is held: `all` is the radio
	-- AND the people standing next to you (a radio in a shared world), `channels`
	-- is the radio alone.
	TALK_INTENT = 'all',
	-- A key held longer than this is let go by the server (a stuck key, a client
	-- that never sent the release). Milliseconds.
	MAX_TALK_MS = 60000,
	-- A downed character cannot key the radio.
	BLOCK_WHEN_DOWN = true,

	-- ── limits and clocks ──────────────────────────────────────────────────

	-- How many channels one character may be on at once. The platform routes a
	-- frame into at most four channels; only the selected one is ever speakable,
	-- so this bounds what a player HEARS.
	MAX_JOINED = 4,
	-- Requests from one player's handset, milliseconds apart at least.
	REQUEST_MS = 300,
	-- Key presses, milliseconds apart at least (a release is never refused).
	TALK_MS = 200,
	-- The safety sweep: every loaded character is re-checked this often, for a
	-- change no event announced. Milliseconds.
	SWEEP_MS = 15000,

	-- What the platform does to a radio voice. Ranges: docs voice#server-lua-api.
	EFFECT = {
		highPassHz = 300.0,
		lowPassHz = 3400.0,
		distortion = 0.12,
		radioNoise = 0.05,
		spatialBlend = 0.0,
	},

	-- ── the channels ───────────────────────────────────────────────────────
	--
	-- key = { LABEL, SHORT?, JOBS?, GANGS?, ON_DUTY?, AUTO?, ENABLED?, ORDER? }
	--   LABEL    what the handset shows (the operator's words, never translated)
	--   SHORT    the tag on the toast when you key up, defaults to the key
	--   JOBS     { job = minimum grade }      ON_DUTY applies to these
	--   GANGS    { gang = minimum grade }
	--   AUTO     joined by itself when the character qualifies
	--   ENABLED  false keeps the entry and opens nothing
	--   ORDER    dial order, lowest first (then the key)
	CHANNELS = {
		ncpd = {
			LABEL = 'NCPD Dispatch - Watson Precinct', SHORT = 'NCPD', ORDER = 10,
			JOBS = { ncpd = 0 }, ON_DUTY = true, AUTO = true,
		},
		maxtac = {
			LABEL = 'MaxTac Tactical Net', SHORT = 'MAXTAC', ORDER = 20,
			JOBS = { maxtac = 0 }, ON_DUTY = true, AUTO = true,
		},
		trauma = {
			LABEL = 'Trauma Team Ops - Night City', SHORT = 'TRAUMA', ORDER = 30,
			JOBS = { trauma = 0 }, ON_DUTY = true, AUTO = true,
		},
		-- The shared emergency band: the three services hear each other here.
		interagency = {
			LABEL = 'Interagency - NCPD / MaxTac / Trauma', SHORT = 'INTER', ORDER = 40,
			JOBS = { ncpd = 0, maxtac = 0, trauma = 0 }, ON_DUTY = true, AUTO = true,
		},
		ripperdoc = {
			LABEL = 'Ripperdoc Clinic Net - Kabuki', SHORT = 'DOC', ORDER = 50,
			JOBS = { ripperdoc = 0 }, ON_DUTY = true, AUTO = true,
		},
		-- Delamain's drivers are the `cabbie` job (on duty by definition).
		delamain = {
			LABEL = 'Delamain Dispatch', SHORT = 'DELAMAIN', ORDER = 60,
			JOBS = { cabbie = 0 }, ON_DUTY = true, AUTO = true,
		},
		arasaka = {
			LABEL = 'Arasaka Security - Corpo Plaza', SHORT = 'ARASAKA', ORDER = 70,
			JOBS = { arasaka = 0 }, ON_DUTY = true, AUTO = true,
		},
		militech = {
			LABEL = 'Militech Field Command', SHORT = 'MILITECH', ORDER = 80,
			JOBS = { militech = 0 }, ON_DUTY = true, AUTO = true,
		},
		-- Command only: Detective (grade 2) and up, joined on request.
		ncpd_command = {
			LABEL = 'NCPD Command', SHORT = 'NCPD-CMD', ORDER = 15,
			JOBS = { ncpd = 2 }, ON_DUTY = true, AUTO = false,
		},

		-- Gang frequencies: off out of the box. Set ENABLED = true to open one.
		maelstrom = {
			LABEL = 'Maelstrom - Totentanz', SHORT = 'MAELSTROM', ORDER = 100,
			GANGS = { maelstrom = 0 }, AUTO = false, ENABLED = false,
		},
		valentinos = {
			LABEL = 'Valentinos - Heywood', SHORT = 'VALENTINOS', ORDER = 110,
			GANGS = { valentinos = 0 }, AUTO = false, ENABLED = false,
		},
		tygerclaws = {
			LABEL = 'Tyger Claws - Japantown', SHORT = 'TYGERS', ORDER = 120,
			GANGS = { tygerclaws = 0 }, AUTO = false, ENABLED = false,
		},
		sixthstreet = {
			LABEL = '6th Street - Santo Domingo', SHORT = '6TH', ORDER = 130,
			GANGS = { sixthstreet = 0 }, AUTO = false, ENABLED = false,
		},
		aldecaldos = {
			LABEL = 'Aldecaldos - Badlands', SHORT = 'ALDECALDOS', ORDER = 140,
			GANGS = { aldecaldos = 0 }, AUTO = false, ENABLED = false,
		},
	},
}
