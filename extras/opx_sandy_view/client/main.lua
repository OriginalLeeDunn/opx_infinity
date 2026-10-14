-- opx_sandy_view, client: holds the OWNER's Sandevistan clock.
--
-- The platform writes a time-scale claim on the engine's global layer under the
-- reason `open77:<resource>`, and stands its session dilation guard down while
-- a claim is live. Claimed HERE, the owner's clock is `open77:opx_sandy_view`:
-- the REDscript this resource ships (r6/scripts/opx_infinity/
-- OpxSandevistanView.reds) sees that reason, exempts V from it -- the world
-- slows, V does not, the base game's own asymmetry -- and puts the camera on the
-- `Sandevistan` curve. Players slowed around the owner are slowed by
-- opx_infinity's own claim, which the REDscript leaves alone.
--
-- Called by opx_infinity (modules/ripperdoc/client/sandevistan.lua) through
-- `Open77.exports.callSync("opx_sandy_view", ...)`: `engage` / `release` for
-- the owner's clock, `wear` for the real item, `develop` for the base game's
-- own development (an admin's "max all levels"), `info` for the report.

-- The claim never outlives a boost: the platform's own ceiling is an hour; the
-- ripperdoc runs a Sandevistan for up to 40 s (level-scaled), 45 s with its
-- ease (up to 1.4.8 this was 20 s, which would have ended a longer boost's
-- slowed world halfway).
local MAX_MS = 45000
local holding = false

local function door()
	local world = Open77.world
	if type(world) ~= 'table' or type(world.setTimeScale) ~= 'function' then return nil end
	return world
end

--- Slows this machine's world to `scale` for `ms`; answers true or false, why.
exports('engage', function(scale, ms, easeMs)
	local world = door()
	if world == nil then return false, 'no_timescale_on_this_build' end
	scale = tonumber(scale)
	ms = math.floor(tonumber(ms) or 0)
	easeMs = math.max(0, math.min(2000, math.floor(tonumber(easeMs) or 0)))
	if scale == nil or scale < 0.05 or scale >= 1 or ms < 250 then return false, 'invalid_request' end
	local ran, ok, why = pcall(world.setTimeScale, scale, { durationMs = math.min(ms, MAX_MS), easeMs = easeMs })
	holding = ran and ok == true
	if not ran then return false, tostring(ok) end
	return ok == true, why
end)

--- Gives the clock back.
exports('release', function(easeMs)
	local world = door()
	if world == nil or not holding then
		holding = false
		return true
	end
	holding = false
	easeMs = math.max(0, math.min(2000, math.floor(tonumber(easeMs) or 0)))
	local ran, ok, why = pcall(world.setTimeScale, 1, { easeMs = easeMs })
	if not ran then return false, tostring(ok) end
	return ok == true, why
end)

-- THE REAL ITEM. A Lua resource reaches this resource's REDscript through
-- nothing but the clock, so a request for the base game's own item is a claim
-- held at `0.999 - code / 10000` for WEAR_MS: a message, not a slowdown (the
-- world 0.1 % slower for half a second), which the REDscript takes only when
-- two samples in a row agree. Code 1 asks for the Militech Apogee Sandevistan
-- in the Operating System slot, 0 for none; the REDscript fits it with the
-- base game's own equipment system and remembers the request for a new body.
local WEAR_BASE, WEAR_STEP, WEAR_MS = 0.999, 0.0001, 600

--- Asks the REDscript for the item `code` names; answers true or false, why.
--- Never over a boost: the boost's own claim is the one that must hold.
exports('wear', function(code)
	local world = door()
	if world == nil then return false, 'no_timescale_on_this_build' end
	code = tonumber(code)
	if code == nil or code ~= math.floor(code) or code < 0 or code > 9 then return false, 'invalid_code' end
	if holding then return false, 'boosting' end
	local ran, ok, why = pcall(world.setTimeScale, WEAR_BASE - code * WEAR_STEP, { durationMs = WEAR_MS, easeMs = 0 })
	if not ran then return false, tostring(ok) end
	return ok == true, why
end)

-- THE BASE GAME'S DEVELOPMENT (1.4.9). An admin's "max all levels" on the
-- server also maxes the base game's own development on the admin's machine,
-- through the same clock message with codes the real item never uses (0-9 are
-- its): 10 = the character's level, street cred, attributes, skills, perk and
-- relic points to the base game's own maxima. The REDscript applies it once
-- per request with the base game's own PlayerDevelopmentData, remembers it for
-- the session and applies it again on a new body.
local DEVELOP = { [10] = 'max everything' }

--- Asks the REDscript for the development `code` names; answers true or false, why.
--- Never over a boost: the boost's own claim is the one that must hold.
exports('develop', function(code)
	local world = door()
	if world == nil then return false, 'no_timescale_on_this_build' end
	code = tonumber(code)
	if code == nil or DEVELOP[code] == nil then return false, 'invalid_code' end
	if holding then return false, 'boosting' end
	local ran, ok, why = pcall(world.setTimeScale, WEAR_BASE - code * WEAR_STEP, { durationMs = WEAR_MS, easeMs = 0 })
	if not ran then return false, tostring(ok) end
	return ok == true, why
end)

--- What this resource is, for opx_infinity's report.
exports('info', function()
	return { version = '1.4.17', reason = 'open77:' .. GetCurrentResourceName(), holding = holding }
end)
