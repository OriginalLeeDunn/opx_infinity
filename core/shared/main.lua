--- The OPX namespace. Every file loaded after this one fills it.
-- @author dop42

OPX = OPX or {}

--- The version this resource's manifest declares.
--
-- ASKED, NOT COPIED, and the reason is that the copy was wrong. This was the
-- literal `'0.1.0'` while `open77.lua` said `0.1.2`, so every boot line, every
-- diagnostics dump and every client report named a version that had not been
-- deployed for two releases -- and the only symptom was somebody reading the
-- wrong number while chasing something else. `opx_lib` carries a test against
-- exactly this failure because it happened there first; here it happened and
-- nothing was watching.
--
-- Both runtimes can answer it and neither needs a permission: the client has
-- `Open77.resource.version()`, and the server reads its own manifest through
-- `Open77.resource.metadata(name, 'version')`. The literal below is the last
-- resort for a host that answers neither. `tests/run.lua` reads this very line
-- out of this file and holds it against the manifest, so even that path cannot
-- drift silently -- and it is read from the SOURCE rather than published on
-- `OPX`, because the suite forbids hanging internals there and is right to.
local DECLARED = '0.2.0'

local function manifestVersion()
	local resource = Open77 ~= nil and Open77.resource or nil
	if type(resource) ~= 'table' then return DECLARED end

	if type(resource.version) == 'function' then
		local read, version = pcall(resource.version)
		if read and type(version) == 'string' and version ~= '' then return version end
	end

	if type(resource.metadata) == 'function' and type(resource.name) == 'function' then
		local named, name = pcall(resource.name)
		if named and type(name) == 'string' and name ~= '' then
			local read, version = pcall(resource.metadata, name, 'version')
			if read and type(version) == 'string' and version ~= '' then return version end
		end
	end

	return DECLARED
end

OPX.VERSION = manifestVersion()

-- Both globals are installed by the bootstrap before the first script, and each
-- exists in exactly one runtime. `Open77.database` cannot be used for this: it is
-- only installed with the `database.access` permission.
--
-- AN ORDINARY GLOBAL READ, and `rawget` being absent is the point. These were
-- `rawget(_G, 'TriggerClientEvent')`, which is wrong twice over: `rawget` skips
-- a metatable, so a host exposing a global through an `__index` accessor answers
-- nil; and `_G` is not necessarily the chunk's `_ENV`, so a host that hands a
-- resource its own environment answers nil again. Either way BOTH of these go
-- false, `runsHere` in the registry then answers false for 'server' and for
-- 'client', and every side-specific module is marked absent -- a resource that
-- boots, logs a clean module report, and does nothing.
--
-- It bought nothing. Reading a global that is not there yields nil in Lua and
-- never raises, which is the only thing `rawget` could have been guarding. This
-- is the same defect `opx_lib/client/native.lua` was fixed for, and that library
-- carries a regression test for it; the eight other sites in `core/` and `lib/`
-- were corrected with this one.
OPX.IsServer = TriggerClientEvent ~= nil
OPX.IsClient = TriggerServerEvent ~= nil

--- Configuration roots, filled by `config/`. `SERVER` is nil on a client and
--- `CLIENT` is nil on the server, so reading the wrong one fails loudly.
OPX.Config = OPX.Config or { SHARED = {}, MODULES = {} }

local resolvedTimer

--- Monotonic milliseconds since process start.
-- @author dop42
-- @return integer
function OPX.Now()
	-- Resolved on first use, not at load: during boot the global may not be
	-- installed yet, and a fallback captured now would be captured forever.
	if resolvedTimer == nil then
		resolvedTimer = GetGameTimer or false
	end
	-- WHOLE MILLISECONDS, WHATEVER THE TIMER ANSWERS. The platform's
	-- `GetGameTimer` carries a fraction (`227832.75839999` on the box that
	-- found this), and `%d` raises on one -- the record reader's nonce and
	-- the stand-up re-projection token both died printing it, which left
	-- records unread and a fitted Sandevistan dead until the next session.
	-- The contract has always been an integer; make it one.
	local at = tonumber(resolvedTimer and resolvedTimer() or Open77.time.monotonic() * 1000)
	if at == nil or at ~= at or at == math.huge or at == -math.huge then return 0 end
	return math.floor(at)
end
