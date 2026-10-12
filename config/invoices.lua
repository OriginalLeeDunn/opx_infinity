--- Invoices: who may bill whom, how much, and where the eddies land.
-- @author dop42
--
-- NIGHT CITY RUNS ON PAPER NOBODY PRINTS. A Delamain driver at the end of a
-- ride, a bartender closing a tab at the Afterlife, a ripperdoc after the
-- stitches: each one hands the customer a bill, the customer's agent pings
-- ACCEPT or REFUSE, and the eddies leave their bank. This file is the operator's
-- half of that: which jobs may bill (`JOBS`), how much one bill may ask, what
-- share the employee keeps and which company account takes the rest.
--
-- THE COMPANY ACCOUNT IS THE `accounts` CONTRACT (module `business`). When it
-- runs, a bill raised by a job with `ACCOUNT = true` pays the employee their
-- `CUT_PCT` and deposits the rest into that job's treasury. When it does not
-- run, the whole bill goes to the employee -- said once at boot -- so a server
-- without `business` still has working bills.
--
-- Read by both halves (shared): the client reads `JOBS` to decide whether to
-- draw the "Send a bill" row and to show the ceiling on the form, and the
-- server re-derives every one of those decisions from the character roster.

OPX.Config.MODULES.invoices = {
	enabled = true,

	-- ── paying ──────────────────────────────────────────────────────────────

	-- The account a bill is taken from, and the one the payouts go to. A bank
	-- transfer, because that is what a bill is in 2077.
	MONEY_TYPE = 'BANK',

	-- Tried when MONEY_TYPE cannot cover the bill: the customer's cash, so
	-- somebody with eddies in their pocket is not filed as a debtor. `false`
	-- turns it off (bank or nothing).
	FALLBACK_TYPE = 'EDDIES',

	-- The employee's share when a caller of the contract gives none, in percent.
	-- A job's own `CUT_PCT` below wins for a bill raised from the eye.
	DEFAULT_CUT_PCT = 10,

	-- ── bounds ──────────────────────────────────────────────────────────────

	-- The most ANY bill may ask, whoever raises it (the contract and the creator
	-- export included). A job's `MAX_AMOUNT` is a ceiling under this one.
	MAX_AMOUNT = 100000,

	-- Characters in a bill's reason ("Ride Japantown -> Watson", "3x Johnny
	-- Silverhand"). Longer is cut.
	REASON_MAX = 64,

	-- Metres between the employee and the customer for a bill raised from the
	-- eye or `/opx.bill`. The eye's own reach is shorter; this is the server's.
	REACH = 5.0,

	-- Seconds the customer has to answer the prompt. Unanswered is EXPIRED, and
	-- nothing is filed.
	ANSWER_TTL_S = 45,

	-- Seconds an accepted bill that could not be paid stays on the customer's
	-- tab (`/opx.bills`) before it lapses. 0 keeps it until it is paid or the
	-- employee withdraws it.
	UNPAID_TTL_S = 7 * 24 * 3600,

	-- Bills on one customer's tab at once (accepted, not yet paid). A customer
	-- at the cap is refused new bills until they pay one.
	MAX_UNPAID = 10,

	-- Milliseconds between two bills raised by one employee.
	ISSUE_COOLDOWN_MS = 3000,

	-- ── commands ────────────────────────────────────────────────────────────

	COMMANDS = {
		-- `/opx.bill <player id> <amount> <reason...>`: the eye row, typed.
		BILL = 'opx.bill',
		-- `/opx.bills`: what I owe, what I am owed. Pay or withdraw from there.
		BILLS = 'opx.bills',
	},

	-- ── who may bill ────────────────────────────────────────────────────────
	--
	-- One entry per job (the names of `config/character.lua` JOBS):
	--   LABEL       the name on the bill (lore, never translated)
	--   MIN_GRADE   the lowest grade that may bill
	--   ON_DUTY     whether the employee must be clocked in
	--   MAX_AMOUNT  the ceiling of one bill from this job (under MAX_AMOUNT)
	--   CUT_PCT     the employee's share when the rest goes to the company
	--   ACCOUNT     true: the rest goes to this job's company account
	--               (`accounts` kind 'job', key = the job name); false: the
	--               whole bill is the employee's (a freelancer's bill)
	--   SOURCE      the word the bus carries as `source` (defaults to the job)
	--
	-- NCPD IS NOT HERE ON PURPOSE. A citation is a fine, not a service: it has
	-- no consent prompt and belongs to the police module when it lands.
	JOBS = {
		cabbie = {
			LABEL = 'Delamain Cab Co.',
			MIN_GRADE = 0, ON_DUTY = true,
			MAX_AMOUNT = 2500, CUT_PCT = 30, ACCOUNT = true, SOURCE = 'taxi',
		},
		bartender = {
			LABEL = 'Afterlife Bar',
			MIN_GRADE = 0, ON_DUTY = true,
			MAX_AMOUNT = 5000, CUT_PCT = 15, ACCOUNT = true, SOURCE = 'bar',
		},
		trauma = {
			LABEL = 'Trauma Team International',
			MIN_GRADE = 1, ON_DUTY = true,
			MAX_AMOUNT = 50000, CUT_PCT = 10, ACCOUNT = true, SOURCE = 'medical',
		},
		ripperdoc = {
			LABEL = 'Ripperdoc Clinic',
			MIN_GRADE = 0, ON_DUTY = true,
			MAX_AMOUNT = 50000, CUT_PCT = 40, ACCOUNT = true, SOURCE = 'ripperdoc',
		},
		fixer = {
			LABEL = 'Fixer Services',
			MIN_GRADE = 1, ON_DUTY = false,
			MAX_AMOUNT = 20000, CUT_PCT = 100, ACCOUNT = false, SOURCE = 'fixer',
		},
	},
}
