--- Map blips: the pins that tell a player where anything in this city is.
-- @author dop42
--
-- WHY THIS FILE EXISTS, in the owner's own words, said across several sessions:
-- "ce serais cool de voir des blips sur la minimap", and then, after a session
-- spent looking for them, "sur la map je vois pas les blips". He tested the
-- FULLSCREEN map as well and confirmed the same thing there: nothing.
--
-- ============================================================================
-- WHAT WAS ACTUALLY WRONG, AND IT WAS NOT WHAT WE THOUGHT
-- ============================================================================
--
-- The standing hypothesis was `config/hud.lua`'s `VANILLA.minimap = false`:
-- this HUD hides the game's minimap, so -- the reasoning went -- it must be
-- hiding the pins with it, on both surfaces.
--
-- HALF OF THAT IS TRUE AND IT IS NOT THE HALF THAT MATTERED. Measured against
-- the platform's own component table (`open77_guide hud-visibility#components`,
-- build 2.31.13+op77.76), the `minimap` component controls, verbatim:
--
--     "Map panel, geometry, player marker, MAPPINS, GPS lines, frame and
--      location label"
--
-- So yes -- hiding `minimap` does hide mappins ON THE MINIMAP. But the
-- FULLSCREEN WORLD MAP IS NOT ONE OF THE THIRTEEN COMPONENTS `Open77.hud`
-- governs at all. There is no switch in that table that touches it, and hiding
-- the minimap cannot suppress it. The owner's own test -- open the big map,
-- still nothing -- is therefore evidence AGAINST the hypothesis rather than for
-- it, and it was the thing that pointed at the real cause.
--
-- THE REAL CAUSE IS THAT THIS RUNTIME HAD NEVER CREATED A BLIP. Not one. Before
-- this file, `grep -rn "blips" .` over the whole tree returned ZERO lines:
-- no `Open77.blips` call, no `ui.vanilla.map` in `open77.lua`, no module. There
-- was nothing to hide. The map was empty because it was empty.
--
-- That is worth writing down plainly, because "the HUD is eating them" is a
-- much more interesting explanation than "we never wrote it", and an afternoon
-- can be spent on the interesting one.
--
-- ============================================================================
-- THE MINIMAP: WHAT THE CHOICE ACTUALLY COSTS
-- ============================================================================
--
-- THERE IS ONE SWITCH AND IT IS NOT IN THIS FILE. It is `VANILLA.minimap` in
-- `config/hud.lua`, and it is deliberately left there rather than mirrored
-- here: two files claiming the same component is how a hide ends up fighting a
-- show, and this tree has a comment against that seam on nearly every module.
--
--   minimap = true   (the default this work set)
--     The player gets the game's minimap back, and the blips below appear on
--     the minimap AND on the fullscreen map. This is what the owner asked for,
--     in as many words. The cost is a vanilla panel in the corner of a screen
--     the rest of which is ours.
--
--   minimap = false  (what it was)
--     The corner stays clean. The blips below STILL WORK -- they are still on
--     the fullscreen map, because that surface is not governed by the component
--     -- but nothing shows on the minimap, because there is no minimap.
--
-- WHY THE DEFAULT WAS FLIPPED. The other twelve hides in `config/hud.lua` are
-- each paid for: this runtime draws its own health, its own stamina, its own
-- clock, its own notifications. `minimap` was the ONE entry in that list where
-- we hide the game's version and draw NOTHING in its place -- `grep -rin
-- "minimap|radar" ui/ web/` finds a single CSS comment and no component. So
-- the old default took the player's map away and handed back an empty corner,
-- which is a straight loss, and it is the whole of the owner's complaint.
--
-- If the clean screen is worth more than the map, set it back to `false` in
-- `config/hud.lua`; the blips stay on the fullscreen map either way, and the
-- blips module says which of the two is in force in its boot note, so the
-- answer is in the server journal rather than in somebody's memory.
--
-- ============================================================================
-- COLOUR AND ICONS: THE NATIVE SVG ADAPTER
-- ============================================================================
--
-- This section used to say there could be no colour here: `Open77.blips`
-- refused `color` by name (`unsupported_option:color`), because a vanilla
-- mappin carries no colour field and its look lives on a UI profile every pin
-- of the same sprite shares. That was true of the platform this was written
-- against and is no longer the whole story.
--
-- THE NATIVE SVG ADAPTER (an OPEN//77 client piece, experimental) draws a
-- declared SVG in place of the sprite's graphic as native Ink geometry, and
-- takes a per-blip `#RRGGBB` / `#RRGGBBAA` -- for THIS pin only, nobody else's.
-- The mappin underneath is still the vanilla one: selection, tooltips, tracking
-- and the visibility the SPRITE's profile gives all stay. So every category
-- below carries both: SPRITE for where it shows and for the clients without
-- the adapter, ICON + COLOR for what it looks like on the ones with it.
--
-- WHICH CLIENT HAS IT is asked, not assumed: the module sends an icon only
-- where `Open77.blips.setColor` exists (the platform's own test for the
-- adapter), and a create refused for the icon is made again with the sprite
-- alone and noted once. `COLOUR` (British), `ALPHA`, `OPACITY` and `SCALE` are
-- still not fields and are still refused at boot, each pointing at the one
-- that does the job: COLOR, or SIZE.
--
-- A HEADQUARTERS STATION names its OWN sprite, icon and colour per station, in
-- `config/headquarters.lua`'s `BLIP` block, on the same fields.
--
-- ============================================================================
-- SPRITES, AND WHICH ONES ARE ACTUALLY ON THE BIG MAP
-- ============================================================================
--
-- `SPRITE` takes a stable alias, an exact 2.31 variant name, or an integer
-- 0..146. The aliases, from the platform guide, are:
--
--   default   objective  quest     important  question   fast_travel
--   vehicle   loot       danger    vendor     apartment  stash      wardrobe
--   bar       clothes    cyberware drop_point food       guns       junk
--   meds      ripperdoc  tech      race       ncart      fixer      tarot
--   ping_door ping_go_here  ping_loot  remote_player
--
-- A WARNING THE GUIDE GIVES AND THIS FILE REPEATS, because it is exactly the
-- failure the owner already reported once: "HUD-only variants can still be
-- ABSENT FROM THE FULLSCREEN MAP; use a map-capable sprite such as `objective`,
-- `quest`, `fast_travel`, `vehicle`, or a service-point variant when map
-- selection is required." Every default below is from that safe set or is a
-- `ServicePoint*` variant. Change one to a `ping_*` or `remote_player` and the
-- pin may live on the HUD only -- which would read, again, as "je vois pas les
-- blips".
--
-- ============================================================================
-- WHERE THE POSITIONS COME FROM -- AND WHY THIS FILE HOLDS NONE
-- ============================================================================
--
-- NOT ONE COORDINATE IS WRITTEN HERE, ON PURPOSE. Every category below names a
-- source that already owns its positions, and a coordinate copied into this
-- file would be a second opinion that drifts the first time somebody moves a
-- garage. `lib/shared/spots.lua` makes that argument at length for the five
-- modules that place things; this is the same argument one level up.
--
--   garages, dealership  config (`GARAGES` in `config/garages.lua`, `SPOTS` in
--                        `config/dealership.lua`) plus any legacy database row
--                        the server adopts at boot. The client is told its own
--                        bucket's list over the module's SYNC event, so the
--                        blips are read from the garages and dealership
--                        clients' own `Runtime.Spots()`. A garage location
--                        is ONE pin, at its menu point: its entry door is a
--                        second point a few metres away and is not pinned.
--   teleports            config, but STILL served over the wire, because the
--                        server marks each entrance allowed or refused for this
--                        player. Read from `Runtime.Entrances()`.
--   shops                static `OPX.Config.MODULES.shops.SHOPS`, a
--                        `shared_script`, read directly -- no event carries it.
--   jobs                 static, and TWO sources: every gunsmith armoury's
--                        BENCH, and every hauling site -- one pin for the yard
--                        (its BLIP, else its first surveyed POINT) and one per
--                        DROPOFF.
--   headquarters         DATABASE positions, CONFIG look. The list is the
--                        headquarters client's own `Runtime.Spots()` (captured
--                        stations live in `opx77_headquarters` and the server
--                        filters to the asker's bucket); the pin look is per
--                        station, the `BLIP` block of the station's row in
--                        `config/headquarters.lua`. A station with no `BLIP`
--                        block is deliberately not pinned -- the pin is the
--                        station's own choice, not this module's opinion.
--
-- A POINT WHOSE X, Y AND Z ARE ALL EXACTLY ZERO IS SKIPPED AND COUNTED. Most of
-- `config/gunsmith.lua` and all of `config/hauling.lua` ship as unsurveyed
-- placeholders and say so in their own headers; `config/elevators.lua` is the
-- cautionary tale both of them cite. A pin at the world origin is a pin in the
-- sea, and four of them would read as this feature being broken rather than as
-- the config being unfilled.

OPX.Config.MODULES.blips = {
	enabled = true,

	-- Milliseconds between two reconciliations of the drawn set against the
	-- sources. This is NOT a per-frame scan: nothing here moves, and the only
	-- reason to look again is that a spot was captured, a bucket changed, or a
	-- job gate opened. Four seconds is slower than the 500 ms the marker scans
	-- use because a marker is a thing you walk into and a blip is a thing you
	-- read on a map you opened.
	SCAN_MS = 4000,

	-- Blips created before the thread yields. THE REASON THIS NUMBER EXISTS is
	-- `modules/admin/client/target.lua`'s `register()` and the four outages in
	-- its comment: a client resume has an INSTRUCTION BUDGET, and a loop that
	-- creates several dozen engine handles in one pass runs out of it partway
	-- down, at which point THE COROUTINE UNWINDS WITH NO ERROR, NO LOG AND NO
	-- REFUSAL. Half the blips would be up, the rest would never exist, and
	-- nothing anywhere would say so.
	--
	-- Blips are exactly that shape: dozens of engine calls, all at start. So the
	-- reconcile yields every BATCH creations, on a thread of its own.
	BATCH = 8,

	-- The most blips this module will create. THE PLATFORM'S OWN QUOTA IS 128
	-- PER RESOURCE and 512 per client; this is that number and not a taste. A
	-- server that captures its 140th garage gets a boot note naming the count
	-- and the cap instead of a silent refusal on the 129th create.
	MAX = 128,

	-- Each category: whether it is drawn, which vanilla sprite it wears, the
	-- words that name it, how far away it stays visible -- and, since the native
	-- SVG adapter, a real icon and its colour.
	--
	-- ICON is the name of an .svg in `web/blips/` ('garage' or 'garage.svg'; the
	-- manifest declares the folder with `files`). SIZE is 16..128 native Ink
	-- units (48 by default). COLOR is '#RRGGBB' or '#RRGGBBAA' and recolours the
	-- whole icon; false keeps the SVG's own colours. The shipped icons are Lucide
	-- line icons (`web/blips/LICENSE-LUCIDE.txt`), drawn white and tinted here.
	--
	-- THE SPRITE STAYS, AND STILL MATTERS. It decides where the pin is visible
	-- (an icon does not lift a HUD-only profile onto the world map) and it is what
	-- a client without the SVG adapter draws, so keep a map-capable one. An icon
	-- the client refuses -- too complex, undeclared -- is logged once and the pin
	-- falls back to the sprite; it is never lost. To add an icon: drop the .svg in
	-- `ui/public/blips/` (the build copies it to `web/blips/`), keep every stroke
	-- inside its viewBox, no text, gradients, masks or filters. Prefer butt caps
	-- and bevel joins: round ones are cut into many small polygons, and with a
	-- few dozen pins that ran the client out of its blip visual budget
	-- (`blip_visual_budget_exceeded`, seen on the garages and the dealership).
	--
	-- RANGE is metres, 0..4000, and 0 MEANS NO GATE -- always visible. It is
	-- Open77's own doing rather than an engine field: it measures the distance
	-- on the game thread and drives `SetMappinActive` on a transition. It is
	-- NOT FiveM's `SetBlipAsShortRange`: Cyberpunk has no per-surface control,
	-- so out of range means off on the HUD, the minimap AND the world map, not
	-- "off the minimap, still on the big map". A value outside 0..4000 is
	-- refused by the engine with `invalid_range` and is refused here at boot.
	--
	-- WALLS is `visibleThroughWalls`. Left false everywhere: these are map pins,
	-- and a garage glowing through the building in front of you is a HUD effect
	-- nobody asked for.
	CATEGORIES = {
		-- THE STATIONS. Only a headquarters whose own row in
		-- `config/headquarters.lua` declares a `BLIP` block is pinned, and each
		-- of them may wear its own SPRITE, ICON and COLOR from that block. This
		-- block is the DEFAULTS and the one switch: `SHOW = false` takes every
		-- headquarters pin off the map at once.
		headquarters = {
			SHOW = true,
			SPRITE = 'objective',
			LABEL = 'Headquarters',
			RANGE = 0,
			WALLS = false,
			ICON = 'headquarters',
			SIZE = 48,
			COLOR = '#4DA3FF',
		},

		-- Where a player's own cars come out. The one the owner names first.
		garages = {
			SHOW = true,
			SPRITE = 'vehicle',
			LABEL = 'Garage',
			RANGE = 0,
			WALLS = false,
			ICON = 'garage',
			SIZE = 48,
			COLOR = '#5EF6FF',
		},

		-- Where cars are bought. `objective` rather than `vehicle` so a dealer is
		-- not mistaken for a garage at a glance -- the two are frequently a metre
		-- apart, which `config/dealership.lua`'s own sample spots demonstrate.
		dealership = {
			SHOW = true,
			SPRITE = 'objective',
			LABEL = 'Vehicle Dealer',
			RANGE = 0,
			WALLS = false,
			ICON = 'dealer',
			SIZE = 48,
			COLOR = '#FFD400',
		},

		-- Clothing shops. `clothes` is the `ServicePoint*` variant for exactly
		-- this and is map-capable.
		--
		-- THE ONE CATEGORY WITH A RANGE BY DEFAULT, because it is the one with
		-- the most instances and the least reason to be seen from across the
		-- city: you look for a shop when you are in a district, not from Pacifica.
		-- 400 m is wide enough to cover a district. Set it to 0 to have them all,
		-- always.
		shops = {
			SHOW = true,
			SPRITE = 'clothes',
			LABEL = 'Clothing Shop',
			RANGE = 400,
			WALLS = false,
			ICON = 'clothes',
			SIZE = 48,
			COLOR = '#FF6AD5',
		},

		-- The shortcuts to places you cannot walk to. `fast_travel` is the
		-- vanilla vocabulary for "you get somewhere from here" and costs no
		-- explanation to a player who has played the single-player game.
		--
		-- BOTH ENDS OF A TWO-WAY GET A PIN, because both ends are places a player
		-- stands to use it. A LOCKED teleport is still pinned: the module draws a
		-- red ring at one and a green ring at the other, and a map that hid the
		-- locked ones would be a map that hides the job content.
		teleports = {
			SHOW = true,
			SPRITE = 'fast_travel',
			LABEL = 'Shortcut',
			RANGE = 0,
			WALLS = false,
			ICON = 'shortcut',
			SIZE = 48,
			COLOR = '#B38CFF',
		},

		-- Job sites: every gunsmith BENCH, every hauling yard and every hauling
		-- DROPOFF. One category and not three, because a player looking at a map is
		-- asking "where is there work", not "which module owns this".
		jobs = {
			SHOW = true,
			SPRITE = 'guns',
			LABEL = 'Job Site',
			RANGE = 0,
			WALLS = false,
			ICON = 'job',
			SIZE = 48,
			COLOR = '#FF9F1C',
		},

		-- Bank branches (`/opx.bank.add`), where a paycheck is drawn as cash.
		-- The base game has no bank sprite: `drop_point` is the
		-- `ServicePointDropPointVariant`, its service point for handing things
		-- over and map-capable, and it is what a client without the SVG adapter
		-- draws; the others draw the bank icon.
		bank = {
			SHOW = true,
			SPRITE = 'drop_point',
			LABEL = 'Bank',
			RANGE = 0,
			WALLS = false,
			ICON = 'bank',
			SIZE = 48,
			COLOR = '#7CFFB2',
		},

		-- Gas stations (`modules/fuel`), one pin per surveyed station: ox's
		-- `showBlips = 2`. ox's `1`, the nearest only, is a RANGE here -- 800 m
		-- shows the stations of the district you are driving through. 2.31 has NO
		-- fuel sprite at all (the list is in the devkit, `blips#complete-sprite-
		-- list-cyberpunk-2077-231`); `drop_point` is a map-capable service-point
		-- variant (the bank branches above wear it too, with their own label), so a
		-- station reads as a service point. Check it on the big map before changing it to a `ping_*`.
		fuel = {
			SHOW = true,
			SPRITE = 'drop_point',
			LABEL = 'Gas Station',
			RANGE = 0,
			WALLS = false,
			ICON = 'fuel',
			SIZE = 48,
			COLOR = '#FFE14D',
		},
	},
}
