--- Public electronic waste recovery feeds the city's existing material economy.
-- @author dop42
-- Positions reuse the surveyed mechanic pickup and sale in config/hauling.lua.
-- They mark public collection/sorting points, not a new claimed vanilla interior.
OPX.Config.MODULES.salvage = {
	enabled = true,
	DURATION_MS = 8000,
	COOLDOWN_SECONDS = 300,
	REACH = 2.5,
	SITES = {
		mechanic_recovery = {
			pickup = { x = -2456.16, y = -909.03, z = 9.26, bucket = 0 },
			bench = { x = -2043.13, y = -602.83, z = 2.84, bucket = 0 },
		},
	},
}
