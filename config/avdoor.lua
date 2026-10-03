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
}
