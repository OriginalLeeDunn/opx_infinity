--- Prints what the server answered, and `/opx.client` for the client's own state.
-- @author dop42

local M = OPX.Modules.Get('diagnostics')

-- Page reports forwarded this session. The page caps itself at 20 and gives up;
-- this is the second floor, because the cap is per PAGE LOAD and a reconnect
-- resets it while the server's journal remembers everything.
local forwarded = 0
local MAX_FORWARDED = 20

--- Sends one page failure to the server, where an operator can actually read it.
-- Best effort and deliberately quiet: a diagnostic that raises on its way out is
-- worse than the fault it was describing.
local function forwardPageReport(payload)
	if type(payload) ~= 'table' or forwarded >= MAX_FORWARDED then return end
	local text = payload.text
	if type(text) ~= 'string' or text == '' then return end
	forwarded = forwarded + 1
	pcall(TriggerServerEvent, M.PAGE, text:sub(1, 400))
end

-- Module states that are not a fault. `started` is the good one; `absent` means
-- the module runs on the other side, which every server-only module reports here
-- and which the server journal already prints as normal.
local HEALTHY = { started = true, absent = true }

-- How long after `Start` the client's own module report is forwarded. It runs
-- inside `OPX.Modules.Run`, so the modules after this one in dependency order
-- have not started yet and reading the report now would call half of them
-- missing. Two seconds is well past the end of boot and long before a player has
-- had time to press anything.
local REPORT_AFTER_MS = 2000

--- Puts every client module that did not come up in the SERVER journal.
--
-- WHY THIS EXISTS. A client module that fails is written to `Open77.log` -- a file
-- on the player's machine, which the operator cannot read -- so from the server a
-- module that failed and a module that was never written look identical, and from
-- the player both look like "it does not work". The owner's words for it were that
-- the inventory "sometimes starts, sometimes not", which is a sentence nobody can
-- act on: this turns it into a line naming the module, its state and its reason.
--
-- THIS IS THE HALF OF THIS MODULE THAT CONVERGED ON `OPX.Note`, and the page relay
-- above is the half that did not. The difference is real. A boot fault is a
-- handful of one-off DECISIONS, which is precisely what a note is; it was
-- borrowing the page's wire, so it landed in the journal mislabelled `[page]`, and
-- it bypassed even that wire's client-side cap -- it called `TriggerServerEvent`
-- directly rather than going through `forwardPageReport`, so the only thing
-- bounding it was the server's window. Going through core fixes the label and the
-- bound at once.
--
-- Only the faults travel. A healthy boot sends nothing at all, so this costs one
-- pass over a dozen records and no traffic on the normal path.
--
-- ONE NOTE A RESUME. Each `OPX.Note` is a formatted line and a net event, about
-- 130 instructions, and every fault was noted in one go: at thirty-six modules a
-- boot whose report arrived early -- every later module still coming up -- was
-- the dearest resume of the client boot, and the next module added would have
-- pushed it past the 4,500 the boot budget test holds it to. The thread yields
-- between two notes, and reads the records rather than formatting a report line
-- for every healthy module only to pattern-match it back apart.
local function forwardModuleFaults()
	local faults = {}
	local records = OPX.Modules.All()
	for index = 1, #records do
		local record = records[index]
		if record ~= nil and not HEALTHY[record.State] then
			faults[#faults + 1] = ('%s %s %s'):format(tostring(record.Id), tostring(record.State),
				tostring(record.Reason or ''))
		end
	end
	if #faults == 0 then return end

	-- One note per fault, filed under the module system rather than under this
	-- module: the line is about `inventory` failing, not about `diagnostics`.
	for index = 1, #faults do
		OPX.Note('modules', ('client module: %s'):format(faults[index]))
		Wait(0)
	end
end

function M.Start()
	-- A SECOND handler on `diag`; `OPX.Surface.On` appends rather than replaces,
	-- so the existing client-log line in `lib/client/surface.lua` is untouched and
	-- this one runs beside it.
	OPX.UI.On('overlay', 'diag', forwardPageReport)

	CreateThread(function()
		Wait(REPORT_AFTER_MS)
		forwardModuleFaults()
	end)

	RegisterNetEvent(M.LINES, function(lines)
		if type(lines) ~= 'table' then return end
		for index = 1, #lines do Open77.log.info(tostring(lines[index])) end
	end)

	RegisterCommand('opx.client', function()
		Open77.log.info(('opx_infinity %s, client'):format(OPX.VERSION))
		for _, line in ipairs(OPX.Modules.Report()) do Open77.log.info('[module] ' .. line) end
		for _, line in ipairs(OPX.Scheduler.Report()) do Open77.log.info('[job] ' .. line) end
	end, false)
end
