--- The crime ledger: who the city is looking for, and how hard.
-- @author XEROX710
--
-- ONE LEDGER PER CHARACTER, NOT PER CONNECTION. A ledger bound to a connection
-- would forget a wanted player the moment they dropped, and a wanted player
-- leaving and rejoining is the ordinary way out of a police chase -- so the key
-- is the citizen id the `character` contract hands out, and a reconnect rejoins
-- the city's memory of them.
--
-- A SCORE THAT CLIMBS ONE STAGE AT A TIME, IN THE ENGINE'S OWN SHAPE.
-- `shared/law.lua` owns what a crime costs and how the ladder is crossed; this
-- file owns only when each of those is asked, and remembers the answer. The
-- crossing rule is deliberately not "enough score to reach stage N": the engine
-- checks its threshold once per crime and ZEROES the score as it crosses
-- (`preventionSystem.script:2501`), so one enormous score buys one stage and
-- starts again from zero. `Law.Advance` is written to that shape and this file
-- never re-derives it.
--
-- THE STAGE FALLS BY TIME, NOT BY SCORE, AND THAT IS NOT A DETAIL. Every
-- crossing resets the score to zero on purpose, so "the score is zero" is the
-- state a player is in immediately after being promoted -- reading it as "no
-- longer wanted" would clear the stage this ledger just raised, on the same
-- call. The drop is therefore `DECAY.RESET_SECONDS` of nothing at all, which is
-- the module's own version of the engine's `HeatCrimeScoreResetTime`.
--
-- NOTHING IS PERSISTED YET, AND THAT IS SAID OUT LOUD. There is no table for
-- this module: a restart clears the city's memory of a crime. A player who
-- rejoins a restarted server is a free citizen, which is the same lie the
-- platform already tells about props, and it is the honest default until a
-- storage contract is chosen rather than an accident of a missing write.

local M = OPX.Modules.Get('ncpd')
local Law = M.Law

local Ledger = {}
M.Ledger = Ledger

--- One entry per character.
-- @field stage number the engine's heat stage this ledger has asked for
-- @field score number the score accumulated INSIDE that stage
-- @field lastCrimeMs integer `OPX.Now()` when the last crime was charged
local entries = {}

--- The character's entry, created on first charge.
-- @param citizenId string
-- @param nowMs integer|nil
-- @return table
local function entryFor(citizenId, nowMs)
	local entry = entries[citizenId]
	if entry == nil then
		entry = { stage = 0, score = 0.0, lastCrimeMs = tonumber(nowMs) or OPX.Now() }
		entries[citizenId] = entry
	end
	return entry
end

--- The character's entry, or nil. Never creates one: asking where somebody
--- stands must not put them on the ladder.
-- @param citizenId any
-- @return table|nil
local function peek(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then return nil end
	return entries[citizenId]
end

--- Drains the score as of `nowMs` and drops the stage once the reset has passed.
-- Called before every read and every charge, so nothing has to remember to.
-- @param citizenId string
-- @param nowMs integer|nil
-- @return table|nil entry
-- @return boolean whether the stage was dropped by this call
function Ledger.Decay(citizenId, nowMs)
	local entry = peek(citizenId)
	if entry == nil then return nil, false end

	local now = tonumber(nowMs) or OPX.Now()
	local seconds = (now - entry.lastCrimeMs) / 1000
	if seconds < 0 then seconds = 0 end

	local drained = Law.Decay(entry.score, seconds)
	if drained ~= entry.score then
		entry.score = drained
	end

	-- See the header: a zero score is the state right after a crossing, so the
	-- drop is the quiet window and nothing else.
	if Law.DecayReset > 0 and seconds >= Law.DecayReset and entry.stage > 0 then
		entry.stage = 0
		entry.score = 0.0
		entry.floor = 0
		return entry, true
	end

	return entry, false
end

--- Charges one offence to one character.
-- @param citizenId string
-- @param lawId string an id from the law book
-- @param options table|nil `{ nowMs, multiplier, district }`
-- @return table a `Result`: `{ ok, value }` charged, or `{ ok = false, error }`
function Ledger.Report(citizenId, lawId, options)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return OPX.Result.Err('ncpd.noCitizen')
	end
	if Law.Known(lawId) == false then
		return OPX.Result.Err('ncpd.unknownLaw', tostring(lawId))
	end

	local opts = type(options) == 'table' and options or {}
	local now = tonumber(opts.nowMs) or OPX.Now()

	-- The drain first: a crime reported ten minutes after the last is scored
	-- against what the player is still worth, never against their peak.
	local entry, dropped = Ledger.Decay(citizenId, now)
	if entry == nil then entry = entryFor(citizenId, now) end

	local verdict = Law.Accrue(entry, lawId, opts.multiplier, opts.district)
	if verdict.ok ~= true then
		return OPX.Result.Err('ncpd.refused', tostring(verdict.reason))
	end

	local previous = dropped and 0 or entry.stage
	entry.stage = verdict.stage
	entry.score = verdict.score
	-- What the SERVER charged is a floor the engine mirror cannot report away
	-- (see `Ledger.Mirror`).
	entry.floor = math.max(entry.floor or 0, entry.stage)
	entry.lastCrimeMs = now

	return OPX.Result.Ok({
		citizenId = citizenId,
		law = verdict.law,
		delta = verdict.delta,
		capped = verdict.capped == true,
		crossed = verdict.crossed == true,
		stage = entry.stage,
		previous = previous,
		division = Law.Division(entry.stage),
		heat = Law.Heat(entry.stage),
		score = entry.score,
		sinceSeconds = 0.0,
	})
end

--- Where one character stands now, after the drain.
-- @param citizenId string
-- @param nowMs integer|nil
-- @return table|nil `{ citizenId, stage, score, division, heat, wanted, sinceSeconds }`
function Ledger.Status(citizenId, nowMs)
	local entry = peek(citizenId) or entryFor(citizenId, nowMs)
	local now = tonumber(nowMs) or OPX.Now()
	local stage = entry.stage or 0
	return {
		citizenId = citizenId,
		stage = stage,
		score = entry.score or 0.0,
		division = Law.Division(stage),
		heat = Law.Heat(stage),
		wanted = stage > 0,
		sinceSeconds = math.max(0, (now - entry.lastCrimeMs) / 1000),
	}
end

--- The stage a character stands at, without draining or creating anything:
--- 0 for a character the ledger does not hold.
-- @param citizenId any
-- @return integer
function Ledger.Stage(citizenId)
	local entry = peek(citizenId)
	return entry ~= nil and (tonumber(entry.stage) or 0) or 0
end

--- Puts a character straight onto a stage, without a crime.
-- This is the job and test door: a bank job holds a crew at Heat_3 while it runs,
-- and an operator proving the response wants a stage without shooting anybody.
-- The score is left where it is, so the stage is a floor rather than a reset.
-- @param citizenId string
-- @param stage number 0..StageCount
-- @param nowMs integer|nil
-- @return table a `Result`
function Ledger.Set(citizenId, stage, nowMs)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return OPX.Result.Err('ncpd.noCitizen')
	end
	local wanted = tonumber(stage)
	if wanted == nil or wanted ~= math.floor(wanted)
		or wanted < 0 or wanted > Law.StageCount then
		return OPX.Result.Err('ncpd.unknownStage', tostring(stage))
	end

	local now = tonumber(nowMs) or OPX.Now()
	local entry = entryFor(citizenId, now)
	local previous = entry.stage
	entry.stage = wanted
	entry.floor = wanted
	entry.lastCrimeMs = now
	if wanted == 0 then entry.score = 0.0 end

	return OPX.Result.Ok({
		citizenId = citizenId,
		stage = wanted,
		previous = previous,
		crossed = wanted ~= previous,
		division = Law.Division(wanted),
		heat = Law.Heat(wanted),
		score = entry.score,
		delta = 0.0,
		capped = false,
		sinceSeconds = 0.0,
	})
end

--- Copies the stage a client says its own engine holds, never below the floor
--- the server itself charged or set.
--
-- THE REPORT IS A CLAIM FROM A MACHINE THE PLAYER OWNS. Copied straight through
-- `Set`, a modified client that sent `0` erased a murder the server had just
-- charged it, and took the response down with it. The engine may still RAISE a
-- stage (that is the crime only the engine saw) and bring an engine-raised stage
-- back down, but what `Report`/`Set` put there is the server's, and only the
-- server's own decay or a `Clear` lowers it. A report pinned to the floor does
-- not refresh the quiet window either, or a client reporting `0` every heartbeat
-- would hold the floor up for ever instead of letting it decay.
-- @param citizenId string
-- @param stage number 0..StageCount
-- @param nowMs integer|nil
-- @return table a `Result`, the same shape `Set` answers
function Ledger.Mirror(citizenId, stage, nowMs)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return OPX.Result.Err('ncpd.noCitizen')
	end
	local wanted = tonumber(stage)
	if wanted == nil or wanted ~= math.floor(wanted)
		or wanted < 0 or wanted > Law.StageCount then
		return OPX.Result.Err('ncpd.unknownStage', tostring(stage))
	end

	local now = tonumber(nowMs) or OPX.Now()
	-- NOT `Decay` here: a drop is the decay pass's to find, publish and announce.
	local entry = peek(citizenId)
	if entry == nil then
		if wanted == 0 then
			return OPX.Result.Ok({ citizenId = citizenId, stage = 0, previous = 0, crossed = false })
		end
		entry = entryFor(citizenId, now)
	end
	local previous = entry.stage
	local floor = entry.floor or 0
	local effective = math.max(wanted, floor)
	entry.stage = effective
	if wanted >= floor and wanted > 0 then entry.lastCrimeMs = now end
	if effective == 0 then entry.score = 0.0 end

	return OPX.Result.Ok({
		citizenId = citizenId,
		stage = effective,
		previous = previous,
		crossed = effective ~= previous,
		pinned = wanted < floor,
		division = Law.Division(effective),
		heat = Law.Heat(effective),
		score = entry.score,
		delta = 0.0,
		capped = false,
		sinceSeconds = 0.0,
	})
end

--- Forgets everything the city holds against a character.
-- @param citizenId string
-- @return table a `Result`: `{ ok, value = { stage = 0 } }`, or a refusal
function Ledger.Clear(citizenId)
	if type(citizenId) ~= 'string' or citizenId == '' then
		return OPX.Result.Err('ncpd.noCitizen')
	end
	local entry = peek(citizenId)
	local previous = entry ~= nil and entry.stage or 0
	entries[citizenId] = nil
	return OPX.Result.Ok({ citizenId = citizenId, stage = 0, previous = previous })
end

--- Every character the ledger is holding, for the decay pass.
-- @return table[] a list of `{ citizenId, entry }`, a snapshot of the keys
function Ledger.All()
	local list = {}
	for citizenId, entry in pairs(entries) do
		list[#list + 1] = { citizenId = citizenId, entry = entry }
	end
	return list
end

--- How many characters the ledger is holding.
-- @return integer
function Ledger.Count()
	local total = 0
	for _ in pairs(entries) do total = total + 1 end
	return total
end

--- Drops every entry. The module's `Stop` uses it, so a resource restart does not
--- leave a stale stage in memory that nothing will ever ask the client about.
function Ledger.Forget()
	entries = {}
end
