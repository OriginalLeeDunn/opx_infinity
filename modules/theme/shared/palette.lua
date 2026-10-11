--- One accent hex to the whole OPX ladder, and the bounds every knob is held to.
-- @author dop42
--
-- THE PAGE IS TOLD NUMBERS, NEVER CSS. The one string this file produces is the
-- style, and it is a word from `STYLES` below, never the operator's own text: a
-- colour crosses the wire as three integers and every other knob as one
-- number, and `design-system/theme.ts` is what turns them into
-- `rgb(...)`/`px`/`deg` and writes them onto the root. A theme that travelled as
-- text would be an operator-supplied string interpolated into a stylesheet,
-- which is the one shape this could have taken that has a hole in it. There is
-- no path from configuration to CSS syntax at all.
--
-- WHY A DERIVATION AND NOT TEN COLOUR FIELDS. `design-system/tokens.css` calls
-- its reds a LADDER, and the rungs are not ten independent choices: they are one
-- hue at five brightnesses plus two grounds, and the whole look depends on them
-- staying in that relation. An operator given ten pickers produces a ladder with
-- a bent rung and no way to see it; an operator given one hex cannot.
--
-- THE FACTORS BELOW WERE MEASURED OFF THE SHIPPED LADDER. Each rung was
-- converted to HSL and compared with `#ff3b47`: the hue is the same to within
-- 1.6 degrees on every one of them, the saturation is a fixed fraction of the
-- accent's and the lightness a fixed offset from it. So the derivation is not a
-- new palette theory -- it is the existing palette, restated as the rule it was
-- already following. Fed `#ff3b47` it reproduces the shipped ladder exactly on
-- red and green and to within 4/255 on blue, and the entire residue is that 1.6
-- degrees of hand-picked hue wobble. `tests/run.lua` holds that claim to 4.
--
-- NOTHING HERE IS THE DEFAULT. A knob the operator did not set produces no key
-- at all, so the page never overrides the property and the stylesheet's own
-- value stands. That is what makes an unconfigured server byte-identical to the
-- one that shipped, rather than merely close.

local M = OPX.Modules.Get('theme')

M.Palette = {}
local Palette = M.Palette

local Clamp = OPX.Math.Clamp

-- The looks the page knows how to draw, and the only words that may cross the
-- wire. A style is NOT CSS either: it is a name from this list, and the page
-- holds the same list and turns it into one attribute on its root
-- (`data-op-style`), which its own stylesheets select on. A word not in here is
-- dropped on both sides, so no operator text ever reaches the document.
--
--   cyberpunk   the house look: red, outlined, chamfered, tilted, interlaced.
--               What `tokens.css` draws on its own.
--   minimal     the same surfaces, quiet: rounded hairlines, flat planes, no
--               scanline and no bloom. `design-system/minimal.css` is all of it.
local STYLES = { cyberpunk = true, minimal = true }
Palette.STYLES = STYLES

-- What a colour key is allowed to be once it has crossed the wire. Triplets are
-- separate from the scalars because their bound is the same for all three
-- channels and is not negotiable: 0..255, integral.
local TRIPLETS = {
	accent = true, idle = true, deep = true, hi = true, text = true,
	alarm = true, plate = true, plateLit = true,
}

-- Every scalar knob, its floor and its ceiling. ONE table in Lua, read by both
-- the producer and the receiver, because two copies of a bound is one bound and
-- one bug: the server clamps what the operator wrote and the client clamps what
-- arrived, and if those disagreed the disagreement would only ever show up as a
-- surface that looks wrong on someone else's machine.
--
-- THE PAGE HAS A SECOND COPY AND IS ALLOWED ONE. `KNOBS` in
-- `ui/src/design-system/theme.ts` carries the same floors and ceilings, on
-- purpose: it is the last clamp before a custom property is written, it must
-- hold against a payload this file never saw, and a `.ts` file cannot read a Lua
-- table. That is the one seam no shared file can close, so `tests/run.lua` reads
-- both files and holds the two lists together -- the same arrangement
-- `core/shared/glyphs.lua` has with `ui/src/modules/target/glyphs.ts`. Change a
-- bound here and the suite will name the line in the other file.
--
--   plateAlpha       the ground under running type. tokens.css calls 0.78 "the
--                    floor for running text over gameplay" and it is right, but
--                    the floor is a JUDGEMENT about a street at night, not a
--                    constant -- a server whose look is darker is allowed one.
--                    0.20 is where a plate stops separating anything at all.
--   interlaceAlpha   the scanline. 0 turns it off, which is a real identity
--                    choice; the ceiling is low because this is a texture over
--                    live gameplay and at 0.15 it is a barcode.
--   tiltDeg          `--op-tilt`. 0 is flat, which surface.css already supports
--                    (a centred surface takes no tilt). Past 15 the far edge of
--                    a 340px toast is off the plane and the type goes soft.
--   cut*             the three chamfer sizes, in pixels, at the 6/12/20 ratio
--                    the design uses. The floor is 1px rather than 0 because
--                    augmented-ui needs a cut before it will draw a border at
--                    all and a 0 has not been measured on this build -- see
--                    ui/README.md, "a cut size is required".
local BOUNDS = {
	plateAlpha      = { 0.20, 0.98 },
	plateQuietAlpha = { 0.00, 0.98 },
	plateLitAlpha   = { 0.20, 1.00 },
	interlaceAlpha  = { 0.00, 0.15 },
	tiltDeg         = { 0.00, 15.0 },
	cutSm           = { 1, 24 },
	cutMd           = { 1, 48 },
	cutLg           = { 1, 80 },
}

-- The accent's own rungs: saturation as a fraction of the accent's, lightness as
-- an offset from it, hue untouched. Measured, not invented; see the header.
local RUNGS = {
	{ key = 'hi',    sat = 1.000, light =  0.094 },
	{ key = 'deep',  sat = 0.724, light = -0.161 },
	{ key = 'text',  sat = 0.742, light =  0.035 },
	{ key = 'idle',  sat = 0.782, light = -0.029 },
	{ key = 'alarm', sat = 1.000, light =  0.214 },
}

-- The two grounds, and they take an ABSOLUTE lightness rather than an offset.
-- A ground is a ground: it exists to put a black under a letter, and following
-- the accent's lightness would give a pale accent a milky plate with the type
-- still on the street. What it does take from the accent is the hue and a
-- fraction of the saturation, which is what keeps `#1c0809` a red black rather
-- than a grey one.
local GROUNDS = {
	{ key = 'plate',    sat = 0.556, light = 0.0706 },
	{ key = 'plateLit', sat = 0.558, light = 0.1863 },
}

-- Where the ladder above an accent stops having room to climb. Outside this band
-- `hi` and `alarm` both land on the ceiling and the two brightest states stop
-- being distinguishable, which is a thing the operator should be told once at
-- boot rather than left to notice on a HUD.
local COMFORTABLE_LIGHT = { 0.30, 0.78 }

-- The ladder may not reach pure black or pure white: at either end the hue is
-- gone and every rung that clamps there collapses onto every other.
local LIGHT_FLOOR, LIGHT_CEILING = 0.02, 0.97

--- Rounds to a fixed number of places, so the wire carries 0.78 and not
--- 0.7800000000000000266. A JSON number that long is legal and ugly, and the
--- payload is read by a human in the journal more often than by anything else.
local function round(value, places)
	local scale = 10 ^ (places or 0)
	return math.floor(value * scale + 0.5) / scale
end

--- One channel of an HSL triple back to 0..1 RGB. The standard piecewise ramp.
local function channel(p, q, t)
	if t < 0 then t = t + 1 end
	if t > 1 then t = t - 1 end
	if t < 1 / 6 then return p + (q - p) * 6 * t end
	if t < 1 / 2 then return q end
	if t < 2 / 3 then return p + (q - p) * (2 / 3 - t) * 6 end
	return p
end

--- HSL (degrees, 0..1, 0..1) to three integers in 0..255.
local function toRgb(hue, saturation, light)
	hue = (hue % 360) / 360
	if saturation <= 0 then
		local grey = math.floor(light * 255 + 0.5)
		return { grey, grey, grey }
	end
	local q = light < 0.5 and light * (1 + saturation) or light + saturation - light * saturation
	local p = 2 * light - q
	return {
		math.floor(channel(p, q, hue + 1 / 3) * 255 + 0.5),
		math.floor(channel(p, q, hue) * 255 + 0.5),
		math.floor(channel(p, q, hue - 1 / 3) * 255 + 0.5),
	}
end

--- Three 0..255 integers to hue in degrees and saturation and lightness in 0..1.
local function toHsl(rgb)
	local r, g, b = rgb[1] / 255, rgb[2] / 255, rgb[3] / 255
	local high = math.max(r, g, b)
	local low = math.min(r, g, b)
	local light = (high + low) / 2
	local spread = high - low
	if spread <= 0 then return 0, 0, light end

	local saturation = light > 0.5 and spread / (2 - high - low) or spread / (high + low)
	local hue
	if high == r then hue = ((g - b) / spread) % 6
	elseif high == g then hue = (b - r) / spread + 2
	else hue = (r - g) / spread + 4 end
	return hue * 60, saturation, light
end

--- Reads `#RRGGBB` and nothing else.
--
-- STRICT, AND THE STRICTNESS IS THE POINT. Lua patterns have no anchored
-- alternation and no length quantifier, so the shape is spelled out: six hex
-- digits between the anchors, which refuses `#fff`, `#ff3b477`, `red`,
-- `rgb(1,2,3)` and every string with a `;` or a `}` in it. The value never
-- becomes CSS text in any case -- the page is sent integers -- but a hex is what
-- an operator types and a typo should be named in the journal rather than
-- silently becoming black.
-- @author dop42
-- @param value any
-- @return table|nil three integers in 0..255
function Palette.Rgb(value)
	if type(value) ~= 'string' then return nil end
	if value:match('^#%x%x%x%x%x%x$') == nil then return nil end
	return {
		tonumber(value:sub(2, 3), 16),
		tonumber(value:sub(4, 5), 16),
		tonumber(value:sub(6, 7), 16),
	}
end

--- The eight triplets one accent implies, keyed as the wire names them.
-- @author dop42
-- @param rgb table three integers in 0..255
-- @return table<string, table>
function Palette.Ladder(rgb)
	local hue, saturation, light = toHsl(rgb)
	local ladder = { accent = { rgb[1], rgb[2], rgb[3] } }

	for index = 1, #RUNGS do
		local rung = RUNGS[index]
		ladder[rung.key] = toRgb(
			hue,
			Clamp(saturation * rung.sat, 0, 1),
			Clamp(light + rung.light, LIGHT_FLOOR, LIGHT_CEILING))
	end

	for index = 1, #GROUNDS do
		local ground = GROUNDS[index]
		ladder[ground.key] = toRgb(hue, Clamp(saturation * ground.sat, 0, 1), ground.light)
	end

	return ladder
end

--- Keeps what the theme is allowed to carry and drops everything else.
--
-- RUN ON BOTH SIDES, deliberately. The server runs it over what the operator
-- wrote, so a bad value is named at boot; the client runs it over what arrived,
-- so a payload from a server running a newer or an older version of this file
-- cannot put an unknown key or an out-of-range number in front of the page. It
-- is the same function, so there is one set of bounds in the resource.
--
-- A key is dropped rather than repaired when its SHAPE is wrong -- a triplet
-- that is not three numbers has no defensible reading -- and CLAMPED when only
-- its magnitude is. An operator who asks for a tilt of 40 degrees wants a strong
-- tilt and gets the strongest one that still draws; an operator who writes a
-- colour as a word has made a mistake and must be told.
-- @author dop42
-- @param payload table|nil
-- @return table the payload that may be applied
-- @return string[] one line per value dropped or clamped
function Palette.Sanitise(payload)
	local clean, notes = {}, {}
	if type(payload) ~= 'table' then return clean, notes end

	for key, value in pairs(payload) do
		if key == 'style' then
			if type(value) == 'string' and STYLES[value] then
				clean.style = value
			else
				notes[#notes + 1] = ('style %s is not a known style and was dropped')
					:format(tostring(value))
			end
		elseif TRIPLETS[key] then
			local triple = {}
			local usable = type(value) == 'table'
			for channelIndex = 1, 3 do
				local component = usable and tonumber(value[channelIndex]) or nil
				if component == nil or not OPX.Math.IsFinite(component) then
					usable = false
				else
					triple[channelIndex] = math.floor(Clamp(component, 0, 255) + 0.5)
				end
			end
			if usable then
				clean[key] = triple
			else
				notes[#notes + 1] = ('%s is not three numbers and was dropped'):format(key)
			end
		elseif BOUNDS[key] ~= nil then
			local bound = BOUNDS[key]
			local number = tonumber(value)
			if number == nil or not OPX.Math.IsFinite(number) then
				notes[#notes + 1] = ('%s is not a number and was dropped'):format(key)
			else
				local held = Clamp(number, bound[1], bound[2])
				if held ~= number then
					notes[#notes + 1] = ('%s %s is outside %s..%s and was held at %s')
						:format(key, tostring(number), tostring(bound[1]),
							tostring(bound[2]), tostring(held))
				end
				clean[key] = round(held, 3)
			end
		else
			notes[#notes + 1] = ('%s is not a theme key and was dropped'):format(tostring(key))
		end
	end

	return clean, notes
end

--- Turns the operator's block into the payload the page is sent.
--
-- THE STYLE PICKS WHICH KNOBS ARE READ. `STYLE` names a look, and a block keyed
-- by that same name (`minimal = { ACCENT = ... }`) holds that look's knobs, so
-- switching look is one word and each look keeps its own tuning: a red accent
-- written for the cyberpunk surface does not follow the operator onto the
-- minimal one. A style with no block of its own reads the knobs at the top
-- level, which is also what a block written before styles existed has.
--
-- A NIL KNOB PRODUCES NO KEY. This is the whole of requirement "an operator who
-- configures nothing sees what shipped": the page only ever writes the
-- properties it is handed, so an empty payload leaves `tokens.css` untouched and
-- the surface is not merely close to the shipped one, it is the shipped one.
-- @author dop42
-- @param settings table|nil the module's own `Settings`
-- @return table the payload, empty when nothing is configured
-- @return string[] one line per value refused, clamped or worth warning about
function Palette.Resolve(settings)
	settings = type(settings) == 'table' and settings or {}
	local raw, notes = {}, {}

	local knobs = settings
	local style = settings.STYLE
	if style ~= nil then
		if type(style) ~= 'string' or not STYLES[style] then
			notes[#notes + 1] = ('STYLE %q is not one of cyberpunk, minimal and was refused')
				:format(tostring(style))
		else
			raw.style = style
			if type(settings[style]) == 'table' then knobs = settings[style] end
		end
	end

	local accent = knobs.ACCENT
	if accent ~= nil then
		local rgb = Palette.Rgb(accent)
		if rgb == nil then
			notes[#notes + 1] = ('ACCENT %q is not #RRGGBB and was refused')
				:format(tostring(accent))
		else
			for key, triple in pairs(Palette.Ladder(rgb)) do raw[key] = triple end
			local _, _, light = toHsl(rgb)
			if light < COMFORTABLE_LIGHT[1] or light > COMFORTABLE_LIGHT[2] then
				notes[#notes + 1] = ('ACCENT %s has a lightness of %.2f; the rungs above '
					.. 'it are compressed and the lit and alarm states will look alike')
					:format(accent, light)
			end
		end
	end

	-- The one place a second hue is sanctioned. `ui/README.md` rule 7 forbids an
	-- accent beside the voice and it is right -- but the ALARM is the one thing
	-- on the surface whose job is to be unlike the voice, and a server whose
	-- voice is blue has nothing white-hot to escalate to that a blue HUD will
	-- not read as another blue. Left nil it is derived from the accent like
	-- every other rung, which is the shipped behaviour.
	local alarm = knobs.ALARM
	if alarm ~= nil then
		local rgb = Palette.Rgb(alarm)
		if rgb == nil then
			notes[#notes + 1] = ('ALARM %q is not #RRGGBB and was refused'):format(tostring(alarm))
		else
			raw.alarm = rgb
		end
	end

	-- The three grounds move together, because they are one ground at three
	-- weights: `quiet` is the same wash 0.20 lighter and `lit` the same wash 0.12
	-- heavier, which is the relation the shipped 0.58 / 0.78 / 0.90 already are.
	-- Splitting them into three knobs would let an operator put the quiet plate
	-- above the lit one, which has no meaning.
	local opacity = knobs.PLATE_OPACITY
	if opacity ~= nil then
		local number = tonumber(opacity)
		if number == nil or not OPX.Math.IsFinite(number) then
			notes[#notes + 1] = ('PLATE_OPACITY %q is not a number and was refused')
				:format(tostring(opacity))
		else
			raw.plateAlpha = number
			raw.plateQuietAlpha = number - 0.20
			raw.plateLitAlpha = number + 0.12
		end
	end

	-- An INTENSITY and not an alpha: 1 is the shipped 0.05, 0 is off, and the
	-- number an operator reasons about is "how much of the house scanline",
	-- which is the only reading under which 2 is a sane thing to type. Sanitise
	-- holds the result at 0.15 however high the intensity goes.
	local interlace = knobs.INTERLACE
	if interlace ~= nil then
		local number = tonumber(interlace)
		if number == nil or not OPX.Math.IsFinite(number) then
			notes[#notes + 1] = ('INTERLACE %q is not a number and was refused')
				:format(tostring(interlace))
		else
			raw.interlaceAlpha = 0.05 * number
		end
	end

	local tilt = knobs.TILT
	if tilt ~= nil then
		local number = tonumber(tilt)
		if number == nil or not OPX.Math.IsFinite(number) then
			notes[#notes + 1] = ('TILT %q is not a number and was refused'):format(tostring(tilt))
		else
			raw.tiltDeg = number
		end
	end

	-- A SCALE, so the 6/12/20 relation survives whatever the operator picks. The
	-- three sizes are not three decisions either: a chip, a toast and a bay are
	-- the same chamfer at three scales, and an operator who wants squarer corners
	-- wants all three squarer.
	local cut = knobs.CUT
	if cut ~= nil then
		local number = tonumber(cut)
		if number == nil or not OPX.Math.IsFinite(number) then
			notes[#notes + 1] = ('CUT %q is not a number and was refused'):format(tostring(cut))
		else
			raw.cutSm = round(6 * number)
			raw.cutMd = round(12 * number)
			raw.cutLg = round(20 * number)
		end
	end

	local clean, bounded = Palette.Sanitise(raw)
	for index = 1, #bounded do notes[#notes + 1] = bounded[index] end
	return clean, notes
end

--- Whether a payload would change anything at all. An empty theme is not an
--- error and is not sent: it is what an unconfigured server has.
-- @author dop42
-- @param payload table
-- @return boolean
function Palette.IsEmpty(payload)
	return type(payload) ~= 'table' or next(payload) == nil
end
