--- The AV autopilot: where it flies, how fast, and the one key that starts it.
-- @author XEROX710
--
-- WHAT THIS IS. A seated pilot presses one key and the aircraft flies ITSELF to
-- the pilot's own map waypoint; the same key hands the controls back at any
-- moment. It is the Delamain-ride shape of the base game -- a vehicle that
-- carries you to the pin you dropped -- rebuilt for aircraft, and the numbers
-- below are therefore AIR numbers: a cruise altitude instead of a lane, a
-- climb and a descent rate instead of a traffic speed, and a hover to release
-- at instead of a kerb to stop at.
--
-- WHY IT IS OURS AND NOT THE ENGINE'S. `Open77.vehicles.ai` is the platform's
-- native auto-drive and it answers `attachDriver`-family tasks for ground
-- cars -- AVs and the Basilisk are explicitly unsupported by it, and a
-- `driveTo` route is snapped to traffic lanes on the road surface anyway. The
-- honest primitive for an aircraft is the one `modules/ncpd/server/av.lua`
-- already flies the MaxTac insertion on: `Open77.vehicles.setTransform` per
-- tick, server-authoritative, revoking the physics lease and republishing the
-- canonical pose. This module is that pattern, aimed at a waypoint instead of
-- a street, and handed back to the pilot at the end instead of taken away.
--
-- THE FLIGHT IS THREE LEGS, and they are the ones a pilot would fly: climb to
-- the cruise altitude over where you are, cruise straight to the pin, descend
-- to a hover above it. The aircraft is FROZEN for the whole flight, which is
-- what makes it a ride and not a fight: a seated pilot's client claims an AV
-- and reports its own poses, and a frozen hull has those reports discarded
-- (kept, not punished -- the platform's own words), so the flight the server
-- publishes is the only flight there is. The moment the run ends the freeze
-- comes off and the platform hands the aircraft back to whoever is seated.
--
-- MANUAL CONTROL IS THE SAME KEY. There is no input-steals-the-wheel here
-- because the flight input lives in the client's raw keyboard path and no Lua
-- sees it: press the key again and the autopilot drops the freeze and stops
-- posing, instantly, wherever the aircraft happens to be. Leaving the seat,
-- losing the aircraft and this module stopping all do the same.
--
-- Server-only in the reading: the client needs nothing but `KEY` and `enabled`.

OPX.Config.MODULES.avdrive = {
	enabled = true,

	-- THE ONE KEY. `ID` is what a rebind is stored under and must not change
	-- between builds; `NAME` is a catalogue key the binding list translates;
	-- `DEFAULT` is the key it comes up on, or `false` for no key at all (the
	-- autopilot then exists only for whatever else raises the event). F10, not
	-- F6: F6 is the Trauma Team's dispatch board (`config/medical.lua`), and a
	-- Trauma medic flying the Trauma AV would open the board with every engage.
	KEY = { ID = 'opx.avdrive.toggle', NAME = 'avdrive.key.toggle', DEFAULT = 'F10' },

	-- How long one press may follow another, in milliseconds. The key is a
	-- toggle, and a key mashed five times a second would be five engage and
	-- cancel pairs a second, each a freeze flip and a scheduler arm. 0 for no
	-- window at all.
	COOLDOWN_MS = 400,

	-- ── the airframe's flight, in metres and metres per second ────────────────

	-- How high the cruise leg flies, ABOVE THE HIGHER of the take-off point and
	-- the destination. Measuring from the higher end is what keeps a cruise leg
	-- between two low points from being under the hill between them; a server
	-- with real mountains under the route raises this number rather than
	-- trusting the pin's own height to be the ground everywhere.
	CRUISE_ALTITUDE = 120.0,

	-- The cruise leg's speed. 22 m/s is the platform's own flight model's
	-- cruise ceiling, so an autopilot that outruns the manual flight ceiling
	-- would be an aircraft that leaves its pilot behind when they take over.
	CRUISE_SPEED = 22.0,

	-- Up and down, at the platform's own flight model rates: 5 m/s climb and
	-- 3.5 m/s descent, the same ceilings a manual pilot has. An autopilot
	-- outside the manual envelope is a flight the pilot could never have flown.
	CLIMB_SPEED = 5.0,
	DESCEND_SPEED = 3.5,

	-- How far above the destination the run ENDS and the pilot gets the
	-- controls back. A hover, not a landing: the ground under a map pin is not
	-- something the server can see, and setting an airframe down on a height it
	-- cannot measure is how a hull ends up inside a roof. The pilot lands.
	HOVER_HEIGHT = 8.0,

	-- ── the run itself ────────────────────────────────────────────────────────

	-- How often the hull is posed. The MaxTac insertion flies at 100 ms and it
	-- reads as one continuous flight; a longer cadence is a stuttering
	-- airframe and a shorter one is packets nobody sees.
	TICK_MS = 100,

	-- The farthest a waypoint may be, flat. Past this the request is refused
	-- BY NAME rather than accepted into a half-hour flight: an accidental pin
	-- across the Badlands is a mistake the player is told about, not a ride.
	MAX_RANGE = 4000.0,

	-- The longest one flight may take, in minutes. A run never outlives this:
	-- a waypoint that cannot be reached, a hull that will not pose and a pilot
	-- who walked away from the keyboard all end here rather than as a frozen
	-- airframe flying for ever.
	MAX_MINUTES = 20.0,
}
