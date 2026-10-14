--- Success or failure as a value, never an ambiguous nil.
-- @author dop42

OPX.Result = {}

--- Wraps a success; its value may be nil.
-- @author dop42
-- @param value any
-- @return Result
function OPX.Result.Ok(value)
	return { ok = true, value = value }
end

--- Wraps a failure with a stable code and a log-only detail.
-- @author dop42
-- @param code string
-- @param detail string|nil
-- @return Result
function OPX.Result.Err(code, detail)
	return { ok = false, error = code, detail = detail }
end

-- ── one toast kind per situation ────────────────────────────────────────────
--
-- THE SAME SITUATION WAS TWO COLOURS. "Too fast" was a warning in the chat,
-- the staff menu and the emotes, and an error everywhere else; "too far" an
-- error at a lift and a warning in a duo emote. The owner's rule: too fast and
-- busy are a WARNING (wait, and it works), too far and not allowed are an ERROR
-- (it will not work from here, or for you). A code names its situation, so the
-- kind is read off the code wherever a refusal becomes a toast.

-- Fragments of a code, flattened to letters, and the kind each one means.
local KIND_BY_FRAGMENT = {
	{ 'toofast', 'warning' }, { 'ratelimit', 'warning' }, { 'busy', 'warning' },
	{ 'toofar', 'error' }, { 'notallowed', 'error' }, { 'notpermitted', 'error' },
	{ 'nopermission', 'error' },
}

--- The toast kind a refusal code's situation calls for, or the caller's own.
-- @author dop42
-- @param code any a refusal code or catalogue key: `error.tooFast`, `too_far`
-- @param fallback string the kind when the code names none of the situations
-- @return string
function OPX.Result.Kind(code, fallback)
	if type(code) ~= 'string' then return fallback end
	local flat = code:lower():gsub('[^%a]', '')
	for index = 1, #KIND_BY_FRAGMENT do
		local entry = KIND_BY_FRAGMENT[index]
		if flat:find(entry[1], 1, true) then return entry[2] end
	end
	return fallback
end
