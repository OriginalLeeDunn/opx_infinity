--- The scaffolding both creator surfaces stand on: who is calling, whether they
--- are admitted, and the one shape every answer takes.
-- @author dop42
--
-- `core/server/exports.lua` and `core/client/exports.lua` each carried their
-- own copy of all of this, line for line: the caller pattern, the read of
-- `GetInvokingResource`, the allowlist test, the `{ ok, value }` /
-- `{ ok = false, error }` constructors and the check that the host has
-- `exports` at all. Two copies of the GATE is the expensive kind of
-- duplication -- the day one is tightened and the other is not, the two halves
-- of one surface disagree about who may call it -- so it is said once, here.
--
-- What stays in each half is what really differs: which config block lists the
-- callers, what a refused call writes to the journal, and the exports
-- themselves. Nothing here reads a config or a module; it is pure apart from
-- the two host globals it names, both read at call time.

OPX.Export = {}
local Export = OPX.Export

-- A resource name as the manifest grammar allows one, bounded.
local CALLER_PATTERN = '^[%w_%-%.]+$'
local MAX_CALLER = 64

--- A refusal, in the shape every export answers with.
-- @author dop42
-- @param code string a stable code a caller can branch on
-- @return table
function OPX.Export.Refuse(code)
	return { ok = false, error = code }
end

--- A success, in the shape every export answers with. The value may be nil.
-- @author dop42
-- @param value any
-- @return table
function OPX.Export.Ok(value)
	return { ok = true, value = value }
end

--- A contract Result as the plain answer: the value on success, the code on a
--- refusal, and `error.unavailable` for anything that is not a Result at all.
-- @author dop42
-- @param result any
-- @return table
function OPX.Export.Answered(result)
	if type(result) ~= 'table' then return Export.Refuse('error.unavailable') end
	if result.ok == true then return Export.Ok(result.value) end
	return Export.Refuse(type(result.error) == 'string' and result.error or 'error.unavailable')
end

--- Whether an allowlist admits a caller: '*', a set, or an array of names.
-- @author dop42
-- @param list any
-- @param caller string
-- @return boolean
function OPX.Export.Admits(list, caller)
	if list == '*' then return true end
	if type(list) ~= 'table' then return false end
	if list[caller] == true then return true end
	for _, name in ipairs(list) do
		if name == caller then return true end
	end
	return false
end

--- Whether a name is one a resource could carry: the manifest grammar, bounded.
-- @author dop42
-- @param name any
-- @return boolean
function OPX.Export.IsResourceName(name)
	return type(name) == 'string' and #name >= 1 and #name <= MAX_CALLER
		and name:match(CALLER_PATTERN) ~= nil
end

--- The resource calling the export being run, as the HOST reports it, or nil.
--- Never an argument: a name a caller could claim is not a gate.
-- @author dop42
-- @return string|nil
function OPX.Export.Caller()
	local caller = GetInvokingResource ~= nil and GetInvokingResource() or nil
	if not Export.IsResourceName(caller) then return nil end
	return caller
end

--- Whether this host offers `exports`.
-- On op77 `exports` is a CALLABLE TABLE, not a function: it is called to
-- publish and indexed for `exports.other:name()`, so `type` answers 'table'.
-- Testing for 'function' alone read every real host as having none, and the
-- whole creator surface went unpublished without an error.
-- @author dop42
-- @return boolean
function OPX.Export.Available()
	local kind = type(exports)
	return kind == 'function' or kind == 'table' or kind == 'userdata'
end
