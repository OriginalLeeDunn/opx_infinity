--- Every animation this module can ask the platform for.
-- @author dop42
--
-- Shared so both halves agree on what a name and a variant number mean. `NAME`
-- is the platform's own profile id and each clip the engine's own clip name;
-- the labels are not here, because a player reads `animations.name.<NAME>`.
--
-- `STEM` is the part every clip of an entry shares; each `VARIANTS` line is
-- appended to it and also renders the words shown beside "Variant n". The first
-- line is the default variant.
--
-- THE WRITTEN ROWS ARE NOT THE WHOLE CATALOGUE. The platform ships its own --
-- `RpAnimationCatalog` in open77_animations, a hundred-odd profiles on op77.123
-- -- and the server reads it at runtime with `Open77.animations.list`, then
-- ADOPTS every profile not written here (`Catalogue.Adopt`); the client adopts
-- the same rows off the offer. It is read rather than copied so a profile a new
-- build adds is offered without a release. A written row wins over the
-- platform's profile of the same id: it carries a translated label, a walking
-- pace and a curated variant list.

local M = OPX.Modules.Get('animations')

M.Catalogue = {}
local Catalogue = M.Catalogue

--- Categories in the order the picker draws them.
--
-- No category may share a name with a profile: `/e <word>` reads a category as
-- "open the picker there", and the platform has profiles called `dance` and
-- `seated`. Hence `music` and `sitting` rather than the platform's own words.
Catalogue.CATEGORIES = { 'gestures', 'onthemove', 'social', 'emotions', 'postures',
	'sitting', 'relaxation', 'music', 'consumables', 'work', 'interactions', 'other' }

--- The glyph each category is drawn with, and the one every emote in it falls
--- back to. A name outside `menu.M.ICONS` would REFUSE the whole picker screen
--- rather than lose one picture, so the fallback below is what an unknown name
--- lands on.
Catalogue.CATEGORY_ICONS = {
	gestures = 'emote',
	onthemove = 'arrow',
	social = 'talk',
	emotions = 'heart',
	postures = 'person',
	sitting = 'location',
	relaxation = 'heal',
	music = 'star',
	consumables = 'drink',
	work = 'tool',
	interactions = 'interact',
	other = 'list',
}

--- The platform's category words, mapped onto the picker's. A word missing
--- here -- one a later build introduces -- files its profiles under `other`
--- rather than dropping them.
Catalogue.PLATFORM_CATEGORIES = {
	gestures = 'gestures',
	onthemove = 'onthemove',
	social = 'social',
	emotions = 'emotions',
	postures = 'postures',
	seated = 'sitting',
	relaxation = 'relaxation',
	dance = 'music',
	music = 'music',
	consumables = 'consumables',
	work = 'work',
	interactions = 'interactions',
}

-- The glyphs an entry's own ICON may name. A CLOSED set for the reason above,
-- and a short one: this is the handful a body doing something is drawn with,
-- not the whole vocabulary the menu knows.
local ENTRY_ICONS = { emote = true, talk = true, heart = true, heal = true, drink = true,
	food = true, smoke = true, interact = true, info = true, eye = true, box = true,
	person = true, star = true }

-- Catalogue rows: profile name, category, clip stem and variant suffixes.
local ENTRIES = {
	{ NAME = 'handsup', CATEGORY = 'gestures', PLACEMENT = 'standing', WALK = 1,
		STEM = 'stand__2h_up__03__',
		VARIANTS = { 'look_around__01', 'look_left__01', 'look_right__01', 'shuffle__01' } },
	{ NAME = 'clap', CATEGORY = 'gestures', PLACEMENT = 'standing',
		STEM = 'stand__2h_on_sides__01__2h_clap__',
		VARIANTS = { 'happy__01', 'broad__01', 'narrow__01' } },

	{ NAME = 'dance', CATEGORY = 'music', PLACEMENT = 'standing', ICON = 'emote',
		STEM = 'stand__dance__02__',
		VARIANTS = { 'dancing__02', 'dancing__03', 'dancing__04', 'dancing__05', 'dancing__07',
			'dancing__08' } },
	{ NAME = 'phone', CATEGORY = 'social', PLACEMENT = 'standing', WALK = 1.4, PROP = 'phone', ICON = 'talk',
		STEM = 'stand__2h_phone__03__',
		VARIANTS = { 'tap_phone__01', 'shuffle__01' } },

	{ NAME = 'cry', CATEGORY = 'emotions', PLACEMENT = 'standing', WALK = 1.2,
		STEM = 'stand__rh_on_forehead__01__',
		VARIANTS = { 'cry__01', 'cry__02', 'rub_tears__01', 'blow_nose__02' } },
	{ NAME = 'think', CATEGORY = 'emotions', PLACEMENT = 'standing', WALK = 1.4, ICON = 'info',
		STEM = 'stand__rh_on_chin__01__',
		-- The space in 'rub_forehead__ 01' is in the platform's clip name, not a
		-- typo; it is also why Common.Text accepts a space.
		VARIANTS = { 'rub_chin__01', 'rub_forehead__ 01', 'shuffle__01', 'shuffle__02' } },

	{ NAME = 'sit', CATEGORY = 'relaxation', PLACEMENT = 'ground',
		STEM = 'sit_ground__2h_elbow_on_knees__01__',
		VARIANTS = { 'shuffle__01', 'shuffle__02', 'shuffle__03', 'shuffle__04' } },
	{ NAME = 'meditate', CATEGORY = 'relaxation', PLACEMENT = 'standing',
		STEM = 'stand__meditate__01__',
		VARIANTS = { 'breathe__01', 'breathe__02', 'raise_hands__01', 'look_left__01',
			'shuffle__01' } },
	{ NAME = 'stretch', CATEGORY = 'relaxation', PLACEMENT = 'standing',
		STEM = 'stand__2h_on_sides__01__',
		VARIANTS = { 'stretch_arms__01', 'stretch_arms__02', 'stretch_arms__03', 'stretch_arms__04',
			'stretch_neck__01', 'stretch_muscle_01', 'stretch_muscle_02', 'stretch_muscle_03',
			'stretch_muscle_04', 'stretch_muscle_05', 'stretch_muscle_06', 'stretch_muscle_07',
			'stretch_muscle_08', 'stretch_muscle_09', 'stretch_muscle_10' } },

	{ NAME = 'smoke', CATEGORY = 'consumables', PLACEMENT = 'standing', WALK = 1.3, PROP = 'cigarette',
		ICON = 'smoke',
		STEM = 'stand__rh_cigarette__01__',
		VARIANTS = { 'smoke__01', 'smoke__02', 'smoke__03', 'drop_ash__01', 'drop_ash__04',
			'look_around__01', 'look_around__02', 'shuffle__01', 'shuffle__02', 'shuffle__04',
			'wipe_forehead__01' } },
	{ NAME = 'cigar', CATEGORY = 'consumables', PLACEMENT = 'standing', WALK = 1.3, PROP = 'cigar', ICON = 'smoke',
		STEM = 'stand__rh_cigar__weight_right__01__',
		VARIANTS = { 'smoke__01', 'smoke__02', 'smoke__03', 'look_left__01', 'scratch_nose__01',
			'scratch_ball__01' } },
	{ NAME = 'drink', CATEGORY = 'consumables', PLACEMENT = 'standing', WALK = 1.2, PROP = 'can', ICON = 'drink',
		STEM = 'stand__rh_can__01__',
		VARIANTS = { 'drink__01', 'drink__03', 'drink__04', 'shuffle__01', 'spill__01',
			'spill__02' } },

	{ NAME = 'give', CATEGORY = 'interactions', PLACEMENT = 'standing', ICON = 'box',
		STEM = 'stand__2h_on_sides__01__to__stand__rh_item__01__',
		VARIANTS = { 'turn0__01' } },
	{ NAME = 'examine', CATEGORY = 'interactions', PLACEMENT = 'ground', ICON = 'eye',
		STEM = 'kneel__rk_on_ground__01__',
		VARIANTS = { 'inspect_ground__01' } },
	{ NAME = 'wounded', CATEGORY = 'interactions', PLACEMENT = 'ground', ICON = 'heal',
		STEM = 'sit_ground_lean180__rh_on_belly__01__',
		VARIANTS = { 'deep_breath__01' } },
}

-- The wire bounds a profile id at 64 bytes and a clip name at 128.
local MAX_NAME, MAX_CLIP = 64, 128

local isCategory = {}
for index = 1, #Catalogue.CATEGORIES do isCategory[Catalogue.CATEGORIES[index]] = true end

-- Reduces a clip suffix to the words shown beside a variant:
-- 'rub_forehead__ 01' reads 'rub forehead 1'.
local function words(suffix)
	local spoken = OPX.String.Trim((suffix:gsub('[_%s]+', ' ')))
	spoken = spoken:gsub('%f[%d]0+(%d)', '%1')
	return spoken
end

-- Entries by name and in picker order, built once. A malformed row is dropped
-- rather than raised on: this file loads on every client.
local byName, ordered = {}, {}
for index = 1, #ENTRIES do
	local row = ENTRIES[index]
	local name, stem = row.NAME, row.STEM
	if type(name) == 'string' and #name <= MAX_NAME and name:match('^[%l%d_]+$') and
		isCategory[row.CATEGORY] and type(stem) == 'string' and type(row.VARIANTS) == 'table' and
		byName[name] == nil then
		local entry = {
			name = name,
			-- Written here, as opposed to adopted from the platform's list.
			written = true,
			kind = 'workspot',
			category = row.CATEGORY,
			-- The entry's own glyph where it has one worth having -- a cigarette
			-- for `smoke`, a can for `drink` -- and its category's otherwise, so
			-- that a row in a flat search result still says which family it came
			-- from. Never nil: a row with no glyph leaves a hole in a column the
			-- strip holds open either way.
			icon = (ENTRY_ICONS[row.ICON] and row.ICON)
				or Catalogue.CATEGORY_ICONS[row.CATEGORY] or 'emote',
			prop = row.PROP,
			placement = row.PLACEMENT or 'standing',
			-- Metres per second this emote may be walked at, or nil for one that
			-- holds the player still. See `client/walk.lua` for what the number
			-- actually buys: `Open77.movement.setWalkMode` is a LEASE on the
			-- player's body, not a property of the animation, and there is no
			-- `canWalk` anywhere in the platform.
			--
			-- ONLY A STANDING POSE MAY CARRY ONE, and the rule is enforced rather
			-- than trusted. `sit`, `examine` and `wounded` are authored against
			-- the ground: walking out of one does not produce a player strolling
			-- while seated, it produces a body sliding across the pavement in a
			-- pose that no longer means anything. A `WALK` on such a row is a
			-- config mistake and is dropped, not honoured.
			walk = nil,
			clips = {},
			words = {},
			variantOf = {},
		}
		-- Bounded to what `setWalkMode` accepts (0.5 to 2.5 m/s). Out of range is
		-- dropped here rather than refused once a second by the native, which
		-- would be a fault nobody sees: the emote would simply never walk and no
		-- line anywhere would say why.
		local wanted = tonumber(row.WALK)
		if wanted ~= nil and entry.placement == 'standing'
			and wanted >= 0.5 and wanted <= 2.5 then
			entry.walk = wanted
		end

		for position = 1, #row.VARIANTS do
			local suffix = row.VARIANTS[position]
			local clip = type(suffix) == 'string' and stem .. suffix or nil
			if clip ~= nil and #clip <= MAX_CLIP and entry.variantOf[clip] == nil then
				local at = #entry.clips + 1
				entry.clips[at] = clip
				entry.words[at] = words(suffix)
				entry.variantOf[clip] = at
			end
		end
		if #entry.clips > 0 then
			byName[name] = entry
			ordered[#ordered + 1] = entry
		end
	end
end

--- Answers one entry by its name, without case, or nil.
-- @author dop42
-- @param name any
-- @return table|nil
function Catalogue.Entry(name)
	if type(name) ~= 'string' then return nil end
	return byName[name:lower()]
end

-- Adopted platform entries, in the order the platform listed them, and the
-- written entries followed by those, rebuilt only when asked after a change.
local adopted, merged = {}, nil

--- Answers every entry: the written ones as written, then the adopted ones as
--- the platform listed them. The picker orders by category itself.
-- @author dop42
-- @return table[]
function Catalogue.Entries()
	if merged == nil then
		merged = table.move(ordered, 1, #ordered, 1, {})
		table.move(adopted, 1, #adopted, #merged + 1, merged)
	end
	return merged
end

--- Whether a value names a category, without case.
-- @author dop42
-- @param name any
-- @return boolean
function Catalogue.IsCategory(name)
	return type(name) == 'string' and isCategory[name:lower()] == true
end

--- Answers which variant of an entry a clip is, or nil.
-- @author dop42
-- @param name any
-- @param clip any
-- @return integer|nil
function Catalogue.VariantOf(name, clip)
	local entry = Catalogue.Entry(name)
	if entry == nil or type(clip) ~= 'string' then return nil end
	return entry.variantOf[clip]
end

-- ── the platform's own catalogue ────────────────────────────────────────────
--
-- Everything below turns one profile of `Open77.animations.list` into an entry
-- the picker, the commands and the contract treat exactly like a written one.
-- The server builds a DEFINITION from the profile and adopts it; the same
-- definition travels to every client on the offer and is adopted there too, so
-- both halves agree on what a name and a variant number mean.

-- Clips an adopted entry keeps; the largest profile on op77.123 has 37.
local MAX_CLIPS = 64

-- A label is a short sentence; a category, a placement and a prop are words.
local MAX_LABEL, MAX_WORD = 64, 32

-- The words a `validation` field carries when the platform says a profile does
-- NOT work. The guide documents none of them: every profile on op77.123 reads
-- `asset_verified_runtime_pending` or `graph_verified_runtime_pending`, which
-- it calls experimental, not unusable -- so those are offered. A later build
-- that marks one failed or unsupported has it skipped without a release.
local UNUSABLE = { 'fail', 'broken', 'unsupported', 'unusable', 'rejected', 'disabled',
	'removed' }

-- The glyph an adopted entry is drawn with, by the platform's prop word.
local PROP_ICONS = { cigarette = 'smoke', cigar = 'smoke', can = 'drink', bottle = 'drink',
	takeout = 'food', phone = 'talk', headphones = 'star', handpan = 'star', guitar = 'star' }

-- Mode words of a layer that plays once rather than holding.
local ONCE_MODES = { once = true, enter = true, exit = true }

--- Whether a profile's `validation` word lets it be offered.
-- @author dop42
-- @param validation any
-- @return boolean
function Catalogue.Usable(validation)
	if validation == nil then return true end
	if type(validation) ~= 'string' then return false end
	local lowered = validation:lower()
	for index = 1, #UNUSABLE do
		if lowered:find(UNUSABLE[index], 1, true) then return false end
	end
	return true
end

-- Cuts a clip prefix back to the boundary before its last `__` token:
-- 'stand__rh_cigarette__01__' becomes 'stand__rh_cigarette__'.
local function shorter(prefix)
	local trimmed = prefix:gsub('_+$', '')
	return trimmed:match('^(.*__)') or ''
end

--- Answers the variant words of a clip list: what follows the stem the clips
--- share, read the way a written row's VARIANTS line is.
-- @author dop42
-- @param clips string[]
-- @return string[]
function Catalogue.WordsOf(clips)
	local stem = #clips > 1 and (clips[1]:match('^(.*__)') or '') or ''
	for index = 2, #clips do
		local clip = clips[index]
		while #stem > 0 and clip:sub(1, #stem) ~= stem do stem = shorter(stem) end
	end
	local spoken = {}
	for index = 1, #clips do
		local suffix = clips[index]:sub(#stem + 1)
		spoken[index] = words(suffix ~= '' and suffix or clips[index])
	end
	return spoken
end

-- A short lower-case word, or nil.
local function word(value)
	if type(value) ~= 'string' or #value == 0 or #value > MAX_WORD then return nil end
	return value:match('^[%l%d_]+$') and value or nil
end

--- Answers the definition of one platform profile, or nil and why not.
-- Server side: the profile is a row of `Open77.animations.list`. A malformed
-- one is refused rather than raised on, and so is one the platform says does
-- not work.
-- @author dop42
-- @param profile any
-- @return table|nil
-- @return string|nil
function Catalogue.Definition(profile)
	if type(profile) ~= 'table' then return nil, 'malformed' end
	local name = profile.id
	if type(name) ~= 'string' or #name > MAX_NAME or not name:match('^[%l%d_]+$') then
		return nil, 'malformed'
	end
	if not Catalogue.Usable(profile.validation) then return nil, 'unusable' end
	local kind = profile.kind
	if kind ~= 'layer' and kind ~= 'workspot' then return nil, 'unknown_kind' end
	local source = type(profile.clips) == 'table' and profile.clips or profile.clipNames
	if type(source) ~= 'table' then return nil, 'no_clips' end
	local clips, seen = {}, {}
	for index = 1, math.min(#source, MAX_CLIPS) do
		local clip = source[index]
		if M.Common.Text(clip, MAX_CLIP) and not seen[clip] then
			seen[clip] = true
			clips[#clips + 1] = clip
		end
	end
	if #clips == 0 then return nil, 'no_clips' end
	-- Measured per clip by the platform, and only for layers: what a one-shot
	-- gesture is scheduled for instead of the configured ONE_SHOT_MS.
	local durations = {}
	if type(profile.clipDurationsMs) == 'table' then
		for index = 1, #clips do
			durations[index] = M.Common.Integer(profile.clipDurationsMs[clips[index]], 1,
				M.SERVICE_MAX_MS)
		end
	end
	return {
		name = name,
		label = M.Common.Text(profile.label, MAX_LABEL) and profile.label or name,
		category = word(profile.category) or 'other',
		kind = kind,
		placement = word(profile.placement) or 'standing',
		prop = word(profile.prop) or '',
		mode = kind == 'layer' and word(profile.mode) or '',
		clips = clips,
		words = Catalogue.WordsOf(clips),
		durations = durations,
	}, nil
end

--- Registers one platform definition as an entry, answering it, or nil and
--- why not. A name already taken -- a written row, or one adopted before --
--- keeps what it was.
-- @author dop42
-- @param definition any a `Catalogue.Definition`, or the same off the wire
-- @return table|nil
-- @return string|nil
function Catalogue.Adopt(definition)
	if type(definition) ~= 'table' then return nil, 'malformed' end
	local name = definition.name
	if type(name) ~= 'string' or #name > MAX_NAME or not name:match('^[%l%d_]+$') then
		return nil, 'malformed'
	end
	if byName[name] ~= nil then return nil, 'duplicate' end
	local kind = definition.kind
	if kind ~= 'layer' and kind ~= 'workspot' then return nil, 'malformed' end
	if type(definition.clips) ~= 'table' or #definition.clips == 0
		or #definition.clips > MAX_CLIPS then
		return nil, 'malformed'
	end
	local source = word(definition.category) or 'other'
	local category = Catalogue.PLATFORM_CATEGORIES[source] or 'other'
	local prop = word(definition.prop)
	local spoken = type(definition.words) == 'table' and definition.words or {}
	local entry = {
		name = name,
		written = false,
		kind = kind,
		label = M.Common.Text(definition.label, MAX_LABEL) and definition.label or name,
		category = category,
		source = source,
		icon = (prop and PROP_ICONS[prop]) or Catalogue.CATEGORY_ICONS[category] or 'emote',
		prop = prop,
		placement = word(definition.placement) or 'standing',
		-- A layer keeps the player's own locomotion, so it needs no walking pace;
		-- a workspot the platform cancels at half a metre gets none either.
		walk = nil,
		-- One gesture, then done: a wave is not held for ten seconds.
		once = kind == 'layer' and ONCE_MODES[definition.mode] == true,
		durations = type(definition.durations) == 'table' and definition.durations or {},
		clips = {},
		words = {},
		variantOf = {},
	}
	for index = 1, #definition.clips do
		local clip = definition.clips[index]
		if not M.Common.Text(clip, MAX_CLIP) or entry.variantOf[clip] ~= nil then
			return nil, 'malformed'
		end
		entry.clips[index] = clip
		entry.variantOf[clip] = index
		local said = spoken[index]
		entry.words[index] = (type(said) == 'string' and #said <= MAX_LABEL
			and not said:find('%c')) and said or ''
	end
	byName[name] = entry
	adopted[#adopted + 1] = entry
	merged = nil
	return entry, nil
end

--- Answers an adopted entry's definition in the shape the offer carries it:
--- no durations, which only the server schedules with.
-- @author dop42
-- @param entry table
-- @return table
function Catalogue.Wire(entry)
	return {
		name = entry.name,
		label = entry.label,
		category = entry.source,
		kind = entry.kind,
		placement = entry.placement,
		prop = entry.prop or '',
		mode = entry.once and 'once' or '',
		clips = entry.clips,
		words = entry.words,
	}
end

--- Drops every adopted entry, so a fresh offer replaces them rather than
--- adding to them. The written rows stay.
-- @author dop42
function Catalogue.Forget()
	for index = 1, #adopted do byName[adopted[index].name] = nil end
	adopted, merged = {}, nil
end

--- How many entries were adopted from the platform.
-- @author dop42
-- @return integer
function Catalogue.AdoptedCount()
	return #adopted
end

--- Answers the name a player reads for an entry. A written row, or a platform
--- profile the locale files translate, reads its catalogue key; any other
--- platform profile reads the platform's own label, which is English.
-- @author dop42
-- @param entry table
-- @return string
function Catalogue.Label(entry)
	local key = 'animations.name.' .. entry.name
	if entry.written or OPX.Locale.Exists(key) then return locale(key) end
	return entry.label or entry.name
end

-- ── the platform's two-player presentations ─────────────────────────────────
--
-- `Open77.playerInteractions` drives five kinds. Four have a presentation of
-- their own -- `give` and `heal` with their default profiles, `carry` and
-- `escort` with a FIXED paired one that walks (the carried body follows the
-- carrier; the coordinator rejects a profile override on either) -- and the
-- fifth, `custom`, plays any catalogue profile on each body.
--
-- Each row here is one way to ask for one of the four, from the asker's side.
-- `swap` means the asker is the coordinator's TARGET: "be carried" is a carry
-- whose actor is the invited player. `mirror` is the row the invited player
-- reads, which is the same interaction seen from the other body. `profiles`
-- are the catalogue ids the presentation is made of: one in DISABLED withholds
-- the row, and so does DISABLED naming the row's own id.
Catalogue.DUO_KINDS = {
	{ id = 'carry', kind = 'carry', swap = false, mirror = 'carried', profiles = { 'carry' } },
	{ id = 'carried', kind = 'carry', swap = true, mirror = 'carry', profiles = { 'carry' } },
	{ id = 'escort', kind = 'escort', swap = false, mirror = 'escorted', profiles = {} },
	{ id = 'escorted', kind = 'escort', swap = true, mirror = 'escort', profiles = {} },
	{ id = 'give', kind = 'give', swap = false, mirror = 'give', profiles = { 'give' } },
	{ id = 'heal', kind = 'heal', swap = false, mirror = 'healed',
		profiles = { 'examine', 'wounded' } },
	{ id = 'healed', kind = 'heal', swap = true, mirror = 'heal',
		profiles = { 'examine', 'wounded' } },
}

local duoKindById = {}
for index = 1, #Catalogue.DUO_KINDS do
	local row = Catalogue.DUO_KINDS[index]
	duoKindById[row.id] = row
end

--- Answers the paired-kind row of an id, or nil.
-- @author dop42
-- @param id any
-- @return table|nil
function Catalogue.DuoKind(id)
	return type(id) == 'string' and duoKindById[id] or nil
end
