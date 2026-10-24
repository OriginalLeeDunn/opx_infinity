--- Physics, network authority, playback and physical input; no nc_pool imports.
local M, now, players, notices, packets, cooldowns = {}, 10000, {}, {}, {}, {}
local spec = { enabled = true, x = 100, y = 10, z = 1, yaw = 0, bucket = 0, halfLength = 1.27, halfWidth = 0.635 }
local sessions = { [7] = {}, [8] = {} }
local env = setmetatable({ OPX = {
	Modules = { Get = function() return M end }, Config = { MODULES = { pool = { TABLE = spec } } },
	Text = { Clean = function(s) return s end }, Now = function() return now end, Sessions = sessions,
	Life = { Down = function(id) return players[id].down end },
	Api = { Get = function(name) if name == 'character' then return { GetPlayer = function(id) return players[id] and players[id].person end } end end },
	Scheduler = { Every = function() return 1 end, Cancel = function() end },
	Cooling = function(id, key, duration)
		local full = id .. key
		if cooldowns[full] and now-cooldowns[full] < duration then return true end
		cooldowns[full] = now; return false
	end,
}, Open77 = { players = { get = function(id) return players[id] and players[id].snapshot end }, log = { warn = function() end } },
	RegisterNetEvent = function() end, TriggerClientEvent = function(_, id, packet)
		if type(packet) == 'table' then packets[id] = packet else notices[#notices+1] = packet end
	end,
}, { __index = _G })
M.Event = { STATE = 'state', NOTICE = 'notice', REQUEST = 'request' }
for _, file in ipairs({ 'shared/model', 'shared/match', 'shared/playback', 'client/input', 'server/physics', 'server/main' }) do
	assert(loadfile('modules/pool/' .. file .. '.lua', 't', env))()
end
local P, B, I, Model = M.Physics, M.Playback, M.Input, M.Model
local checks = 0
local function check(value, reason) checks = checks+1; assert(value, reason) end
local function ball(x,y,vx,vy) return { x=x,y=y,vx=vx or 0,vy=vy or 0,alive=true } end
-- A fast cue cannot tunnel through a stationary object even in a large step.
local balls = { ball(-0.25,0,4.5,0), ball(0,0), ball(0.7,0.3) }
check(P.Step(balls,spec,0.1), 'fast collision solver refused')
check(balls[2].vx > 4 and balls[1].vx < 0.1 and balls[1].x < balls[2].x, 'tunnelled through object')
local rail = { ball(1.20,0.3,2,0) }
check(P.Step(rail,spec,0.1) and rail[1].vx < 0 and rail[1].x < spec.halfLength-Model.RADIUS, 'rail bounce')
local pocket = { ball(0,0.5,0,2), ball(0.8,0.3), ball(-0.8,0.3) }
check(P.Step(pocket,spec,0.1) and not pocket[1].alive, 'side pocket capture')
check(P.Respot(pocket,spec) and pocket[1].alive, 'scratch respot')
for i=2,3 do check((pocket[1].x-pocket[i].x)^2+(pocket[1].y-pocket[i].y)^2 > (Model.RADIUS*2)^2, 'respot overlapped') end
balls=P.Rack(spec)
check(not P.Shoot(balls,0/0,1) and not P.Shoot(balls,0,math.huge), 'nonfinite shot accepted')
check(P.Shoot(balls,0,1) and not P.Shoot(balls,0,1), 'moving shot accepted')
local previous=math.huge
for _=1,1400 do
	check(P.Step(balls,spec,Model.STEP), 'contact ceiling on ordinary shot')
	local energy=0
	for _,b in ipairs(balls) do
		energy=energy+b.vx*b.vx+b.vy*b.vy
		check(b.x==b.x and math.abs(b.x)<=spec.halfLength and math.abs(b.y)<=spec.halfWidth, 'invalid ball position')
	end
	check(energy <= previous+1e-7, 'energy created'); previous=energy
end
check(not P.Moving(balls), 'shot never settled')
-- A full triangle fits every accepted table and never starts overlapped.
for _,size in ipairs({{0.9,0.4},{1.4,0.68},{2,1}}) do
 local tableSpec={halfLength=size[1],halfWidth=size[2]}
 local rack=P.Rack(tableSpec);check(#rack==16,'full rack is not fifteen objects plus white')
 for i,a in ipairs(rack) do
  check(math.abs(a.x)+Model.RADIUS<tableSpec.halfLength and math.abs(a.y)+Model.RADIUS<tableSpec.halfWidth,'rack outside cloth')
  for j=i+1,#rack do local b=rack[j];check((a.x-b.x)^2+(a.y-b.y)^2>(Model.RADIUS*2)^2,'overlapping starting balls') end
 end
end
-- Breaks through a dense triangle remain finite, bounded and dissipative.
for _,angle in ipairs({-0.1,-0.025,0,0.025,0.1}) do
 for _,power in ipairs({0.2,0.6,1}) do
  local rack=P.Rack(spec);check(P.Shoot(rack,angle,power),'break refused')
  local previous=math.huge
  for tick=1,1000 do
   check(P.Step(rack,spec,Model.STEP),'full-rack break exceeded contact ceiling')
   local energy=0
   for _,b in ipairs(rack) do
    check(b.x==b.x and b.y==b.y and math.abs(b.x)<=spec.halfLength and math.abs(b.y)<=spec.halfWidth,'break escaped table')
    energy=energy+b.vx*b.vx+b.vy*b.vy
   end
   check(energy<=previous+1e-7,'full-rack break created energy');previous=energy
   if not P.Moving(rack) then break end
  end
  check(not P.Moving(rack),'full-rack break never settled')
 end
end
-- Delayed playback must be smooth, ordered and bounded, including visibility.
local function packet(epoch,seq,t,x,alive)
 local frame=P.Frame(P.Rack(spec),t);frame.balls[1]={x,0,alive}
 return {epoch=epoch,sequence=seq,revision=1,owner=7,readyAt=0,phase='ready',frames={frame}}
end
local buffer=B.New()
check(B.Push(buffer,packet(1,1,0,0,true),10000), 'initial playback')
check(B.Push(buffer,packet(1,2,50,0.5,false),10050), 'second playback')
local view=B.Sample(buffer,10125)
check(math.abs(view[1][1]-0.25)<1e-9 and view[1][3], 'interpolation not between states')
view=B.Sample(buffer,10200)
check(view[1][1]==0.5 and not view[1][3], 'pocket visibility or extrapolation')
check(not B.Push(buffer,packet(1,1,100,0,true),10200), 'out of order packet accepted')
check(B.Push(buffer,packet(2,1,0,0,true),10200), 'rerack epoch did not reset time')
check(not B.Push(buffer,packet(1,999,200,0,true),10201), 'old rack resurrected')
local bad=packet(2,2,10,0/0,true)
check(not B.Push(buffer,bad,10210) and buffer.sequence==1, 'corrupt packet changed playback')
for j=2,100 do check(B.Push(buffer,packet(2,j,j*10,0,true),10200+j*10),'history append') end
check(#buffer.frames<=40,'unbounded history')
-- Mouse charge depends on elapsed time; UI capture/cancel never fires a shot.
local input=I.New()
check(I.Step(input,0,{right=true},true,false,0,0.0025,2.4).kind=='aim','right press did not arm')
I.Step(input,0.1,{left=true},true,false,0,0.0025,2.4)
I.Step(input,1.3,{left=true},true,false,0,0.0025,2.4)
local shot=I.Step(input,1.3,{},true,false,0,0.0025,2.4)
check(shot.kind=='shoot' and math.abs(shot.power-0.5)<1e-9,'charge tied to frame count')
input=I.New(); I.Step(input,0,{right=true},true,false,0,0.0025,2.4)
I.Step(input,0.1,{left=true},true,false,0,0.0025,2.4)
check(I.Step(input,1,{},true,true,0,0.0025,2.4)==nil and not input.aiming,'UI capture fired a shot')
I.Step(input,2,{right=true},true,false,0,0.0025,2.4)
I.Step(input,2.1,{left=true},true,false,0,0.0025,2.4)
check(I.Step(input,3,{right=true},true,false,0,0.0025,2.4).kind=='aim' and not input.aiming,'cancel fired a shot')
-- Server seat and request checks use fresh host position and captured identity.
for _,id in ipairs({7,8}) do players[id]={ person={PlayerData={citizenId='CID'..id}}, snapshot={fresh=true,bucket=0,position={x=100,y=10,z=1}} } end
M.Init(); M.Start()
local function request(id,action,data) now=now+200; return M.Server.Request(id,action,data) end
check(request(7,'enter'),'valid practice entry')
check(not request(8,'enter'),'second owner accepted')
check(request(8,'watch'),'spectator subscribe')
M.Server.Step(); players[8].snapshot.bucket=1; M.Server.Step()
check(packets[8].closed==true,'bucket change retained spectator projection')
players[8].snapshot.bucket=0
M.Server.Step(); local state=packets[7]
check(#state.frames==2 and #state.frames[1].balls==16,'wire packet omitted full-rack endpoints')
local Host=dofile('tests/host.lua')
check(Host.PayloadNodes(state)<Host.MAX_PAYLOAD_NODES,'full-rack packet exceeds transport budget')
local command={epoch=state.epoch,revision=state.revision,angle=0,power=1}
check(not request(8,'shoot',command),'nonowner shot accepted')
check(request(7,'aim',{epoch=state.epoch,revision=state.revision,angle=0,power=0,visible=true}),'valid aim')
now=now+1
check(M.Server.Request(7,'shoot',command),'aim rate limiter swallowed release')
check(not request(7,'shoot',command),'duplicate shot accepted')
for _=1,200 do M.Server.Step() end
local settled=packets[7]
check(settled.phase=='ready' and settled.revision>state.revision,'server never settled')
check(not request(7,'shoot',command),'stale revision accepted')
local current={epoch=settled.epoch,revision=settled.revision,angle=0,power=1}
players[7].snapshot.bucket=1
check(not request(7,'shoot',current),'cross-bucket shot accepted')
players[7].snapshot.bucket=0; players[7].snapshot.fresh=false
check(not request(7,'shoot',current),'stale transform accepted')
players[7].snapshot.fresh=true; sessions[7]={}
check(not request(7,'shoot',current),'recycled session took old seat')
M.Server.Step()
check(request(8,'enter'),'abandoned seat not released')
now=now+1
check(M.Server.Request(8,'leave'),'quick leave swallowed by entry timer')
check(request(7,'enter'),'practice could not be reclaimed')
M.Stop()
check(not request(7,'enter'),'stopped resource accepted request')
-- Named base measurements are adapted as data; no placement helper is imported.
assert(loadfile('config/pool.lua','t',env))()
local config=env.OPX.Config.MODULES.pool
check(Model.Table()==nil,'unverified preset enabled by default')
local mapped=Model.Models()
check(#mapped.objects==15,'missing object ball models')
local distinct={}
for _,path in ipairs(mapped.objects) do check(not distinct[path] and path:match('ball_[c-q]_billiard%.mesh$'),'duplicate/non-billiard model');distinct[path]=true end
check(mapped.cue=='recreation.tent' and mapped.object=='recreation.sleeping_bag' and mapped.stick=='recreation.gym_equipment','asset profile mapping mismatch')
local count=0
for key in pairs(config.PRESETS) do
	count=count+1; config.TABLE={enabled=true,preset=key}
	check(Model.Table()~=nil,'malformed inherited measurement: '..key)
end
check(count==10,'missing base table measurements')
config.TABLE={enabled=true,preset='el_coyote_cojo'}
local coyote=Model.Table()
check(coyote.x==-1247.944 and coyote.z==13.263 and coyote.halfLength==1.4,'floor height used as ball centre')
config.TABLE.preset='missing'
check(Model.Table()==nil,'unknown preset did not fail closed')
print('pool full rack:',checks,'physics, playback, input and server-authority checks passed')
