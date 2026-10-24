--- Real client lifecycle with an enabled table; natives are explicit render doubles.
local Host = dofile('tests/host.lua')
local env, control = Host.Environment('client')
local props, nextId, creates, moves, mouse, state = {}, 0, 0, 0, 0, {}
local failed, refused, cameraFov = false, nil, 52
for _,name in ipairs({'allowShoot','allowAim','allowInteraction','freezeRotation','freezePosition','allowWeapons','allowJump','allowDodge'}) do
	env.Open77.players[name] = function(value) state[name]=value; return true end
end
env.Open77.players.localId = function() return 7 end
env.Open77.character.position = function() return 99,10,1 end
env.Open77.input.axis = function() return mouse end
env.Open77.props = {
	create = function(options)
		local modes={static=true,kinematic=true,dynamic=true,none=true}
		if not modes[options.physics] then return nil,'invalid_physics' end
		assert(options.collision==false and options.physics=='none' and options.visible==true,'pool visual prop acquired collision/physics')
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
local camId, cameraHeld, cameraCreated, cameraDestroyed, cameraRefused = nil, false, 0, 0, false
env.Open77.camera = env.Open77.camera or {}
env.Open77.camera.create = function(options) cameraCreated=cameraCreated+1; camId=cameraCreated; return camId end
env.Open77.camera.activate = function(id) if cameraRefused then return false,'camera_held_by:test' end; cameraHeld=true; return true end
env.Open77.camera.destroy = function(id) cameraDestroyed=cameraDestroyed+1; cameraHeld=false; camId=nil; return true end
env.Open77.camera.setTransform = function(_, transform) cameraFov=transform.fov; return true end
env.Open77.camera.lookAt = function() return true end
env.Open77.camera.cameras = function() return {held=cameraHeld,activeCamera=camId} end
local guideShown=false
env.Open77.debugDraw={set=function() guideShown=true; return true end,clear=function() guideShown=false; return true end}
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
M.Client.Frame(); M.Client.Guide(); M.Client.Strip()
assert(cameraHeld and state.freezePosition==true and guideShown,'entry did not arm a camera/guide')
control.input.down.V=true;control.Advance(20);M.Client.Frame();control.input.down.V=false
assert(cameraFov==52,'inventory V key switched pool view')
control.input.down.mouse3=true;control.Advance(20);M.Client.Frame();control.input.down.mouse3=false
assert(cameraFov>52,'middle click did not switch pool view')
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
assert(creates==4 and moves>=300 and cameraCreated==2,'movement respawned props or camera')
-- Right click cancels the automatically armed view; another press arms it.
control.input.down.mouse2=true; M.Client.Frame()
assert(not cameraHeld and state.freezePosition==false,'cancel kept camera/body frozen')
control.input.down.mouse2=false; M.Client.Frame()
control.input.down.mouse2=true; M.Client.Frame()
assert(state.freezeRotation==true and state.freezePosition==true and cameraHeld,'aim failed to acquire camera/position')
M.Client.Draw(); assert(creates>=4,'cue missing')
control.input.down.mouse2=false; control.input.down.mouse1=true; M.Client.Input()
control.Advance(1200); control.input.captured=true; M.Client.Input(); M.Client.Draw()
assert(state.freezeRotation==false and state.freezePosition==false and not cameraHeld and not guideShown,'chat capture kept view/guide/body frozen')
for _,message in ipairs(control.serverEvents) do assert(not(message.name==M.Event.REQUEST and message[1]=='shoot'),'captured release fired shot') end
control.input.captured=false; control.input.down.mouse1=false; M.Client.Frame()
assert(not cameraHeld and state.freezePosition==false,'closing inventory resumed an interrupted aim')
-- A server scope revocation immediately drops local props, input and seat.
M.Client.Receive({closed=true})
assert(next(props)==nil and state.allowShoot==true and state.freezeRotation==false and not cameraHeld and not guideShown,'scope revoke leaked projection/view')
M.Client.Watch()
local resumed=packet(1,0); resumed.epoch=4; M.Client.Receive(resumed); M.Client.Frame()
assert(state.allowShoot==false,'practice did not recover after scope resubscribe')
-- A renderer failure releases the seat and controls and does not silently retry.
failed=true; M.Client.Watch()
assert(next(props)==nil and M.Render.Failed() and state.allowShoot==true,'failed model kept objects or controls')
local before=creates
M.Client.Draw(); M.Client.Watch(); assert(creates==before,'failed model retry loop')
M.Stop(); assert(next(props)==nil and state.freezeRotation==false and state.freezePosition==false and not cameraHeld,'stop leaked props/controls/camera')
-- Refusing a camera must release the seat and every view/control claim.
failed=false; cameraRefused=true
M.Init(); M.Start(); M.Client.Watch()
local denied=packet(1,0); denied.epoch=9; M.Client.Receive(denied)
M.Client.Frame(); M.Client.Frame()
assert(not cameraHeld and state.freezePosition==false and state.allowShoot==true and next(props)==nil,'camera refusal left a practice seat/view')
M.Stop(); cameraRefused=false
-- An accepted shot changes to table view and rearms only after playback settles.
M.Init(); M.Start(); M.Client.Watch()
local ready=packet(1,0); ready.epoch=10; M.Client.Receive(ready)
M.Client.Frame(); M.Client.Frame()
control.input.down.mouse1=true; M.Client.Input(); control.Advance(400)
control.input.down.mouse1=false; M.Client.Frame()
assert(cameraHeld and state.freezePosition==true,'shot dropped the table camera')
local moving=packet(2,50); moving.epoch=10; moving.phase='rolling'; M.Client.Receive(moving); M.Client.Frame()
local settled=packet(3,100); settled.epoch=10;settled.revision=2;settled.readyAt=100
M.Client.Receive(settled); M.Client.Frame(); control.Advance(200);M.Client.Frame();M.Client.Frame()
assert(cameraHeld and state.freezePosition==true,'settled shot did not rearm the aiming view')
control.input.down.BACKSPACE=true; M.Client.Frame();control.input.down.BACKSPACE=false
assert(not cameraHeld and state.freezePosition==false and not guideShown,'leave failed to release the table view')
M.Stop()
-- A mode can be accepted before native focus finishes closing its menu.
M.Init(); M.Start(); M.Client.Watch(); control.input.captured=true;control.input.down.mouse1=true
local beforeSelect=#control.serverEvents
local selected=packet(1,0); selected.epoch=11; M.Client.Receive(selected)
M.Client.Frame(); M.Client.Frame()
assert(not cameraHeld,'mode started while the menu still owned native input')
control.input.captured=false; M.Client.Frame();M.Client.Frame()
assert(cameraHeld and state.freezePosition==true,'accepted menu choice lost its deferred aim during focus release')
control.input.down.mouse1=false;M.Client.Frame()
for index=beforeSelect+1,#control.serverEvents do
 local message=control.serverEvents[index]
 assert(not(message.name==M.Event.REQUEST and message[1]=='shoot'),'menu selection click charged or fired the cue')
end
M.Stop()
-- Exercise the actual OPX menu page, rather than injecting a chosen mode.
M.Init(); M.Start(); M.Client.Watch()
local idle=packet(1,0,0); idle.epoch=12;idle.game=M.Match.New('practice')
M.Client.Receive(idle);M.Client.Frame();control.ReadyPages();M.Client.OpenTable();control.Pump(5)
local menu=O.Api.Get('menu').State();assert(menu.ok)
local page
for _,candidate in ipairs(control.pages) do
 for _,message in ipairs(candidate.sent) do if message.channel=='opx:menu:open' then page=candidate end end
end
assert(page,'table menu page missing')
local start=#control.serverEvents
worst=math.max(worst,measured(function()
 control.PageEmit(page,'opx:menu:choose',{handle=menu.value.handle,index=1})
end))
local choice
for index=start+1,#control.serverEvents do
 local e=control.serverEvents[index]
 if e.name==M.Event.REQUEST and e[1]=='create' then choice=e[2] end
end
assert(choice and choice.mode=='practice','actual menu did not send create')
local accepted=packet(2,50);accepted.epoch=13;accepted.game=M.Match.New(choice.mode,7)
M.Client.Receive(accepted);M.Client.Frame();M.Client.Frame()
assert(cameraHeld,'real menu selection failed to arm camera')
M.Stop()
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
