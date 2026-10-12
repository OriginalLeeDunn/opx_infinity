--- Client half: the break on screen, the tips, the pass shown, the two forms
--- and the editor desks on the eye.
-- @author dop42
--
-- NONE OF IT DECIDES. The server says which form to open and with what limits,
-- which break to draw, which tip arrived and whose pass was shown; this half
-- draws them and sends back what the player typed or which desk they chose.
--
-- THE BREAK IS DRAWN LIKE A STAFF ANNOUNCEMENT, through `OPX.Toast.Show` on
-- the runtime's own overlay with the stingers of THIS client's config
-- (`config/media.lua` BROADCAST.STINGER), so the opening clip plays before the
-- headline appears and the closing one after it goes. One toast id: a second
-- break replaces the first instead of stacking on top of it.
--
-- THE CLIENT BUDGET. The desks are put on the eye on a thread of their own,
-- one row a resume, out of the same `Model.Build` the server runs.

local M = OPX.Modules.Get('media')
local Model = M.Model

local OWNER = 'media'
local BREAK_ID = 'opx.media.breaking'
local FORM_ID = 'media.form'

-- ── what the server says ────────────────────────────────────────────────────

local function clean(value, maximum)
	return type(value) == 'string' and OPX.Text.Clean(value, maximum) or nil
end

local function onBroadcast(payload)
	if type(payload) ~= 'table' then return end
	local headline = clean(payload.headline, 120)
	if headline == nil or headline == '' then return end
	local label = clean(payload.label, 48) or ''
	local text = clean(payload.text, 400)
	local durationMs = tonumber(payload.durationMs)
	if durationMs == nil or durationMs ~= durationMs or durationMs < 0 then durationMs = nil end
	local stinger = type(M.Settings.BROADCAST) == 'table' and M.Settings.BROADCAST.STINGER or nil
	local raised, why = OPX.Toast.Show({
		id = BREAK_ID,
		kind = 'warning',
		title = locale('media.break.title', { network = label }),
		message = text and text ~= '' and ('%s - %s'):format(headline, text) or headline,
		durationMs = durationMs,
		stinger = stinger,
	})
	if raised == nil then OPX.Note('media', ('a break was not drawn: %s'):format(tostring(why))) end
end

local function onTip(payload)
	if type(payload) ~= 'table' then return end
	local text = clean(payload.text, 400)
	if text == nil or text == '' then return end
	OPX.Toast.Show({ kind = 'info', title = locale('media.tip.title', { id = math.tointeger(payload.id) or 0 }),
		message = text, durationMs = 12000 })
end

local function onPass(payload)
	if type(payload) ~= 'table' then return end
	local status = (payload.status == 'valid' or payload.status == 'revoked') and payload.status or 'unverified'
	OPX.Toast.Show({
		kind = status == 'valid' and 'success' or (status == 'revoked' and 'error' or 'info'),
		title = locale('media.pass.title'),
		message = locale('media.pass.' .. status, { name = clean(payload.name, 64) or '?',
			network = clean(payload.network, 48) or '?', grade = clean(payload.grade, 48) or '' }),
		durationMs = 8000,
	})
end

-- ── the forms ───────────────────────────────────────────────────────────────

local function limit(value, fallback)
	local read = type(value) == 'table' and math.tointeger(value.max) or nil
	if read == nil or read < 1 then return fallback end
	return math.min(read, 512)
end

local function onForm(payload)
	if type(payload) ~= 'table' then return end
	local form = OPX.Api.Get('form')
	if form == nil or type(form.Open) ~= 'function' then
		return OPX.Toast.Locale('media.error.no_form', nil, 'error')
	end
	local label = clean(payload.label, 48) or ''
	local spec
	if payload.kind == 'breaking' then
		spec = {
			owner = OWNER, id = FORM_ID,
			title = locale('media.form.breakingTitle', { network = label }),
			description = locale('media.form.breakingHelp'),
			fields = {
				{ id = 'headline', label = locale('media.form.headline'), required = true,
					maxLength = limit(payload.headline, 80) },
				{ id = 'text', label = locale('media.form.text'), maxLength = limit(payload.text, 240) },
			},
			on = function(answer)
				if type(answer) ~= 'table' or answer.action ~= 'submit' then return end
				local values = type(answer.values) == 'table' and answer.values or {}
				TriggerServerEvent(M.Event.REQUEST, { verb = 'breaking', headline = values.headline, text = values.text })
			end,
		}
	elseif payload.kind == 'story' then
		spec = {
			owner = OWNER, id = FORM_ID,
			title = locale('media.form.storyTitle', { network = label }),
			description = locale('media.form.storyHelp'),
			fields = {
				{ id = 'headline', label = locale('media.form.headline'), required = true,
					maxLength = limit(payload.headline, 80) },
				{ id = 'body', label = locale('media.form.body'), required = true,
					maxLength = limit(payload.body, 480) },
			},
			on = function(answer)
				if type(answer) ~= 'table' or answer.action ~= 'submit' then return end
				local values = type(answer.values) == 'table' and answer.values or {}
				TriggerServerEvent(M.Event.REQUEST, { verb = 'story', headline = values.headline, body = values.body })
			end,
		}
	else
		return
	end
	local opened = form.Open(spec)
	if type(opened) ~= 'table' or not opened.ok then
		OPX.Note('media', ('the form was refused: %s'):format(tostring(type(opened) == 'table' and opened.error or opened)))
	end
end

-- ── the eye ─────────────────────────────────────────────────────────────────

local function registerDesks()
	local target = OPX.Api.Get('target')
	if target == nil or type(target.RegisterSpheres) ~= 'function' then
		OPX.Note('media', 'no target contract: no editor desk rows on the eye')
		return
	end
	local desks = Model.Desks(M.Settings, function() Wait(0) end)
	Wait(0)
	for index, desk in ipairs(desks) do
		local placed = target.RegisterSpheres(OWNER, { { x = desk.x, y = desk.y, z = desk.z, radius = desk.radius } }, {
			id = ('media.desk.%d'):format(index),
			label = locale('media.row.sell', { desk = desk.label }),
			icon = 'money',
			distance = desk.radius,
			order = 32,
			onSelect = function()
				TriggerServerEvent(M.Event.REQUEST, { verb = 'sell', network = desk.network, desk = desk.key })
				return true
			end,
		})
		if type(placed) ~= 'table' or not placed.ok then
			OPX.Note('media', ('a desk row was refused: %s'):format(tostring(type(placed) == 'table' and placed.error or placed)))
			return
		end
		Wait(0)
	end
end

-- ── the phases ──────────────────────────────────────────────────────────────

--- Listens to the server and puts the desks on the eye, on a thread.
-- @author dop42
function M.Start()
	RegisterNetEvent(M.Event.BROADCAST, onBroadcast)
	RegisterNetEvent(M.Event.TIP, onTip)
	RegisterNetEvent(M.Event.PASS, onPass)
	RegisterNetEvent(M.Event.FORM, onForm)
	CreateThread(registerDesks)
end

--- Takes the break off the screen.
-- @author dop42
function M.Stop()
	pcall(OPX.Toast.Dismiss, BREAK_ID)
end
