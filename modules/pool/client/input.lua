--- Edge-driven aim/charge state machine, independent of FPS and the network.
-- @author dop42
local M = OPX.Modules.Get('pool')
M.Input = {}
local I = M.Input
function I.New() return { aiming = false, power = 0, angle = 0, previous = {} } end
function I.Step(state, now, buttons, allowed, captured, delta, sensitivity, seconds)
	local old, event = state.previous, nil
	local right = buttons.right and not old.right
	local left = buttons.left and not old.left
	local release = not buttons.left and old.left
	state.previous = buttons
	if not allowed or captured then state.aiming, state.chargedAt, state.power = false, nil, 0; return nil end
	if buttons.leave and not old.leave then
		state.aiming, state.chargedAt, state.power = false, nil, 0
		return { kind = 'leave' }
	end
	if right or (buttons.cancel and not old.cancel) then
		state.aiming = right and not state.aiming or false
		state.chargedAt, state.power = nil, 0
		return { kind = 'aim', visible = state.aiming }
	end
	if state.aiming then
		state.angle = (state.angle + delta*sensitivity + math.pi) % (2*math.pi) - math.pi
		if left then state.chargedAt = now end
		if state.chargedAt then state.power = math.max(0.02, math.min(1, (now-state.chargedAt)/seconds)) end
		if release and state.chargedAt then
			event = { kind = 'shoot', angle = state.angle, power = state.power }
			state.aiming, state.chargedAt, state.power = false, nil, 0
		end
	elseif buttons.rack and not old.rack then event = { kind = 'rack' } end
	return event
end
