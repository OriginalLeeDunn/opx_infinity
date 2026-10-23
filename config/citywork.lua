--- Night City service work: paid shard runs and replacement relay modules.
-- @author dop42
-- Every position below is reused from surveyed hauling pickups/drop-offs.
-- These are resource-owned service points, not claims about vanilla devices.
OPX.Config.MODULES.citywork = {
	enabled = true,
	SELF_ENROL = true,
	REACH = 3.0,
	DISPATCH = { x = -2456.16, y = -909.03, z = 9.26, bucket = 0 },
	MAX_OPEN = 6,
	MIN_TRAVEL_S = 30,
	HANDOVER_MS = 4000,
	SERVICE_MS = 12000,
	COMMAND = 'citywork',
	ROUTES = {
		workshop = { x = -2043.13, y = -602.83, z = 2.84, bucket = 0 },
		yard = { x = -2420.51, y = 465.42, z = 11.24, bucket = 0 },
		market = { x = -1436.29, y = -179.89, z = 8.18, bucket = 0 },
	},
	-- Professionals must be on duty in the corresponding PRIMARY job.
	-- Freelance work is open to all; the global contracts mint cap still applies.
	PAY = {
		courier = { freelance = 160, professional = 220, perGrade = 20 },
		technician = { freelance = 180, professional = 250, perGrade = 25 },
	},
}
