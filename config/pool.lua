--- Survey the cloth centre at BALL CENTRE height; no floor-height offsets.
-- @author dop42
OPX.Config.MODULES.pool = {
	enabled = true,
	-- One table in this prototype. Set enabled=true only after model validation.
	TABLE = { enabled = false, x = 0, y = 0, z = 0, yaw = 0, bucket = 0,
		label = 'Practice table', halfLength = 1.27, halfWidth = 0.635 },
	SENSITIVITY = 0.0025, -- radians per physical mouse count
	CHARGE_SECONDS = 2.4,
	-- Raw meshes found in Open77.data; discoverable, NOT individually validated.
	-- Supply authored, spawn-safe hosts here if the runtime cannot render them.
	MODELS = {
		cue = 'base\\environment\\decoration\\recreation\\sports\\ball\\ball_b_billiard.mesh',
		object = 'base\\environment\\decoration\\recreation\\sports\\ball\\ball_m_billiard.mesh',
		stick = 'base\\environment\\decoration\\recreation\\sports\\billiard_stick\\billiard_stick_a.mesh',
		-- Host-specific heading/pivot calibration, in degrees/metres.
		stickYaw = 0, stickOffset = 0.7,
	},
}
