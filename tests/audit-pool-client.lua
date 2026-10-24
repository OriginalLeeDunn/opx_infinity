--- Real client lifecycle with an enabled table; natives are explicit render doubles.
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('client')
local props, nextId, creates, moves, mouse, state = {}, 0, 0, 0, 0, {}
local failed, refused = false, nil
for _,name in ipairs({'allowShoot','allowAim','allowInteraction','freezeRotation','allowWeapons','allowJump','allowDodge'}) do
	env.Open77.players[name] = function(value) state[name]=value; return true end
end
env.Open77.players.localId = function() return 7 end
env.Open77.character.position = function() return 99,10,1 end
env.Open77.input.axis = function() return mouse end
env.Open77.props = {
	create = function(options)
		nextId=nextId+1; creates=creates+1
		local id=tostring(nextId)
		props[id]={id=id,model=options.model,position=options.position,rendered=true,failed=false,backend='test_host'}
		return id
	end,
	setTransform = function(id, transform) if refused then return false,refused end; assert(props[id]); moves=moves+1; props[id].position=transform.position; return true end,
	remove = function(id) props[id]=nil; return true end,
	list = function()
		local rows={}
		for _,row in pairs(props) do row.failed=failed; rows[#rows+1]=row end
		return rows
	end,
}
for _,file in ipairs(Host.LoadOrder('open77.lua','client')) do
	assert(loadfile(file,'t',env))()
	if file=='config/pool.lua' then env.OPX.Config.MODULES.pool.TABLE={enabled=true,x=100,y=10,z=1,yaw=0,bucket=0,halfLength=1.27,halfWidth=0.635,label='Audit pool'} end
end
control.Fire('onClientResourceStart','opx_infinity'); control.Pump(320)
local O=env.OPX
local M=O.Modules.Get('pool')
assert(O.Modules.IsRunning('pool'),'enabled prototype failed to boot')
O.Modules.Get('character').PlayerData={citizenId='POOL_TEST'}
M.Client.Watch()
local now=O.Now()
local function packet(seq,time,owner)
	return {epoch=1,sequence=seq,revision=1,owner=owner or 7,phase='ready',readyAt=0,
		frames={{time=time,balls={{-0.6,0,true},{0.4,0,true},{0.5,0.2,true}}}}}
end
M.Client.Receive(packet(1,0))
M.Client.Draw(); M.Client.Input()
assert(creates==3 and state.allowShoot==false and state.allowAim==false,'practice did not render/hold weapons')
local function measured(fn)
	local cost=0
	debug.sethook(function() cost=cost+100 end,'',100)
	local ok,why=pcall(fn)
	debug.sethook()
	assert(ok,why); assert(cost<5000,'client resume exceeds prototype budget: '..cost)
	return cost
end
local worst=0
local burst=packet(2,50)
burst.epoch=2; burst.frames={}
for sample=0,6 do burst.frames[#burst.frames+1]={time=sample*1000/120,balls={{-0.6,0,true},{0.4,0,true},{0.5,0.2,true}}} end
worst=math.max(worst,measured(function() M.Client.Receive(burst) end))
local reset=packet(1,0); reset.epoch=3; M.Client.Receive(reset)
for _=1,100 do worst=math.max(worst,measured(M.Client.Frame)) end
assert(creates==3 and moves>=300,'movement respawned props')
control.input.down.mouse2=true; M.Client.Input()
assert(state.freezeRotation==true and creates==3,'aim failed to freeze camera')
M.Client.Draw(); assert(creates==4,'cue missing')
control.input.down.mouse2=false; control.input.down.mouse1=true; M.Client.Input()
control.Advance(1200); control.input.captured=true; M.Client.Input(); M.Client.Draw()
assert(state.freezeRotation==false,'chat capture kept camera frozen')
for _,message in ipairs(control.serverEvents) do assert(not(message.name==M.Event.REQUEST and message[1]=='shoot'),'captured release fired shot') end
control.input.captured=false; control.input.down.mouse1=false; M.Client.Input()
-- A server scope revocation immediately drops local props, input and seat.
M.Client.Receive({closed=true})
assert(next(props)==nil and state.allowShoot==true and state.freezeRotation==false,'scope revoke leaked projection')
M.Client.Watch()
local resumed=packet(1,0); resumed.epoch=4; M.Client.Receive(resumed); M.Client.Frame()
assert(state.allowShoot==false,'practice did not recover after scope resubscribe')
-- A renderer failure releases the seat and controls and does not silently retry.
failed=true; M.Client.Watch()
assert(next(props)==nil and M.Render.Failed() and state.allowShoot==true,'failed model kept objects or controls')
local before=creates
M.Client.Draw(); M.Client.Watch(); assert(creates==before,'failed model retry loop')
M.Stop(); assert(next(props)==nil and state.freezeRotation==false,'stop leaked props/controls')
-- A just-created native entity may not be transformable until streaming ends.
M.Render.Reset(); failed=false
local geometry={x=100,y=10,z=1,yaw=0}
local points={{-0.6,0,true},{0.4,0,true},{0.5,0.2,true}}
assert(M.Render.Draw(geometry,points,false,0,0))
local initial=creates
refused='projection_pending'
control.Advance(100)
assert(M.Render.Draw(geometry,points,false,0,0) and creates==initial,'transient refusal respawned or failed early')
control.Advance(3000)
assert(not M.Render.Draw(geometry,points,false,0,0) and M.Render.Failed() and next(props)==nil,'permanent refusal retried forever')
local diagnosed=false
for _,event in ipairs(control.serverEvents) do
	if event[1]=='pool' and tostring(event[2]):find('projection_pending',1,true) then diagnosed=true end
end
assert(diagnosed,'native refusal reason was discarded')
print('pool enabled client: render reuse, focus cancellation, failed-model cleanup; maximum measured callback',worst,'instructions')
