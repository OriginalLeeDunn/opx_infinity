--- Survey the cloth centre at BALL CENTRE height; no floor-height offsets.
-- @author dop42
OPX.Config.MODULES.pool = {
	enabled = true,
	-- Choose ONE practice table. The VPS test uses el_coyote_cojo.
	-- Presets are placement measurements from Darkpickle's nc_pool data, not
	-- copied gameplay code. Original floor Z + documented 0.843 m ball-centre
	-- offset; inherited measurements still need visual alignment on this build.
	TABLE = { enabled = false, preset = 'el_coyote_cojo' },
	PRESETS = {
		el_coyote_cojo = { label = 'El Coyote Cojo', x = -1247.944, y = -995.978, z = 13.263, yaw = 99.85, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		glen_apartment = { label = 'The Glen Apartment', x = -1518.22, y = -983.58, z = 87.793, yaw = -90, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		glen_gang_east = { label = 'Glen Pool Hall East', x = -1525.497, y = -1107.560, z = 14.248, yaw = -180, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		glen_gang_north = { label = 'Glen Pool Hall North', x = -1528.608, y = -1099.506, z = 14.248, yaw = 90, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		glen_gang_west = { label = 'Glen Pool Hall West', x = -1530.345, y = -1107.377, z = 14.248, yaw = -90, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		heywood_gig_bar_north = { label = 'Heywood Bar North', x = -929.667, y = -219.99, z = 7.552, yaw = 56.02, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		heywood_gig_bar_south = { label = 'Heywood Bar South', x = -925.004, y = -223.584, z = 7.552, yaw = 54.02, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		hooh_rec_room = { label = 'Ho-Oh Rec Room', x = -1033.104, y = 1334.094, z = 14.124, yaw = 0.31, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		north_oak_casino_main = { label = 'North Oak Casino', x = 1003.637, y = 1494.385, z = 246.863, yaw = -178.49, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
		westbrook_luxury_apartment = { label = 'Luxury Apartment', x = 16.227, y = -0.07, z = 135.687, yaw = -31.88, bucket = 0, halfLength = 1.4, halfWidth = 0.68 },
	},
	SENSITIVITY = 0.0018, -- radians per physical mouse count
	CHARGE_SECONDS = 1.8,
	OVERVIEW_HEIGHT = 1.65, -- metres above ball centres for the side camera
	SOLO_SHOTS = 10,
	DUEL_TARGET = 5,
	AUDIO_VOLUME = 0.65, -- 0 mutes the recorded table contacts
	AIM_GUIDE = true, -- straight line to the first ball/cushion; no bounce prediction
	-- opx_pool_assets reserves these three native recreation aliases globally.
	-- Do not use them as tents, sleeping bags or gym equipment on this world.
	MODELS = {
		cue = 'recreation.tent',
		object = 'recreation.sleeping_bag', -- retained legacy profile field
		-- Object balls use the fifteen vanilla ball_c..ball_q meshes by default.
		-- Optional objects = { ... } must name exactly fifteen distinct models.
		stick = 'recreation.gym_equipment',
		-- Host-specific heading/pivot calibration, in degrees/metres.
		stickYaw = 0, stickOffset = 0.7,
	},
}
