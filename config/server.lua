--- Server-only configuration. Never distributed: credentials, webhooks and
--- anything a client must not read belong here.
-- @author dop42

OPX.Config.SERVER = {
	-- Resources that also place players. Warned about at boot, because server
	-- resources cannot call each other: asking the host whether one is running is
	-- the only way to find out that two things will fight over the same body.
	CONFLICTING_PLACERS = { 'open77_playerstate', 'freeroam', 'pursuit', 'race' },

	-- WHO MAY CALL THE CREATOR EXPORTS, `core/server/exports.lua`. The caller is
	-- the resource name the HOST reports (`GetInvokingResource`), never one an
	-- argument claims, and a refused call answers `export.callerDenied` and is
	-- written to the audit log with the name it came from.
	--
	--   READ     who may ASK: GetPlayerData, GetMoney, HasJob, HasItem, IsStaff
	--            and the other reads. '*' is every resource on the host, or a
	--            set: { my_hud = true }. The answers name characters, jobs, gangs
	--            and balances: a resource that hands them on to clients hands
	--            them to strangers, and never a name to a stranger is the owner's
	--            rule -- the state bag stopped carrying any of it for that reason.
	--   WRITERS  who may CHANGE something: money, items, stashes, chat lines,
	--            keys, a vehicle's state, a job, a gang, duty, a revive, the
	--            caller's own character metadata, a runtime item or use handler,
	--            a vehicle row, a toast, a server-started bar and a crafting
	--            bench. EMPTY OUT OF THE BOX, on purpose: a
	--            write export is a money printer for whichever resource holds
	--            it, and the operator is the one who decides which of the
	--            resources they installed is trusted with that. The first refused
	--            call from a resource prints the exact line to add here.
	--            `'*'` admits every resource and is for a development server.
	--   STAFF_PERMISSION
	--            the ACL right `IsStaff` asks about. The right that opens the
	--            staff menu, so "staff" means the same thing everywhere.
	EXPORTS = {
		READ = '*',
		WRITERS = {},
		STAFF_PERMISSION = 'command.opx.admin',
		-- STASHES BY NAME: what `CountInStash`, `AddToStash` and
		-- `RemoveFromStash` may do to a stash that does not exist yet.
		--   * CountInStash answers 0 and RemoveFromStash `not_enough`; neither
		--     ever creates one.
		--   * AddToStash creates one only if it is listed in config/inventory, or
		--     is named in the CALLER's own namespace -- `<resource>.<name>`, e.g.
		--     `my_shop.backroom` -- and that resource holds fewer than CREATE_CAP
		--     of those (counted in the database, so a restart does not reset it).
		--     Anything else is refused `stash_namespace` or `stash_cap`. A stash
		--     that already exists, whatever its name, is used as it is.
		--   * A stash loaded this way and not opened by a player is written and
		--     put away IDLE_MS after its last touch, and loads again on demand.
		STASHES = { CREATE_CAP = 25, IDLE_MS = 60000 },
		-- WHAT `SetMetadata` LETS ONE RESOURCE KEEP ON ONE CHARACTER. A caller
		-- writes only under its own name (`ext.<resource>.<key>`), never one of
		-- opx's own keys; these bound how much: the encoded size of one value,
		-- how many keys, and the encoded size of all of them together.
		METADATA = { MAX_BYTES = 4096, MAX_KEYS = 32, MAX_TOTAL_BYTES = 16384 },
		-- WHAT `RegisterItem` LETS ONE RESOURCE ADD TO THE CATALOGUE while the
		-- server runs: at most MAX_PER_CALLER items. A runtime item is never a
		-- weapon, never replaces a config item or another resource's, and is not
		-- persisted -- the resource registers it again on every start.
		ITEMS = { MAX_PER_CALLER = 64 },
	},

	-- Short spellings, so `opx.admin.self.noclip` can also be typed `noclip`.
	--
	-- THE LONG NAME IS THE COMMAND AND NOTHING HERE RENAMES IT. Every key below
	-- keeps working exactly as it always has: it is what `acl.jsonc` grants, what
	-- `config/admin.lua`'s LINKS block names, and what the staff menu and the eye
	-- run. The value is a convenience that lives alongside it, and an operator who
	-- empties this table loses nothing but the typing.
	--
	-- A VALUE THE HOST WILL NOT GIVE US IS SKIPPED, NOT FATAL. This session also
	-- runs open77_shell, open77_pause, open77_voice, open-voice, open77_weapons,
	-- open77_interactions and open77_props, and a bare word is a far likelier
	-- collision than a prefixed one -- `open77_weather` ships a plain `weather`
	-- command, which is the shape of the thing. If one of these is already taken,
	-- `core/server/commands.lua` logs the name and the reason and moves on.
	--
	-- WHAT IS DELIBERATELY ABSENT, because symmetry is the wrong goal here:
	--   * `opx.admin` itself. It is the grant that makes somebody staff, `admin`
	--     is the single likeliest bare name for another resource to own, and the
	--     menu is already on F9.
	--   * everything irreversible: `...moderate.ban`, `...moderate.kick`,
	--     `...player.kill`, `...character.delete`, `opx.delete`. A bare `ban` or
	--     `kill` is a word you can type by accident, and none of them can be
	--     taken back. Typing the long name is friction that matches the
	--     consequence.
	--   * the generic nouns -- `save`, `give`, `list`, `add`, `open`, `set`,
	--     `money`, `status`, `time`, `weather`. Claiming one of those out of the
	--     session-wide namespace is asking for the collision, and half of them
	--     say nothing about which of eight commands they mean.
	COMMAND_ALIASES = {
		-- Players.
		['opx.characters'] = 'chars',
		['opx.duty'] = 'duty',
		['opx.withdraw'] = 'withdraw',

		-- Staff, on themselves.
		['opx.admin.self.noclip'] = 'noclip',
		['opx.admin.self.god'] = 'god',
		['opx.admin.self.invisible'] = 'invis',
		['opx.admin.self.heal'] = 'heal',
		['opx.admin.self.revive'] = 'revive',
		['opx.admin.self.speed'] = 'speed',
		['opx.admin.self.pos'] = 'pos',

		-- Staff, on somebody else. The bare verbs above are the self ones because
		-- those are the ones typed without stopping to think; these keep a word
		-- that says a target is coming.
		['opx.admin.player.goto'] = 'goto',
		['opx.admin.player.bring'] = 'bring',
		['opx.admin.player.tp'] = 'tp',
		['opx.admin.player.freeze'] = 'freeze',
		['opx.admin.player.observe'] = 'spectate',

		-- Weapons and vehicles.
		['opx.admin.weapon.give'] = 'addweapon',
		['opx.admin.weapon.giveammo'] = 'addammo',
		['opx.admin.weapon.remove'] = 'delweapon',
		['opx.admin.vehicle.spawn'] = 'car',
		['opx.admin.vehicle.repair'] = 'fix',
		['opx.admin.vehicle.remove'] = 'dv',

		['opx.admin.world.announce'] = 'announce',
	},

	-- The readiness gate, and the bucket a player waits in behind it. Every value
	-- below is validated once at load by the file that reads it: a bad one is
	-- named in the log once and the shipped value is used in its place.
	ENTRY = {
		-- Liveness interval declared to the gate. A watchdog on the HOLDER, never
		-- a limit on the player: someone may sit in a creator for an hour as long
		-- as the holder refreshes. Clamped to 1000..600000.
		GATE_MS = 300000,

		-- How long the gate watch waits before giving up on a player and
		-- releasing without them. Held BELOW GATE_MS, so the runtime gives up
		-- first, deliberately, and says why -- rather than the host opening the
		-- gate with the player possibly not incarnated at all.
		WATCH_MS = 240000,

		BUCKET = {
			-- One bucket per player. False moves nobody, and a stored bucket is
			-- honoured exactly as it was.
			ISOLATE = true,

			-- A player's own bucket is BASE plus their id, so the range runs to
			-- BASE + 65535. Bucket ids are uint32.
			BASE = 77000,

			-- The shared world bucket characters are placed in. A WORLD inside the
			-- selection range would break isolation: that is an error line, and
			-- isolation is switched off rather than left broken.
			WORLD = 0,

			-- Ambient population inside a selection bucket.
			POPULATION = false,

			-- Ambient population in the shared world, where the players
			-- actually live. True takes the vanilla figures -- crowds, traffic
			-- and prevention spawns -- exactly as the base game has them;
			-- false leaves every street empty, which is what an unconfigured
			-- bucket always was.
			WORLD_POPULATION = true,

			-- inactive, relaxed, strict or full; false leaves the host's own mode
			-- alone.
			LOCKDOWN = 'relaxed',
		},
	},
}
