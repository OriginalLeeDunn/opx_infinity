--- Fuel: the tank, what burns it, the stations that fill it and the jerry can.
-- @author dop42
--
-- THE OWNER: "clone ox_fuel, comprends-le, comprends comment l'adapter comme on
-- a fait avec ox_doorlock, puis implémente-le." So this is ox_fuel's config,
-- setting for setting, under the names a reader of ox's `config.lua` will look
-- for, upper-cased like every file here. Where a setting has no meaning on this
-- platform the block says so instead of pretending.
--
-- CYBERPUNK HAS NO FUEL. There is no `GetVehicleFuelLevel`, no consumption
-- rate multiplier and no petrol tank health in REDengine 2.31: a car drives
-- for ever. Fuel on Open77 is a field of the vehicle's replicated STATE BAG,
-- `fuel`, in LITRES -- the field and the unit the platform's own sample,
-- `open77_fuel`, burns (devkit `state-bags#the-fuel-sample-open77fuel`), so a
-- resource written against either one reads the other's tank. ox keeps a
-- PERCENTAGE in `Entity(vehicle).state.fuel`; the percentage here is the
-- litres over CAPACITY, and every export that speaks ox's language
-- (`GetFuel`, `SetFuel`) speaks it in percent.
--
-- THE SERVER BURNS THE TANK. ox's client reads GTA's own fuel level every
-- second and pushes it to the server; a client that pushed 100 was never
-- empty. Here the server walks every vehicle once per TICK_MS and burns it
-- from what the HOST knows -- the replicated speed the physics owner reports,
-- which the server already validates, AND how far the car really moved since
-- the last tick, whichever is more -- so a client reporting a standing car
-- while it drives still pays for the road. See `modules/fuel/shared/model.lua`.
--
-- WHEN `open77_fuel` RUNS TOO, this module stands down from BURNING (two burns
-- would empty a tank twice as fast) and keeps everything else -- stations,
-- jerry cans, persistence, the gauge -- writing the same `fuel` field through
-- that resource's own `set` export. See STAND_DOWN below.

OPX.Config.MODULES.fuel = {
	enabled = true,

	-- ── the tank ───────────────────────────────────────────────────────────

	-- Litres in a full tank, for every vehicle. ox has none -- a GTA tank is a
	-- percentage -- and `open77_fuel` has one number for every car, so one
	-- number here as well: a resource reading the bag of a car this module
	-- filled must not have to know which class it was.
	CAPACITY = 60.0,

	-- How full a tank the server has never seen starts, in percent: a staff
	-- spawn, a dealership car fresh off the lot, a car from before this module.
	-- `open77_fuel` starts them full; ox reads whatever GTA rolled. An owned car
	-- coming out of a garage keeps the litres it was put away with instead.
	INITIAL_PERCENT = 100,

	-- ── what burns it ──────────────────────────────────────────────────────

	CONSUMPTION = {
		-- How often the server burns every tank, in milliseconds. ox ticks every
		-- 1000 ms on the client; this is the same second, on the server.
		TICK_MS = 1000,

		-- `open77_fuel`'s own two numbers, under its names: litres per hundred
		-- kilometres while moving, litres per minute while the engine idles.
		LITRES_PER_100KM = 9.0,
		IDLE_LITRES_PER_MINUTE = 0.05,

		-- ox's `globalFuelConsumptionRate` (10.0 there) and `open77_fuel`'s
		-- `multiplier`: one factor over both numbers above. Night City is a few
		-- kilometres across, so a real-world 9 L/100 km would never empty a tank
		-- in an evening; at 12 a full 60 L tank lasts about 55 km -- half an hour
		-- of city driving, which is what ox's 10 gives in Los Santos.
		MULTIPLIER = 12.0,

		-- The speed past which nothing is believed, in km/h. A distance between
		-- two ticks longer than this allows is a teleport (a garage recall, a
		-- staff move) and burns nothing extra; a reported speed above it is
		-- clamped. Fast enough for any hypercar this city has.
		MAX_SPEED_KPH = 350,

		-- How the burn per kilometre bends with speed: { km/h, factor } pairs,
		-- read as straight lines between them and flat past both ends. ox has no
		-- curve because GTA's own fuel model reads the RPM; THE SERVER IS NOT
		-- SENT AN RPM (the snapshot carries speed, not engine speed -- `rpm` is
		-- client telemetry, which a server must not take as a reason to bill), so
		-- the curve is drawn on road speed: a crawl in traffic and a flat-out run
		-- both cost more per kilometre than a cruise.
		SPEED_CURVE = {
			{ 0, 1.3 }, { 50, 1.0 }, { 90, 0.9 }, { 130, 1.15 }, { 180, 1.5 }, { 250, 2.0 },
		},

		-- ox's `classUsage`, by TweakDB record. The record's class token -- the
		-- `standard2`, `sport1`, `utility4` in `Vehicle.v_<class>_<make>_<model>`
		-- -- is the closest thing Cyberpunk has to GTA's vehicle class. Read top
		-- to bottom, lower-cased, a plain substring of the record; the first row
		-- that matches wins and DEFAULT_USAGE is everything else.
		--
		-- USAGE = 0 IS ox's `DoesVehicleUseFuel` ANSWERING FALSE: the tank is never
		-- burned and no pump fills it. The AVs are 0 because cutting an engine in
		-- the air is a crash nobody asked for.
		CLASSES = {
			{ MATCH = 'vehicle.av_', USAGE = 0 },
			{ MATCH = 'vehicle.max_tac_av', USAGE = 0 },
			{ MATCH = '_sportbike', USAGE = 0.55 },
			{ MATCH = 'v_sport2_', USAGE = 1.5 },
			{ MATCH = 'v_sport1_', USAGE = 1.25 },
			{ MATCH = 'v_utility4_', USAGE = 1.6 },
			{ MATCH = 'v_standard3_', USAGE = 1.2 },
			{ MATCH = 'v_standard25_', USAGE = 1.1 },
			{ MATCH = 'v_standard2_', USAGE = 1.0 },
		},
		DEFAULT_USAGE = 1.0,

		-- ox's leak: `GetVehiclePetrolTankHealth < 700` loses 0.1 to 0.2 % more a
		-- second. Cyberpunk has ONE health pool and no tank (devkit
		-- `vehicles#health-is-one-pool`), so a car below BELOW_HEALTH (0..1) loses
		-- LITRES_PER_MINUTE more while its engine runs. 0 turns it off.
		LEAK = { BELOW_HEALTH = 0.25, LITRES_PER_MINUTE = 0.5 },
	},

	-- WHEN THE PLATFORM'S OWN `open77_fuel` IS RUNNING. It burns the same `fuel`
	-- field on every vehicle, from the same speed, and cuts the same engine at
	-- zero; two burns on one tank empty it twice as fast. true: this module stops
	-- burning while it runs and writes the tank through its `set` export, so its
	-- model and this one agree on every refuel. false: both burn -- only for an
	-- operator who has really configured `open77_fuel` to do nothing.
	STAND_DOWN = true,

	-- ── at a pump ──────────────────────────────────────────────────────────

	-- What a litre costs, in whole eddies (ox's `priceTick`, which charged per
	-- tick; here per litre, which is what a player reads on a pump). A station
	-- may name its own PRICE.
	PRICE_PER_LITRE = 4,

	-- How the player may pay: ox charges the cash item and lets a server swap
	-- the method (`setPaymentMethod`); here the pump asks, and both are offered.
	-- `EDDIES` is cash and `BANK` is the account, as in `config/shared.lua`.
	PAYMENT = { 'EDDIES', 'BANK' },

	-- ox's `refillValue` every `refillTick`: how fast a pump fills, in litres a
	-- second, and how often the server checks the session and moves the gauge.
	-- 1.2 L/s fills an empty 60 L tank in 50 seconds, ox's speed.
	REFILL = { LITRES_PER_SECOND = 1.2, TICK_MS = 500 },

	-- Metres a player may stand from a pump and still use it (measured by the
	-- server, with `config/shared.lua`'s REACH_SLACK added), and from the pump to
	-- the vehicle it fills -- ox's `#(vehicle - player) <= 3`.
	USE_RADIUS = 2.5,
	VEHICLE_REACH = 4.0,

	-- A refuel stops, and the litres already in are billed, when the vehicle
	-- moves more than MOVE_TOLERANCE metres from where it stood or goes faster
	-- than STOP_SPEED m/s, or when the player walks out of reach. ox's
	-- progress bar takes the player's movement; the server checks the CAR too,
	-- because somebody else may be sitting in it.
	MOVE_TOLERANCE = 1.0,
	STOP_SPEED = 0.5,

	-- The progress bar's own animation, a name the progress module's caller may
	-- pass (`modules/progress`): '' plays none. ox plays a gardener filling a
	-- can; this platform has no fuelling clip, so it ships none.
	ANIMATION = '',

	-- How often the client looks for the nearest pump, in milliseconds.
	SCAN_MS = 500,

	-- Floor between two fuel requests from one player, in milliseconds.
	REQUEST_MS = 800,

	-- The key that opens the pump (ox's `startfueling` on E). ID is what a
	-- rebind is stored under; DEFAULT = false declares no key and leaves the
	-- target eye's row. E is shared: away from a pump it does nothing.
	KEY = { ID = 'opx.fuel.use', NAME = 'fuel.key.use', DEFAULT = 'E' },

	-- ── the jerry can (ox's `petrolCan`) ───────────────────────────────────

	-- An inventory item, not a weapon: Cyberpunk has no petrol can to hold. Its
	-- metadata `durability` IS its fill, 0..100 -- ox writes the same number to
	-- `durability` and `ammo` -- and the bag draws it as the wear bar.
	CAN = {
		ENABLED = true,
		ITEM = 'petrolcan',
		-- Litres a full can holds.
		CAPACITY = 10.0,
		-- ox's `petrolCan.duration`: the bar to buy or refill one at a pump.
		DURATION_MS = 5000,
		-- ox's `petrolCan.price` and `refillPrice`, in whole eddies.
		PRICE = 100,
		REFILL_PRICE = 60,
		-- How fast a can pours into a tank, litres a second (ox's
		-- `durabilityTick` against `refillValue`).
		LITRES_PER_SECOND = 0.8,
		-- Metres from the player to the vehicle a can is poured into.
		REACH = 3.0,
	},

	-- ── the stations ───────────────────────────────────────────────────────
	--
	-- ox's `data/stations.lua` is Los Santos: a GTA coordinate is a point in the
	-- sea off Night City. Every station below is a NIGHT CITY PLACE WITH NO
	-- SURVEYED COORDINATE YET, and it is DISABLED until somebody stands at its
	-- pumps: a station whose centre or any pump has X, Y and Z all exactly zero
	-- is refused at boot with a line naming it -- no blip, no row, no prompt.
	-- `config/hauling.lua` tells the story of four lifts whose sample positions
	-- matched nothing for weeks; this is the same rule.
	--
	-- TO MAKE ONE REAL: stand at the forecourt and run `/opx.fuel.capture <key>`,
	-- which prints the station's centre line; then stand at each pump and run
	-- `/opx.fuel.capture <key> pump`, which prints one PUMPS row. Paste both in
	-- here and restart. Nothing is stored in the database: the file is the city.
	--
	--   key = {
	--       LABEL = 'Sunset Motel gas station',
	--       X = 0.0, Y = 0.0, Z = 0.0,       -- the centre: the blip
	--       BUCKET = 0,
	--       PRICE = 5,                       -- optional, else PRICE_PER_LITRE
	--       PUMPS = { { X = 0.0, Y = 0.0, Z = 0.0 }, ... },
	--   },
	STATIONS = {
		badlands_sunset = {
			LABEL = 'Sunset Motel gas station',
			X = 0.0, Y = 0.0, Z = 0.0,
			PUMPS = { { X = 0.0, Y = 0.0, Z = 0.0 } },
		},
		badlands_rocky_ridge = {
			LABEL = 'Rocky Ridge gas station',
			X = 0.0, Y = 0.0, Z = 0.0,
			PUMPS = { { X = 0.0, Y = 0.0, Z = 0.0 } },
		},
		santo_domingo_arroyo = {
			LABEL = 'Arroyo gas station',
			X = 0.0, Y = 0.0, Z = 0.0,
			PUMPS = { { X = 0.0, Y = 0.0, Z = 0.0 } },
		},
		watson_northside = {
			LABEL = 'Northside gas station',
			X = 0.0, Y = 0.0, Z = 0.0,
			PUMPS = { { X = 0.0, Y = 0.0, Z = 0.0 } },
		},
		heywood_wellsprings = {
			LABEL = 'Wellsprings gas station',
			X = 0.0, Y = 0.0, Z = 0.0,
			PUMPS = { { X = 0.0, Y = 0.0, Z = 0.0 } },
		},
	},

	-- Most pumps one station may hold: the target eye takes 32 spheres a row.
	MAX_PUMPS = 16,

	-- ── staff ──────────────────────────────────────────────────────────────
	--
	--   command.opx.fuel.set       /opx.fuel.set <vehicleId|near> <0-100>
	--   command.opx.fuel.capture   /opx.fuel.capture <station> [pump] [label]
	--   command.opx.fuel.stations  /opx.fuel.stations
	--
	-- A typed vehicle id must carry the operator or stand within STAFF_REACH of
	-- them, unless they hold `opx.admin.vehicle.anywhere` (the staff module's
	-- right of the same meaning); `near` is the seat, else the nearest vehicle
	-- within STAFF_REACH in the operator's bucket.
	STAFF_REACH = 100.0,
}
