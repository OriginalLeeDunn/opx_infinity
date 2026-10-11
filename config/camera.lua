--- The player's own third-person camera: the styles offered on ALT, on yourself.
-- @author dop42
--
-- Each style is a framing the platform's own third-person rig draws -- this
-- module only asks for it (`Open77.camera.configureThirdPerson`, client
-- op77.78) and never moves a camera itself, so there is no per-frame loop and
-- the blend between two styles is the rig's, at `TRANSITION` seconds.
--
-- Every number below is held to the platform's own bounds before it is sent,
-- and a style with one value out of range is dropped whole with a line in the
-- player's log rather than half-applied:
--
--   DISTANCE      boom length, 0.8 to 8 metres
--   OFFSET        { X, Y, Z }: right, forward and up of the view, in metres.
--                 X -2..2, Y -1..1, Z -1.5..3
--   FOV           40 to 110 degrees, or 0 to keep the game's own lens
--   TRANSITION    0 to 3 seconds
--   RUN_SPEED     0.5 to 15 m/s, where RUN_FOV starts
--   RUN_FOV, SPRINT_FOV   40 to 110, or 0 for none
--
-- HIP is on foot, AIM is while aiming, EXPLORE is the relaxed framing; a style
-- that names none of them keeps the base preset's. BASE is the platform preset
-- a style starts from: 'classic', 'shoulder' or 'centered'.

OPX.Config.MODULES.camera = {
	enabled = true,

	-- The style a player starts on before they have chosen one. 'default' is
	-- the game's own camera, untouched: a server that ships this module changes
	-- nothing until a player asks.
	DEFAULT = 'default',

	-- The order here is the order on the eye.
	STYLES = {
		-- Over the right shoulder, upper body framed, the lens widening as the
		-- player runs and sprints. The shoulder swaps from its own row.
		{
			ID = 'shoulder',
			BASE = 'shoulder',
			TRANSITION = 0.35,
			RUN_SPEED = 2.5, RUN_FOV = 72, SPRINT_FOV = 78,
		},

		-- Tighter and lower: the character fills more of the frame.
		{
			ID = 'close',
			BASE = 'shoulder',
			HIP = { DISTANCE = 1.25, OFFSET = { X = 0.5, Y = 0, Z = -0.08 }, FOV = 60 },
			EXPLORE = { DISTANCE = 1.4, OFFSET = { X = 0.45, Y = 0, Z = -0.05 }, FOV = 62 },
			AIM = { DISTANCE = 1.0, OFFSET = { X = 0.55, Y = 0.05, Z = -0.04 }, FOV = 52 },
			TRANSITION = 0.3,
			RUN_SPEED = 2.5, RUN_FOV = 66, SPRINT_FOV = 72,
		},

		-- Straight behind, no lateral bias; aiming still steps aside so the
		-- character never covers the reticle.
		{
			ID = 'centered',
			BASE = 'centered',
			TRANSITION = 0.35,
			RUN_SPEED = 2.5, RUN_FOV = 70, SPRINT_FOV = 76,
		},

		-- Far and slightly high, a narrower lens: the street around the
		-- player, for walking and for screenshots.
		{
			ID = 'cinematic',
			BASE = 'classic',
			HIP = { DISTANCE = 4.0, OFFSET = { X = 0.3, Y = 0, Z = 0.35 }, FOV = 58 },
			EXPLORE = { DISTANCE = 4.6, OFFSET = { X = 0.3, Y = 0, Z = 0.45 }, FOV = 55 },
			AIM = { DISTANCE = 1.6, OFFSET = { X = 0.6, Y = 0.05, Z = -0.04 }, FOV = 55 },
			TRANSITION = 0.6,
			RUN_SPEED = 2.5, RUN_FOV = 62, SPRINT_FOV = 68,
		},
	},
}
