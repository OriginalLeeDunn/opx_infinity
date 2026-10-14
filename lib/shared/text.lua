--- Display text helpers that measure and cut in characters, not bytes.
-- @author dop42

OPX.Text = {}
local Text = OPX.Text

-- Past 2^53 an integer no longer survives a round trip through a double, and
-- every number reaching us has been through JSON as one.
local MAGNITUDE = 2 ^ 53

-- Absent on a runtime without the 5.3 utf8 library; every use is guarded.
local utf8lib = utf8

-- How many broken sequences one text may have mended before the rest of it is
-- dropped. Each mend is a native scan of what is left, and a text that is mostly
-- broken bytes is noise, not a sentence -- this keeps the walk a few calls long
-- on the client, whose resume budget does not care whose text it was.
local MAX_MENDS = 16

--- Byte length of the first maximum characters of a text.
-- The scan is bounded at four bytes a character before it starts, so a long
-- string cut to a short limit costs the limit, not the string. Continuation
-- bytes are 0x80..0xBF, so anything outside that range opens a new character
-- and a cut is only ever taken there, never through the middle of one.
-- @author dop42
-- @param text string
-- @param maximum integer Characters, not bytes.
-- @return integer
function OPX.Text.Span(text, maximum)
	local size = #text
	local ceiling = maximum * 4
	if size > ceiling then size = ceiling end
	local characters, index = 0, 1
	while index <= size do
		local byte = text:byte(index)
		if byte < 0x80 or byte > 0xBF then
			if characters >= maximum then return index - 1 end
			characters = characters + 1
		end
		index = index + 1
	end
	return size
end

--- Replaces every byte that does not start a valid UTF-8 sequence with `?`.
-- A text that is already valid costs one native call, which is every text a
-- person typed on a real keyboard. Past `MAX_MENDS` the rest is dropped.
-- @param text string
-- @return string
local function mended(text)
	if utf8lib == nil or utf8lib.len == nil then return text end
	local length, bad = utf8lib.len(text)
	if length ~= nil then return text end
	local parts, from = {}, 1
	for _ = 1, MAX_MENDS do
		parts[#parts + 1] = text:sub(from, bad - 1)
		parts[#parts + 1] = '?'
		from = bad + 1
		length, bad = utf8lib.len(text, from)
		if length ~= nil then
			parts[#parts + 1] = text:sub(from)
			return table.concat(parts)
		end
	end
	return table.concat(parts)
end

--- Replaces control characters and cuts display text to maximum characters.
-- AND MENDS BROKEN UTF-8. A client can send any bytes it likes, and a lone
-- `\xC3` relayed to every other client, written into a JSON column or cut into a
-- name is a line that renders as garbage, a row MySQL refuses, or a save that
-- fails until somebody edits it by hand. What comes out of here is valid UTF-8.
-- @author dop42
-- @param value any
-- @param maximum integer Characters, not bytes.
-- @param ellipsis string|nil Appended when the text was cut.
-- @return string|nil
function OPX.Text.Clean(value, maximum, ellipsis)
	if value == nil then return nil end
	if type(value) == 'number' then value = tostring(value) end
	if type(value) ~= 'string' then return nil end
	-- CUT BEFORE THE SCAN, the correction `OPX.Audit.Safe` already carries: the
	-- strip walked the WHOLE string and the cut came second, so a 64-character
	-- toast title another resource handed the client exports as a megabyte cost
	-- a megabyte. `Span` never looks past four bytes a character, and a control
	-- character is one byte replaced by one byte, so nothing past that head can
	-- change the answer.
	local head = maximum * 4 + 4
	if #value > head then value = value:sub(1, head) end
	value = mended((value:gsub('[%c]', ' ')))
	if #value <= maximum then return value end
	local cut = Text.Span(value, maximum)
	if cut >= #value then return value end
	return value:sub(1, cut) .. (ellipsis or '')
end

--- Cuts text to a byte limit without splitting a character.
-- @author dop42
-- @param text string
-- @param limit integer Bytes to keep.
-- @return string
function OPX.Text.Bytes(text, limit)
	if #text <= limit then return text end
	-- Walk back while the byte that would follow the cut is a continuation.
	local cut = limit
	while cut > 0 do
		local following = text:byte(cut + 1)
		if following == nil or following < 0x80 or following > 0xBF then break end
		cut = cut - 1
	end
	return text:sub(1, cut)
end

--- Answers a finite number within MAGNITUDE, or nil.
-- The value ~= value test rejects NaN, which arrives from a client through
-- JSON like any other number and passes every comparison on its own.
-- @author dop42
-- @param value any
-- @return number|nil
function OPX.Text.Finite(value)
	value = tonumber(value)
	if value == nil or value ~= value or value > MAGNITUDE or value < -MAGNITUDE then return nil end
	return value
end

--- @author dop42
-- @param value any
-- @return integer|nil
function OPX.Text.Integer(value)
	local parsed = Text.Finite(value)
	if parsed == nil or parsed % 1 ~= 0 then return nil end
	return math.floor(parsed)
end

--- Joins the typed words from one position on into a sentence.
-- @author dop42
-- @param args table
-- @param first integer
-- @return string|nil
function OPX.Text.Rest(args, first)
	-- args.n rather than #args: a trailing nil argument leaves a hole the
	-- length operator is free to stop at.
	local words = {}
	local count = Text.Integer(args.n) or #args
	for index = first, count do
		local word = args[index]
		if word ~= nil then words[#words + 1] = tostring(word) end
	end
	if #words == 0 then return nil end
	return table.concat(words, ' ')
end

--- Reads on or off and their synonyms; nil when absent.
-- @author dop42
-- @param value any
-- @return boolean|nil, string|nil
function OPX.Text.Switch(value)
	if value == nil then return nil end
	local word = tostring(value):lower()
	if word == 'on' or word == 'true' or word == '1' or word == 'yes' then return true end
	if word == 'off' or word == 'false' or word == '0' or word == 'no' then return false end
	return nil, 'invalid'
end

--- Answers a lower-cased name of letters, digits, underscores and hyphens.
-- @author dop42
-- @param value any
-- @return string|nil
function OPX.Text.Slug(value)
	if type(value) ~= 'string' then return nil end
	local lowered = value:lower()
	if #lowered > 32 or lowered:match('^[%w_%-]+$') == nil then return nil end
	return lowered
end
