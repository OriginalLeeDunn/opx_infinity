--- The law book: what is a crime, what it costs, and which division answers.
-- @author XEROX710
--
-- THE WANTED LEVEL IS A CRIME SCORE, NOT A FACT WE WRITE. The engine keeps
-- `m_totalCrimeScore` and raises `m_heatStage` (`EPreventionHeatStage.Heat_0 ..
-- Heat_5`) when the score reaches that stage's capacity, zeroing the score as it
-- crosses (`preventionSystem.script:2501`). The `wanted_level` quest fact is an
-- OUTPUT of that stage -- `TryUpdateWantedLevelFact` writes it `:2281`, and the
-- only reader in the whole script tree is a debug overlay `:4916` -- so setting
-- it moves nothing. This file therefore describes the SCORE, and the module
-- drives the engine's own ladder so the wanted bar, the siren stake, the police
-- radio and the spawn reinitialisation all happen inside the game's own path.
--
-- WHAT IS OURS AND WHAT IS THE ENGINE'S. Ours: which acts count, what they cost,
-- how fast the score falls, who may answer, and -- since the engine's own route
-- was measured to refuse it -- the MaxTac AV's insertion run. The engine's: the
-- six stages, the response each one already has wired to it, and every vehicle
-- and character record below.
--
-- THE AV IS SUMMONED THROUGH THE ENGINE AND, WHEN THAT IS REFUSED, FLOWN BY US.
-- `gamePreventionSpawnSystem.RequestAVSpawn` is the engine's own route and the
-- bridge asks for it (`prevention.av`). On the live node it answers
-- `prevention.av.ticket.0` -- the call lands, no aircraft is scheduled, nothing
-- renders for anybody -- so `MAXTAC.AV.INSERTION` below is the run the server
-- flies instead, on an Open77 vehicle every client can see. The airframe's
-- authored visuals (jet flames, thrusters, the model's own lights) come with
-- the record; the red warning lines are a property of the entity template and
-- its AI package (`av_spawn_setup`, `summonDistanceMin/Max`, `verticalOffset`)
-- and an unoccupied server-flown AV cannot command them, so what this feature
-- does about them is keep the aircraft's lights on and point its nose at the
-- player it came for.
--
-- THE TWO DIVISIONS ARE THE ENGINE'S OWN SPLIT. `Heat_1 .. Heat_4` is the NCPD
-- ladder -- Cortes, Archer Hella, Emperor, Merrimac, and the Hellhound at
-- `Heat_5` -- and MaxTac is the separate division that arrives at `Heat_5` with
-- its own agent registry, its own tag (`MaxTac_NotPrevention`), its own status
-- effect (`BaseStatusEffect.MaxTacAlone`) and its own insertion vehicle. Both
-- are declared here so a server can run the police without MaxTac, or MaxTac
-- alone on a job, without editing any Lua.
--
-- A LAW IS { id, label, score, ceiling }. `ceiling` is the stage at or above
-- which that offence stops counting: a fist fight stops mattering once the city
-- is already hunting you, and murder-past-Heat_4 is what MaxTac is for. Unset
-- means no ceiling. The score scale is ours and deliberately small -- the
-- capacities below are the operator's dial, so a server that wants a slower city
-- raises them rather than editing every law.
--
-- Every value here is validated by `modules/ncpd/shared/law.lua` when the
-- resource loads, and a value it cannot use is named in a warning rather than
-- raised: a typo costs one law, not the session.

OPX.Config.MODULES.ncpd = {
	enabled = true,

	-- The two divisions, by the name the log and the HUD use. `LADDER` names one
	-- per stage; this table is what those names are checked against.
	DIVISIONS = {
		ncpd = { label = 'NCPD' },
		maxtac = { label = 'MaxTac' },
	},

	-- WHO ANSWERS AT EACH NCPD STAGE. The ground roster the module spawns when a
	-- stage's response has to put somebody on the street, and the records are the
	-- platform's own verified police peds (`modules/admin/data/peds.lua`). MaxTac
	-- has its own two rosters below, because the division is separable.
	--
	-- `RESPONSE.UNITS` on a ladder row is how many of these stand at the scene;
	-- `RESPONSE.VEHICLES` is the cars they arrive in. A record the client cannot
	-- resolve is a refused spawn, journalled by name, not a silent nothing.
	NCPD = {
		OFFICERS = {
			'Character.ncpd_base_ma',
			'Character.ncpd_base_wa',
			'Character.ncpd_base_mb',
		},
		-- The roadblock, when a stage declares `ROADBLOCK = true`: cars placed
		-- across the road, locked and immortal so the blockade is an obstacle to
		-- drive around rather than a wall that can be removed with a bumper.
		ROADBLOCK = {
			CARS = 2,
			SPACING_METERS = 4.0,
			AHEAD_METERS = 12.0,
			OFFICERS = 2,
		},
	},

	-- THE LADDER, KEYED BY THE ENGINE'S OWN HEAT NUMBER. `[0]` is `Heat_0` -- not
	-- wanted -- so a row's key is the heat stage it describes, and the `heat` name
	-- beside it is documentation of that: the validator refuses a row whose name
	-- and key disagree, which is how an inserted stage is caught instead of
	-- quietly handing one heat stage another's threshold.
	--
	-- CAPACITY is the score at which the player LEAVES that stage: the engine
	-- zeroes the accumulated score and raises the stage, once per crime, which is
	-- why the numbers climb -- the fifth star is meant to be hard to reach and
	-- harder to keep. `Heat_5`'s capacity is never used to advance (there is
	-- nothing above it) and is kept so a listing can print the whole ladder.
	--
	-- VEHICLES are the engine's own prevention records (`prevention_vehicles.tweak`),
	-- spelled the way a spawn call names them. A stage with no VEHICLES is a stage
	-- whose response is on foot, which is `Heat_1`'s whole point.
	--
	-- No AV here: the air unit at `Heat_5` belongs to the MaxTac division below,
	-- because that is where the engine puts it.
	LADDER = {
		[0] = {
			heat = 'Heat_0',
			-- Nobody answers at Heat_0, which is what makes it Heat_0 -- so this is
			-- the one row with no division -- but its capacity is the threshold the
			-- whole ladder is entered by: the score that makes a player wanted.
			division = nil,
			CAPACITY = 50.0,
			RESPONSE = { UNITS = 0, VEHICLES = {}, ROADBLOCK = false },
		},
		[1] = {
			heat = 'Heat_1',
			division = 'ncpd',
			CAPACITY = 120.0,
			RESPONSE = {
				UNITS = 2,
				VEHICLES = { 'Vehicle.ncpd_villefort_cortes_heat_1' },
				ROADBLOCK = false,
			},
		},
		[2] = {
			heat = 'Heat_2',
			division = 'ncpd',
			CAPACITY = 220.0,
			RESPONSE = {
				UNITS = 3,
				VEHICLES = {
					'Vehicle.ncpd_villefort_cortes_heat_2',
					'Vehicle.ncpd_archer_hella_heat_2',
					'Vehicle.ncpd_brennan_apollo_bike',
				},
				ROADBLOCK = false,
			},
		},
		[3] = {
			heat = 'Heat_3',
			division = 'ncpd',
			CAPACITY = 350.0,
			RESPONSE = {
				UNITS = 4,
				VEHICLES = {
					'Vehicle.ncpd_archer_hella_heat_3',
					'Vehicle.ncpd_villefort_cortes_heat_2',
				},
				ROADBLOCK = false,
			},
		},
		[4] = {
			heat = 'Heat_4',
			division = 'ncpd',
			CAPACITY = 500.0,
			RESPONSE = {
				UNITS = 5,
				VEHICLES = {
					'Vehicle.ncpd_suv_chevalier_emperor_heat_4',
					'Vehicle.ncpd_thorton_merrimac_police_heat_4',
				},
				-- The engine's own roadblock takes the MaxTac AV record for its
				-- overflight; the blockade itself is four NCPD vehicles.
				ROADBLOCK = true,
			},
		},
		[5] = {
			heat = 'Heat_5',
			division = 'maxtac',
			-- Never used to advance. The Hellhound and MaxTac both belong to this
			-- stage, and what ends it is the squad dying, not the score.
			CAPACITY = 500.0,
			RESPONSE = {
				UNITS = 6,
				VEHICLES = { 'Vehicle.ncpd_hellhound_heat_5' },
				ROADBLOCK = true,
			},
		},
	},

	-- WHAT COUNTS AS A CRIME, AND WHAT IT COSTS. The engine's own weights are the
	-- reference for the shape -- a civilian kill (`HeatKillCiv`), a police kill
	-- (`HeatKillPolice`), and vehicle damage scaled by the percentage dealt
	-- (`PoliceVehicleCrimeScoreMultiplier`, `CivVehicleCrimeScoreMultiplier`) --
	-- and these are ours to tune. `group` is what a law listing and the ACL
	-- surface filter on; it carries no behaviour of its own.
	--
	-- `ceiling` is a STAGE. `ceiling = 2` means the offence adds nothing once the
	-- player is at `Heat_2` or above: it did not stop being a crime, the city
	-- simply has bigger things pointed at them.
	LAWS = {
		{ id = 'assault', label = 'Assault', score = 8.0, ceiling = 2, group = 'violence' },
		{ id = 'murder', label = 'Murder', score = 40.0, group = 'violence' },
		{ id = 'murderPolice', label = 'Murder of an officer', score = 70.0, group = 'violence' },
		{ id = 'discharge', label = 'Discharging a weapon in public', score = 5.0, ceiling = 3, group = 'violence' },
		{ id = 'resisting', label = 'Resisting arrest', score = 20.0, ceiling = 4, group = 'obstruction' },
		{ id = 'vehicleTheft', label = 'Vehicle theft', score = 25.0, group = 'property' },
		{ id = 'vehicleDamage', label = 'Damaging a vehicle', score = 15.0, group = 'property' },
		{ id = 'propertyDamage', label = 'Property damage', score = 10.0, group = 'property' },
		{ id = 'trespass', label = 'Trespassing', score = 3.0, ceiling = 1, group = 'minor' },
		{ id = 'contraband', label = 'Contraband', score = 12.0, group = 'minor' },
		{ id = 'jobHeat', label = 'Job heat', score = 30.0, group = 'job' },
	},

	-- A district multiplier scales every score earned inside it. An unlisted
	-- district is 1.0, so a new district needs no entry -- and the names are the
	-- game's own districts, matched case-insensitively by the module.
	DISTRICTS = {
		watson = 1.0,
		westbrook = 1.2,
		['city_center'] = 1.5,
		heywood = 1.1,
		santo_domingo = 1.0,
		pacifica = 0.8,
		badlands = 0.6,
	},

	-- HOW THE SCORE FALLS. `HOLD_SECONDS` is how long a score survives a player
	-- who stops; after that it drains at `PER_SECOND`, and a player who has done
	-- nothing for `RESET_SECONDS` is dropped to zero outright -- the soft version
	-- of the engine's own `HeatCrimeScoreResetTime` zeroing, which is a hard
	-- timer inside `PreventionSystem`.
	DECAY = {
		HOLD_SECONDS = 15.0,
		PER_SECOND = 2.0,
		RESET_SECONDS = 90.0,
	},

	-- HOW MUCH THE CITY PUTS ON THE STREET AT ONCE, for every wanted character
	-- together. The owner, 2026-10-07: "theres a stacking bug spawning in
	-- reapedetly maxtac agents more and more its slowing my game down almost
	-- crashing". Fifty bots killing each other left 35 responses standing at
	-- once -- 265 officers and troopers, 126 cars -- because every wanted
	-- character was stood a whole response of their own and none came down.
	--
	-- `UNITS` and `VEHICLES` are NCPD's: every officer and every car (the
	-- roadblock's too) standing for every wanted character. A stage asked for
	-- past them stands what is left, with cars in proportion to its officers, and
	-- the rest when another response comes down.
	--
	-- `MAXTAC_SQUADS` is how many cyberpsychos MaxTac answers at once. Another one
	-- is still at MaxTac's stage -- the stars, the alarm and the call-out are
	-- unchanged -- but NCPD's top stage holds them until a squad is free, and the
	-- squad then comes to them. 0 is a MaxTac of players only.
	--
	-- `NEUTRALIZED_SECONDS`: a wanted character who has been down this long is
	-- NEUTRALIZED -- the stage is cleared and the response goes home, the way a
	-- MaxTac squad leaves once the psycho is down. `false` keeps a downed suspect
	-- wanted, with the units standing over them, until the stage decays.
	--
	-- `LIMITS = false` is the old street: no ceiling, nobody neutralized.
	LIMITS = {
		UNITS = 24,
		VEHICLES = 10,
		MAXTAC_SQUADS = 1,
		NEUTRALIZED_SECONDS = 10,
	},

	-- MAXTAC: the division that arrives when the NCPD ladder has failed.
	--
	-- WHO ANSWERS. A player is offered a seat in the squad if they hold
	-- `OPT_IN.RIGHT` or their job is one of `OPT_IN.JOBS`. Any seat still empty
	-- when `RESPONSE_SECONDS` have passed is filled by the engine's own troopers
	-- -- `FILL = 'bots'` -- so the squad always arrives: an empty division must
	-- not mean an empty street. `FILL = 'players'` is legal and makes the job
	-- player-only, which is a choice a server may want on a job night.
	-- ── the call-out ────────────────────────────────────────────────────────
	--
	-- WHO IS TOLD THAT THE CITY HAS A PROBLEM. A stage that RISES is broadcast
	-- to every player who is ON DUTY in one of the jobs below, with the place it
	-- happened: this is the half of a wanted level a roleplay server has and a
	-- bot response cannot be -- the engine's units answer on their own, and the
	-- people PLAYING the police go and do it because somebody told them.
	--
	-- IT SPAWNS NOTHING AND REPLACES NOTHING. The engine's own units and this
	-- module's response are already on their way when it runs, so a call-out
	-- that fails to send cannot leave the city unprotected; what it costs is
	-- that the people playing the police never hear about it, which is why the
	-- count and the failure are both journalled rather than swallowed.
	--
	-- A RISE, AND ONLY A RISE. Every poll that crosses a stage passes through the
	-- same function, and so does the ledger's own decay back to zero --
	-- repeatedly, once per poll. Neither is news. What is news is the instant a
	-- stage goes up.
	ALERTS = {
		enabled = true,

		-- The heat stage a call-out is worth making at, 1..5. Stage 1 is a
		-- wanted player; a server that wants radio silence until somebody is
		-- actually dangerous raises this.
		MIN_STAGE = 1,

		-- Which jobs are on the air. A player is on call when their PRIMARY job
		-- is one of these AND they are ON DUTY -- duty is the character
		-- module's own field and not a second one, so a clocked-off officer
		-- hears nothing, which is what clocking off is for.
		--
		-- `ncpd_maxtac` USED TO BE IN THIS LIST AND IS GONE (2026-09-26): a
		-- draft division name, never in the character catalogue, held by no
		-- character row in any database on the box (both schemas, live and
		-- deleted, checked). The other three lists that carried it -- the
		-- dispatch board below, `MAXTAC.OPT_IN.JOBS`, `BOARDING.JOBS` and
		-- `config/avgarages.lua`'s pad gate -- say `maxtac` and nothing else.
		JOBS = { 'ncpd', 'maxtac' },

		-- Floor between two call-outs about the SAME suspect, so one firefight
		-- that climbs three stages is one message rather than three.
		COOLDOWN_MS = 20000,

		-- Metres a suspect's position is rounded to before it is named. A
		-- call-out is radio traffic and not a coordinate: ten metres is a place
		-- somebody can walk to, and it does not hand every officer a
		-- metre-perfect fix on a player who is trying to get away.
		ROUND_METRES = 10.0,

		-- Whether the call-out names the suspect. Off is the setting for a
		-- server whose radio should not be a nameplate detector.
		NAME_SUSPECT = true,

		-- THE LOUD HALF OF THE CALL-OUT: the dispatch board on the screens of
		-- everybody who answers for the city.
		--
		-- `callOut` above is radio traffic -- a toast in the corner and a line on
		-- the scanner band -- and a wanted player two streets over is exactly the
		-- thing nobody reads in the corner of a screen. This is the same moment
		-- shouted: a full-stress toast on the overlay, wrapped in the two clips
		-- the world announcement uses, for every on-duty holder of the jobs in
		-- the call-out. ONE moment, ONE wording, three surfaces: the words are the
		-- radio's own keys and arguments, so the board cannot drift from the air.
		--
		-- IT RIDES THE CALL-OUT AND NOT A TRIGGER OF ITS OWN. The cooldown, the
		-- MIN_STAGE floor and "a RISE, and only a rise" above are exactly the
		-- conditions under which a city wants its police screens lit up; a second
		-- trigger would be a second thing to drift from them. `enabled = false`
		-- takes the board down and leaves the radio alone.
		--
		-- Nothing about the SOUND crosses the wire. The two clips below are read
		-- by each RECEIVING client out of its own copy of this file, exactly as
		-- `modules/admin/client/announce.lua` reads its own -- a client that has
		-- the files plays them, one that named `''` does not, and neither case can
		-- make a dispatch fail to arrive. A name that is not a bare file name is
		-- dropped and logged by `core/client/notify.lua`, and the words still
		-- arrive.
		DISPATCH = {
			enabled = true,

			-- The toast's frame. `error` is the loudest shape this overlay has --
			-- an announcement arriving in the shape of a "saved" toast is one
			-- players learn to ignore.
			KIND = 'error',

			-- How long the board holds the screen, in milliseconds. Longer than a
			-- toast and shorter than an announcement: a dispatch is news with a
			-- half-life, not a decree.
			DURATION_MS = 12000,

			-- The two stingers that wrap the dispatch, by BARE FILE NAME -- the
			-- same files, and the same rule, as `config/admin.lua`'s ANNOUNCE block:
			-- the page resolves a name against its own `web/audio/` and nothing
			-- else is reachable from it. `''` turns one off.
			STINGER = {
				OPEN = 'announce-open.mp3',
				CLOSE = 'announce-close.mp3',
				VOLUME = 0.9,
			},

			-- WHOSE SCREENS LIGHT UP. `false` here is the call-out's own audience
			-- (the JOBS list above); a list here is its own air crew -- a server
			-- that wants MaxTac alone on the board names `{ 'maxtac' }`.
			JOBS = false,
		},

		-- THE MAXTAC ALARM, for the squad, when somebody goes cyberpsycho. A stage
		-- that crosses into MaxTac's (the LADDER's `maxtac` division) alerts every
		-- on-duty holder of JOBS. First comes a FLASH_MS flash: a red frame round
		-- the screen's edge and "MAXTAC ALERT" in the top part of the screen, over
		-- a klaxon and a voice ("MaxTac alert. Cyberpsycho reported. All MaxTac
		-- units, respond."). Then a slim strip at the top edge holds who and how
		-- far until DURATION_MS is up. It never covers the middle of the screen,
		-- and it never takes the keyboard or the pointer: the squad has to fight
		-- and run for the AV while it is up.
		--
		-- THE BOT LAB, 2026-10-07: "the maxtac alert is covering the whole screen
		-- while i try to get rid of the cyberpsycho i cant see". The first alarm
		-- held a band across the middle of the screen for nine seconds, and bots
		-- killing each other brought it back every few seconds. So an alarm within
		-- QUIET_MS of the last flash only updates the strip: no second flash and
		-- no second klaxon.
		--
		-- It rides the call-out like the board does -- the same rise, the same
		-- cooldown, the suspect never told -- so it cannot fire where the board
		-- would not. SOUND is a bare file name under the page's own `audio/`,
		-- read by each receiving client; `''` keeps the screen and drops the
		-- sound. SOUNDS is the same klaxon and voice ("MaxTac alert. Cyberpsycho
		-- reported. All MaxTac units respond.") in other languages, by the
		-- game's two-letter language code: a player whose game's voice-over is
		-- one of them hears it in that language (the bot lab, 2026-10-07: "give
		-- the voice locales with french german spanish etc"), anybody else
		-- SOUND. `enabled = false` takes the alarm away and leaves the board.
		ALARM = {
			enabled = true,
			JOBS = { 'maxtac' },
			DURATION_MS = 9000,
			FLASH_MS = 1500,
			QUIET_MS = 30000,
			SOUND = 'maxtac-alarm.wav',
			SOUNDS = {
				fr = 'maxtac-alarm-fr.mp3', de = 'maxtac-alarm-de.mp3', es = 'maxtac-alarm-es.mp3',
				it = 'maxtac-alarm-it.mp3', pl = 'maxtac-alarm-pl.mp3', pt = 'maxtac-alarm-pt.mp3',
				ru = 'maxtac-alarm-ru.mp3', uk = 'maxtac-alarm-uk.mp3', cs = 'maxtac-alarm-cs.mp3',
				hu = 'maxtac-alarm-hu.mp3', zh = 'maxtac-alarm-zh.mp3', ko = 'maxtac-alarm-ko.mp3',
				ja = 'maxtac-alarm-ja.mp3',
			},
			VOLUME = 1.0,
			-- The cyberpsycho's own screen: a klaxon and what is coming for them
			-- ("CYBERPSYCHO -- MaxTac has been dispatched to neutralize you"), never
			-- the squad's alarm with their own name in it. `false`: nothing.
			SUSPECT = true,
			SUSPECT_SOUND = 'maxtac-klaxon.wav',
		},
	},

	-- ── A KILL IS CALLED IN THE MOMENT IT HAPPENS ──────────────────────────
	--
	-- THE OWNER, 2026-09-29: "im not seeing the alert when somebody kills
	-- somebody or a npc ... maxtac ncpd should get alerted". Two faults, both
	-- measured before this block was written:
	--
	--   * THE CALL-OUT ABOVE ONLY EVER FIRED ON A STAGE THAT ROSE, and one murder
	--     does not raise one: `murder` scores 40 and `Heat_0` is left at 50, so a
	--     single body on the street moved no stage and told nobody. That rule is
	--     right for a WANTED LEVEL and wrong for a body -- a dispatcher does not
	--     wait for the second corpse.
	--   * A PLAYER KILLED BY A PLAYER WAS NEVER CHARGED AT ALL. The platform
	--     raises `open77:playerKilled(victim, killer, context)` for every
	--     attributed player death and nothing in this resource listened.
	--
	-- So a kill is charged here, and a charge of a law named in `CALL_OUT` is
	-- called in AT ONCE -- the toast, the scanner line and the loud dispatch
	-- board -- to everybody on duty in `ALERTS.JOBS`, with the scene pinned on
	-- their map. The stage still rises (or does not) by the book exactly as
	-- before; the call-out below is the body, the one above is the manhunt.
	--
	-- WHAT CANNOT BE SEEN FROM HERE, said so nobody hunts for it: the base
	-- game's own street crowd lives on each client alone, and the platform build
	-- players run does not publish the engine's crime reading
	-- (`Open77.prevention.state` has no `engineHeat` -- every client log says
	-- so at boot). A pedestrian of the vanilla crowd is therefore invisible to
	-- the server.
	--
	-- WHAT CAN, AND HOW (2026-09-29, the second look, after "still no toast"):
	--   * A PLAYER KILLED BY A PLAYER, from three doors that agree on one
	--     charge: the lethal `open77:playerDamaged`, `open77:playerDied` and
	--     `open77:playerKilled`. The platform raises the last only for a death
	--     the host could ATTRIBUTE (an unattributed one raises `playerDied`
	--     alone), so the first two are the net under it.
	--   * A SERVER-OWNED NPC -- the police units this module stands up, the
	--     MaxTac ground squad, the test crowd -- ONLY THROUGH `HITS` BELOW. The
	--     platform does not carry a player's shot at an NPC to the server at
	--     all, so before that block existed these bodies could not die
	--     server-side, `onNpcDied` never fired, and this whole section was
	--     waiting for an event no player could cause.
	HOMICIDE = {
		enabled = true,

		-- Which deaths are charged. PLAYERS is a player killed by a player (the
		-- platform's own attributed death); NPCS is a server-owned NPC killed by a
		-- player. The test crowd books its own kills through `BOTS` below and is
		-- never charged twice.
		PLAYERS = true,
		NPCS = true,

		-- The law a kill is charged as, and the one for a kill of the city's own:
		-- an ON-DUTY holder of `ALERTS.JOBS`, or a unit this module put on the
		-- street. Any id from `/opx.ncpd.laws`.
		LAW = 'murder',
		POLICE_LAW = 'murderPolice',

		-- An officer ON DUTY in `ALERTS.JOBS` who kills a player who was WANTED,
		-- or who had just hurt them (inside ATTRIBUTION_MS), is not charged and
		-- not called in: use of force is the job, and a squad that became wanted
		-- for stopping a wanted player would be hunting itself. Any other body is
		-- a murder like anybody's, badge or not, and counts toward the
		-- cyberpsycho rule below. The bot lab, 2026-10-07: "i killed more then 3
		-- bot players and i didnt get maxtac alert" -- an on-duty tester's four
		-- bystanders were all booked as use of force. `'all'` exempts every kill
		-- on duty (the old rule); `false` exempts none. Off the clock they answer
		-- like anybody else.
		EXEMPT_ON_DUTY = true,

		-- THE CYBERPSYCHO. The owner, 2026-10-07: "when i kill more then 3 people
		-- thats when your labeled cyberphysco". A character charged with more than
		-- PSYCHO_KILLS of the CALL_OUT laws below (murder, an officer's murder)
		-- inside PSYCHO_WINDOW_SECONDS goes straight to MaxTac's stage: the
		-- MaxTac alarm, the dispatch board and the AV, as if the ladder had been
		-- climbed. Kills an on-duty officer makes are use of force (above) and
		-- never counted. `PSYCHO_KILLS = false` leaves it to the ladder.
		PSYCHO_KILLS = 3,
		PSYCHO_WINDOW_SECONDS = 600,

		-- The laws that are a body on the street, and the sentence each is called
		-- in with (a catalogue key; `<key>Named` is the variant that names the
		-- suspect, used when `ALERTS.NAME_SUSPECT` allows it). A charge of any of
		-- these is called in whoever charged it -- this block, the test crowd,
		-- `/opx.ncpd.report murder`, or another resource through the contract.
		CALL_OUT = {
			murder = 'ncpd.dispatch.homicide',
			murderPolice = 'ncpd.dispatch.officerDown',
		},

		-- Floor between two kill call-outs about the SAME suspect, in
		-- milliseconds: a spree is one call-out every few seconds, not one per
		-- body. 0 calls every one in.
		COOLDOWN_MS = 8000,

		-- How long after a hit a player's death is still put down to the player
		-- who landed it, in milliseconds. The platform raises `playerKilled` only
		-- for a death it could attribute; one that arrives as a bare `playerDied`
		-- is charged to whoever hit the victim last inside this window (never a
		-- fall, the environment or a script). 0 turns the fallback off.
		ATTRIBUTION_MS = 8000,

		-- Seconds the scene stays pinned on the map of everybody who was told.
		-- 0 pins nothing. The pin is drawn by each receiving client and removed
		-- by it; nothing about it is stored.
		PIN_SECONDS = 120,
		PIN_SPRITE = 'objective',
	},

	-- ── THE HIT RELAY: A PLAYER'S SHOT AT ONE OF OUR BODIES ──────────────────
	--
	-- A player who shoots a server-owned NPC -- an officer of the response, a
	-- MaxTac trooper, a body of the test crowd -- hits a body the SERVER owns,
	-- and the platform does not carry that hit to the server: the shooter's
	-- client raises `open77:npcHit` for its own player and stops there
	-- (`docs/combat.md`: "these are observations, not applications"; the
	-- platform's own research, E6/F8: "no client-side hit on an NPC reaches the
	-- server today"). A resource has to forward it and apply the damage itself.
	-- This one did neither, so an officer stood at 100/100 for ever, nobody
	-- could kill one server-side, `onNpcDied` never fired and the murder
	-- call-out above waited for a death no player could cause.
	--
	-- `client/hits.lua` forwards the event (bounded, and coalesced per body).
	-- `server/hits.lua` admits it and prices it. THE NUMBER IS THE SERVER'S:
	-- the engine's damage is only a hint, clamped into MIN_DAMAGE..MAX_DAMAGE
	-- (a gang record's rifle is priced for a levelled solo player), and the
	-- body part is derived from the intercept's height against the body's own
	-- canonical position, never taken from the client. A hit is refused for a
	-- body this module does not own, a shooter who is dead, out of range, in
	-- another bucket, faster than MIN_INTERVAL_MS or past MAX_DPS.
	--
	-- `enabled = false` takes the relay down and leaves every body server-side
	-- immortal again, which is what the platform does on its own.
	HITS = {
		enabled = true,

		-- What one relayed hit is worth, on the 100-point scale the bodies are
		-- created with. The engine's own number is used when it lies between the
		-- two and clamped to them when it does not; a report with no usable
		-- number is worth FALLBACK_DAMAGE.
		MIN_DAMAGE = 12.0,
		MAX_DAMAGE = 60.0,
		FALLBACK_DAMAGE = 34.0,

		-- A hit at or above this height over the body's feet is a headshot and
		-- is worth HEADSHOT times as much.
		HEAD_METRES = 1.55,
		HEADSHOT = 2.0,

		-- The farthest a shooter may be from the body they hit, in metres.
		MAX_RANGE_METRES = 120.0,

		-- Floor between two accepted hits from the same shooter, and the most
		-- damage one shooter may land in a second. A shotgun burst arrives as one
		-- report (the client sums the pellets), so neither bites a real weapon.
		MIN_INTERVAL_MS = 45,
		MAX_DPS = 480.0,

		-- If a hit looked lethal and the platform has not raised `onNpcDied` this
		-- many milliseconds later, the body's own health is read and the death is
		-- booked from there. 0 turns the check off.
		DEATH_CHECK_MS = 900,
	},

	-- THE POLICE SCANNER'S THREE KNOBS. `modules/ncpd/module.lua` carries the
	-- same three values as its own shipped fallbacks; a usable block here wins
	-- on every read (the same live-config rule as `config/skills.lua`'s KEY),
	-- so the bands, the backlog and the key are dial settings rather than code.
	--
	-- KEY is the same shape as the crew door's: the id is stable because a
	-- player's rebind is stored under it, and `DEFAULT = false` is a real
	-- declaration of "no default binding" (the scanner simply ships without a
	-- key). A KEY block that is not one -- no ID or no NAME, or a DEFAULT that
	-- is neither a key name nor `false` -- falls back to the shipped block
	-- rather than leaving the scanner unreachable.
	--
	-- BACKLOG is how many lines the feed keeps for a scanner that stows and
	-- comes back: bounded so the frame carrying them is one host payload (the
	-- ceiling is 1024 value nodes and one line is about ten) and capped again
	-- on the page. CHANNELS are vocabulary -- id, the locale key the row names
	-- itself with, and the frequency the row's micro-label states -- and the
	-- audience rule stays the server's (`server/radio.lua` says who HEARS a
	-- band; nothing here does).
	RADIO = {
		KEY = { ID = 'opx.ncpd.radio', NAME = 'ncpd.key.radio', DEFAULT = 'F2' },
		BACKLOG = 30,
		CHANNELS = {
			{ id = 'ncpd',     NAME = 'ncpd.radio.channel.ncpd',     FREQ = '154.980' },
			{ id = 'tactical', NAME = 'ncpd.radio.channel.tactical', FREQ = '155.475' },
			{ id = 'maxtac',   NAME = 'ncpd.radio.channel.maxtac',   FREQ = '39.720' },
			{ id = 'air',      NAME = 'ncpd.radio.channel.air',      FREQ = '45.880' },
		},
	},

	MAXTAC = {
		STAGE = 5,
		HEAT = 'Heat_5',
		OPT_IN = {
			RIGHT = 'opx.ncpd.maxtac',
			JOBS = { 'maxtac' },
		},
		FILL = 'bots',
		RESPONSE_SECONDS = 20.0,

		-- The insertion. `Vehicle.max_tac_av` is a Zetatech Surveyor in MaxTac
		-- camo carrying a rifleman, a mantis-blade, a netrunner and an elite
		-- sniper. The camo is the base game's optical cloak, lifted there only
		-- by the prevention AI; opx_sandy_view (1.4.10, `OpxMaxTacAv.reds`)
		-- draws every AV of these records in the airframe's visible MaxTac
		-- livery on each player's game instead, so this stays the record the
		-- platform flies as an AV. The variants below are the same airframe
		-- with swapped crew (`max_tac_av2` carries the LMG), and the `2nd_wave`
		-- set is what the engine sends after a squad is wiped. ONE_AT_A_TIME is
		-- the engine's own rule (`CanRequestAVSpawn` refuses a second), kept
		-- here so a server cannot ask for two and be silently refused.
		AV = {
			RECORD = 'Vehicle.max_tac_av',
			-- The livery the insertion's aircraft is created in, on every
			-- player's game: the same airframe's visible MaxTac livery rather
			-- than the record's cloak. The platform applies a create's appearance
			-- on every client since its 2026-09-14 build; `OpxMaxTacAv.reds` is
			-- the second line for a client that does not. false: the record's own.
			APPEARANCE = 'zetatech_surveyor__basic_ep1_maxtac_01',
			VARIANTS = { 'max_tac_av1', 'max_tac_av2', 'max_tac_av3', 'max_tac_av_LMG_mb' },
			SECOND_WAVE = { 'max_tac_av_2nd_wave1', 'max_tac_av_2nd_wave2', 'max_tac_av_2nd_wave3' },
			ONE_AT_A_TIME = true,
			COOLDOWN_SECONDS = 90.0,
			-- Metres above the pad a requested AV is placed, so it does not start
			-- half-buried: an AV record's pivot is the chassis centre.
			LIFT = 1.2,

			-- THE INSERTION RUN. The engine's own route -- `RequestAVSpawn`, asked
			-- for by the client as `prevention.av` -- answers `ticket 0` on the
			-- live node: the call lands, no aircraft is scheduled, and the only
			-- thing on the street is the squad the response placed there. So the
			-- AV below is an Open77 vehicle flown by the server. Every number here
			-- is metres, seconds or milliseconds, and the order the aircraft flies
			-- is: APPROACH_METRES out at APPROACH_ALTITUDE, in over CRUISE_SECONDS
			-- to HOVER_ALTITUDE, down over DESCENT_SECONDS to DROP_ALTITUDE, hold
			-- DEPLOY_SECONDS while the squad steps out, back up to HOVER_ALTITUDE,
			-- hold HOVER_SECONDS, then out and away over EXIT_SECONDS.
			INSERTION = {
				APPROACH_METRES = 320.0,
				APPROACH_ALTITUDE = 95.0,
				HOVER_ALTITUDE = 26.0,
				DROP_ALTITUDE = 5.0,
				CRUISE_SECONDS = 6.0,
				DESCENT_SECONDS = 3.5,
				DEPLOY_SECONDS = 2.5,
				HOVER_SECONDS = 14.0,
				EXIT_SECONDS = 6.0,
				-- The pose cadence. `setTransform` revokes the physics lease and
				-- republishes the canonical transform on every call, so this is a
				-- cost on every viewer: ten a second is smooth at cruise and does
				-- not make one aircraft the most expensive thing in the bucket.
				TICK_MS = 100,
			},

			-- THE AIRCRAFT'S OWN VOICE, from the base game's MaxTac AV (2.31
			-- scripts): `AvStartDescentSFXBehaviour` as it drops, the
			-- `MaxTacFearEvent` horn as the squad bails out onto the street,
			-- `AvHoverIdleSFXBehaviour` while it hangs there, and
			-- `AvStartAscentSFXBehaviour` as it leaves -- the base game plays each
			-- on the airframe's `vehicle_general_emitter`. The server plays them on
			-- the airframe (`Open77.effects.sound`, kind `vehicle`), so everyone
			-- near it hears them from where the aircraft is. `false` silences one.
			SOUNDS = {
				DESCEND = 'av_maxtac_start_descent',
				DEPLOY = 'av_maxtac_descent_horn',
				HOLD = 'av_maxtac_hover_idle',
				CLIMB = 'av_maxtac_start_ascent',
			},
		},

		-- The ground division: the Merrimac in MaxTac livery, and the two troopers
		-- that arrive with it.
		VEHICLE = 'Vehicle.ncpd_suv_thorton_merrimac_maxtac',
		-- NAMES THAT EXIST IN THIS BUILD'S TweakDB. `prevention_maxtac_wa` was
		-- written here for a year of passes and does not exist: the engine's
		-- ground-trooper pair is `..._rifle_ma` and `..._rifle_wa`. A record that
		-- does not exist is refused by the client (`npc_record_not_found`), the
		-- car still pulls up, and the division that arrives is EMPTY -- which is
		-- what "two trucks that get stuck and are not moving or fighting me" was.
		-- `tests/run.lua` now checks every name below against the 2.31 dump in
		-- `docs/generated/npc-records-2.31.csv`, so a name the engine cannot
		-- answer fails the suite instead of shipping an empty car.
		GROUND = {
			'Character.prevention_maxtac_rifle_ma',
			'Character.prevention_maxtac_rifle_wa',
		},

		-- The AV-borne family, in the order the engine's own record lists them.
		-- These are the bots a player seat falls back to.
		TROOPERS = {
			'Character.maxtac_av_riffle_ma',
			'Character.maxtac_av_mantis_wa',
			'Character.maxtac_av_netrunner_ma',
			'Character.maxtac_av_sniper_wa_elite',
		},

		-- A MaxTac NPC spawned outside the prevention system carries its own tag
		-- and its own heat rule; both are the engine's, and both are named here so
		-- a spawn call cannot quietly forget them.
		TAG = 'MaxTac_NotPrevention',
		ALONE_EFFECT = 'BaseStatusEffect.MaxTacAlone',

		-- The squad a summon aims for, and how far a trooper may be from the
		-- insertion point before it is recalled rather than left behind.
		SQUAD = {
			SEATS = 4,
			WAVES = 3,
			INSERTION_RADIUS = 40.0,
		},

		-- THE CREW DOOR. A MaxTac worker walks up to the aircraft while it holds
		-- at the street and presses `KEY.DEFAULT` to get aboard.
		--
		-- THE MOUNT IS THE PLATFORM'S, NOT OURS. Boarding is
		-- `Open77.vehicles.warpPlayerIntoVehicle(player, hull, seat,
		-- { moveBucket = false, exitLocked = true })` -- the host's own
		-- authoritative seat assignment, which reserves the seat, publishes the
		-- forced entry and keeps the order until the client confirms the native
		-- mount. Proximity and the vehicle's locked flag are bypassed by that
		-- call on purpose: the reach rule below is OURS and is decided from the
		-- player's position as the SERVER reads it, never from the client's.
		--
		-- THE HULL IS HANDED OVER, NOT SHARED. The aircraft is flown by the
		-- server while nobody is aboard (`setTransform` per tick). A player
		-- seated in an AV is its pilot as far as the platform is concerned --
		-- `VehicleReplication` lets a seated client claim an AV at ANY seat --
		-- so the moment somebody boards, this run STOPS POSING the hull, clears
		-- its freeze and lets the crew fly it. Two hands on one airframe at
		-- 10 Hz is a fight, not a ride.
		--
		-- NOBODY IS EVER DROPPED. A crew member is released when the aircraft is
		-- down and at rest (see `REST_SPEED`), when the insertion is retracted,
		-- or when this module stops. The aircraft is only removed from the world
		-- when no player holds a seat in it.
		BOARDING = {
			ENABLED = true,
			-- Who may board: the division's jobs, and only while ON DUTY. The
			-- check is the character module's own `job.onDuty`, the same one the
			-- call-out uses, so a clocked-off officer cannot take a seat.
			JOBS = { 'maxtac' },
			-- How long the aircraft holds at the street after the squad is out.
			-- This is the window the crew walks up in; it is also the window in
			-- which the row is on screen.
			SECONDS = 20.0,
			-- How close the asker has to be, measured by the server against the
			-- hull's own canonical transform. The aircraft holds at
			-- `AV.INSERTION.DROP_ALTITUDE`, so this is a radius around a hull 5 m
			-- up: a walkable distance, not a reach through a wall.
			REACH_METRES = 12.0,
			-- The seats a crew takes, in the order they fill. THE CONTROLS GO
			-- FIRST: the platform flies an AV from any seat a body holds, but the
			-- cockpit is where the flight controls are authored, and "pilotable
			-- from inside" is a crew reaching for them -- so the first body
			-- through the door is placed where the flying is done and the rest
			-- fill the cabin behind them.
			SEATS = { 'seat_front_left', 'seat_front_right', 'seat_back_left', 'seat_back_right' },
			-- The strip row names the player's own binding; the id is what a
			-- rebind is stored under, so it must not change between builds.
			KEY = { ID = 'opx.ncpd.board', NAME = 'ncpd.key.board', DEFAULT = 'F' },
			-- While the hull is flying, an aboard body stays aboard: the exit lock
			-- goes up with the seat and comes off when the aircraft is down and
			-- slower than `REST_SPEED` for `REST_SECONDS`. "Down" is the hull
			-- within `REST_HEIGHT` metres of the height the insertion dropped at,
			-- because that is the last height this module knows the street to be
			-- at. Without all three numbers the lock is a trap -- a crew that can
			-- never step out of a parked aircraft.
			REST_SPEED = 2.0,
			REST_HEIGHT = 3.0,
			REST_SECONDS = 1.0,
			-- How often the crew's seats are read while they hold the hull.
			CUSTODY_MS = 1000,
			-- THE HULL WAITS FOR ITS CREW. The owner, 2026-09-29: "not being able
			-- to reboard the maxtac av after landing". Once the last crew member
			-- has stepped out, the aircraft stays parked where they left it for
			-- this many seconds, with the aircraft door on it (`config/avdoor.lua`,
			-- key F) open to the division on duty; whoever climbs back in rejoins
			-- the crew. 0 is the old shape: she leaves the moment they are out.
			PARK_SECONDS = 600,
		},
	},

	-- THE TEST CROWD: mortal civilians a player can kill, so the wanted ladder
	-- can be driven with real bodies (`modules/ncpd/server/bots.lua`). Placed
	-- on demand with `/opx.ncpd.bots spawn [count]`, taken off the street with
	-- `clear`. THE KILL IS A CRIME: a death with a player behind it is charged
	-- as `LAW` through the module's own charge path, so the ladder climbs, the
	-- response stands up and MaxTac answers exactly as they would for any
	-- other murder.
	--
	-- `BOTS = false` switches the whole rig off: the command refuses by name
	-- and no death is ever charged. Every field below falls back to the
	-- shipped value when it is not usable, and is read on every ask -- the
	-- same live-config rule as the radio's KEY block.
	BOTS = {
		-- The law a kill is charged as -- any id from `/opx.ncpd.laws`.
		LAW = 'murder',
		-- FALSE books nothing and leaves the ladder to whatever else scores
		-- the kill -- the engine's own heat, mirrored by the client. Set it
		-- when your engine already counts these deaths, or one kill climbs
		-- twice.
		CHARGE = true,
		-- How many one `spawn` places, and how many may stand at once.
		COUNT = 24,
		MAX = 64,
		-- How far from the asker the crowd stands (metres), and how far each
		-- body wanders from its own spot. `WANDER = 0` pins them.
		SPREAD = 45.0,
		WANDER = 12.0,
		-- The first wound sends a body fleeing from the player who landed it,
		-- the way a pedestrian would.
		FLEE = true,
		-- A killed body comes back this many seconds later, where it fell, so
		-- a long test does not run out of victims.
		RESPAWN = true,
		RESPAWN_SECONDS = 25.0,
		-- The bodies themselves: the civilian family of the admin ped
		-- catalogue (`modules/admin/data/peds.lua`). A row that is not a
		-- usable `Character.*` id is dropped rather than placed.
		RECORDS = {
			'Character.DefaultNCResidentMale',
			'Character.DefaultNCResidentFemale',
			'Character.AsianMale',
			'Character.AsianFemale',
			'Character.CreoleMan',
			'Character.CreoleWoman',
			'Character.TenantMale',
			'Character.TenantWoman',
			'Character.YoungsterMale',
			'Character.YoungsterFemale',
			'Character.SlackerMale',
			'Character.SlackerFemale',
			'Character.MorningCrowdMan',
			'Character.MorningCrowdWoman',
			'Character.NightlifeMale',
			'Character.NightlifeWoman',
		},
	},
}
