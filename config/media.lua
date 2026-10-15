--- Media: the newsrooms of Night City -- N54 News, WNS and the street's own
--- screamsheet -- their reporters, their editor desks and the breaking news.
-- @author dop42
--
-- SEVERAL NETWORKS IN ONE FILE, EACH ON ITS OWN. A network is a newsroom: its
-- name on the air, its chat tag, the company account its desk pays from and the
-- DESKS where reporters sell their photos and stories. A network the validator
-- refuses is refused ALONE, with a line at boot naming it; the others keep
-- broadcasting.
--
-- ONE JOB, MANY NEWSROOMS. Every journalist holds the `reporter` job of
-- config/character.lua (Stringer 0 / Reporter 1 / Anchor 2 / Editor-in-chief 3).
-- WHICH newsroom they work for is a line on their character (metadata
-- `METADATA`), set by an Editor-in-chief with `/pressnet <id> <network>` or by
-- staff with `/opx.media.assign`; nobody assigned works for DEFAULT_NETWORK.
-- A Stringer is a freelancer and may sell to ANY desk; staff sell to their own.
--
-- POSITIONS 0, 0, 0 ARE "NOT SURVEYED YET". A desk at three exact zeros is
-- DISABLED -- no eye row, no sale -- and named at boot. Stand at the editor's
-- desk and run `/opx.media.capture <network> <desk>`, which prints the line to
-- paste here. `/opx.media.desks` lists what is open, disabled and refused.

OPX.Config.MODULES.media = {
	enabled = true,

	-- ── who ────────────────────────────────────────────────────────────────

	JOB = 'reporter',
	-- Whether the reporter must be on duty to shoot, write, sell and air.
	ON_DUTY = true,
	-- The character metadata key holding `{ network = '<key>' }`.
	METADATA = 'press',
	-- Where somebody nobody assigned works.
	DEFAULT_NETWORK = 'n54',
	-- The grade an Editor-in-chief needs to move a reporter to their newsroom.
	ASSIGN_GRADE = 3,
	-- The grades that sell to any desk, not only their own newsroom's.
	FREELANCE_GRADES = { 0 },
	-- The money every payment is made in.
	CURRENCY = 'BANK',

	-- ── the newsrooms ──────────────────────────────────────────────────────
	--
	--   key = {
	--     LABEL, TAG,                  -- on the air / in chat
	--     BROADCAST = true,            -- may it break news to the whole city
	--     ACCOUNT = { KIND = 'job', KEY = 'reporter' },  -- the `accounts` treasury it pays from
	--     DESKS = { { KEY, LABEL, X, Y, Z, RADIUS, BUCKET, RATE } },
	--   }
	--
	-- RATE multiplies every price a desk pays. Without the `accounts` contract
	-- the desk mints the money, capped per network by SALES.MINT_PER_HOUR.
	NETWORKS = {
		-- Network 54: the city's biggest channel, Corpo Plaza tower.
		n54 = {
			LABEL = 'N54 News', TAG = 'N54',
			BROADCAST = true,
			ACCOUNT = { KIND = 'job', KEY = 'reporter' },
			DESKS = {
				{ KEY = 'corpo_plaza_newsroom', LABEL = 'N54 newsroom, Corpo Plaza',
					X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0, RATE = 1.0 },
			},
		},
		-- World News Service: the wire service, a bureau in Japantown.
		wns = {
			LABEL = 'WNS', TAG = 'WNS',
			BROADCAST = true,
			ACCOUNT = { KIND = 'job', KEY = 'reporter' },
			DESKS = {
				{ KEY = 'japantown_bureau', LABEL = 'WNS bureau, Japantown',
					X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0, RATE = 1.1 },
			},
		},
		-- The indie screamsheet, printed in a Kabuki back room. Pays less, asks
		-- no questions, and is on the air too.
		screamsheet = {
			LABEL = 'Night City Screamsheet', TAG = 'SCREAM',
			BROADCAST = true,
			ACCOUNT = { KIND = 'job', KEY = 'reporter' },
			DESKS = {
				{ KEY = 'kabuki_backroom', LABEL = 'Screamsheet press, Kabuki',
					X = 0.0, Y = 0.0, Z = 0.0, RADIUS = 2.0, BUCKET = 0, RATE = 0.8 },
			},
		},
	},

	-- ── breaking news ──────────────────────────────────────────────────────
	--
	-- `/breaking` (or `/breaking <headline> | <text>`): drawn on the runtime's
	-- own overlay exactly like a staff announcement, with the two stingers of
	-- the receiving client's own config, and a chat line.
	BROADCAST = {
		MIN_GRADE = 2,
		HEADLINE = { MIN = 6, MAX = 80 },
		TEXT = { MIN = 0, MAX = 240 },
		DURATION_MS = 14000,
		CHAT = true,
		-- Least time between two breaks of one newsroom, and between any two at
		-- all (two newsrooms must not take turns on every screen).
		NETWORK_COOLDOWN_MS = 300000,
		GLOBAL_COOLDOWN_MS = 60000,
		MAX_PER_HOUR = 6,
		-- Bare file names under ui/public/audio (web/audio once built); '' none.
		STINGER = { OPEN = 'announce-open.mp3', CLOSE = 'announce-close.mp3', VOLUME = 0.7 },
		-- How many breaks `/news` reads back.
		FEED = 10,
	},

	-- ── field photos ───────────────────────────────────────────────────────
	--
	-- A photo is the item `PHOTO_ITEM` carrying where, when, who shot it and
	-- how many people were in frame. When UPLOAD_URL is set the server also
	-- asks the reporter's client for a real screenshot of its game view
	-- (`Open77.players.requestScreenshot`, permission `players.screenshot`),
	-- POSTed by that client to the URL -- an image host or a webhook the
	-- server owner trusts. '' keeps the photo a metadata record only.
	PHOTO = {
		MIN_GRADE = 0,
		DURATION_MS = 2500,
		-- How far the reporter may move during the bar.
		MAX_DRIFT = 3.0,
		MAX_PER_HOUR = 12,
		-- Other players within this many metres count as the crowd in frame.
		CROWD_RADIUS = 25.0,
		UPLOAD_URL = '',
		UPLOAD = { FORMAT = 'jpeg', QUALITY = 70, SCALE = 0.5, TIMEOUT_MS = 20000 },
		ANIMATION = '',
	},

	-- ── stories ────────────────────────────────────────────────────────────
	--
	-- `/story` opens a form; the story is the item `STORY_ITEM` with its
	-- headline and body on it, ready for the desk.
	STORY = {
		MIN_GRADE = 0,
		HEADLINE = { MIN = 8, MAX = 80 },
		BODY = { MIN = 60, MAX = 480 },
		COOLDOWN_MS = 300000,
		MAX_PER_HOUR = 6,
	},

	-- ── the desk ───────────────────────────────────────────────────────────
	--
	-- What a desk pays. A photo: BASE + CROWD_BONUS per head in frame (up to
	-- CROWD_MAX), x UPLOADED_MULT when a real picture went up. A story: BASE +
	-- PER_WORD per word (up to WORD_CAP). Both lose value with age: full price
	-- for FRESH_S, then down to STALE_MULT at STALE_S. A photo shot within
	-- REPEAT_RADIUS of one the same desk bought in the last REPEAT_S is old
	-- news and pays REPEAT_MULT. Only the author sells their own work.
	SALES = {
		PHOTO = { BASE = 120, CROWD_BONUS = 25, CROWD_MAX = 6, UPLOADED_MULT = 1.25 },
		STORY = { BASE = 150, PER_WORD = 3, WORD_CAP = 120 },
		FRESH_S = 1800,
		STALE_S = 21600,
		STALE_MULT = 0.25,
		REPEAT_RADIUS = 40.0,
		REPEAT_S = 3600,
		REPEAT_MULT = 0.3,
		-- Most one reporter is paid an hour, and most a newsroom without the
		-- `accounts` contract mints an hour.
		SELLER_CAP_PER_HOUR = 4000,
		MINT_PER_HOUR = 12000,
	},

	-- ── the tips line ──────────────────────────────────────────────────────
	--
	-- `/tip <text>`: anybody, anonymously, to every reporter on duty. The
	-- sender's identity is in the server's audit journal and nowhere else.
	TIPS = {
		MIN = 10,
		MAX = 240,
		COOLDOWN_MS = 60000,
		-- How many tips `/tips` reads back to a reporter coming on duty.
		KEEP = 20,
		KEEP_S = 7200,
	},

	-- ── the kit ────────────────────────────────────────────────────────────
	--
	-- `/presskit`: an on-duty reporter draws a press pass (their own, with
	-- their name and newsroom) and a camera, whichever is missing.
	KIT = { COOLDOWN_MS = 600000, CAMERA_GRADE = 0 },
	-- Showing the pass (use it from the bag) tells everybody this close.
	PASS = { SHOW_RADIUS = 3.0 },

	ITEMS = {
		PASS = { NAME = 'press_pass', LABEL = 'Press pass', WEIGHT = 10,
			DESCRIPTION = 'A laminated press accreditation. Use it to show it.' },
		CAMERA = { NAME = 'press_camera', LABEL = 'Press camera', WEIGHT = 900,
			DESCRIPTION = 'A Kiroshi-optics news camera. Use it to take a photo.' },
		PHOTO = { NAME = 'press_photo', LABEL = 'Press photo', WEIGHT = 5,
			DESCRIPTION = 'A field photo with its time, place and byline.' },
		STORY = { NAME = 'press_story', LABEL = 'Story draft', WEIGHT = 5,
			DESCRIPTION = 'A filed story, ready for the editor desk.' },
	},

	-- Floor between two requests from one player, in milliseconds.
	REQUEST_MS = 800,
}
