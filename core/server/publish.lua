--- The public server bus: what another Open77 resource may listen to.
-- @author dop42
--
-- ON THE SERVER, `TriggerEvent` IS HOST-WIDE. The devkit card for
-- `server:TriggerEvent` (op77.45 on) is exact: "every running resource that
-- handles the name receives it", queued and drained on the next tick, with the
-- arguments copied through the export marshaller. So a server raise is already a
-- broadcast to every resource on the host -- `opx:in:*` included, which is why
-- the internal raises stay plain values and why nothing here is a secret.
--
-- What this file adds is the PROMISE. `opx:in:*` is this resource's own wiring
-- and changes shape whenever a module needs it to; `opx:on:*` on the server is
-- the curated surface a creator writes against, and its payloads are the ones
-- docs/MANUAL.md "For creators" lists. Every one of them is `(source, payload)`:
-- the player id the change is about (nil for a character who is not online), and
-- one plain table built for the occasion -- never a live record, which would
-- hand the bus a copy of PlayerData nobody meant to publish.
--
-- A RAISE THAT IS REFUSED IS SAID ONCE, AND NEVER RAISES. The host answers
-- `false, reason` for a payload it cannot marshal or a queue that is full; the
-- gameplay that caused the event has already happened by then and must not be
-- undone by the announcement of it.

local REFUSED_ONCE = {}

-- Only the public channel goes through here. A private name raised through the
-- public door would be a promise nobody made.
local PREFIX = 'opx:' .. OPX.Channel.LOCAL .. ':'

--- Raises one public server event for every resource on the host.
-- @author dop42
-- @param name string an `opx:on:<module>:<verb>` name
-- @param source integer|nil the player the event is about
-- @param payload table a plain table: no function, no cycle, no live record
-- @return boolean whether the host took it
function OPX.Publish(name, source, payload)
	if type(name) ~= 'string' or name:sub(1, #PREFIX) ~= PREFIX then
		error(('OPX.Publish takes an %s* name, got %s'):format(PREFIX, tostring(name)), 2)
	end
	local raised, accepted, reason = pcall(TriggerEvent, name, source, payload)
	if raised and accepted ~= false then return true end
	if not REFUSED_ONCE[name] then
		REFUSED_ONCE[name] = true
		Open77.log.warn(('[publish] %s was not raised: %s')
			:format(name, tostring(raised and reason or accepted)))
	end
	return false
end
