--- What a TweakDB vehicle record is, independently of who is looking at it.
-- @author dop42
--
-- ONE RULE AND ONE CONFIG KEY. Whether a record flies is a FACT ABOUT THE
-- RECORD: the garage that recalls it, the dealer that sells it and the staff
-- catalogue that lists it are three readers of one answer, not three answers.
-- It was three rules over three keys -- `config/garages.lua`,
-- `config/dealership.lua` and `VEHICLES.AV_PREFIXES` in `config/admin.lua` --
-- which agreed on the data and not on the code: two guarded the argument's type
-- and fell back to the documented pair, the third did neither, so emptying the
-- admin list alone silently reclassified every AV as ground in the staff
-- catalogue while the garage and the dealer went on calling the same records
-- air. Each of the three comments named one of the other two as the rule it
-- shared.
--
-- WHY THIS FILE AND NOT `lib/shared/text.lua`, WHERE IT WAS. That file's own
-- header says it holds "display text helpers that measure and cut in characters,
-- not bytes" -- `Span`, `Cut`, `Finite`. This is not one: it does not measure,
-- cut or display anything. It reads an operator's config block and answers a
-- question about a game entity, and it landed in `text.lua` only because the
-- author who un-duplicated it could not add a manifest line at the time and had
-- to put it in a file that was already declared. A helper filed under a header
-- that disclaims it is a helper the next author will not find, and will write a
-- fourth copy of.
--
-- WHY NOT `lib/shared/spots.lua` EITHER, which was the other candidate. Two of
-- the three readers are spot modules, and it is tempting: the AVPAD-versus-
-- GARAGE choice is exactly what this decides for them. But `modules/admin` is
-- the third reader and places nothing -- it lists every vehicle in the game --
-- and making the staff catalogue read the placed-spot vocabulary to ask what a
-- record is would be filing it under the wrong header a second time.

OPX.Vehicle = {}

-- The names `open77_avcleanup` sweeps the world by, read when the operator's
-- list is empty or unusable. An empty list must not mean "nothing flies": it
-- means the operator has not said, and the documented default is what the
-- platform itself says.
local AV_FALLBACK = { 'vehicle.av_', 'vehicle.max_tac', '_av', '_heli' }

-- The normalised list, and the config table it was built from. Rebuilt when that
-- table is REPLACED rather than on every call, because the admin catalogue asks
-- this question once per vehicle row inside a load-time instruction budget the
-- host will cancel the resource set for overrunning. Editing the list in place
-- will not be noticed; replacing it will.
local avEntries, avSource = nil, nil

-- Whether an entry found at `at` in `lowered` names a whole WORD and not three
-- letters in the middle of one. The word's end is what keeps `_av` from
-- declaring the Quadra Type-66 AVENGER an aircraft: its record carries
-- `_avenger`, whose `_av` runs straight on into `enger`. Either the entry
-- itself closes the word -- `vehicle.av_` names the whole family -- or the
-- name ends with the entry, or one of `_`, `.` and a digit follows it.
local function wordEntry(lowered, entry, at)
	local last = at + #entry - 1
	local tail = entry:sub(-1)
	if tail == '_' or tail == '.' or (tail >= '0' and tail <= '9') then return true end
	if last >= #lowered then return true end
	local char = lowered:sub(last + 1, last + 1)
	return char == '_' or char == '.' or (char >= '0' and char <= '9')
end

--- The words a player reads for a vehicle model: a catalogue label as it is, or a
--- TweakDB record turned into something readable. Nil for nothing usable.
-- @author dop42
--
-- `Vehicle.v_standard2_villefort_cortes_player` reads `Villefort Cortes`: the
-- namespace, the `v_` prefix, the class-and-size token (`standard2`, `sport1`
-- -- a word ENDING IN A DIGIT, so `militech_` in a record without one is kept)
-- and the `_player` suffix are the engine's filing, not the car's name. Moved
-- here from the vehicle keys so the garage list can say the same name; a list
-- of bare plates is a list nobody recognises their car in.
-- @param model any
-- @param maxBytes integer|nil
-- @return string|nil
function OPX.Vehicle.DisplayName(model, maxBytes)
	if type(model) ~= 'string' or model == '' then return nil end
	local name = model
	if name:find('^Vehicle%.') then
		name = name:gsub('^Vehicle%.', ''):gsub('^v_', ''):gsub('_player$', '')
		name = name:gsub('^%a+%d+_', '', 1)
		name = name:gsub('_', ' '):gsub('(%a)([%w]*)', function(first, rest)
			return first:upper() .. rest
		end)
	end
	name = name:gsub('%c', '')
	if name == '' then return nil end
	local limit = tonumber(maxBytes) or 48
	if #name > limit then name = name:sub(1, limit) end
	return name
end

--- Whether a TweakDB vehicle record names an AV.
-- @author dop42
--
-- The one reader of `OPX.Config.SHARED.AV_MATCHES`. Each entry is matched
-- lower-cased -- the database column and the wire disagree about case -- and
-- either names the record's start or lands on a word's end, which is the
-- difference between `vehicle.batty_av` being an aircraft and the Quadra
-- Type-66 AVENGER being one. A config written before the entries grew past
-- prefixes may still say `AV_PREFIXES`; both names are read.
-- @param record any
-- @return boolean
function OPX.Vehicle.IsAvRecord(record)
	if type(record) ~= 'string' then return false end

	local shared = type(OPX.Config) == 'table' and type(OPX.Config.SHARED) == 'table'
		and OPX.Config.SHARED or nil
	local configured = shared and (shared.AV_MATCHES or shared.AV_PREFIXES) or nil
	if avEntries == nil or avSource ~= configured then
		local list = {}
		if type(configured) == 'table' then
			for index = 1, #configured do
				local entry = configured[index]
				if type(entry) == 'string' and entry ~= '' then
					list[#list + 1] = entry:lower()
				end
			end
		end
		if #list == 0 then list = AV_FALLBACK end
		avEntries, avSource = list, configured
	end

	local lowered = record:lower()
	for index = 1, #avEntries do
		local entry = avEntries[index]
		local at = lowered:find(entry, 1, true)
		while at ~= nil do
			if wordEntry(lowered, entry, at) then return true end
			at = lowered:find(entry, at + 1, true)
		end
	end
	return false
end

-- ── the airframe's clearance ────────────────────────────────────────────────

-- Metres of air under a spawning AV when the operator has not said, and the
-- range one may be configured in. NOT the marker's GROUND_OFFSET, which is
-- centimetres of clearance so a ring is not co-planar with the floor: this is
-- metres under a chassis, and the two ranges say which is which.
local DEFAULT_AV_LIFT = 1.2
local MAX_AV_LIFT = 10.0

--- How high above the ground an AV is created.
-- @author dop42
--
-- THE SAME QUESTION AS `IsAvRecord`, ASKED SECOND. An AV record's pivot is the
-- chassis centre, so the offset that puts a car's wheels on the road leaves an
-- airframe half-buried in it; `IsAvRecord` says whether to lift, and this says
-- how far. There were three answers: `config/garages.lua` and
-- `config/dealership.lua` each clamped to 0..10 and fell back to 1.2, and
-- `modules/admin/server/vehicles.lua` read `Server.Setting(settings.AV_LIFT,
-- 1.2)`, which is a plain numeric default with NO BOUND -- so an operator who
-- typed 500 got an AV dropped from 500 metres out of the staff spawner and a
-- quiet 1.2 everywhere else. All three ship 1.2 today, which is exactly why
-- nobody noticed.
--
-- 0 is honoured, not replaced: an operator who wants an airframe on the deck of
-- a landing pad that is already at the right height has said so.
-- @param value any the operator's AV_LIFT
-- @return number
function OPX.Vehicle.AvLift(value)
	local lift = OPX.Math.Finite(value)
	if lift == nil or lift < 0.0 or lift > MAX_AV_LIFT then return DEFAULT_AV_LIFT end
	return lift
end

--- Appends the fault an unusable AV_LIFT is, against the bound `AvLift` clamps to.
-- @author dop42
-- @param value any
-- @param lines string[] collector, appended to
-- @return string[] the same collector
function OPX.Vehicle.AvLiftProblem(value, lines)
	local lift = OPX.Math.Finite(value)
	if lift == nil or lift < 0.0 or lift > MAX_AV_LIFT then
		lines[#lines + 1] = 'AV_LIFT must be a finite number, 0 to 10 metres'
	end
	return lines
end
