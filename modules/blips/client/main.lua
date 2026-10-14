--- Turns the lists somebody else owns into real Cyberpunk mappins.
-- @author dop42
--
-- READ `config/blips.lua` FIRST. It carries the measurement that started this
-- work -- what actually suppressed the blips, and why the minimap was only half
-- of it -- and every number this file reads.
--
-- THE SHAPE IS `modules/teleports/client/main.lua`'s MARKER RECONCILE, and
-- deliberately so. A desired set is derived from the sources, the drawn set is
-- diffed against it, what is gone is removed and what is new is created. There
-- is no "add a blip" call anywhere: a blip exists because a spot exists, so a
-- spot that goes away cannot leave a pin behind, which is the failure mode this
-- kind of module has every single time it is written the other way round.
--
-- THE ONE THING THAT IS NOT LIKE THE MARKERS, AND IT IS THE IMPORTANT ONE.
-- `reconcile` YIELDS, every `BATCH` creations, on a thread of its own. See the
-- long comment at `apply()`. `modules/admin/client/target.lua` paid for that
-- comment four times.

local M = OPX.Modules.Get('blips')

M.Runtime = {}
local Runtime = M.Runtime

-- What this module calls itself in a log line and in an `OPX.Note`.
local TAG = 'blips'

-- Blip ids, keyed by the stable point id. THE VALUES ARE 64-BIT DECIMAL STRINGS
-- AND ARE NEVER PUT THROUGH `tonumber`: the platform guide says so in as many
-- words, and a 64-bit handle through a double comes back a different handle.
local created = {}

-- What each drawn blip was made from, so a point that MOVED or was re-sprited
-- is remade rather than left pointing at where it used to be. Keyed the same,
-- the value is the signature `signatureOf` builds.
local drawn = {}

-- The scheduler handle, so Shutdown can cancel it.
local scanJob

-- The reconcile is asynchronous, so these are the re-entrancy pair from
-- `modules/admin/client/target.lua`: `syncing` says a pass is on a thread,
-- `dirty` says another was asked for while it ran.
local syncing, dirty = false, false

-- One-shot latches for the things worth saying to the OPERATOR. Every one of
-- these is bounded because `OPX.Note` costs a net event and has a 60-per-
-- session budget: a line per failed create on a server with 128 blips would
-- spend the whole budget on one bad sprite name.
local notedBoot, notedRefusal, notedQuota = false, false, false

-- The counts the last pass ended with, for `Report` and for the boot note.
local tally = { wanted = 0, live = 0, refused = 0, skipped = 0, capped = 0 }

--- The module's settings, read LIVE. `OPX.Modules.Rebind` re-points `M.Settings`
--- after every shared script has loaded, so a file-scope copy taken at load time
--- is a copy of the table that existed before the config did.
local function settings()
	return type(M.Settings) == 'table' and M.Settings or {}
end

--- The blips API, or nil when this host has no such backend.
-- Looked up before every use rather than cached, on the same argument
-- `modules/teleports/server/main.lua` makes about `Open77.players.teleport`: a
-- native absent on one build must cost this module its feature and nothing else.
local function api()
	local native = Open77.blips
	if type(native) ~= 'table' or type(native.create) ~= 'function' then return nil end
	return native
end

-- ── the pace ────────────────────────────────────────────────────────────────

-- How much work a reconcile does between two yields, in the rough units the
-- `pace` calls below charge: one per point read, signed or diffed, more for a
-- job gate. 24 units keeps the dearest resume of a pass near 2,500 VM
-- instructions, the pass's own setup included.
--
-- WHY THE DERIVE IS PACED AND NOT ONLY THE CREATES. The meter in
-- `tests/host.lua` put a reconcile of 200 garage spots at ~36,000 instructions
-- in ONE resume -- the read, the sort and 128 signatures before the first
-- create, and the whole set again on a pass that changed nothing. The client
-- budget is ~10,000 a resume and an overrun unwinds the thread in silence,
-- which here leaves `syncing` true and the map never reconciled again.
local PACE = 24

--- A fresh pacer for one pass on the reconcile thread. `pace(cost)` adds the
--- cost to the work done since the last yield and gives the frame back once it
--- reaches `PACE`.
-- @return function
local function pacer()
	local spent = 0
	return function(cost)
		spent = spent + (cost or 1)
		if spent >= PACE then
			spent = 0
			Wait(0)
		end
	end
end

--- The pace of a caller that must not yield: `Runtime.Wanted()` answers a test
--- or a diagnostic synchronously, never from a thread of its own.
local function unpaced() end

-- ── the config ──────────────────────────────────────────────────────────────

--- A whole number of milliseconds above zero, or the fallback.
local function positiveMs(value, fallback)
	local number = math.tointeger(value)
	if number == nil or number <= 0 then return fallback end
	return number
end

--- Whether a value is the platform's own colour spelling: exactly #RRGGBB or
-- #RRGGBBAA. `color` is a real `create` field since the native Ink adapter
-- grew per-widget colours; `colour` is what the engine refuses by name.
local function hexColor(value)
	return type(value) == 'string'
		and (value:match('^#%x%x%x%x%x%x$') ~= nil or value:match('^#%x%x%x%x%x%x%x%x$') ~= nil)
end

--- Validates one category block, answering the usable form or nil and why.
--
-- EVERY FAULT IS NAMED WITH ITS CATEGORY. An operator reading a boot log wants
-- to know which of the blocks they have to open, and "SPRITE must be a
-- string" without that word is a message that sends them to read all of them.
-- @param name string
-- @param raw any
-- @param problems table appended to, one string per fault
-- @return table|nil
local function category(name, raw, problems)
	if type(raw) ~= 'table' then
		problems[#problems + 1] = ('%s: every category must be a table'):format(name)
		return nil
	end

	-- THE REFUSED KEYS FIRST, and they are reported even when the category is
	-- switched off. A `COLOUR` that is only mentioned once the operator turns
	-- the category back on is a message that arrives a week after the edit.
	for key in pairs(raw) do
		local instead = type(key) == 'string' and M.REFUSED_KEYS[key:upper()] or nil
		if instead ~= nil then
			problems[#problems + 1] = ('%s: %s is refused by the engine ' ..
				'(`unsupported_option:%s`) and cannot be honoured. Use %s instead.')
				:format(name, tostring(key), tostring(key):lower(), instead)
		end
	end

	if raw.SHOW == false then return nil end

	local sprite = raw.SPRITE
	if type(sprite) ~= 'string' or sprite == '' then
		if math.tointeger(sprite) == nil then
			problems[#problems + 1] =
				('%s: SPRITE must be an alias, a 2.31 variant name, or an integer 0..146')
					:format(name)
			return nil
		end
	end

	local label = raw.LABEL
	if label ~= nil and type(label) ~= 'string' then
		problems[#problems + 1] = ('%s: LABEL must be a string'):format(name)
		return nil
	end

	-- `range` is 0..4000 and the engine answers `invalid_range` outside it. The
	-- refusal is moved to boot because a refused create is a blip that is simply
	-- absent, which is indistinguishable from the bug this whole module fixes.
	local range = raw.RANGE == nil and 0 or tonumber(raw.RANGE)
	if range == nil or range ~= range or range < M.MIN_RANGE or range > M.MAX_RANGE then
		problems[#problems + 1] = ('%s: RANGE must be a number of metres from %d to %d, ' ..
			'0 meaning no gate'):format(name, M.MIN_RANGE, M.MAX_RANGE)
		return nil
	end

	-- A tint over the whole category. `color` is a real per-blip field now
	-- (see `M.REFUSED_KEYS`), so it is carried here and never sent under the
	-- British spelling the engine refuses.
	local color = raw.COLOR
	if color ~= nil and not hexColor(color) then
		problems[#problems + 1] = ('%s: COLOR must be #RRGGBB or #RRGGBBAA'):format(name)
		color = nil
	end

	return {
		name = name,
		sprite = sprite,
		label = (type(label) == 'string' and label ~= '') and label or name,
		range = range,
		walls = raw.WALLS == true,
		color = color,
	}
end

--- Every category that is on and usable, by name, plus the faults found.
-- @author dop42
-- @return table name -> category
-- @return table problems
function Runtime.Categories()
	local declared = settings().CATEGORIES
	local out, problems = {}, {}
	if type(declared) ~= 'table' then return out, problems end
	for _, name in ipairs(M.ORDER) do
		local raw = declared[name]
		if raw ~= nil then
			local usable = category(name, raw, problems)
			if usable ~= nil then out[name] = usable end
		end
	end
	-- A category name that is not one of the six is a typo, and a typo that
	-- draws nothing while looking exactly like a block that works is the worst
	-- kind. It is named rather than ignored.
	for name in pairs(declared) do
		local known = false
		for _, id in ipairs(M.ORDER) do
			if id == name then known = true end
		end
		if not known then
			problems[#problems + 1] = ('%s: not a category this module sources; it must be ' ..
				'one of %s'):format(tostring(name), table.concat(M.ORDER, ', '))
		end
	end
	return out, problems
end

-- ── the sources ─────────────────────────────────────────────────────────────

--- Whether a module is declared, enabled, and publishing the accessor named.
-- Answers the accessor itself so the caller has nothing left to check.
local function accessor(id, fn)
	local module = OPX.Modules.Get(id)
	if type(module) ~= 'table' then return nil end
	local runtime = module.Runtime
	if type(runtime) ~= 'table' or type(runtime[fn]) ~= 'function' then return nil end
	return runtime[fn]
end

--- The settings of ANOTHER module, when that module is switched on.
-- A disabled module's config is still loaded -- every `config/*.lua` is a
-- `shared_script` -- so reading the table is not enough to know it is live.
local function foreignSettings(id)
	local block = OPX.Config.MODULES ~= nil and OPX.Config.MODULES[id] or nil
	if type(block) ~= 'table' or block.enabled == false then return nil end
	return block
end

--- Appends one point, unless it is an unsurveyed blank.
--
-- A POINT AT EXACTLY (0, 0, 0) IS A PLACEHOLDER AND IS SKIPPED. This is the
-- same test `modules/hauling` makes on its own sites and for the same stated
-- reason: `config/gunsmith.lua` and `config/hauling.lua` both ship unsurveyed
-- and say so in their headers, and `config/elevators.lua` is the tale both of
-- them cite -- four lifts whose coordinates passed every shape check and
-- matched nothing in Night City, silently, for weeks. A pin in the sea off
-- Night City would read as this feature being broken.
local function point(out, key, label, x, y, z, look)
	x, y, z = tonumber(x), tonumber(y), tonumber(z)
	if x == nil or y == nil or z == nil then return false end
	if x ~= x or y ~= y or z ~= z then return false end
	if x == 0.0 and y == 0.0 and z == 0.0 then return false end
	out[#out + 1] = {
		key = key,
		label = (type(label) == 'string' and label ~= '') and label or key,
		x = x, y = y, z = z,
		-- The per-point look (a headquarters station's own sprite/icon/colour),
		-- or nil where the point wears its category's. See `create` below.
		look = look,
	}
	return true
end

--- A counter that hands the resume back every `every` units of work.
--
-- THE CLIENT'S TIME BUDGET IS PER RESUME, AND IT IS ENFORCED EVERY 10,000 VM
-- INSTRUCTIONS: the platform's count hook (`kInstructionHookStep`) checks the
-- clock only then, against a deadline that is this resource's share of the
-- frame's two milliseconds -- or already past, when the frame is busy. So a
-- resume that stays under ten thousand instructions can never be cut, and one
-- that runs past it is cut whenever the frame is busy. The derivation below ran
-- whole in one resume -- every source, every signature, the sort -- and the
-- client log carried `[blips] reconcile: ... script execution budget exceeded`
-- 70 to 80 times a session (2026-09-27 and -28), each one a pass thrown away.
-- A unit is roughly a hundred instructions; a slice of SLICE_UNITS stays far
-- under the hook's first check.
--
-- WITHOUT A STEP IT DOES NOTHING: a test calling `Runtime.Wanted()` directly is
-- not on a thread and must not yield.
local SLICE_UNITS = 32

local function spender(step, every)
	if type(step) ~= 'function' then return function() end end
	local spent = 0
	return function(units)
		spent = spent + (units or 1)
		if spent >= every then
			spent = 0
			step()
		end
	end
end

--- Whether the local character passes one place's JOBS block.
--
-- THE OWNER: "fait en sorte que les blips job on les voit uniquement si on fait
-- partie du job si possible". It is possible, and it is possible WITHOUT a
-- second rule: `config/gunsmith.lua` and `config/hauling.lua` already say who
-- may use a place, in the same `JOBS` / `ON_DUTY` / `MEMBERSHIP` vocabulary that
-- `config/elevators.lua` and `config/teleports.lua` use, and one gate decides all
-- of them. So the map asks that gate. A pin appears for exactly the people the
-- bench would open for, and the two can never drift apart, because there is only
-- one of them.
--
-- A PLACE WITH NO `JOBS` BLOCK IS PUBLIC and stays pinned for everybody --
-- `Evaluate`'s first line, and the reason hauling's sample sites stay visible:
-- the owner asked for a job-free job, and "anyone may haul" must not read as
-- "nobody may see where".
--
-- THIS IS A VISIBILITY FILTER AND NOT A GATE, which inverts the asymmetry the
-- gate itself is built on. `jobgate.lua` closes on every doubt because granting
-- a gated surface costs the operator the gate. Here the cost runs the other way:
-- hiding a pin from somebody entitled to it is the failure, and showing one to
-- somebody who cannot use the bench is untidy at worst -- the server refuses
-- them at the bench either way, and nothing here decides anything. So every
-- doubt this side opens:
--
--   * no character API, no character yet, no snapshot -- pinned. A player
--     reading a map during a database hiccup is not a threat model;
--   * `MEMBERSHIP = 'any'` with a job held as a secondary membership -- pinned.
--     The client mirror carries the PRIMARY job and no memberships table, so
--     this side genuinely cannot answer, and it must not answer "no". Both
--     shipped configs say `primary` today, where the mirror is exactly enough.
--
-- The snapshot is stamped now because the mirror IS now: it is replicated, and
-- `character` raises `job` the moment it changes. Staleness is a server-roster
-- problem and stamping it honestly here would invent one.
local function passesJob(requirement, membership)
	local required = type(requirement) == 'table' and requirement.jobs or nil
	if type(required) ~= 'table' or next(required) == nil then return true end

	local api = OPX.Api.Get('character')
	if type(api) ~= 'table' or type(api.GetJobData) ~= 'function' then return true end

	-- THE TWO NILS ARE NOT THE SAME NIL, which is the whole of the distinction
	-- the paragraph above promises. `GetJobData` answers nil for a character with
	-- no job AND for no character at all, and those want opposite answers: the
	-- first is somebody who is genuinely not on the payroll and must not see the
	-- pin, the second is a client that has not finished joining and must not be
	-- punished for it. `IsLoggedIn` is what tells them apart.
	local known, logged = pcall(api.IsLoggedIn)
	if not known or logged ~= true then return true end

	local read, job = pcall(api.GetJobData)
	if not read then return true end
	if type(job) ~= 'table' then return false end

	-- `membership = 'any'` cannot be decided from a mirror with no memberships
	-- table, so it is decided as `primary` and anything that fails is shown
	-- rather than hidden. See the note above about which way the doubt runs.
	local now = OPX.Now()
	local passed = OPX.JobGate.Evaluate(requirement, { job = job, atMs = now }, now,
		{ maxAgeMs = 0, membership = 'primary' })
	if passed then return true end
	return membership == 'any'
end

--- Every point of one category, and how many blanks were skipped building it.
-- @param name string one of `M.ORDER`
-- @param pace function charged per point read, see `pacer`
-- @return table list of points
-- @return integer skipped
local function pointsOf(name, pace)
	local out, skipped = {}, 0

	-- A LIVE LIST IS COPIED BEFORE IT IS WALKED IN SLICES. `pace` may yield,
	-- and a `pairs` walk that is suspended while its table's owner adds a key is
	-- undefined behaviour in Lua. The other modules' lists (headquarters,
	-- garages, dealership, teleports) are their live state, so their pairs are
	-- taken in one cheap pass (a few instructions each) and the costly part runs
	-- over the copy; the config tables (`shops`, `gunsmith`, `hauling`) never
	-- change at run time and are walked directly.
	local function add(key, label, x, y, z)
		pace(1)
		if not point(out, key, label, x, y, z) then skipped = skipped + 1 end
	end
	local function snapshot(list)
		local pairsOf = {}
		for key, value in pairs(list) do pairsOf[#pairsOf + 1] = { key, value } end
		pace(math.ceil(#pairsOf / 10))
		return pairsOf
	end

	if name == 'headquarters' then
		-- THE STATION'S OWN CHOICE, AND THE ONE SOURCE WHOSE LOOK IS NOT THE
		-- CATEGORY'S. Positions come from the headquarters client's own list
		-- -- the server filtered it to this player's routing bucket and
		-- captures live in the database, so the config is not the list. The
		-- PIN LOOK rides each point as `spot.blip`, resolved by the
		-- headquarters module from the `BLIP` block of the station's own row
		-- in `config/headquarters.lua`; a station that declares none is
		-- deliberately not pinned at all, which is what makes the pin the
		-- station's own choice rather than this module's opinion.
		local hqSpots = accessor('headquarters', 'Spots')
		if hqSpots == nil then return out, skipped end
		local read, list = pcall(hqSpots)
		if not read or type(list) ~= 'table' then return out, skipped end
		for _, pair in ipairs(snapshot(list)) do
			local key, spot = pair[1], pair[2]
			pace(1)
			if type(spot) == 'table' and type(spot.blip) == 'table' then
				if not point(out, tostring(key), spot.label, spot.x, spot.y, spot.z, spot.blip) then
					skipped = skipped + 1
				end
			end
		end

	elseif name == 'garages' or name == 'dealership' or name == 'bank' then
		-- The spots this client was TOLD ABOUT, which is not the same list as
		-- `config/<name>.lua`: garage and dealer spots are captured in game and
		-- live in the database, and the server filters what it sends to this
		-- player's own routing bucket. Reading the config here would show a
		-- player pins for spots in a bucket they are not in, and would miss every
		-- legacy row the server adopted from the database at boot.
		--
		-- ONE PIN PER GARAGE LOCATION, AT ITS MENU POINT. A garage location
		-- draws two points -- the menu where the list opens and the entry door a
		-- vehicle is taken in at, usually a few metres apart -- and both arrive
		-- in `Spots()`. Pinning every point put two identical "Garage" pins on
		-- each location, stacked on the map. The door is skipped; a dealer has no
		-- roles and every one of its spots is pinned.
		local spots = accessor(name, 'Spots')
		if spots == nil then return out, skipped end
		local read, list = pcall(spots)
		if not read or type(list) ~= 'table' then return out, skipped end
		for _, pair in ipairs(snapshot(list)) do
			local key, spot = pair[1], pair[2]
			if type(spot) == 'table' and spot.role ~= 'entry' then
				add(tostring(key), spot.label, spot.x, spot.y, spot.z)
			end
		end

	elseif name == 'teleports' then
		-- Both ends of a two-way are separate entrances under one key, already
		-- keyed apart by the teleports client as `key .. '\1' .. leg`. That key
		-- is reused verbatim: two pins, because both ends are places you stand.
		local entrances = accessor('teleports', 'Entrances')
		if entrances == nil then return out, skipped end
		local read, list = pcall(entrances)
		if not read or type(list) ~= 'table' then return out, skipped end
		for _, pair in ipairs(snapshot(list)) do
			local key, entrance = pair[1], pair[2]
			if type(entrance) == 'table' then
				add(tostring(key), entrance.label, entrance.x, entrance.y, entrance.z)
			end
		end

	elseif name == 'shops' then
		-- Static, and the client reads the same `shared_script` the server does:
		-- no event carries shop positions, because nothing about a shop is
		-- per-player. `modules/shops/client/main.lua`'s own `shopList()` reads it
		-- exactly this way.
		local block = foreignSettings('shops')
		local declared = block ~= nil and block.SHOPS or nil
		if type(declared) ~= 'table' then return out, skipped end
		for key, raw in pairs(declared) do
			if type(raw) == 'table' then add(tostring(key), raw.LABEL, raw.X, raw.Y, raw.Z) end
		end

	elseif name == 'fuel' then
		-- The OPEN stations, as `modules/fuel` built them from its config: a
		-- station that is not surveyed yet or was refused is not in the list, so
		-- it is not pinned -- the same rule the module itself keeps, asked of the
		-- module rather than written again here. One pin per station, at its
		-- centre (ox's `createBlip(station)`), never one per pump.
		local stations = accessor('fuel', 'Stations')
		if stations == nil then return out, skipped end
		local read, list = pcall(stations)
		if not read or type(list) ~= 'table' then return out, skipped end
		for key, station in pairs(list) do
			if type(station) == 'table' then
				add(tostring(key), station.label, station.x, station.y, station.z)
			end
		end

	elseif name == 'jobs' then
		-- TWO SOURCES UNDER ONE CATEGORY. A player reading a map asks "where is
		-- there work", not "which module owns this", so a gunsmith bench and a
		-- hauling drop-off are the same kind of thing here even though nothing in
		-- the code below them is shared. The keys are prefixed so a site and an
		-- armoury that happen to share a name cannot collide into one pin.
		local guns = foreignSettings('gunsmith')
		local armouries = guns ~= nil and guns.ARMOURIES or nil
		if type(armouries) == 'table' then
			local membership = guns.MEMBERSHIP
			for key, raw in pairs(armouries) do
				local bench = type(raw) == 'table' and raw.BENCH or nil
				-- The armoury's own JOBS block, read straight off the config the
				-- gunsmith module gates the bench with. An ungated armoury is
				-- public and stays pinned.
				pace(4)
				if type(bench) == 'table'
					and passesJob({ jobs = raw.JOBS, onDuty = raw.ON_DUTY }, membership) then
					add('bench\1' .. tostring(key), raw.LABEL, bench.X, bench.Y, bench.Z)
				end
			end
		end

		-- A hauling SITE has no single coordinate -- it is a scatter of crate
		-- points -- but its DROPOFFS are single places with names, and a drop-off
		-- is the half of the job a driver actually has to navigate to. The crate
		-- points are deliberately not pinned: they are up to 64 of them, they
		-- move, and 64 pins would eat half the platform's per-resource quota to
		-- say "there are boxes in this yard" once.
		local haul = foreignSettings('hauling')
		local sites = haul ~= nil and haul.SITES or nil
		if type(sites) == 'table' then
			local membership = haul.MEMBERSHIP
			for siteKey, site in pairs(sites) do
				local drops = type(site) == 'table' and site.DROPOFFS or nil
				-- THE GATE IS ON THE SITE, NOT ON THE DROP-OFF, which is where
				-- `modules/hauling` puts it too: a site's JOBS block is what makes
				-- the whole job a whitelist, and its drop-offs are places inside it
				-- rather than jobs of their own. Both shipped sites have no JOBS
				-- block at all, deliberately -- the owner asked for a job-free job
				-- -- so both stay pinned for everybody and this changes nothing
				-- until somebody writes one.
				--
				-- A SITE THAT IS NOT A TABLE IS NOT PINNED, and is not indexed:
				-- `site.JOBS` on one raised inside the pass and lost every pin of
				-- all six categories, every four seconds, for one bad config row.
				pace(4)
				local allowed = type(site) == 'table'
					and passesJob({ jobs = site.JOBS, onDuty = site.ON_DUTY }, membership)
					or false

				-- ── AND THE YARD ITSELF, WHICH WAS THE HALF NOBODY COULD FIND ──
				-- THE OWNER: "pour la hauling tu peux mettre des blips aussi car
				-- sinon ont sais pas ou sais". The drop-offs were pinned and the
				-- PICKUP was not, so the map said where to deliver a crate and
				-- nothing at all about where to collect one -- which is the half
				-- of the job you have to find first.
				--
				-- ONE PIN PER SITE, AT ITS FIRST SURVEYED POINT. A site has no
				-- coordinate of its own -- it is a scatter of crate points -- and
				-- pinning all of them would be up to 64 pins eating half the
				-- platform's per-resource quota to say "there are boxes in this
				-- yard" over and over. The first point that is not a placeholder
				-- is a real place inside the yard, which is all a driver needs.
				--
				-- A SITE MAY NAME ITS OWN `BLIP`, surveyed apart from the crates --
				-- the shop door rather than a pallet round the back. When it is
				-- there and real, it wins and the points are not consulted.
				local blip = type(site) == 'table' and site.BLIP or nil
				local pinned = allowed and type(blip) == 'table'
					and point(out, 'site\1' .. tostring(siteKey), site.LABEL, blip.X, blip.Y, blip.Z)
				if not pinned and type(site) == 'table' and allowed
					and type(site.POINTS) == 'table' then
					-- `point` is the helper; `spot` is the row. The first draft named
					-- the loop variable `point` and shadowed the function it was
					-- about to call.
					--
					-- CALLED DIRECTLY RATHER THAN THROUGH `add`, because `add`
					-- counts every refusal as a skipped placeholder -- and the
					-- unsurveyed points before the first real one would then be
					-- counted twice, once here and once as themselves.
					--
					-- THE KEY IS WHAT MAKES IT ONE PIN, NOT THE BREAK, and that is
					-- worth writing down because the first version of this comment
					-- claimed the opposite. Every point of a site is offered under
					-- the same `site\<key>`, and the reconciliation downstream is
					-- keyed -- so even without the break a yard gets one blip.
					-- Proved by mutation: removing the break changes nothing, and
					-- making the key per-point produces two. The break is the cheap
					-- early exit it looks like and no more.
					for _, spot in ipairs(site.POINTS) do
						pace(1)
						if type(spot) == 'table' and point(out, 'site\1' .. tostring(siteKey),
							site.LABEL, spot.X, spot.Y, spot.Z) then
							break
						end
					end
				end

				if type(drops) == 'table' and allowed then
					for dropKey, drop in pairs(drops) do
						if type(drop) == 'table' then
							add('drop\1' .. tostring(siteKey) .. '\1' .. tostring(dropKey),
								drop.LABEL, drop.X, drop.Y, drop.Z)
						end
					end
				end
			end
		end
	end

	return out, skipped
end

--- What one blip is made of, as a string. Two blips with the same signature are
--- the same blip and the drawn one is left alone; a difference in ANY field is
--- a remake.
--
-- WHY A REMAKE AND NOT AN UPDATE. `Open77.blips.update` exists and would be
-- cheaper. It is not used because the cheapness is the trap: a partial update
-- that is refused halfway leaves a pin whose position came from the new list
-- and whose sprite came from the old one, and nothing anywhere holds the fact
-- that the two disagree. A remove and a create cannot end in that state. These
-- lists change when an operator captures a spot, which is to say almost never,
-- so the cost is a handful of engine calls a week.
local function signatureOf(entry, block)
	-- A look is part of what a pin is: a station whose colour or icon changed
	-- is remade, not left wearing the look it was created with. The icon is
	-- spelled by what it NAMES -- `tostring` on its table would be its address,
	-- a different string every rebuild, and every HQ pin would be remade on
	-- every pass.
	local look = entry.look or {}
	local icon = look.icon
	local iconPart
	if type(icon) == 'table' then
		iconPart = tostring(icon.asset) .. '@' .. tostring(icon.size)
	else
		iconPart = tostring(icon)
	end
	return ('%s|%s|%.3f|%.3f|%.3f|%s|%s|%s|%s|%s|%s|%s'):format(
		block.name, entry.label, entry.x, entry.y, entry.z,
		tostring(block.sprite), tostring(block.range), tostring(block.walls),
		tostring(block.color), tostring(look.sprite), iconPart, tostring(look.color))
end

--- Every blip this config wants right now, keyed by a stable id, charging the
--- work to `pace` so the reconcile thread can spread it over several resumes.
-- @param pace function see `pacer`
-- @return table id -> { entry, block, signature }
-- @return integer how many blank points were skipped
-- @return integer how many were dropped over `MAX`
local function derive(pace)
	local blocks = Runtime.Categories()
	-- Every category's config read and checked: charged, so a pass that starts
	-- late in a resume does not add a whole parse to it.
	pace(10)
	local limit = math.tointeger(settings().MAX) or M.QUOTA
	-- Clamped to the platform's own per-resource quota rather than trusted: a
	-- config asking for 300 is asking the engine to refuse 172 creates one at a
	-- time, silently, which is the shape of bug this module exists to end.
	if limit > M.QUOTA then limit = M.QUOTA end
	if limit < 0 then limit = 0 end

	local out, count, skipped, capped = {}, 0, 0, 0
	for _, name in ipairs(M.ORDER) do
		local block = blocks[name]
		if block ~= nil then
			local list, blanks = pointsOf(name, pace)
			skipped = skipped + blanks
			-- Sorted so the set that survives the cap is the SAME set every pass.
			-- `pairs` order is not stable between runs, and without this a server
			-- over the quota would draw a different arbitrary 128 on every
			-- reconcile -- pins flickering in and out with nothing changing.
			--
			-- THE KEYS ARE SORTED, NOT THE POINTS, because a comparator is a Lua
			-- call per comparison -- ~1,500 of them for 200 spots, ~12,000
			-- instructions in one resume that cannot be split -- and strings with
			-- no comparator are ordered by the runtime itself.
			local keys, byKey = {}, {}
			for index = 1, #list do
				local entry = list[index]
				keys[index] = entry.key
				byKey[entry.key] = entry
				if index % 16 == 0 then pace(2) end
			end
			table.sort(keys)
			for index = 1, #keys do
				if count >= limit then
					capped = capped + (#keys - index + 1)
					break
				end
				pace(1)
				local entry = byKey[keys[index]]
				count = count + 1
				out[name .. '\1' .. entry.key] =
					{ entry = entry, block = block, signature = signatureOf(entry, block) }
			end
		end
	end
	return out, skipped, capped
end

--- Every blip this config wants right now, keyed by a stable id. Never yields
--- by itself.
-- @author dop42
-- @param step function|nil called between slices of SLICE_UNITS units of the
-- derivation (see `spender`) -- a test that measures each slice passes one;
-- nil runs it whole, the synchronous answer a test or a diagnostic wants. The
-- reconcile thread does not come through here: it paces `derive` itself.
-- @return table id -> { entry, block, signature }
-- @return integer how many blank points were skipped
-- @return integer how many were dropped over `MAX`
function Runtime.Wanted(step)
	return derive(type(step) == 'function' and spender(step, SLICE_UNITS) or unpaced)
end

-- ── the engine ──────────────────────────────────────────────────────────────

--- Creates one blip, or answers why not. Never raises.
local function create(entry, block)
	local native = api()
	if native == nil then return nil, 'ui.vanilla.map is unavailable on this host' end
	-- THE POINT'S OWN LOOK WINS, PER FIELD. A headquarters station may name
	-- its own sprite, its own custom SVG icon and its own colour in
	-- `config/headquarters.lua`; everything else wears the category block.
	local look = entry.look or {}
	local options = {
		position = { x = entry.x, y = entry.y, z = entry.z },
		sprite = look.sprite or block.sprite,
		-- `title` and `description` are Open77's own mappin data and are what the
		-- fullscreen map's tooltip shows when the pin is highlighted. The POINT's
		-- own label is the title, because that is the operator's word for this
		-- particular place; the CATEGORY's label is the description, because that
		-- is what kind of place it is. A garage the operator called `garage1`
		-- therefore reads "garage1 / Garage", which is not beautiful and is at
		-- least true -- the fix for that is to give the spot a better LABEL, in
		-- the one file that owns it.
		title = entry.label,
		description = block.label,
		active = true,
		visibleThroughWalls = block.walls,
	}
	-- 0 IS "NO GATE" AND THE KEY IS OMITTED RATHER THAN SENT AS 0. Both are
	-- accepted by the engine, but sending the key says this module has an
	-- opinion about range on every blip, and `get(id).range` reading 0 would
	-- then be indistinguishable from a gate that was set and cleared.
	if look.icon ~= nil then options.icon = look.icon end
	local color = look.color or block.color
	if color ~= nil then options.color = color end
	if block.range > 0 then options.range = block.range end

	local read, id, reason = pcall(native.create, options)
	if not read then return nil, tostring(id) end
	if type(id) ~= 'string' or id == '' then return nil, tostring(reason or 'refused') end
	return id, nil
end

--- Removes one blip without raising. A removal that fails is not reported: the
--- id is dropped from `created` either way, and a handle the engine has already
--- cleaned up (a reload, a world change) is the common case rather than a fault.
local function remove(id)
	local native = api()
	if native == nil or type(native.remove) ~= 'function' then return end
	pcall(native.remove, id)
end

--- Brings the drawn set in line with `wanted`, yielding every `BATCH` creates.
--
-- ============================================================================
-- THIS FUNCTION YIELDS, AND THAT IS THE WHOLE REASON IT IS ASYNCHRONOUS
-- ============================================================================
--
-- A CLIENT RESUME HAS AN INSTRUCTION BUDGET. A loop that creates several dozen
-- engine handles in one pass runs out of it partway down, and when it does THE
-- COROUTINE UNWINDS WITH NO ERROR, NO LOG AND NO REFUSAL. Half the blips would
-- be up, the rest would never exist, and every diagnosis would start at the
-- wrong end -- the sprite name, the permission, the map itself.
--
-- `modules/admin/client/target.lua`'s `register()` carries the full story and
-- paid for it four times: three dozen staff rows registered inside a single
-- resume, the last kind in the list never registered at all, and the defect
-- read as a missing feature for days because the unconditional report at the
-- end of the function never sent once across a dozen restarts.
--
-- BLIPS ARE EXACTLY THAT SHAPE. A hundred-odd engine calls, all at start, all
-- in one pass. So this yields every `BATCH`, the removals yield too, and the
-- whole thing runs on a `CreateThread` that `sync()` starts -- because a thread
-- the host started may always yield, and the scheduler step that calls this one
-- makes no such promise.
-- @param wanted table see `derive`
-- @param pace function charged per id walked, see `pacer`: a pass where
-- nothing changed walks every id three times and creates nothing, so the
-- `BATCH` yields alone never come round
local function apply(wanted, pace)
	local size = math.tointeger(settings().BATCH) or 8
	if size < 1 then size = 1 end

	local live, refused = 0, 0
	local since = 0

	-- GONE FIRST, so a server that is at the quota can replace a spot it removed
	-- in the same pass rather than refusing the new one and freeing the old.
	for id, handle in pairs(created) do
		pace(1)
		if wanted[id] == nil then
			remove(handle)
			created[id], drawn[id] = nil, nil
			since = since + 1
			if since >= size then
				since = 0
				Wait(0)
			end
		end
	end

	-- CHANGED, on the same pass: a point whose position or sprite moved is taken
	-- down here and rebuilt below, so it cannot survive as a pin to where it
	-- used to be.
	for id, want in pairs(wanted) do
		pace(1)
		if created[id] ~= nil and drawn[id] ~= want.signature then
			remove(created[id])
			created[id], drawn[id] = nil, nil
			since = since + 1
			if since >= size then
				since = 0
				Wait(0)
			end
		end
	end

	for id, want in pairs(wanted) do
		pace(1)
		if created[id] == nil then
			local handle, why = create(want.entry, want.block)
			if handle == nil then
				refused = refused + 1
				-- ONE LINE PER SESSION, not one per blip. A bad sprite name refuses
				-- every blip of its category, and a note per refusal would spend the
				-- whole 60-note budget saying the same sentence 40 times -- which
				-- would then hide every other module's notes behind it.
				if not notedRefusal then
					notedRefusal = true
					OPX.Note(TAG, ('a %s blip was refused: %s'):format(want.block.name,
						tostring(why)))
				end
				Open77.log.warn(('[%s] %s: %s'):format(TAG, id, tostring(why)))
			else
				created[id], drawn[id] = handle, want.signature
				live = live + 1
			end
			since = since + 1
			if since >= size then
				since = 0
				Wait(0)
			end
		else
			live = live + 1
		end
	end

	return live, refused
end

--- Whether the game's own minimap is currently on, as a word for the boot note.
-- `nil` when this host cannot be asked, which is NOT the same answer as "no"
-- and is not reported as one.
local function minimapState()
	local hud = Open77.hud
	if type(hud) ~= 'table' or type(hud.isVisible) ~= 'function' then return nil end
	local read, visible = pcall(hud.isVisible, M.MINIMAP_COMPONENT)
	if not read or type(visible) ~= 'boolean' then return nil end
	return visible
end

--- One reconcile: derive, diff, apply, and say so once.
local function pass()
	local pace = pacer()
	local wanted, skipped, capped = derive(pace)
	local count = 0
	for _ in pairs(wanted) do count = count + 1 end

	local live, refused = apply(wanted, pace)
	tally = { wanted = count, live = live, refused = refused, skipped = skipped, capped = capped }

	-- THE BOOT NOTE, and it is the one thing in this module the OWNER will
	-- actually see. `Open77.log` on a client writes to a file on the PLAYER's
	-- machine; from the server journal a module that failed and a module that was
	-- never written look identical, which is exactly how this feature's absence
	-- went unexplained across several sessions. So the first completed pass says,
	-- in the server's own log, how many pins went up and whether the minimap can
	-- show them.
	if not notedBoot then
		notedBoot = true
		local minimap = minimapState()
		local where
		if minimap == nil then
			where = 'the fullscreen map; this host could not be asked about the minimap'
		elseif minimap then
			where = 'the minimap and the fullscreen map'
		else
			where = 'the fullscreen map only -- config/hud.lua hides VANILLA.minimap, ' ..
				'which hides mappins on the minimap with it'
		end
		OPX.Note(TAG, ('%d blips on %s (%d refused, %d unsurveyed points skipped)')
			:format(live, where, refused, skipped))
	end

	-- The quota is a server-shaped problem -- it means an operator captured more
	-- spots than the platform will pin -- so it is said once, with the numbers.
	if capped > 0 and not notedQuota then
		notedQuota = true
		OPX.Note(TAG, ('%d points are not pinned: the platform allows %d blips per ' ..
			'resource and this config asks for more'):format(capped, M.QUOTA))
	end
end

--- Starts a reconcile on a thread of its own, or marks one wanted.
-- The `syncing`/`dirty` pair is `modules/admin/client/target.lua`'s, for the
-- same reason: the pass yields, so a second scheduler tick can arrive in the
-- middle of one, and two passes interleaving over `created` would double-create.
local function sync()
	if syncing then
		dirty = true
		return
	end
	syncing = true
	CreateThread(function()
		repeat
			dirty = false
			local ok, failure = pcall(pass)
			if not ok then
				-- A raise here is how a module of this shape loses half its pins in
				-- silence, so it becomes a line rather than an absence.
				Open77.log.error(('[%s] reconcile: %s'):format(TAG, tostring(failure)))
			end
			-- A pass asked for during this one starts on a fresh resume rather
			-- than in the tail of the one that just finished.
			if dirty then Wait(0) end
		until not dirty
		syncing = false
	end)
end

-- ── the surface ─────────────────────────────────────────────────────────────

--- Every blip this module has up, by point id. The values are the platform's
--- 64-bit decimal-string handles.
-- @author dop42
-- @return table
function Runtime.Created()
	return created
end

--- What this client drew, for a diagnostic or a test.
-- @author dop42
-- @return table
function Runtime.Report()
	return {
		wanted = tally.wanted,
		live = tally.live,
		refused = tally.refused,
		skipped = tally.skipped,
		capped = tally.capped,
		minimap = minimapState(),
	}
end

--- Forces a reconcile now. Used by the tests, and by anything that knows a list
--- changed and does not want to wait out `SCAN_MS`.
-- @author dop42
function Runtime.Sync()
	sync()
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Clears everything this half holds. Never yields.
-- @author dop42
function Runtime.Init()
	created, drawn = {}, {}
	scanJob = nil
	syncing, dirty = false, false
	notedBoot, notedRefusal, notedQuota = false, false, false
	tally = { wanted = 0, live = 0, refused = 0, skipped = 0, capped = 0 }
end

--- Reports the config's faults once, then reconciles on the scan.
-- @author dop42
function Runtime.Start()
	-- THE CONFIG'S FAULTS ARE SAID AT BOOT AND NOT ON EVERY PASS. A `COLOUR` key
	-- or a RANGE of 9000 is a thing an operator typed and has to go and change;
	-- saying it every four seconds would bury the journal and would still not
	-- change it any faster.
	local _, problems = Runtime.Categories()
	for index = 1, #problems do
		Open77.log.warn(('[%s] %s'):format(TAG, problems[index]))
	end
	if #problems > 0 then
		OPX.Note(TAG, ('%d category settings were refused; the first is: %s')
			:format(#problems, problems[1]))
	end

	if api() == nil then
		-- Not a warning-and-continue: with no backend there is nothing to
		-- reconcile against, and a scan job that can only ever fail is a job that
		-- burns a slot forever.
		OPX.Note(TAG, 'Open77.blips is unavailable on this host; no pin will be drawn')
		return
	end

	scanJob = OPX.Scheduler.Every(TAG .. ':scan', positiveMs(settings().SCAN_MS, 4000), sync)
	-- One pass now, so a player who joins with their lists already in hand does
	-- not stare at an empty map for the length of a scan.
	sync()
end

--- Cancels the scan and takes every pin down.
-- @author dop42
function Runtime.Shutdown()
	if scanJob ~= nil then
		OPX.Scheduler.Cancel(scanJob)
		scanJob = nil
	end
	-- `clear()` rather than a remove per id: the platform drops a resource's
	-- blips when it stops anyway, and one call cannot run out of instruction
	-- budget partway through the way a hundred-iteration loop can.
	local native = api()
	if native ~= nil and type(native.clear) == 'function' then pcall(native.clear) end
	Runtime.Init()
end

-- ── the lifecycle ───────────────────────────────────────────────────────────
--
-- The three thin wrappers the kernel actually calls, in the shape
-- `modules/teleports/client/exports.lua` uses. They are separate from the
-- `Runtime` functions above rather than assigned to them so that a test can
-- drive one phase without the kernel, which is how every reconcile assertion in
-- `tests/run.lua` is written.
--
-- THERE IS NO `M.Api` AND THERE SHOULD NOT BE. Nothing in this resource needs
-- to ask this module anything: it consumes six lists and publishes pins. A
-- contract here would be a surface offered on the chance somebody wants it,
-- which is the thing `tests/run.lua`'s `CORE_NAMESPACE` note argues against one
-- level up.

--- Builds the client state. Never yields.
-- @author dop42
function M.Init()
	Runtime.Init()
end

--- Reports the config's faults, then reconciles on the scan.
-- @author dop42
function M.Start()
	Runtime.Start()
end

--- Cancels the scan and takes every pin down.
-- @author dop42
function M.Stop()
	Runtime.Shutdown()
end
