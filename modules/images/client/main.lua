--- Relays bounded public URL pages, including when CEF is rebuilt mid-session.
-- @author dop42
-- No image catalogue walk in a client resume: each packet holds eight rows and
-- page-ready replays yield between packets. The server config is never loaded here.
local M = OPX.Modules.Get('images')
local revision, packets, ready, epoch = -1, {}, false, 0

local function onPacket(payload)
	if type(payload) ~= 'table' or type(payload.entries) ~= 'table' or #payload.entries > 8 then return end
	local version, index, total = payload.revision, payload.index, payload.total
	if type(version) ~= 'number' or version % 1 ~= 0 or version < revision
		or type(index) ~= 'number' or index % 1 ~= 0 or index < 1
		or type(total) ~= 'number' or total % 1 ~= 0 or total < index or total > 6250 then return end
	if version ~= revision then revision, packets = version, {} end
	packets[index] = payload
	if ready then OPX.UI.Send('interactive', M.Page.SET, payload) end
end

function M.Init() end

function M.Start()
	RegisterNetEvent(M.Event.SET, onPacket)
	OPX.UI.On('interactive', M.Page.READY, function()
		ready, epoch = true, epoch + 1
		local current = epoch
		CreateThread(function()
			local snapshot = packets
			for _, packet in pairs(snapshot) do
				if not ready or epoch ~= current or snapshot ~= packets then return end
				OPX.UI.Send('interactive', M.Page.SET, packet)
				Wait(0)
			end
		end)
	end)
	TriggerServerEvent(M.Event.REQUEST)
end

function M.Stop()
	ready, epoch = false, epoch + 1
end
