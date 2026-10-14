--- NCPD and MaxTac: one law book, one heat ladder, two divisions.
-- @author XEROX710
--
-- THE WANTED LEVEL IS A CRIME SCORE THE ENGINE RAISES ITSELF. `PreventionSystem`
-- keeps `m_totalCrimeScore` and raises `m_heatStage` (`Heat_0 .. Heat_5`) when
-- the score reaches the current stage's capacity, zeroing it as it crosses. The
-- `wanted_level` quest fact is written FROM that stage and read only by a debug
-- overlay, so a feature that sets the fact moves the bar and nothing else. This
-- module therefore owns the SCORE -- what a crime is worth, who is charged, how
-- fast it drains -- and drives the engine's own ladder so the sirens, the radio,
-- the roadblocks, the wanted bar and the response units are the game's.
--
-- THE TWO DIVISIONS ARE THE ENGINE'S OWN SPLIT, not a taxonomy we invented:
-- `Heat_1 .. Heat_4` is the NCPD ladder (Cortes, Archer Hella, Emperor,
-- Merrimac, the Hellhound at `Heat_5`), and MaxTac is the separate division that
-- arrives at `Heat_5` in a Zetatech Surveyor with its own agent registry, its
-- own tag (`MaxTac_NotPrevention`), its own status effect and its own insertion
-- run. `config/ncpd.lua` names every record; nothing in this module spells one
-- as a literal.
--
-- TROOPERS ARE PLAYERS FIRST AND BOTS SECOND. A MaxTac summon fills the squad
-- from players who opted into the division and any seat still empty at the
-- response deadline is filled with the engine's own trooper records, so an empty
-- division never means an empty street. `FILL = 'bots'` in config is what makes
-- that the default, and `'players'` makes the job player-only on purpose.
--
-- THE LEVER IS A PLATFORM SEAM. `PreventionSystem`'s 287 methods are all
-- scripted, so nothing native can raise a stage: the client enqueues a command
-- string and its REDscript loop executes it inside the script frame it owns, on
-- the local player only. `open77-base` now carries the two this feature needs --
-- `prevention.heat:<0-5>` and `prevention.av`, each addressed to the player it
-- was asked for and refused when that player is not the client running it -- and
-- the client reads the effect back with `prevention.state`.
--
-- A CRIME COMMITTED IN THE WORLD ARRIVES AS THE CLIENT'S OWN READING. The engine
-- scores its own crimes and publishes nothing, so the client reads its own
-- `PreventionSystem` through `Open77.prevention.state()` and reports the stage it
-- holds; the server mirrors that into the ledger and stands the response up. The
-- law book is therefore the server's own instrument -- for jobs, for the operator
-- commands, for anything a script wants charged -- rather than the only way a
-- player becomes wanted.
--
-- `character` is optional here and not required: the ledger binds heat to a
-- loaded character, and without that contract it has nobody to charge, which is
-- a refusal with a line rather than a module that takes the whole resource down.
-- `vehicles`, `hud` and `prompts` are optional for the same reason: without them
-- the law book still loads and still scores, and only the surfaces are missing.

local M = OPX.Modules.Declare{
	id = 'ncpd',
	side = 'both',
	fatal = false,
	requires = {},
	optional = { 'character', 'vehicles', 'hud', 'prompts' },
}

--- The two divisions, spelled the way the config's `LADDER` spells them.
-- A stage's division is the config's answer, never a literal in code.
M.DIVISION = { NCPD = 'ncpd', MAXTAC = 'maxtac' }

-- The three prefixes are disjoint by construction (core/shared/channels.lua):
-- the host dispatcher matches on the name alone, so a local raise on a NET name
-- would re-enter the wire handler registered under it.
local NET = OPX.Channel.NET
local LOCAL = OPX.Channel.LOCAL

--- Every event name this module raises, built once so both halves agree.
M.Event = {
	-- Server to client. ONE payload carries the whole instruction: which stage
	-- the engine should be at, which division owns it, and whether this crossing
	-- is the one that calls MaxTac. A second event for the AV would be a second
	-- thing to lose.
	STAGE = OPX.Event(NET, 'ncpd', 'stage'),

	-- Server to client, to the on-duty holders of the call-out's jobs: the loud
	-- dispatch board. It carries the locale KEY and its arguments rather than a
	-- sentence, for the reason `RADIO_LINE` does -- the page holds no English
	-- and the catalogue is already there -- and NOTHING about the presentation:
	-- the stinger, the frame and the lifetime are read by each receiving client
	-- out of its own `ALERTS.DISPATCH` block, exactly as the world announcement
	-- reads its own. One moment, one wording, three surfaces.
	DISPATCH = OPX.Event(NET, 'ncpd', 'dispatch'),

	-- Server to client, to the on-duty holders of `ALERTS.ALARM.JOBS`: somebody
	-- went cyberpsycho -- a stage crossed into MaxTac's -- and the squad's
	-- screens go red. `{ stage, x, y, name, division }`; the sound and the
	-- lifetime are each client's own `ALERTS.ALARM`, as the board's are.
	ALARM = OPX.Event(NET, 'ncpd', 'alarm'),

	-- Client to server. The stage its own engine is holding -- the ONLY report of a
	-- real crime, because the engine charges its own score and never publishes it.
	-- The payload is one number and the server attributes it to the connection it
	-- arrived on, so a client cannot report a crime for anybody but itself.
	REPORT = OPX.Event(NET, 'ncpd', 'engine'),

	-- Client to server. The local player's own shot landed on an NPC: the host's
	-- `open77:npcHit`, which only the SHOOTER's client raises and which the
	-- platform does not carry to the server on its own. The payload names the
	-- body, the engine's damage and the height of the intercept and nothing the
	-- server has to believe -- it prices the hit itself and refuses a body that
	-- is not this module's (`server/hits.lua`).
	NPC_HIT = OPX.Event(NET, 'ncpd', 'npcHit'),

	-- Client to server. A body is at the crew door of the MaxTac aircraft and
	-- wants in. IT CARRIES NOTHING, deliberately: the server resolves the player
	-- from the connection it arrived on, the hull from its own runs, and the
	-- distance from its own position read -- so a modified client can ask and
	-- nothing else. It cannot name a seat, an aircraft, or a place.
	BOARD = OPX.Event(NET, 'ncpd', 'board'),

	-- Server to client, to the asker alone: what the aircraft controller
	-- answered, so a refusal is a sentence the player reads rather than a key
	-- that did nothing.
	BOARDED = OPX.Event(NET, 'ncpd', 'boarded'),

	-- Server to client, to the air division's on-duty holders: where the crew
	-- door is while it is open, and `nil` the moment it shuts.
	DOOR = OPX.Event(NET, 'ncpd', 'door'),

	-- Server to client, to one seated crew member alone: the exit lock is off.
	-- Said because the lock coming off is the one moment a body in a flying hull
	-- has something to do, and a seat that quietly stops being a seat reads as a
	-- bug rather than a landing.
	RELEASED = OPX.Event(NET, 'ncpd', 'released'),

	-- Client to server, the police scanner: open it or stow it. It carries one
	-- word, and the server answers with everything the panel draws -- who this
	-- player is to the city decides which bands exist for them, so the request is
	-- a knock and never a claim.
	RADIO = OPX.Event(NET, 'ncpd', 'radio'),

	-- Server to client, to the asker alone: the whole scanner frame (the bands,
	-- which of them this listener may hear, the effective key) or a refusal that
	-- names why there is no scanner for them.
	RADIO_STATE = OPX.Event(NET, 'ncpd', 'radioState'),

	-- Server to client, to the subscribers who may hear its band: one line of
	-- traffic. It carries the locale KEY and its arguments rather than a
	-- sentence, because the page holds no English and the catalogue is already
	-- there.
	RADIO_LINE = OPX.Event(NET, 'ncpd', 'radioLine'),

	-- The client's own bus: what the module decided, local refusals included, so
	-- a HUD or a job resource can hear a crossing without asking for it.
	ON_STAGE = OPX.Event(LOCAL, 'ncpd', 'stage'),
	ON_REFUSED = OPX.Event(LOCAL, 'ncpd', 'refused'),
	ON_BOARD = OPX.Event(LOCAL, 'ncpd', 'board'),

	-- The scanner's view seam: the state half publishes what the page draws and
	-- never touches the page -- `client/radioview.lua` is the only file here that
	-- knows the other end is a CEF surface (README: the view seam).
	RADIO_VIEW = OPX.Event(LOCAL, 'ncpd', 'radioView'),
}

--- Which request a refusal answers. Passed to `OPX.Refuse` so a client waiting
--- on one of several requests can tell which refusal is its own.
M.Operation = { REPORT = 'ncpdReport', HEAT = 'ncpdHeat', AV = 'ncpdAv', BOARD = 'ncpdBoard' }

--- Every refusal the crew door can name, as the sentence a player reads.
--
-- ONE TABLE, TWO READERS. The aircraft controller refuses with a CODE
-- (`server/av.lua`: `too_far`, `no_seat`, `departed` ...), because a code is what
-- a log and a test can match. A player reads a sentence. The map between them
-- lives here so the console door and the strip row say the same thing in the same
-- words rather than each inventing its own wording for "you are off duty".
--
-- Codes with no entry fall back to `ncpd.board.failed`, which names the code, so
-- a refusal this table has not heard of is still readable rather than blank.
M.BoardRefusal = {
	-- The division's half: who this player is to the city.
	noCitizen = 'ncpd.board.noCitizen',
	notOnDuty = 'ncpd.board.notOnDuty',
	notDivision = 'ncpd.board.notDivision',
	no_door = 'ncpd.board.noDoor',
	-- The aircraft's half: whether there is a door to walk through at all.
	no_position = 'ncpd.board.noPosition',
	no_aircraft = 'ncpd.board.noAircraft',
	not_boarding = 'ncpd.board.notBoarding',
	departed = 'ncpd.board.departed',
	crewed = 'ncpd.board.crewed',
	too_far = 'ncpd.board.tooFar',
	-- The seat itself.
	no_seat = 'ncpd.board.noSeat',
	seat_taken = 'ncpd.board.seatTaken',
	invalid_seat = 'ncpd.board.invalidSeat',
	seat_refused = 'ncpd.board.seatRefused',
	-- A key pressed into a menu: refused before it reaches the wire.
	captured = 'ncpd.board.menuOpen',
	-- The two shapes that are our fault and not the player's.
	invalid_player = 'ncpd.board.failed',
	vehicles_api_unavailable = 'ncpd.board.failed',
}

--- The command names, in one place, spelled the way the ACL checks them
--- (`command.<name>`).
M.Command = {
	STATUS = 'opx.ncpd.status',
	REPORT = 'opx.ncpd.report',
	HEAT = 'opx.ncpd.heat',
	AV = 'opx.ncpd.av',
	CLEAR = 'opx.ncpd.clear',
	LAWS = 'opx.ncpd.laws',
	-- The console door to the same seat the `KEY` offers. It exists because a
	-- player whose strip row was never drawn still has a way in, and because the
	-- door and the key share ONE implementation (`Av.Board`) -- two doors, one
	-- decision.
	BOARD = 'opx.ncpd.board',
	-- The operator's crowd of mortal civilians: the rig a kill is tested
	-- against. See `server/bots.lua` and `BOTS` in `config/ncpd.lua`.
	BOTS = 'opx.ncpd.bots',
}

--- The police scanner: its bands, its key, and every refusal it can read.
--
-- CHANNELS ARE VOCABULARY; AUDIENCE IS THE SERVER'S. The four bands exist for
-- everybody who may open a scanner -- one piece of hardware with two knobs --
-- but only the server decides who HEARS a band, and it says so per band in the
-- frame (`hear`), so a band this listener cannot hear is drawn as a dark band
-- rather than looking like a quiet one. `server/radio.lua` is the only reader of
-- the rule; nothing here says which job hears what.
--
-- EVERY BAND IS ALSO A VOICE CHANNEL. Talking is the platform's own VOIP
-- (`wiki/voice.md`): one Opus stream routed through up to four channels at
-- once, with a radio effect the host renders itself -- so the PTT keys a real
-- transmission and the volume knob turns a real gain, and no audio payload
-- ever passes through Lua. `server/radio.lua` owns the channels (it owns the
-- audience rule already) and carries each band's voice id in the frame;
-- `VOICE_EFFECT` is the band's declared sound.
--
-- FREQUENCIES ARE CONTENT (rule 8 of the UI contract): the micro-label on a
-- channel row states the band's own declared frequency -- something the surface
-- knows -- rather than invented chrome.
-- The client seam's home: `client/radioview.lua` fills this in with the
-- wiring between the state half and the CEF page. Created here -- beside
-- `M.Radio` -- so the seam file never has to index a table that does not
-- exist yet (the namespace is owned in one place).
M.RadioView = {}

M.Radio = {
	CHANNELS = {
		{ id = 'ncpd',     NAME = 'ncpd.radio.channel.ncpd',     FREQ = '154.980' },
		{ id = 'tactical', NAME = 'ncpd.radio.channel.tactical', FREQ = '155.475' },
		{ id = 'maxtac',   NAME = 'ncpd.radio.channel.maxtac',   FREQ = '39.720' },
		{ id = 'air',      NAME = 'ncpd.radio.channel.air',      FREQ = '45.880' },
	},

	-- The sound of one band on the air, as the HOST renders it -- the .87
	-- wiki's own radio tuning, passed as a `createChannel` effect. Nothing is
	-- heard through Lua ("PCM and Opus payloads are never exposed to Lua");
	-- this is the metadata the native mixer applies per voice route.
	VOICE_EFFECT = {
		gain = 1.0,
		highPassHz = 220.0,
		lowPassHz = 4800.0,
		distortion = 0.08,
		radioNoise = 0.04,
		spatialBlend = 0.0,
		reverbWet = 0.22,
		reverbRoomSize = 0.7,
		reverbDecay = 1.8,
		reverbDamping = 0.55,
		reverbPreDelayMs = 24.0,
	},

	-- The key, in the same shape as the crew door's: the id is stable because a
	-- player's rebind is stored under it, and `DEFAULT = false` would be a real
	-- declaration of "no default binding". THE SHIPPED DEFAULT, and nothing
	-- more -- `RADIO.KEY` in `config/ncpd.lua` is the operator's answer and
	-- wins whenever it is a usable block (see `M.Radio.KeySettings`).
	KEY = { ID = 'opx.ncpd.radio', NAME = 'ncpd.key.radio', DEFAULT = 'F2' },

	-- Lines the feed keeps for a scanner that stows and comes back. Bounded so
	-- the frame carrying them is one host payload -- the ceiling is 1024 value
	-- nodes and one line is about ten -- and capped again on the page. THE
	-- SHIPPED DEFAULT -- `RADIO.BACKLOG` in `config/ncpd.lua` wins whenever it
	-- is a usable number (see `M.Radio.Backlog`).
	BACKLOG = 30,

	-- ONE TABLE, TWO READERS, exactly as `M.BoardRefusal` is: the server refuses
	-- with a code, a player reads a sentence, and the map between them lives here
	-- so the toast and the panel say the same thing in the same words. A code
	-- this table has not heard of names itself rather than going blank.
	Refusal = {
		noCitizen = 'ncpd.radio.noCitizen',
		notOnDuty = 'ncpd.radio.notOnDuty',
		notDivision = 'ncpd.radio.notDivision',
		-- A key pressed into a menu: refused before it reaches the wire.
		captured = 'ncpd.radio.menuOpen',
		failed = 'ncpd.radio.failed',
	},
}

--- The scanner's key declaration: the one the operator configured, or the
--- shipped one.
--
-- Read on every ask rather than captured once, the same reason `M.Skill.Branches`
-- resolves on every read: config is live, and a block an operator fixed must
-- take effect without a code change. A `KEY` block that is not one -- no ID or
-- no NAME, or a DEFAULT that is neither a key name nor `false` -- falls back to
-- the declaration above rather than leaving the scanner unreachable.
-- @return table `{ ID, NAME, DEFAULT }`
function M.Radio.KeySettings()
	local declared = type(M.Settings) == 'table' and type(M.Settings.RADIO) == 'table'
		and M.Settings.RADIO.KEY or nil
	if declared ~= nil
		and type(declared.ID) == 'string' and declared.ID ~= ''
		and type(declared.NAME) == 'string' and declared.NAME ~= '' then
		local default = declared.DEFAULT
		if default == false or (type(default) == 'string' and default ~= '') then
			return { ID = declared.ID, NAME = declared.NAME, DEFAULT = default }
		end
	end
	return M.Radio.KEY
end

--- The bands the scanner draws, as the config declares them, or the shipped
--- four when the configured list is not one -- empty, or a row that is not a
--- band (a row must at least name its id, the one thing the wire and the
--- voice route are keyed by).
-- @return table array of `{ id, NAME, FREQ, ... }`, never empty
function M.Radio.Bands()
	local configured = type(M.Settings) == 'table' and type(M.Settings.RADIO) == 'table'
		and M.Settings.RADIO.CHANNELS or nil
	if type(configured) == 'table' and #configured > 0 then
		for i = 1, #configured do
			local band = configured[i]
			if type(band) ~= 'table' or type(band.id) ~= 'string' or band.id == '' then
				configured = nil
				break
			end
		end
		if configured ~= nil then return configured end
	end
	return M.Radio.CHANNELS
end

--- How many lines the feed keeps for a stowed scanner. A configured value
--- that is not a count (not a number, or negative) falls back to the shipped
--- one rather than emptying or flooding the ring.
-- @return integer at least 0
function M.Radio.Backlog()
	local configured = type(M.Settings) == 'table' and type(M.Settings.RADIO) == 'table'
		and M.Settings.RADIO.BACKLOG or nil
	local count = tonumber(configured)
	if count ~= nil and count >= 0 then return math.floor(count) end
	return M.Radio.BACKLOG
end
