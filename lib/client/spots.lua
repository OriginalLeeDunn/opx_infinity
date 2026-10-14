--- The client half of a placed spot: its markers, and the key that uses it.
-- @author dop42
--
-- `lib/shared/spots.lua` is the record -- what a spot is, how it is read off a
-- config or the wire, which one a player stands on. This is what every module
-- that draws spots did with them on the client, written once. `garages`,
-- `dealership`, `clothing` and `teleports` each held a copy of the marker set
-- (create, remove, reconcile, clear), and those four plus the elevator door each
-- held a copy of the key mapping (register, read the answer, the silent press).
-- Five copies of one behaviour drift; the eight-markers-a-pass cap had already
-- reached three of them and not the fourth.
--
-- Hung on `OPX.Spots` rather than a namespace of its own: it is the same subject,
-- and the namespace list in the test suite is the boundary of what the runtime
-- publishes.

OPX.Spots = OPX.Spots or {}

--- Whether another surface holds the keyboard: the chat box, a form, the pause
--- menu. A read that raises answers FREE, where `OPX.Lib.Input.IsCaptured`
--- answers captured -- the spots modules have always read it this way, and a key
--- that went dead because a host read failed would be a key nobody can explain.
-- @author dop42
-- @return boolean
function OPX.Spots.Captured()
	local input = Open77.input
	if type(input) ~= 'table' or type(input.isCaptured) ~= 'function' then return false end
	local read, answer = pcall(input.isCaptured)
	return read and answer == true
end

--- The player's own ground position, or nil before there is a world to read.
-- `Open77.character.position()` answers numbers, not a table.
-- @author dop42
-- @return number|nil x
-- @return number|nil y
function OPX.Spots.PlayerXY()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then
		return nil, nil
	end
	local read, x, y = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' or x ~= x or y ~= y then
		return nil, nil
	end
	return x, y
end

-- ── the markers ─────────────────────────────────────────────────────────────

--- Markers one set creates in one pass, at most. A marker is an engine call and
--- a pass runs in one resume: the first list, or a change of bucket, used to
--- create every marker in range at once -- the "dozens of engine calls in one
--- resume" shape the platform's per-resume instruction budget ends without a
--- word (`modules/blips` caps its pins for the same reason). The rest come on the
--- next passes; a removal is never deferred.
OPX.Spots.MARKER_CREATES_PER_PASS = 8

OPX.Spots.Markers = {}

--- A set of engine markers kept in line with a spot list.
-- @author dop42
-- @param options table
--   tag          string   the module name, for the one log line a refusal gets
--   look         function (spot) -> { shape, style, radius, lift }
--   maxDistance  function () -> metres; a spot within it has a marker
--   variant      function|nil (spot) -> any; a marker whose variant changed is
--                remade, because a marker's style is fixed when it is created
-- @return table the set: `Reconcile(list, x, y)`, `Clear()`, `Count()`, `Has(key)`
function OPX.Spots.Markers.New(options)
	local tag = tostring(options.tag or 'spots')
	local look, maxDistance, variant = options.look, options.maxDistance, options.variant
	local markers, drawn = {}, {}
	local reported = false
	local set = {}

	-- Creates one marker, or answers why it could not be. Never raises. The draw
	-- distance is the pass's, read once: resolving it again per marker was
	-- another config clamp inside the scan's one resume.
	local function create(spot, limit)
		local api = Open77.markers
		if type(api) ~= 'table' or type(api.create) ~= 'function' then
			return nil, 'world.markers is unavailable'
		end
		local shape = look(spot)
		local read, id, reason = pcall(api.create, {
			-- The spot's declared height plus the look's own lift: a marker left
			-- at floor height is co-planar with the floor and draws nothing.
			position = { x = spot.x, y = spot.y, z = spot.z + (shape.lift or 0) },
			shape = shape.shape,
			style = shape.style,
			radius = shape.radius,
			maxDistance = limit,
		})
		if not read then return nil, tostring(id) end
		if id == nil then return nil, tostring(reason or 'refused') end
		return id, nil
	end

	-- Removes one marker without raising.
	local function remove(id)
		local api = Open77.markers
		if type(api) ~= 'table' or type(api.remove) ~= 'function' then return end
		pcall(api.remove, id)
	end

	local function forget(key)
		remove(markers[key])
		markers[key], drawn[key] = nil, nil
	end

	--- Brings the drawn set in line with what is in range: a spot within
	--- `maxDistance()` has a marker, one beyond it does not, and a spot the list
	--- no longer names loses its marker even while in range.
	-- THE POSITION IS HANDED IN, NOT READ HERE: the caller has just read it to
	-- find the nearest spot, and a second read per pass is a second host call
	-- for the same answer. Nil means it could not be read, and draws nothing.
	-- @param list table key -> spot
	-- @param x number|nil
	-- @param y number|nil
	--
	-- THE POSITION IS COERCED ONCE A PASS, and the distance worked out inline:
	-- `FlatDistanceSquared` re-coerced it for every spot on the list, in a scan
	-- that runs inside the scheduler's shared resume -- most of the meter's
	-- 9,200 for `garages:scan` on a twenty-point lot.
	function set.Reconcile(list, x, y)
		local limit = maxDistance()
		local reach = limit * limit
		local creates = 0
		if x ~= nil then x, y = OPX.Spots.Coordinate(x), OPX.Spots.Coordinate(y) end
		local located = x ~= nil and y ~= nil
		local cap = OPX.Spots.MARKER_CREATES_PER_PASS
		for key, spot in pairs(list) do
			local wanted = false
			if located then
				local dx, dy = x - spot.x, y - spot.y
				wanted = dx * dx + dy * dy <= reach
			end
			local have = markers[key]
			if wanted then
				if have ~= nil and variant ~= nil and drawn[key] ~= variant(spot) then
					forget(key)
					have = nil
				end
				if have == nil and creates < cap then
					creates = creates + 1
					local id, failure = create(spot, limit)
					if id == nil then
						if not reported then
							reported = true
							Open77.log.warn(('[%s] no marker is drawn: %s'):format(tag, tostring(failure)))
						end
					else
						markers[key] = id
						if variant ~= nil then drawn[key] = variant(spot) end
					end
				end
			elseif have ~= nil then
				forget(key)
			end
		end
		for key in pairs(markers) do
			if list[key] == nil then forget(key) end
		end
	end

	--- Drops every marker this set drew.
	function set.Clear()
		for key in pairs(markers) do forget(key) end
	end

	--- How many markers are drawn.
	-- @return integer
	function set.Count()
		local count = 0
		for _ in pairs(markers) do count = count + 1 end
		return count
	end

	--- Whether a spot has a marker drawn.
	-- @param key any
	-- @return boolean
	function set.Has(key)
		return markers[key] ~= nil
	end

	--- Forgets whether a refusal was already logged, for a module's Init.
	function set.Reset()
		markers, drawn, reported = {}, {}, false
	end

	return set
end

-- ── the key ─────────────────────────────────────────────────────────────────

OPX.Spots.Key = {}

--- Declares the rebindable key a spot module uses, and answers whether the host
--- took it.
-- @author dop42
--
-- THE SILENT PRESS. E is shared -- garages, dealership, clothing, teleports,
-- doors and the elevator door all declare it -- so a press while another surface
-- holds the keyboard does nothing at all, a press another of them owns is not
-- this one's (`wants`, below), and the module's own handler decides what a
-- press away from its spots says (each of them: nothing). The handler runs under
-- pcall, so a raise is a log line and not a dead key.
--
-- The mapping's name is translated at registration and its id is stable,
-- because a player's rebind is stored under the id. `DEFAULT = false` declares
-- no key. Two answer shapes are documented for the host call -- the effective
-- key, or `true, key` -- and both are read; reading only the second logged a
-- working mapping as refused.
-- @param options table
--   tag      string   the module name, for the log lines
--   declared table    { ID, NAME, DEFAULT } as the module's KEY block reads
--   onPress  function (origin) called with 'key'
--   wants    function|nil (x, y, z) -> rank|nil, distance|nil: enters the
--            mapping into the contest for its key, see `OPX.Spots.Key.Owns`
-- @return boolean registered
function OPX.Spots.Key.Register(options)
	local tag = tostring(options.tag or 'spots')
	local declared = options.declared
	if type(declared) ~= 'table' or declared.DEFAULT == false then return false end
	local onPress = options.onPress
	local called, ok, answer = pcall(RegisterKeyMapping, declared.ID, locale(declared.NAME),
		declared.DEFAULT, function()
			if OPX.Spots.Captured() then return end
			if not OPX.Spots.Key.Owns(declared.ID) then return end
			local ran, failure = pcall(onPress, 'key')
			if not ran then
				Open77.log.error(('[%s] key %s: %s'):format(tag, declared.ID, tostring(failure)))
			end
		end)
	local effective = nil
	if called then
		effective = type(ok) == 'string' and ok ~= '' and ok
			or (ok == true and type(answer) == 'string' and answer ~= '' and answer) or nil
	end
	if not called or (ok ~= true and effective == nil) then
		Open77.log.warn(('[%s] key mapping %s (%s) not registered: %s')
			:format(tag, declared.ID, tostring(declared.DEFAULT), tostring(called and answer or ok)))
		return false
	end
	if type(options.wants) == 'function' then
		OPX.Spots.Key.Contend({ tag = tag, id = declared.ID, default = declared.DEFAULT,
			wants = options.wants })
		-- The key the host just answered with is the binding, so the row's
		-- claim starts with it and makes no host read at all until a rebind.
		OPX.Spots.Key.Prime(declared.ID, effective)
	end
	return true
end

--- The key a registered mapping is bound to now, or nil when it is not
--- registered: a row with no key to name says nothing.
-- @author dop42
-- @param registered boolean what `Register` answered
-- @param declared table { ID, DEFAULT }
-- @return string|nil
function OPX.Spots.Key.Label(registered, declared)
	if not registered or type(declared) ~= 'table' then return nil end
	return OPX.Lib.Input.KeyFor(declared.ID) or declared.DEFAULT
end

-- ── one press, one owner ────────────────────────────────────────────────────
--
-- THE HOST FIRES EVERY MAPPING BOUND TO A KEY FROM ONE PRESS, in an order nobody
-- chose. E is declared by six modules and X by four, so "each handler is silent
-- away from its own context" was the whole rule -- and it held only until two
-- contexts overlapped: a garage spot beside a managed door turned the door AND
-- asked for the car; X to put a crate down during a call also hung the call up.
--
-- A contested press goes to ONE mapping. Each contender says whether it has
-- something to do right now and at which rank (`OPX.Config.CLIENT.KEY_PRIORITY`),
-- the highest acts, and at equal rank the nearer one does. The first handler of a
-- press decides for all of them, BEFORE any of them has acted -- the second
-- handler to run would otherwise see the world the first one just changed (a bar
-- already cancelled, an emote already stopped) -- and the decision is kept until
-- every other contender on that key has asked once.
--
-- When nobody wants the press, every handler runs as it always did, each silent
-- away from its own context: a contest decides between features that have
-- something to do, it never invents one.

--- A decision older than this is a stale press, never the current one. The host
--- calls every mapping of one press a frame apart at most.
OPX.Spots.Key.PRESS_MS = 500

--- The ranks when the config names none, highest first in effect.
OPX.Spots.Key.RANK_DEFAULTS = {
	PROGRESS = 100, PICK = 95, OPEN = 90, RINGING = 80, OUTGOING = 70,
	CARRY = 60, EMOTE = 50, SPOT = 20, CALL = 10,
}

-- id -> { id, default, wants, tag }
local contenders = {}
-- physical key -> { winner, pending = { id = true }, atMs }
local decisions = {}
-- mapping id -> { rank, distance, atMs }, filed by each module's scan: see `Shows`
local claims = {}
-- mapping id -> the physical key it is bound to, for the strip rows only. A
-- press reads the host every time; a row reads this, which a rebind clears.
local bindings = {}

--- The rank one context name stands at.
-- @author dop42
-- @param name string one of `RANK_DEFAULTS`'s names
-- @return number
function OPX.Spots.Key.Rank(name)
	local client = OPX.Config and OPX.Config.CLIENT
	local ranks = type(client) == 'table' and client.KEY_PRIORITY or nil
	local value = type(ranks) == 'table' and ranks[name] or nil
	if type(value) == 'number' and value == value then return value end
	return OPX.Spots.Key.RANK_DEFAULTS[name] or 0
end

-- The physical key a contender is bound to now, rebinds included, upper-cased so
-- 'e' and 'E' are the same key.
local function boundTo(contender)
	local key = OPX.Lib.Input.KeyFor(contender.id) or contender.default
	return type(key) == 'string' and key:upper() or nil
end

--- Enters one mapping into the contest for the key it is bound to. A mapping that
--- never contends is never held back.
-- @author dop42
-- @param options table
--   id      string    the mapping id, as declared
--   default string    the declared default key
--   wants   function  (x, y, z) -> rank|nil, distance|nil; nil when this press
--                     is nothing to it. Runs under pcall, and must not act. A
--                     press hands it the position; a row's claim (`Shows`)
--                     hands it none, and it answers from its last scan.
--   tag     string|nil the module, for the one log line a raise gets
function OPX.Spots.Key.Contend(options)
	if type(options) ~= 'table' or type(options.id) ~= 'string' or type(options.wants) ~= 'function' then
		return
	end
	contenders[options.id] = { id = options.id, default = options.default, wants = options.wants,
		tag = tostring(options.tag or 'spots') }
	decisions, claims = {}, {}
end

-- The player's position, read once a press, or nils before there is a world.
local function position()
	local character = Open77.character
	if type(character) ~= 'table' or type(character.position) ~= 'function' then return nil end
	local read, x, y, z = pcall(character.position)
	if not read or type(x) ~= 'number' or type(y) ~= 'number' then return nil end
	return x, y, type(z) == 'number' and z or 0.0
end

-- Decides a fresh press among the contenders bound to one key: the winner's id,
-- or nil when nobody wants it.
local function decide(rivals)
	local x, y, z = position()
	local winner, bestRank, bestDistance = nil, nil, nil
	for index = 1, #rivals do
		local contender = rivals[index]
		local id = contender.id
		local ran, rank, distance = pcall(contender.wants, x, y, z)
		if not ran then
			Open77.log.error(('[%s] key %s: %s'):format(contender.tag, id, tostring(rank)))
		elseif type(rank) == 'number' then
			distance = type(distance) == 'number' and distance or math.huge
			if winner == nil or rank > bestRank or (rank == bestRank and (distance < bestDistance
				or (distance == bestDistance and id < winner))) then
				winner, bestRank, bestDistance = id, rank, distance
			end
		end
	end
	return winner
end

--- Whether this press of a mapping's key is this mapping's to act on.
-- @author dop42
--
-- True for a mapping that does not contend, and for every contender when none of
-- them wants the press. Otherwise true for exactly one of the mappings bound to
-- that key, whichever order the host calls them in.
-- @param id string the mapping id
-- @return boolean
function OPX.Spots.Key.Owns(id)
	local me = contenders[id]
	if me == nil then return true end
	local physical = boundTo(me)
	if physical == nil then return true end
	local now = OPX.Now()
	local decision = decisions[physical]
	if decision ~= nil and decision.pending[id] and now - decision.atMs <= OPX.Spots.Key.PRESS_MS then
		decision.pending[id] = nil
		if next(decision.pending) == nil then decisions[physical] = nil end
		return decision.winner == nil or decision.winner == id
	end

	-- One key read per contender per press: the rivals are listed once and both
	-- the decision and the pending set are made from that list.
	local rivals, pending = { me }, {}
	for other, contender in pairs(contenders) do
		if other ~= id and boundTo(contender) == physical then
			rivals[#rivals + 1] = contender
			pending[other] = true
		end
	end
	local winner = decide(rivals)
	decisions[physical] = next(pending) ~= nil and { winner = winner, pending = pending, atMs = now } or nil
	return winner == nil or winner == id
end

-- ── the row follows the contest ─────────────────────────────────────────────
--
-- TWO ROWS NAMING ONE KEY, ONE OF WHICH WILL DO NOTHING. A garage spot beside a
-- door drew "E Garage" AND "E Unlock door", and the press went to one of them.
-- A strip row now asks `Shows` before it is drawn: the row of a contender that
-- would lose the press right now is not drawn.
--
-- EVERY MODULE CLAIMS FROM ITS OWN SCAN, AND READS THE OTHERS' CLAIMS. A row
-- that ran the whole contest -- every rival's `wants` and key -- from inside a
-- scan put a thousand instructions into the scheduler's shared resume. Each
-- module asks `Shows` once a scan, which runs ITS OWN `wants` once and files the
-- answer; the comparison is then a walk over at most six filed claims, with no
-- host read but the one position. A claim not renewed within CLAIM_MS (a module
-- that stopped scanning) is ignored. A press still decides from the live state
-- (`Owns`): a row lags its scan by at most one pass, a key never does.

--- How long a filed claim stands without being renewed by its module's scan.
OPX.Spots.Key.CLAIM_MS = 1500

-- The key a contender is bound to, read from the host once and then kept until
-- a rebind: an answer that changes only when a player opens the pause menu.
local function cachedBinding(contender)
	local known = bindings[contender.id]
	if known == nil then
		known = boundTo(contender) or false
		bindings[contender.id] = known
	end
	return known or nil
end

AddEventHandler(OPX.Host.KEYBINDS_CHANGED, function()
	bindings = {}
end)

--- Keeps the key a contender is bound to, for its strip row: the key the host
--- answered its registration with, or nothing (the first `Shows` then reads it).
-- @author dop42
-- @param id string
-- @param key string|nil
function OPX.Spots.Key.Prime(id, key)
	if contenders[id] ~= nil and type(key) == 'string' and key ~= '' then bindings[id] = key:upper() end
end

-- Whether a filed claim takes the press from another: the higher rank, then
-- the nearer, then the id -- the order `decide` uses.
local function beats(claim, id, other, otherId)
	if claim.rank ~= other.rank then return claim.rank > other.rank end
	if claim.distance ~= other.distance then return claim.distance < other.distance end
	return id < otherId
end

--- Files this mapping's claim from its module's scan, and answers whether its
--- strip row should be drawn: true unless another mapping on the same key holds
--- a claim that would take the press. Call it every scan, row or no row, so a
--- claim that lapsed is withdrawn.
-- @author dop42
-- @param id string the mapping id
-- @return boolean
function OPX.Spots.Key.Shows(id)
	local me = contenders[id]
	if me == nil then return true end
	local now = OPX.Now()
	local ran, rank, distance = pcall(me.wants, nil, nil, nil)
	if not ran then
		Open77.log.error(('[%s] key %s: %s'):format(me.tag, id, tostring(rank)))
		claims[id] = nil
		return true
	end
	if type(rank) ~= 'number' then
		claims[id] = nil
		return true
	end
	local mine = { rank = rank, distance = type(distance) == 'number' and distance or math.huge, atMs = now }
	claims[id] = mine
	local physical = cachedBinding(me)
	if physical == nil then return true end
	for other, claim in pairs(claims) do
		if other ~= id and now - claim.atMs <= OPX.Spots.Key.CLAIM_MS then
			local contender = contenders[other]
			if contender ~= nil and cachedBinding(contender) == physical and beats(claim, other, mine, id) then
				return false
			end
		end
	end
	return true
end

--- The flat distance from a position to a spot, for a contender's `wants`; nil
--- when either cannot be read, which ranks the spot behind any that can.
-- @author dop42
--
-- WITH NO POSITION -- a claim filed from a scan (`Shows`) -- it answers the
-- distance that scan already measured, so a row costs no second host read.
-- @param spot table|nil anything with numeric `x` and `y`
-- @param x number|nil
-- @param y number|nil
-- @param measuredSq number|nil the squared distance the module's scan found
-- @return number|nil
function OPX.Spots.Key.Reach(spot, x, y, measuredSq)
	if x == nil and type(measuredSq) == 'number' then return math.sqrt(measuredSq) end
	if type(spot) ~= 'table' or type(spot.x) ~= 'number' or type(spot.y) ~= 'number'
		or type(x) ~= 'number' or type(y) ~= 'number' then
		return nil
	end
	local dx, dy = x - spot.x, y - spot.y
	return math.sqrt(dx * dx + dy * dy)
end

-- ── Escape: the top layer, and only the top layer ───────────────────────────
--
-- ESCAPE CLOSED EVERYTHING AT ONCE. `open77_pause` swallows it and raises
-- `open77:pauseKey` to every listener, and a menu, a form, a panel, the door
-- panel, the chat box and the call hologram each closed itself on it: a menu
-- opened over the hologram took the hologram down with it. Escape is now a
-- contest like E and X, on a key no mapping is bound to, and the rank of an
-- open layer is WHEN it opened: the newest takes the press and the rest stay.

--- The pseudo-key the layers contend for.
OPX.Spots.Key.ESCAPE = 'ESCAPE'

--- Enters one layer into the contest for Escape.
-- @author dop42
-- @param layer string the layer's name, e.g. 'menu'
-- @param openedAt function () -> ms|nil: when the layer opened, nil when shut
-- @return string the contender id its pause handler asks `TopLayer` with
function OPX.Spots.Key.Layer(layer, openedAt)
	local id = 'escape.' .. tostring(layer)
	OPX.Spots.Key.Contend({ tag = tostring(layer), id = id, default = OPX.Spots.Key.ESCAPE,
		wants = function()
			local at = openedAt()
			if type(at) ~= 'number' then return nil end
			return at
		end })
	return id
end

--- Whether this Escape is this layer's: asked FIRST in every pause handler.
-- @author dop42
-- @param id string what `Layer` answered
-- @return boolean
function OPX.Spots.Key.TopLayer(id)
	return OPX.Spots.Key.Owns(id)
end
