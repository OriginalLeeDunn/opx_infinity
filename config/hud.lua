--- Where each HUD block sits, what the gauges read, and the tone thresholds.
-- @author dop42
--
-- The page decides no colour and formats no number: `TONE_WARN` and `TONE_BAD`
-- below are the whole of the gauge palette's logic, and the money separator is
-- the whole of its formatting. Both live here because both are operator
-- decisions, and a page that made either would be a second opinion.
--
-- Every anchor is a closed set on the page, which falls back to its own default
-- for a name it does not know: a typo here is a block in the wrong corner, never
-- a broken layout.

OPX.Config.MODULES.hud = {
	enabled = true,

	-- bottom-left, bottom-right, top-left, top-right, top-center, bottom-center.
	ANCHOR = 'bottom-left',
	-- THE MONEY AND THE CLOCK, AND THEY MOVED BECAUSE THE MINIMAP CAME BACK.
	-- "l'hud des eddis etc passe la a gauche ... car la minimap native du jeu
	-- est a droite". `minimap` was `false` here until the blips work, which put
	-- the game's own map panel back in the top-right corner -- straight under
	-- this block. Left is the free corner now.
	INFO_ANCHOR = 'top-left',
	-- Absent, the strip rides in the gauge column's corner.
	STATUS_ANCHOR = 'bottom-left',
	-- Pixels from the anchored edge's inset to the foot of the chip strip, which
	-- sits on top of the gauge column. 144 = the column at its tallest -- five
	-- gauges and the microphone row, six 16 px rows with 8 px between them, 136
	-- px -- plus the same 8 px of clearance. It was 120 for five rows; the voice
	-- indicator became the column's sixth row when the game's round minimap took
	-- the bottom-right corner it used to hold, and at 120 the chips sat on the
	-- health gauge.
	STATUS_OFFSET = 144,
	VEHICLE_ANCHOR = 'bottom-center',

	-- Gauge column width in pixels on the 1920-wide surface, and how many
	-- segments a gauge and the voice meter are cut into.
	WIDTH = 210,
	SEGMENTS = 10,
	VOICE_SEGMENTS = 8,

	-- Milliseconds between two samples. The vitals stream is the surface's own
	-- 30 fps; the voice and vehicle read-outs move far slower than they are
	-- looked at. Neither sends a frame that changed nothing.
	VITALS_MS = 33,
	WIDGET_MS = 100,

	-- Percent at or under which a gauge takes the warning and the danger tone.
	TONE_WARN = 33,
	TONE_BAD = 15,

	-- The gauges, in drawing order.
	--   SOURCE      health, armor, stamina, or any need name
	--   LABEL       a catalogue key; the page resolves it
	--   ICON        health, armor, stamina, hunger or thirst; anything else
	--               draws no glyph
	--   TONE        the tone above TONE_WARN; omit for the quiet one
	--   ALERT       false leaves the gauge untoned at every value
	--   HIDE_AT_ZERO / HIDE_ABOVE   when the row is not worth the space
	GAUGES = {
		{ ID = 'health', SOURCE = 'health', ICON = 'health',
			LABEL = 'hud.gauge.health', TONE = 'health' },
		-- Untoned on purpose: a low armour is not the alert a low health is.
		{ ID = 'armor', SOURCE = 'armor', ICON = 'armor',
			LABEL = 'hud.gauge.armor', ALERT = false, HIDE_AT_ZERO = true },
		{ ID = 'stamina', SOURCE = 'stamina', ICON = 'stamina',
			LABEL = 'hud.gauge.stamina', HIDE_ABOVE = 99 },
		{ ID = 'hunger', SOURCE = 'hunger', ICON = 'hunger',
			LABEL = 'hud.gauge.hunger' },
		{ ID = 'thirst', SOURCE = 'thirst', ICON = 'thirst',
			LABEL = 'hud.gauge.thirst' },
	},

	-- Money lines, in order. A type held and not listed here is appended after
	-- them, sorted, so a new purse shows up without a config change.
	MONEY = { 'EDDIES', 'BANK' },
	MONEY_SEPARATOR = ' ',

	-- The eyebrow over the read-out, and the two identity lines.
	INFO_EYEBROW = 'hud.info.eyebrow',
	SHOW_JOB = true,
	SHOW_CRED = true,

	-- The microphone block. `OPEN_VOICE` and `DRIVER` are platform resources,
	-- read through their exports and never a dependency: without them the block
	-- still draws what the engine's own voice status says.
	VOICE = {
		OPEN_VOICE = 'open-voice',
		DRIVER = 'open77_voice',
		HIDE_OPEN_VOICE = true,
	},

	-- The speed dial. PASSENGER false draws it for the driver only. FUEL false
	-- leaves the tank off it; it is drawn only for a vehicle whose tank has been
	-- filled (`modules/fuel`), toned at TONE_WARN and TONE_BAD like integrity.
	VEHICLE = {
		PASSENGER = true,
		FUEL = true,
	},

	-- Components of the game's own HUD, which this one replaces. `false` hides
	-- one; `true` leaves it to the game. The platform drops every hide request of
	-- a resource when it stops, so nothing is put back by hand, and a hide is a
	-- CLAIM rather than an override -- releasing ours does not reveal a component
	-- another resource is still hiding.
	--
	-- ALL THIRTEEN ARE LISTED, and that is the change. Seven were named and six
	-- were simply absent, which reads as "we decided to show them" and meant "we
	-- did not think about them". Every one now carries a value and a reason, so
	-- the next person is disagreeing with a decision rather than filling a gap.
	--
	-- `Open77.hud.components()` is the authority on the set; the client half
	-- reads it and applies only the names this build knows, so a name added or
	-- renamed upstream costs nothing here.
	VANILLA = {
		-- ====================================================================
		-- THE MINIMAP, AND THE ONE ENTRY IN THIS LIST THAT WAS NOT PAID FOR
		-- ====================================================================
		--
		-- `true` since the blips work, and it is a REVERSAL. It was `false`, under
		-- the heading "replaced outright by this HUD", alongside health, stamina,
		-- the clock and the rest.
		--
		-- IT WAS NOT REPLACED. Every other hide in this block is paid for by
		-- something this runtime draws instead: `core/client/notify.lua` for the
		-- notifications, our own gauges for health and stamina, our own clock. The
		-- minimap was the one entry where we hid the game's version and drew
		-- NOTHING. `grep -rin "minimap|radar" ui/ web/` finds a single CSS comment
		-- in `MenuView.vue` positioning something "below the minimap" and no
		-- component anywhere. So the player lost their map and got an empty corner.
		--
		-- THAT IS THE OWNER'S COMPLAINT, VERBATIM AND REPEATED: "ce serais cool de
		-- voir des blips sur la minimap". There were no blips at all until
		-- `modules/blips` -- that, and not this flag, is what the map was missing,
		-- and `config/blips.lua` carries the measurement. But this flag decides
		-- WHERE they land, because the platform's component table
		-- (`open77_guide hud-visibility#components`) gives `minimap` as: "Map
		-- panel, geometry, player marker, MAPPINS, GPS lines, frame and location
		-- label". Hiding it hides the pins ON THE MINIMAP.
		--
		-- THE FULLSCREEN MAP IS NOT AFFECTED EITHER WAY. It is not one of the
		-- thirteen components `Open77.hud` governs; there is no switch here that
		-- reaches it. So:
		--
		--   true   pins on the minimap AND the fullscreen map. A vanilla panel in
		--          the corner of a screen the rest of which is ours.
		--   false  pins on the fullscreen map only. A clean corner, and a player
		--          who has to open the big map to navigate.
		--
		-- Set it back to `false` if the clean screen is worth more than the map.
		-- Nothing breaks: `modules/blips` reads this component's effective state
		-- at boot and says which of the two is in force in its `OPX.Note`, so the
		-- answer is in the server journal rather than in somebody's memory.
		minimap = true,

		-- Replaced outright by this HUD.
		compass = false,
		clock = false,
		health = false,
		stamina = false,
		weapon = false,
		speedometer = false,

		-- THE BASE GAME'S MISSIONS ARE PLAYABLE HERE NOW (opx_sandy_view 1.4.11,
		-- `OpxQuests.reds`), so this is on. It was `false` under "there are no
		-- quests" -- and with the missions open, a player who started a side job
		-- by talking to an NPC saw no objective, no countdown and no "wait for the
		-- call", which read as the job being stuck (reported 2026-09-28). The
		-- platform hides the tracker on its own; the preload shows it again only
		-- while this says `true`, so `false` still hides it.
		questTracker = true,

		-- ON FOR THE MISSIONS. `core/client/notify.lua` and the overlay still draw
		-- every message this runtime sends; the base game's own stack is where a
		-- mission says "new quest", "objective updated", "quest completed" and
		-- "item received", which nothing here replaces. `false` hides that stack
		-- again (and a mission's toasts with it).
		vanillaNotifications = true,

		-- THE VANILLA INVENTORY AND CHARACTER SCREENS. This runtime has its own
		-- for both, and two inventories over one body is the double-surface
		-- problem every other seam in this tree is shaped to avoid: the vanilla
		-- one shows the engine's equipment, ours shows the bag, and they disagree.
		hubMenu = false,

		-- THE OWNER'S WORD ON MAIN, 2026-09-24, was to hide these three too ("regarde
		-- si ont hide bien tous ... sauf la minimap"), and main ships them `false`.
		-- THIS BRANCH KEEPS THEM ON because its missions need them -- an owner's
		-- call, not settled by the merge. `false` is main's choice.
		--
		-- `crosshair` is how a player aims. Hiding it is not a style choice, it
		-- is taking away the weapon's usability.
		crosshair = true,
		-- `scanner` is real gameplay and we replace nothing it does. The platform
		-- refuses the scanner in a session; the preload (`OpxQuests.reds`) gives it
		-- back while this says `true` -- missions scan clues and braindances.
		scanner = true,
		-- `phone` is the base game's phone: a mission's holocalls, its texts and
		-- "call X" steps. The platform hides it; the preload shows it again while
		-- this says `true`. `false` keeps it hidden (calls still connect).
		phone = true,

		-- ANY COMPONENT NOT NAMED HERE IS HIDDEN. `modules/hud` walks the build's
		-- own `Open77.hud.components()`, so one the platform adds later is covered
		-- without an edit here. Name it `true` to leave it to the game.
	},
}
