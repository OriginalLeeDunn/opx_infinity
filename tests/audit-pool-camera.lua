--- Camera geometry, ownership, failures and bounded aiming aid using real code.
local M, notes, calls, current, nextId, failAt = {}, {}, {}, nil, 0, nil
local env = setmetatable({ OPX={Modules={Get=function() return M end},Note=function(_,why) notes[#notes+1]=why end},Open77={camera={},debugDraw={}} },{__index=_G})
for _,name in ipairs({'create','activate','setTransform','lookAt','destroy','cameras'}) do
 env.Open77.camera[name]=function(...)
  calls[#calls+1]={name,...}
  if failAt==name then return false,'test_refused' end
  if name=='create' then nextId=nextId+1;return nextId end
  if name=='activate' then current=(...);return true end
  if name=='destroy' then if current==(...) then current=nil end;return true end
  if name=='cameras' then return {held=current~=nil,activeCamera=current} end
  return true
 end
end
local geometry, cleared
function env.Open77.debugDraw.set(_,g) geometry=g;return true end
function env.Open77.debugDraw.clear() cleared=true;geometry=nil;return true end
for _,file in ipairs({'shared/model','client/camera','client/guide','client/input'}) do assert(loadfile('modules/pool/'..file..'.lua','t',env))() end
local C,G,I=M.Camera,M.Guide,M.Input
local spec={x=100,y=50,z=10,yaw=90,halfLength=1.4,halfWidth=0.68}
local balls={{0,0,true},{0.5,0,true},{0.8,0.3,true}}
for index=4,M.Model.BALLS do balls[index]={0,0,false} end
local p=C.Pose(spec,balls,0,false,0.5)
assert(math.abs(p.position.x-100)<1e-9 and math.abs(p.position.y-48.75)<1e-9 and p.position.z==10.5,'cue camera not behind white ball in world frame')
assert(p.target.x==100 and p.target.y==50 and p.target.z==10,'white ball is not exactly centered')
assert(C.Pose(spec,balls,0,true,0.5).position.z==11.65,'side camera height changed')
-- Project the cloth's corners into a conservative 4:3 camera frustum.
for _,size in ipairs({{0.9,0.4},{1.4,0.68},{2,1}}) do
 for _,yaw in ipairs({0,90,179}) do
  local tableSpec={x=100,y=50,z=10,yaw=yaw,halfLength=size[1],halfWidth=size[2]}
  local pose=C.Pose(tableSpec,balls,2,true,0.5)
  local dx,dy,dz=pose.target.x-pose.position.x,pose.target.y-pose.position.y,pose.target.z-pose.position.z
  local n=math.sqrt(dx*dx+dy*dy+dz*dz);dx,dy,dz=dx/n,dy/n,dz/n
  local h=math.sqrt(dx*dx+dy*dy);local rx,ry=dy/h,-dx/h
  local ux,uy,uz=-dz*ry,dz*rx,dx*ry-dy*rx
  local tangent=math.tan(math.rad(pose.fov/2))
  for _,x in ipairs({-size[1],size[1]})do for _,y in ipairs({-size[2],size[2]})do
   local point=M.Model.World(tableSpec,x,y);local a,b,c=point.x-pose.position.x,point.y-pose.position.y,point.z-pose.position.z
   local depth=a*dx+b*dy+c*dz
   assert(depth>0 and math.abs(a*rx+b*ry)<depth*tangent*4/3 and math.abs(a*ux+b*uy+c*uz)<depth*tangent,'side view clips a cloth corner')
  end end
 end
end
assert(C.Update(spec,balls,0,false,0.5,0) and current==1)
assert(calls[1][2].thirdPersonBody==true,'scripted view omitted the full body request')
assert(C.Check())
for now=16,160,16 do assert(C.Update(spec,balls,0.2,true,0.5,now)) end
assert(nextId==1,'camera respawned while orbiting')
local lastPose
for _,row in ipairs(calls) do if row[1]=='setTransform' then lastPose=row[3] end end
assert(lastPose.position.z>11 and lastPose.position.z<12.35,'table transition did not interpolate')
C.Clear();assert(current==nil and C.Check())
failAt='activate';assert(not C.Update(spec,balls,0,false,0.5,200));assert(current==nil,'refused activation leaked view')
failAt=nil;assert(C.Update(spec,balls,0,false,0.5,210));current=999
assert(not C.Check(),'lost view ownership not detected');C.Clear();assert(current==999,'clear released another module camera')
current=nil;assert(C.Update(spec,balls,0,false,0.5,220));failAt='setTransform'
assert(not C.Update(spec,balls,0,false,0.5,240) and current==nil,'transform failure kept view')
failAt=nil
C.Clear()
local nativeCreate=env.Open77.camera.create
env.Open77.camera.create=function(options) if options.thirdPersonBody then return nil,'invalid_camera_body' end;return nativeCreate(options) end
assert(C.Update(spec,balls,0,false,0.5,300),'old client fallback failed')
C.Clear();env.Open77.camera.create=nativeCreate
local x,y,d=G.End(spec,balls,0)
assert(math.abs(d-(0.5-M.Model.RADIUS*2))<1e-9 and y==0,'guide ignores first ball radius')
balls[2][3]=false;x,y,d=G.End(spec,balls,0)
assert(math.abs(d-(spec.halfLength-M.Model.RADIUS))<1e-9,'guide ignores cushion boundary')
balls[2][3]=true
local cost=0;debug.sethook(function()cost=cost+100 end,'',100)
G.Draw(spec,balls,0,1000);debug.sethook()
assert(geometry and #geometry.lines<=20 and cost<5000,'unbounded guide or instruction budget: '..cost)
G.Clear();assert(cleared and not geometry,'aim guide survived cancellation')
local input=I.New();I.Step(input,0,{right=true},true,false,0,1,1)
I.Step(input,0.1,{precise=true,overview=true},true,false,1,1,1)
assert(math.abs(input.angle-0.15)<1e-9 and input.overview,'precision/view switch failed')
I.Step(input,0.2,{overview=true},true,false,0,1,1);assert(input.overview,'held V toggled repeatedly')
local charged=I.New();I.Step(charged,0,{right=true},true,false,0,1,1)
I.Step(charged,.1,{left=true},true,false,0,1,1)
local reset=I.Step(charged,.2,{left=true,rack=true},true,false,0,1,1)
assert(reset.kind=='rack' and not charged.aiming and charged.chargedAt==nil,'reset while aiming fired or retained charge')
print('pool camera: world framing, reuse, smoothing, ownership/failure cleanup, first-contact guide; guide budget',cost)
