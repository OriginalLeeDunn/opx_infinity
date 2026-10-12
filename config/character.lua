--- Characters, money, groups and the definitions behind them.
-- @author dop42
--
-- The module reads this as `M.Settings`. It ships to every client in the signed
-- resource set, so nothing secret belongs here -- an entry in SLOTS_BY_USER names
-- an account id and travels with it.
--
-- JOBS and GANGS are definitions, not settings: the key is what is
-- written on a character's row, so rows are added freely and NEVER renamed --
-- renaming one renames what players already own. Grades are indexed from 0 and
-- contiguous. `none` is the absence of a gang, kept as an entry so that nothing
-- has to handle nil. `unemployed` has `defaultDuty = true`: there is nowhere to
-- clock in, so its small wage asks for no shift.

OPX.Config.MODULES.character = {
	enabled = true,

	-- How often a loaded character is written back. Saving only on logout is lossy
	-- in exactly the cases people care about -- a crash, a power cut, a server
	-- killed rather than stopped -- so this is what bounds how much anyone loses.
	AUTOSAVE_SECONDS = 300,

	-- Milliseconds between two heading reports from a client. Not authoritative:
	-- only the heading is kept, and x, y and z are re-derived on the server.
	HEADING_REPORT_MS = 5000,

	MONEY = {
		-- What a NEW character is endowed with, per money type of
		-- `OPX.Config.SHARED.MONEY.TYPES`. A missing type on an existing character
		-- loads as zero, never as this: this is a new-character endowment.
		STARTING = {
			EDDIES = 500,
			BANK = 5000,
		},

		-- Minutes between paychecks; 0 turns them off without touching a job
		-- definition, so switching them back on resumes the same salaries.
		PAYCHECK_MINUTES = 10,
		PAYCHECK_REQUIRES_DUTY = true,

		-- Unknown falls back to SHARED.MONEY.DEFAULT, reported once at start.
		PAYCHECK_TYPE = 'BANK',
	},

	CHARACTERS = {
		-- HOW `opx.select` MOVES AN ACCOUNT ONTO ANOTHER CHARACTER. Two values,
		-- and no third:
		--
		--   'relog'      take the other character here, in the world. The one
		--                being left is saved and waited on, the other is loaded
		--                and placed, and the client reloads the body family, the
		--                face and the clothes onto the puppet it already has. No
		--                disconnect, no loading screen, no re-queue.
		--   'reconnect'  move the lock and end the session, so the next connection
		--                arrives on the new character. What this did before the
		--                setting existed.
		--
		-- A REFUSED RELOG FALLS BACK TO THE RECONNECT rather than leaving the
		-- player on the character they asked to leave. The save of the outgoing
		-- character is the one thing that can refuse it -- the switch is abandoned
		-- rather than losing what was not written -- and the player is then
		-- disconnected, which saves it again on the way out.
		--
		-- `opx.create` IS NOT COVERED BY THIS AND CANNOT BE. A new character has
		-- no body, so it needs the game's own character creator, and that creator
		-- belongs to the game's MAIN MENU: it is drawn for the character-bootstrap
		-- transaction, which is spent before the world exists. Resetting the
		-- bootstrap mid-session was measured in game on 2026-09-17 (2.31.13+op77.81)
		-- -- the request is granted, the phase moves on, and NO CREATOR IS EVER
		-- DRAWN, because the game is no longer in its main menu. The shell takes
		-- the world down for a bootstrap it now expects answered and the player
		-- sits under the loading cover until they kill the connection. The
		-- platform has a disconnect native and no reconnect, so there is nothing
		-- softer to offer. `opx.create` ends the session whatever is written here.
		--
		-- WHY 'relog' IS NOT OBVIOUSLY RIGHT, and is a setting rather than the
		-- only behaviour: a switch in the world is a save, a load, a kill-respawn
		-- placement and -- when the two characters are not the same body family --
		-- a covered body reload, all while the player is incarnated and other
		-- players can see them. 'reconnect' does all of that behind a join, where
		-- it has always run. If a switch ever leaves somebody in the wrong body or
		-- under a cover that does not lift, this is the one word to change back.
		--
		-- An unknown value is REFUSED WITH A LINE IN THE JOURNAL and falls back to
		-- 'reconnect'.
		SWITCH = 'relog',

		DEFAULT_SLOTS = 3,

		-- Per-account overrides, keyed by user id.
		SLOTS_BY_USER = {},

		-- Lifetime rows per account, not characters: a soft delete keeps the row
		-- while the slot is freed, so create-delete-create writes a new row every
		-- time. Keep it well above DEFAULT_SLOTS.
		ROW_CEILING = 60,

		-- Extra { TABLE, COLUMN } pairs whose rows really go when a character is
		-- deleted. FOR TABLES THIS RUNTIME DOES NOT OWN -- another resource's, or
		-- one added by hand. Every table a module in here owns is purged by that
		-- module, on `character:deleted`, so nothing belongs on this list twice.
		--
		-- AN ON DELETE CASCADE FOREIGN KEY DOES **NOT** EXCUSE AN ENTRY, which is
		-- what this comment used to say and it was wrong. A character delete is a
		-- SOFT delete -- `deleted_at` is stamped and the row stays, which is what
		-- frees the slot without losing the history -- and a cascade fires for a
		-- DELETE and never for an UPDATE. So the foreign keys in this schema are
		-- all correct and not one of them has ever run on a player deleting a
		-- character. If a table out there has to be emptied, name it here.
		CASCADE_TABLES = {},

		-- Whether a player may delete their OWN character with `/opx.delete`.
		--
		-- Staff are never affected by this: the staff menu deletes through the ACL
		-- and answers to that instead. This is only the self-service door, and it
		-- is a door worth being able to shut -- a delete takes the character's
		-- clothes, needs, containers and cars with it, and there is no undo. On a
		-- roleplay server that is a ticket for an admin; on a test server it is
		-- how you get a clean slate in one command.
		--
		-- False refuses the command with `character.deleteNotAllowed` and writes
		-- nothing. It does not hide the command: a player who tries is told no,
		-- rather than left wondering whether it silently worked.
		SELF_DELETE = true,

		-- Bounds on each half of a character name, in characters and not bytes.
		NAME = { MIN = 2, MAX = 32 },
	},

	PLAYER = {
		-- Initial metadata. The module itself reads health and armor.
		--
		-- Health is stored in POINTS, so a new character starts with the pool
		-- this server configures rather than a literal. `config/shared.lua` is a
		-- shared script and the manifest loads it before this one, so the value
		-- is there to read; the `or 100` is the engine's own default, for a
		-- config an operator has emptied.
		STARTING_METADATA = {
			health = (OPX.Config.SHARED.HEALTH or {}).MAX or 100,
			armor = 0,
			isDead = false,
			inLastStand = false,
		},

		DEFAULT_JOB = 'unemployed',
		DEFAULT_GANG = 'none',
	},

	-- Where a character with no stored position is placed -- which is EVERY brand
	-- new character, since a row is created before its player has stood anywhere.
	-- Nobody is placed here until SET is true; until then a new character is left
	-- wherever the pristine save put them, which on 2026-09-17 was a spot that
	-- killed them on arrival and took the identity form down with them.
	--
	-- Run `opx.here` in game to print this block for the spot you are standing on.
	DEFAULT_SPAWN = {
		SET = true,
		X = -1600.137451,
		Y = -2340.758057,
		Z = 43.250328,
		HEADING = 139.650009,
	},

	JOBS = {
		unemployed = {
			label = 'Unemployed',
			defaultDuty = true,
			offDutyPay = true,
			grades = {
				[0] = { name = 'Freelancer', payment = 25 },
			},
		},

		merc = {
			label = 'Mercenary',
			type = 'merc',
			defaultDuty = true,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Street Merc', payment = 120 },
				[1] = { name = 'Solo', payment = 220 },
				[2] = { name = 'Edgerunner', payment = 380 },
				[3] = { name = 'Legend', payment = 600, isBoss = true },
			},
		},

		fixer = {
			label = 'Fixer',
			type = 'fixer',
			defaultDuty = true,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Runner', payment = 100 },
				[1] = { name = 'Broker', payment = 260 },
				[2] = { name = 'Fixer', payment = 500, isBoss = true, bankAuth = true },
			},
		},

		ripperdoc = {
			label = 'Ripperdoc',
			type = 'medical',
			defaultDuty = false,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Apprentice', payment = 140 },
				[1] = { name = 'Ripperdoc', payment = 300 },
				[2] = { name = 'Chrome Surgeon', payment = 520, isBoss = true, bankAuth = true },
			},
		},

		netrunner = {
			label = 'Netrunner',
			type = 'tech',
			defaultDuty = false,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Script Kiddie', payment = 110 },
				[1] = { name = 'Netrunner', payment = 280 },
				[2] = { name = 'Blackwall Diver', payment = 540, isBoss = true },
			},
		},

		trauma = {
			label = 'Trauma Team',
			type = 'medical',
			defaultDuty = false,
			offDutyPay = true,
			grades = {
				[0] = { name = 'Paramedic', payment = 180 },
				[1] = { name = 'Trauma Specialist', payment = 320 },
				[2] = { name = 'Team Lead', payment = 480 },
				[3] = { name = 'Regional Director', payment = 700, isBoss = true, bankAuth = true },
			},
		},

		ncpd = {
			label = 'NCPD',
			type = 'leo',
			defaultDuty = false,
			offDutyPay = true,
			grades = {
				[0] = { name = 'Cadet', payment = 150 },
				[1] = { name = 'Officer', payment = 260 },
				[2] = { name = 'Detective', payment = 400 },
				[3] = { name = 'Captain', payment = 620, isBoss = true, bankAuth = true },
			},
		},

		maxtac = {
			label = 'MaxTac',
			type = 'leo',
			defaultDuty = false,
			offDutyPay = true,
			grades = {
				[0] = { name = 'Operator', payment = 460 },
				[1] = { name = 'Squad Lead', payment = 720, isBoss = true },
			},
		},

		arasaka = {
			label = 'Arasaka',
			type = 'corpo',
			defaultDuty = false,
			offDutyPay = true,
			grades = {
				[0] = { name = 'Junior Analyst', payment = 200 },
				[1] = { name = 'Field Agent', payment = 380 },
				[2] = { name = 'Counterintel', payment = 600 },
				[3] = { name = 'Executive', payment = 950, isBoss = true, bankAuth = true },
			},
		},

		militech = {
			label = 'Militech',
			type = 'corpo',
			defaultDuty = false,
			offDutyPay = true,
			grades = {
				[0] = { name = 'Contractor', payment = 200 },
				[1] = { name = 'Operative', payment = 380 },
				[2] = { name = 'Handler', payment = 600 },
				[3] = { name = 'Executive', payment = 950, isBoss = true, bankAuth = true },
			},
		},

		cabbie = {
			label = 'Delamain Driver',
			type = 'transport',
			defaultDuty = true,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Driver', payment = 90 },
				[1] = { name = 'Dispatcher', payment = 180, isBoss = true },
			},
		},

		bartender = {
			label = 'Bartender',
			type = 'service',
			defaultDuty = true,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Barback', payment = 70 },
				[1] = { name = 'Bartender', payment = 140 },
				[2] = { name = 'Owner', payment = 260, isBoss = true, bankAuth = true },
			},
		},

		-- Journalists: N54 News, WNS and the screamsheet (config/media.lua says
		-- which newsroom; a Stringer is the freelancer who sells to any desk).
		reporter = {
			label = 'Reporter',
			type = 'media',
			defaultDuty = false,
			offDutyPay = false,
			grades = {
				[0] = { name = 'Stringer', payment = 80 },
				[1] = { name = 'Reporter', payment = 200 },
				[2] = { name = 'Anchor', payment = 360 },
				[3] = { name = 'Editor-in-chief', payment = 560, isBoss = true, bankAuth = true },
			},
		},
	},

	GANGS = {
		none = {
			label = 'No affiliation',
			grades = {
				[0] = { name = 'Civilian' },
			},
		},

		maelstrom = {
			label = 'Maelstrom',
			grades = {
				[0] = { name = 'Chromehead' },
				[1] = { name = 'Enforcer' },
				[2] = { name = 'Cyberpsycho' },
				[3] = { name = 'Warlord', isBoss = true, bankAuth = true },
			},
		},

		valentinos = {
			label = 'Valentinos',
			grades = {
				[0] = { name = 'Novato' },
				[1] = { name = 'Soldado' },
				[2] = { name = 'Teniente' },
				[3] = { name = 'Jefe', isBoss = true, bankAuth = true },
			},
		},

		tygerclaws = {
			label = 'Tyger Claws',
			grades = {
				[0] = { name = 'Kouhai' },
				[1] = { name = 'Senpai' },
				[2] = { name = 'Kyodai' },
				[3] = { name = 'Oyabun', isBoss = true, bankAuth = true },
			},
		},

		sixthstreet = {
			label = '6th Street',
			grades = {
				[0] = { name = 'Recruit' },
				[1] = { name = 'Veteran' },
				[2] = { name = 'Sergeant' },
				[3] = { name = 'Colonel', isBoss = true, bankAuth = true },
			},
		},

		voodooboys = {
			label = 'Voodoo Boys',
			grades = {
				[0] = { name = 'Initiate' },
				[1] = { name = 'Runner' },
				[2] = { name = 'Houngan' },
				[3] = { name = 'Mambo', isBoss = true, bankAuth = true },
			},
		},

		animals = {
			label = 'Animals',
			grades = {
				[0] = { name = 'Cub' },
				[1] = { name = 'Bruiser' },
				[2] = { name = 'Beast' },
				[3] = { name = 'Alpha', isBoss = true, bankAuth = true },
			},
		},

		scavengers = {
			label = 'Scavengers',
			grades = {
				[0] = { name = 'Scav' },
				[1] = { name = 'Harvester' },
				[2] = { name = 'Ringleader', isBoss = true },
			},
		},

		moxes = {
			label = 'The Mox',
			grades = {
				[0] = { name = 'Regular' },
				[1] = { name = 'Bouncer' },
				[2] = { name = 'Matron', isBoss = true, bankAuth = true },
			},
		},

		wraiths = {
			label = 'Wraiths',
			grades = {
				[0] = { name = 'Raider' },
				[1] = { name = 'Outrider' },
				[2] = { name = 'Chief', isBoss = true, bankAuth = true },
			},
		},

		barghest = {
			label = 'Barghest',
			grades = {
				[0] = { name = 'Conscript' },
				[1] = { name = 'Trooper' },
				[2] = { name = 'Zealot' },
				[3] = { name = 'Commander', isBoss = true, bankAuth = true },
			},
		},

		aldecaldos = {
			label = 'Aldecaldos',
			grades = {
				[0] = { name = 'Kin' },
				[1] = { name = 'Rider' },
				[2] = { name = 'Elder', isBoss = true, bankAuth = true },
			},
		},
	},
}
