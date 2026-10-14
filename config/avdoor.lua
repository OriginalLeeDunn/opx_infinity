--- The AV door: walk up to an aircraft you may fly, see the row, press the key.
-- @author XEROX710
--
-- THE OWNER, 2026-09-29: "not being able to reboard the maxtac av after
-- landing ... i dont even see press f ... fix properly". Measured in the client
-- log of that session: the pad seated the pilot the moment the hull existed
-- (`LOCALSEAT seat=seat_front_left`), the flight was eleven minutes, the exit
-- at 22:49:47 was clean -- and after it there was no way back in. The base
-- game authors NO entry interaction on an aircraft (V boards one in a scene),
-- so the only door an AV ever had was the pad's hand-off at the moment it was
-- recalled, and the MaxTac crew door that is open for twenty seconds at the
-- street. Step out anywhere else and the aircraft was a statue.
--
-- THIS IS THAT DOOR, FOR EVERY AIRCRAFT. On foot, within `REACH_METRES` of a
-- parked AV you may fly, the strip shows `KEY` and the press seats you through
-- the platform's own authoritative mount (`warpPlayerIntoVehicle`) -- the same
-- call the pad and the crew door already use. THE SERVER FINDS THE DOOR: it
-- is the only side that holds world coordinates for a vehicle (a client
-- snapshot carries none, `wiki/vehicles.md`), so every `SCAN_MS` it measures
-- each player on foot against every aircraft in their bucket and tells the
-- client which door, if any, is open to them. Who may fly what is decided from
-- the server's own reads: the character a pad issued the hull to, an on-duty
-- holder of the job a job aircraft belongs to, or whatever rule the module that
-- owns the hull registered (the MaxTac insertion parks its aircraft here once
-- its crew has stepped out). `/opx.avdoor.why` says, for the aircraft nearest
-- to you, what the door answers and why.
--
-- ALSO HERE, because they are the same aircraft seen from the other side:
--   * the EXIT, which the platform performs with no animation -- its animated
--     AV exit crashed the game and is switched off in its own client
--     (`VehicleReplication.cpp`: "cockpit records author no humanoid exit
--     workspot"), so the body is carried out in one cut. The fade below turns
--     that cut into a scene change instead of a pop, the guard puts the body
--     on the ground beside the seat's door, and the server swings that door
--     open for everybody to see (see EXIT);
--   * the MaxTac AV's own VOICE when a player flies one: the base game's
--     ascent, descent and landing-horn events, played on the airframe for
--     everybody near it.
--
-- THE OWNER, 2026-09-29, three things in one message, each measured before it
-- was changed:
--   "make sure maxtac av sound is heard from all players not just the pilot" --
--   the relay now sends every listener near the hull the sound, the pilot
--   included, each listener's client answers what it did with it (the server
--   journals the answer), and a listener the host refused is given the sound
--   through the platform's own fan-out instead (SOUNDS.RESCUE);
--   "make sure other players can mount in av" -- PASSENGERS is on, and a hull
--   whose owner's rule refuses somebody is no longer refused to them outright;
--   "the player gets thrown out av and the av door doesnt open for some" -- the
--   client log of 2026-09-29 21:04:35 has the whole exit to the millisecond
--   (t = the platform's `vexit-anim-off`): the mount drops at +0.0 s and the
--   engine puts the body at the cockpit's exit point, INSIDE the hull; at
--   +0.1 s the platform wakes the chassis for 230 ms and at +0.38 s it
--   reports a car impact on the body (`impulse=474`, and a knock-down cue);
--   at +1.6 s its foot camera cuts in and about +1.7 s its own deferred eject
--   moves the body 3.5 m behind and 2 m UNDER the hull's centre. The old fade
--   was back before +1.5 s, so the player SAW the throw and the eject. The
--   door the platform opens is a local actuation, reported by a parked owner
--   that the same exit has just dropped (`vowner-loss ... mounted=0`), so
--   nobody else was ever told it opened.

OPX.Config.MODULES.avdoor = {
	enabled = true,

	-- WHICH RECORDS ARE AIRCRAFT. Lua patterns, matched against the vehicle's
	-- TweakDB record. The platform's own flight code decides which records FLY
	-- (`IsAvRecord`); this list only decides which hulls get a door, and a
	-- record it misses is an aircraft you board with a console command instead.
	RECORDS = { '^Vehicle%.av_', '_av$', '_av%d+$', '_av_', '_heli$', 'max_tac_av' },

	-- Metres from the hull's centre, measured by the SERVER against its own
	-- canonical transform. An AV is ten metres long and its door is beside the
	-- cockpit: nine metres from the centre is a walk to the door, not a reach
	-- through the fuselage.
	REACH_METRES = 9.0,

	-- Metres per second above which a hull is "moving" and has no door, on a
	-- host whose snapshot reports a speed. A parked aircraft reads zero.
	REST_SPEED = 2.0,

	-- The seats a pilot fills, in order, and the ones a passenger may take.
	-- The flight controls are at `seat_front_left`, so it is first.
	SEATS = { 'seat_front_left', 'seat_front_right', 'seat_back_left', 'seat_back_right' },

	-- Whether anybody may ride along in a passenger seat of an UNLOCKED
	-- aircraft that is not theirs. False: only the people who may fly it get in.
	-- ON, at the owner's word ("make sure other players can mount in av"): the
	-- pilot's seat stays the crew's -- a passenger is never offered
	-- `seat_front_left` -- but anybody within reach of a parked aircraft may sit
	-- in a free seat beside it. A hull whose owner registered a rule of its own
	-- (the MaxTac insertion's duty rule) still decides who FLIES; the rule can
	-- also close the passenger seats with `passengers = false`.
	PASSENGERS = true,

	-- THE DOOR THE SEAT USES: which door of the hull swings for which seat, by
	-- the platform's door names (`Open77.vehicles.openDoor`: frontLeft,
	-- frontRight, backLeft, backRight). The server opens it as a body boards and
	-- as one steps out, and every viewer sees it -- the door state is canonical
	-- and replicated, unlike the platform's own local actuation. `false` puts no
	-- door on any seat. A door the model does not animate is a bit that changes
	-- and nothing that moves, which is harmless.
	DOORS = {
		seat_front_left = 'frontLeft',
		seat_front_right = 'frontRight',
		seat_back_left = 'backLeft',
		seat_back_right = 'backRight',
	},

	-- BOARDING. The press opens the seat's door and the body is seated
	-- `DELAY_MS` later, judged again then -- so it is a body stepping in through
	-- an open door rather than a pop. `0` seats on the press. `HOLD_MS` is how
	-- long the door stays open after the body is in, so a second player boarding
	-- the same side finds it open.
	BOARD = {
		DELAY_MS = 450,
		HOLD_MS = 1500,
		-- A HULL THAT HAS JUST APPEARED IS NOT BOARDED YET. The owner,
		-- 2026-10-03: "the maxtac av is not driving when i drive it off it stays
		-- invisible". The client log of that flight: the pad put the pilot in the
		-- seat 0.3 s after the hull appeared -- before its projection had
		-- settled (the AV lift's drop onto the pad, the record's appearance
		-- swapped in, the observer physics handed over) -- and for the whole
		-- flight the hull the engine drew stayed on the pad while the controls
		-- flew on (`hullTrailM` 14-17 m; a flight that works trails by
		-- centimetres): a pilot flying in nothing, the AV left behind. A body
		-- boards a hull no sooner than this long after it was created, whether
		-- the pad seats it or the door key does (`M.Fresh`). `0` boards at once.
		SETTLE_MS = 2500,
	},

	-- THE KEY. `F`, like the MaxTac crew door: the gesture a player already
	-- knows for "get in". The platform fires every mapping on a pressed key,
	-- and this one does nothing unless its row is up.
	KEY = { ID = 'opx.avdoor.board', NAME = 'avdoor.key.board', DEFAULT = 'F' },

	-- How often the SERVER measures the players on foot against the aircraft
	-- in their bucket. Half a second: the row is up before a walk to the door
	-- is over, and one pass is one `vehicles.all` plus one position per player.
	SCAN_MS = 500,

	-- THE WATCH: WHERE EVERY SCREEN DRAWS AN AIRCRAFT, AND WHERE THE SERVER HAS IT.
	--
	-- THE OWNER, 2026-09-30: "the av is driving away on other player screen going
	-- through buildings but when i move it comes back to same spot on other play
	-- screen". The pilot's own client log of that flight cannot show it -- the
	-- pilot's screen is the one that was right -- and nothing on the server wrote a
	-- line about an aircraft's authority, so the drift left no evidence anywhere a
	-- log collection reaches. This block is that evidence, on both sides:
	--
	--   * EVERY CLIENT, every `SIGHT_MS`, compares where its engine DRAWS each
	--     aircraft it does not simulate itself (the entity's own frame) with
	--     where the server's last sample put it (the client snapshot), for the
	--     nearest `MAX_HULLS` within `RANGE`. Drawn more than `DRIFT_METRES` away
	--     (plus `DRIFT_PER_SPEED` metres per m/s the hull is moving, because an
	--     observer draws a moving hull a jitter buffer behind its newest sample)
	--     opens an EPISODE: one line in that client's log and one report to the
	--     server, which writes it to ITS journal with its own reads beside it --
	--     the physics owner, the epoch, who is seated, the freeze. Under
	--     `SETTLE_METRES` twice in a row closes it, with how long it lasted and
	--     how far it got. An open episode is reported again every `REPEAT_MS`.
	--   * THE SERVER journals every change of an aircraft's physics owner
	--     (`onVehicleAuthorityChanged`, with the platform's reason) and every
	--     canonical move bigger than `JUMP_METRES` between two scans, which is
	--     faster than any AV flies.
	--   * `HEAL`: an EMPTY, unfrozen aircraft that a client reports drawing far
	--     from where the server has it is re-published where it stands
	--     (`setTransform` to its own canonical pose and heading), which starts a
	--     new authority epoch and makes every viewer drop its buffered path and
	--     draw the hull where the server has it. At most once per `HEAL_EVERY_MS`
	--     per hull, and never with anybody aboard: a seated pilot's lease is
	--     theirs, and a server pose would fight it.
	--
	-- `WATCH = false` switches all of it off.
	WATCH = {
		SIGHT_MS = 500,
		RANGE = 350.0,
		MAX_HULLS = 3,
		DRIFT_METRES = 10.0,
		DRIFT_PER_SPEED = 0.4,
		SETTLE_METRES = 4.0,
		REPEAT_MS = 5000,
		JUMP_METRES = 45.0,
		HEAL = true,
		HEAL_EVERY_MS = 10000,
	},

	-- THE EXIT, ON THE SCREEN. A native quest fade -- out as the mount drops,
	-- held through everything the platform does to the body, and back in on a
	-- body that is standing beside the open door -- so the cut the platform makes
	-- is a scene change rather than a throw. `false` for none.
	--
	-- THE HOLD IS MEASURED, NOT GUESSED. From the mount dropping, the platform's
	-- exit runs its unmount at +0.1 s, the car impact at +0.4 s, the foot camera
	-- at +1.6 s and its deferred eject at about +1.7 s (see the header). The
	-- screen may not come back before the last of them:
	--   HOLD_MS            the least the screen stays covered after a PILOT's
	--                      exit, counted from the fade beginning -- the pilot
	--                      seat is the one the platform's flight code ejects;
	--   PASSENGER_HOLD_MS  the same for every other seat, which the platform
	--                      does not eject (only the engine's own drop, at once);
	--   MAX_HOLD_MS        the ceiling: a screen is never held past this.
	-- It also waits for `EXIT.SETTLE_MS` of stillness after the last time the
	-- body was moved, so a late eject is still hidden.
	EXIT_FADE = {
		OUT_MS = 160,
		HOLD_MS = 1900,
		PASSENGER_HOLD_MS = 800,
		MAX_HOLD_MS = 3600,
		IN_MS = 550,
	},

	-- THE EXIT, ON THE GROUND. The client guard and the server's door.
	--
	-- THE GUARD (client): from the moment the mount drops it puts the body on
	-- the ground beside its seat's door -- `SIDE_METRES` out from the hull's
	-- centre on the door's side and `FORWARD_METRES` toward the nose, on the
	-- ground the static ray finds there -- and keeps it there for `GUARD_MS`:
	-- a jump of more than `JUMP_METRES` between two looks (50 ms) is the
	-- platform's own eject putting it back under the hull, and it is put back.
	-- The platform's hull is `halfW=5.00` in its own log, so 6 m is a metre
	-- clear of it; `REACH_METRES` (9 m) still covers it, so the door row is up
	-- the moment the screen is. A body still inside `DANGER_METRES` of the
	-- hull's centre when the guard ends is moved once more. Higher than
	-- `MAX_AIR_METRES` over the ground the exit is in flight: the body is put
	-- beside the door at the door's own height and falls from there, and is
	-- never carried down to the ground. A seat lost more than `NEAR_METRES`
	-- from the hull is a teleport (a server move, a respawn) and is left alone.
	-- `PLACE = false` is the old exit: the fade only.
	--
	-- THE DOOR (server): the seat's door (DOORS) opens as the seat empties and
	-- closes `DOOR_HOLD_MS` later. The platform's own engine closes a pilot
	-- door a moment after an unmount, so for `DOOR_REASSERT_FOR_MS` the server
	-- looks every `DOOR_REASSERT_MS` and opens it again if it was shut. Every
	-- one of those reads goes to the journal.
	EXIT = {
		PLACE = true,
		SIDE_METRES = 6.0,
		FORWARD_METRES = 1.5,
		LIFT_METRES = 0.25,
		MAX_AIR_METRES = 4.0,
		NEAR_METRES = 14.0,
		GUARD_MS = 2800,
		JUMP_METRES = 2.5,
		DANGER_METRES = 3.2,
		SETTLE_MS = 350,
		DOOR_HOLD_MS = 6000,
		DOOR_REASSERT_MS = 400,
		DOOR_REASSERT_FOR_MS = 3200,
	},

	-- THE MAXTAC AV'S OWN VOICE WHEN A PLAYER FLIES ONE. The base game's
	-- events (2.31 scripts: `AvStartAscentSFXBehaviour`,
	-- `AvStartDescentSFXBehaviour`, `MaxTacFearEvent`), played on the airframe
	-- for every player within `RANGE`. The pilot's own client reads the flight
	-- -- its seated body's height over the ground under it
	-- (`Open77.world.groundZ`) and the climb rate -- and the server relays it
	-- after checking the asker really is seated in that hull. The platform's
	-- AV flight publishes `onGround = false` on every frame
	-- (`VehicleFlight.cpp`), so the ground is measured, never read off the
	-- snapshot. `''` switches one event off; `SOUNDS = false` switches all of
	-- them off.
	SOUNDS = {
		-- Which aircraft speak with this voice: patterns over the record.
		RECORDS = { 'max_tac' },
		-- WHO HEARS IT, AND HOW WE KNOW. The relay sends the event to every
		-- player within `RANGE` of the hull -- the pilot included -- and each
		-- listener's client answers what it did with it (`played`, or the reason
		-- it could not), which the server writes to ITS journal: a sound that
		-- fails on somebody else's machine leaves no line anywhere else. That is
		-- the road the 2026-09-29 log proved for the pilot (`av_maxtac_start_ascent
		-- on ...: playing on the airframe`).
		--
		-- `RESCUE` (the default): a listener that answers with a REFUSAL by the
		-- host -- not "this hull is not streamed here", which the platform would
		-- drop just the same -- is given the sound through the platform's own
		-- fan-out instead (`Open77.effects.sound` with a vehicle target, the call
		-- the MaxTac insertion already makes), addressed to that listener alone by
		-- excluding everybody else in the bucket, so nobody hears it twice.
		-- `false` leaves a refusal a refusal.
		RESCUE = true,
		TAKEOFF = 'av_maxtac_start_ascent',
		DESCENT = 'av_maxtac_start_descent',
		TOUCHDOWN = 'av_maxtac_descent_horn',
		-- THE GROUND BAND: a hull whose pilot sits at most this high over the
		-- ground, and that has stopped sinking for `SETTLE_MS`, is down. The
		-- pilot sits in a cockpit two to four metres over the belly, and the
		-- platform eases any AV hovering inside five metres of a surface down
		-- onto it (`kSettleWindow`), so a hull that holds still in this band
		-- is a hull that has landed.
		GROUND_METRES = 7.0,
		-- Metres per second of climb or sink below which the hull holds still.
		REST_CLIMB = 0.5,
		SETTLE_MS = 750,
		-- The descent call: under this height, sinking faster than this.
		DESCENT_METRES = 30.0,
		DESCENT_SPEED = 1.5,
		-- The take-off call: off the ground and climbing faster than this.
		CLIMB_SPEED = 0.8,
		-- One event of a kind per hull at most this often, and how far it carries.
		FLOOR_MS = 6000,
		RANGE = 220.0,
		DURATION_S = 8.0,
	},

	-- THE LANDING CALL. A woman's voice on the aircraft's loudspeaker --
	-- "Warning. Clear the area. MaxTac landing." or "... Trauma Team landing."
	-- -- said over and over while one of those AVs comes down, on top of the
	-- airframe's own sounds, and stopped when it is down:
	--   * a player-flown AV: from the moment its pilot's client reports the
	--     descent (SOUNDS.DESCENT_METRES and DESCENT_SPEED above) until it
	--     reports the touchdown, or climbs back out of the descent band;
	--   * the MaxTac insertion and the Trauma Team's (`modules/ncpd`,
	--     `modules/downed`): from the approach until the AV is down at the drop.
	-- When the AV is down, the voice fades out over FADE_MS (0 cuts it at once),
	-- wherever the sentence is. It used to finish the sentence, up to a whole
	-- clip after the touchdown. The bot lab, 2026-10-07: "it doesnt stop when av
	-- lands". MAX_SECONDS ends a call that never heard its touchdown.
	--
	-- IN EACH PLAYER'S OWN LANGUAGE (TRANSPORT = 'local', the default). The
	-- server says which hull is calling to every player in its bucket within
	-- MAX_METRES -- and to anybody who comes near, every TELL_MS, at the point
	-- the loop has reached -- and each game plays the line itself, in the
	-- language its voice-over is set to (`Open77.session.locale`, permissions
	-- `session.locale` and `audio.play`), from where it draws the hull: at full
	-- volume within MIN_METRES, fading out to MAX_METRES. The bot lab,
	-- 2026-10-07: "give the voice locales with french german spanish etc".
	-- TRANSPORT = 'network' is the old way: one server-owned network sound
	-- (`Open77.audio`, permission `audio.network`) in ASSET's language for the
	-- whole bucket, moved with the hull every FOLLOW_MS.
	--
	-- KINDS: which hulls say which line. RECORDS are patterns over the vehicle
	-- record, like RECORDS above. ASSET is the English line, a file in `audio/`
	-- (declared in open77.lua's `files`), and SECONDS its exact length: a loop
	-- needs it, and the suite checks it against the file. VOICES are the same
	-- line in other languages, by the game's two-letter language code, each its
	-- own file and length; a language with no line hears ASSET. The English
	-- Trauma line says "Trauma" as "TRAW-muh", not "Traumer" (the bot lab,
	-- 2026-10-07: "she says it with a r at the end prounouned traumer").
	-- `CALLOUTS = false` switches the call off.
	CALLOUTS = {
		TRANSPORT = 'local',
		KINDS = {
			maxtac = { RECORDS = { 'max_tac', 'maxtac' },
				ASSET = 'audio/av-callout-maxtac.wav', SECONDS = 4.4517,
				VOICES = {
					fr = { ASSET = 'audio/av-callout-maxtac-fr.mp3', SECONDS = 4.9371 },
					de = { ASSET = 'audio/av-callout-maxtac-de.mp3', SECONDS = 5.2767 },
					es = { ASSET = 'audio/av-callout-maxtac-es.mp3', SECONDS = 4.3886 },
					it = { ASSET = 'audio/av-callout-maxtac-it.mp3', SECONDS = 4.9371 },
					pl = { ASSET = 'audio/av-callout-maxtac-pl.mp3', SECONDS = 4.8849 },
					pt = { ASSET = 'audio/av-callout-maxtac-pt.mp3', SECONDS = 6.2433 },
					ru = { ASSET = 'audio/av-callout-maxtac-ru.mp3', SECONDS = 6.5045 },
					uk = { ASSET = 'audio/av-callout-maxtac-uk.mp3', SECONDS = 5.1461 },
					cs = { ASSET = 'audio/av-callout-maxtac-cs.mp3', SECONDS = 4.4408 },
					hu = { ASSET = 'audio/av-callout-maxtac-hu.mp3', SECONDS = 4.3102 },
					zh = { ASSET = 'audio/av-callout-maxtac-zh.mp3', SECONDS = 5.6424 },
					ko = { ASSET = 'audio/av-callout-maxtac-ko.mp3', SECONDS = 5.9559 },
					ja = { ASSET = 'audio/av-callout-maxtac-ja.mp3', SECONDS = 6.9224 },
				},
			},
			trauma = { RECORDS = { 'trauma' },
				ASSET = 'audio/av-callout-trauma.wav', SECONDS = 4.1392,
				VOICES = {
					fr = { ASSET = 'audio/av-callout-trauma-fr.mp3', SECONDS = 5.3029 },
					de = { ASSET = 'audio/av-callout-trauma-de.mp3', SECONDS = 4.9110 },
					es = { ASSET = 'audio/av-callout-trauma-es.mp3', SECONDS = 4.5192 },
					it = { ASSET = 'audio/av-callout-trauma-it.mp3', SECONDS = 4.8327 },
					pl = { ASSET = 'audio/av-callout-trauma-pl.mp3', SECONDS = 5.1461 },
					pt = { ASSET = 'audio/av-callout-trauma-pt.mp3', SECONDS = 6.3478 },
					ru = { ASSET = 'audio/av-callout-trauma-ru.mp3', SECONDS = 6.5567 },
					uk = { ASSET = 'audio/av-callout-trauma-uk.mp3', SECONDS = 6.1127 },
					cs = { ASSET = 'audio/av-callout-trauma-cs.mp3', SECONDS = 4.8588 },
					hu = { ASSET = 'audio/av-callout-trauma-hu.mp3', SECONDS = 4.4147 },
					zh = { ASSET = 'audio/av-callout-trauma-zh.mp3', SECONDS = 5.3290 },
					ko = { ASSET = 'audio/av-callout-trauma-ko.mp3', SECONDS = 6.2955 },
					ja = { ASSET = 'audio/av-callout-trauma-ja.mp3', SECONDS = 7.1837 },
				},
			},
		},
		TELL_MS = 1000,
		VOLUME = 1.0,
		MIN_METRES = 30.0,
		MAX_METRES = 300.0,
		MAX_SECONDS = 90,
		FADE_MS = 400,
		FOLLOW_MS = 150,
	},

	-- WHERE AN AV THE SERVER FLIES COMES DOWN: the MaxTac insertion
	-- (`modules/ncpd`) and the Trauma Team (`modules/downed`). The bot lab,
	-- 2026-10-07: "all avs need to land on the road in game the trauma team av
	-- is landing outside on the water while the trauma soldiers or visually
	-- walking on air". Both came down a fixed distance from the body on a fixed
	-- bearing, at the body's height, wherever that fell.
	--
	-- Before the AV comes in, the server asks the players' games for the ground
	-- around the place (`Open77.world.groundZ`: a static ray from 400 m up, run
	-- by the nearest game within OBSERVER_METRES) and takes the first point
	-- that is ground (open water answers nothing), open to the sky (a roof or an
	-- overpass answers its own height), within LEVEL_METRES of the person's
	-- level, and flat under the hull: the ground FOOTPRINT_METRES either side,
	-- both ways, within FLAT_METRES. Rings out to FAR_METRES, every 45 degrees
	-- from the AV's own bearing. BUDGET_SECONDS bounds the asking; the AV waits
	-- for it far out and high, and a survey that finds nothing keeps the old
	-- place and says why. The team steps out on the ground that was measured.
	-- Only a game can measure, and a load-test bot never answers: the first
	-- point is asked of several players near it at once (PROBE_MS each), the
	-- first that answers measures the rest, and one that did not is left out
	-- of the next survey for ten minutes.
	-- `LANDING = false` is the old fixed place.
	LANDING = {
		LEVEL_METRES = 2.5,
		FOOTPRINT_METRES = 4.5,
		FLAT_METRES = 0.8,
		FAR_METRES = 40.0,
		BUDGET_SECONDS = 4.0,
		OBSERVER_METRES = 250.0,
		PROBE_MS = 1500,
	},

	-- THE LANDING PAD UNDER AN AV THE SERVER FLIES. The bot lab, 2026-10-07:
	-- "make sure the trauma team av has the red warning laser underneath like
	-- maxtac av does". That red laser is the Open77 client's own landing pad: a
	-- ring of red beams on the ground under the hull, a beam running round
	-- inside it and the OPEN77 sign in dots, shown while the hull is within
	-- SHOW_METRES of the ground and coming down (faster than DESCEND_SPEED) or
	-- sitting there (within REST_METRES), with the dust under the hull and the
	-- engine's hover voice. The client draws them only under a record it flies
	-- as an AV -- PLATFORM, Lua patterns on the lower-cased record -- and the
	-- Trauma Team's airframes are not, so this module draws the same pad for
	-- them: every player within METRES of the hull is told (and anybody who
	-- comes near, every TELL_MS). The pad is centred on the hull's own mesh and
	-- drawn on the ground under it; RADIUS_METRES and BEAMS are the client's
	-- own pad's, SIGN the OPEN77 dots. DUST is the effect under the hull within
	-- DUST_METRES of the ground (the prologue's Trauma AV dust), VOICE the
	-- engine's while it runs (`false` for none). `PADS = false`: no pad from
	-- this module at all.
	PADS = {
		METRES = 300.0,
		TELL_MS = 1000,
		PLATFORM = { '^vehicle%.av_', '^vehicle%.max_tac_av$' },
		RADIUS_METRES = 3.5,
		BEAMS = 12,
		SIGN = true,
		SHOW_METRES = 6.0,
		REST_METRES = 2.2,
		DESCEND_SPEED = 0.4,
		DUST = 'base\\fx\\quest\\q001\\00c_rescuing_girl\\q001_av_dust_loop.effect',
		DUST_METRES = 11.0,
		VOICE = { START = 'v_av_trauma_big_engine_start', STOP = 'v_av_trauma_big_engine_stop' },
	},
}
