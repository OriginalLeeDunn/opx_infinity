--- Locale catalogues, lookup with fallback and the global locale shorthand.
-- @author dop42

-- Language code, then key, then text.
local catalogs = {}

local active = 'en'

-- Every lookup falls back here, so an untranslated key still reads as words.
local FALLBACK = 'en'

OPX.Locale = {}
local Locale = OPX.Locale

--- Merges a language's strings into its catalogue, replacing only the keys given.
-- @author dop42
-- @param code string
-- @param strings table<string, string>
function OPX.Locale.Register(code, strings)
	local catalog = catalogs[code]
	if not catalog then
		catalog = {}
		catalogs[code] = catalog
	end
	for key, text in pairs(strings) do catalog[key] = text end
end

--- @author dop42
-- @param code string
-- @return boolean
function OPX.Locale.Set(code)
	if type(code) ~= 'string' or code == '' then return false end
	active = code
	return true
end

--- @author dop42
-- @return string
function OPX.Locale.Current()
	return active
end

--- A flat copy of the active catalogue over the fallback, for handing the whole
--- of it to something that cannot call back -- a WebUI page, which has no way to
--- resolve a key per render.
-- @author dop42
-- @return table<string, string>
function OPX.Locale.Catalogue()
	local flat = {}
	for key, text in pairs(catalogs[FALLBACK] or {}) do flat[key] = text end
	if active ~= FALLBACK then
		for key, text in pairs(catalogs[active] or {}) do flat[key] = text end
	end
	return flat
end

--- The same flat catalogue as `Catalogue`, built a slice at a time.
-- Yields every `every` entries when the host has `Wait`, so a client building
-- it for the page does not spend a whole resume's budget on one copy loop:
-- several thousand keys, copied twice when the active language is not the
-- fallback, is past that budget. Call it from a thread.
-- @author dop42
-- @param every integer entries between two yields
-- @return table<string, string>
function OPX.Locale.CatalogueSliced(every)
	local flat, copied = {}, 0
	local canWait = type(Wait) == 'function'
	local function copy(from)
		for key, text in pairs(from or {}) do
			flat[key] = text
			copied = copied + 1
			if canWait and copied % every == 0 then Wait(0) end
		end
	end
	copy(catalogs[FALLBACK])
	if active ~= FALLBACK then copy(catalogs[active]) end
	return flat
end

--- Whether the active or fallback catalogue carries a key.
-- @author dop42
-- @param key string
-- @return boolean
function OPX.Locale.Exists(key)
	return (catalogs[active] and catalogs[active][key] ~= nil)
		or (catalogs[FALLBACK] and catalogs[FALLBACK][key] ~= nil)
end

--- Resolves a key through the active catalogue, the fallback, then itself.
-- Answering the key itself rather than nil means a missing string shows up on
-- screen as the key that is missing, and never as a concatenation error.
-- @author dop42
-- @param key string
-- @param params table<string, string|number>|nil
-- @return string
function OPX.Locale.Text(key, params)
	local catalog = catalogs[active]
	local text = (catalog and catalog[key])
		or (catalogs[FALLBACK] and catalogs[FALLBACK][key])
		or key
	return OPX.String.Interpolate(text, params)
end

--- An amount of money as a player reads it, in the active language.
-- @author dop42
--
-- ONE FORMAT FOR EVERY PRICE. Prices reached the screen as bare numbers
-- (`Paid 4500 at Jinguji.`, `You received 500 BANK`), each module formatting
-- its own way or not at all. The thousands separator is the language's
-- (`money.separator`: `4,500` in English, `4 500` in French, with a narrow
-- no-break space), the currency is a word from the catalogue
-- (`money.type.<TYPE>`, `€$` for eddies), and an unknown type is shown by its
-- configured name rather than dropped.
-- @param amount number
-- @param moneyType string|nil the configured type; the default type when nil
-- @return string
function OPX.Locale.Money(amount, moneyType)
	local value = tonumber(amount) or 0
	local separator = Locale.Exists('money.separator') and Locale.Text('money.separator') or ','
	-- Grouped on a one-byte comma and swapped after: `GroupDigits` reverses the
	-- string, which would reverse the bytes of a multi-byte separator too.
	local grouped = OPX.Math.GroupDigits(math.floor(value + 0.5), ',')
		:gsub(',', (separator:gsub('%%', '%%%%')))
	local shared = OPX.Config and OPX.Config.SHARED
	local typeName = type(moneyType) == 'string' and moneyType ~= '' and moneyType
		or (shared and shared.MONEY and shared.MONEY.DEFAULT) or 'EDDIES'
	local key = 'money.type.' .. typeName
	local currency = Locale.Exists(key) and Locale.Text(key) or typeName
	return Locale.Text('money.amount', { amount = grouped, currency = currency })
end

-- ── the player's own game language, for what is HEARD ────────────────────────
--
-- The catalogues above are the server's one language (`SHARED.LOCALE`). A voice
-- line is the player's: the language their game's voice-over is set to, read
-- off the engine on the client (`Open77.session.locale`, permission
-- `session.locale`). The bot lab, 2026-10-07: "give the voice locales with
-- french german spanish etc".

-- The engine's own codes that are not the two-letter ones (`jp`, `kr`, `cz`, `ua`).
local ENGINE_CODES = { jp = 'ja', kr = 'ko', cz = 'cs', ua = 'uk' }

--- The languages this player's game runs in, best first -- its voice-over, its
--- text, then the BCP-47 tag -- as two-letter codes. Empty on a server, and on
--- a client whose game has not reported its language yet.
-- @return string[]
local function gameLanguages()
	local session = type(Open77) == 'table' and Open77.session or nil
	if type(session) ~= 'table' or type(session.locale) ~= 'function' then return {} end
	local read, reported = pcall(session.locale)
	if not read or type(reported) ~= 'table' then return {} end
	local out = {}
	for _, code in ipairs({ reported.voiceLanguage, reported.gameLanguage, reported.code }) do
		if type(code) == 'string' and #code >= 2 then
			local head = code:sub(1, 2):lower()
			out[#out + 1] = ENGINE_CODES[head] or head
		end
	end
	return out
end

--- The variant of something heard in this player's language: `variants` keyed
--- by two-letter code, `fallback` (the English one) when the game's voice-over
--- is English, its language has no variant, or it has not reported.
-- @param variants table|nil
-- @param fallback any
-- @return any the variant
-- @return string its language
function OPX.Locale.ForVoice(variants, fallback)
	if type(variants) == 'table' then
		for _, lang in ipairs(gameLanguages()) do
			if lang == 'en' then break end
			if variants[lang] ~= nil then return variants[lang], lang end
		end
	end
	return fallback, 'en'
end

-- The global shorthand every gameplay file calls.
locale = Locale.Text

Locale.Set(OPX.Config.SHARED and OPX.Config.SHARED.LOCALE)
