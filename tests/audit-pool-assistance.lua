--- Installed optics gates, approximate outgoing paths, private grants and VM bounds.
local M, env = {}, nil
env=setmetatable({OPX={Modules={Get=function()return M end},Note=function()end},Open77={debugDraw={}}},{__index=_G})
for _,f in ipairs({'shared/model','shared/assistance','shared/match','shared/playback','client/prediction','client/guide'})do assert(loadfile('modules/pool/'..f..'.lua','t',env))()end
local A,P,B=M.Assistance,M.Prediction,M.Playback
local settings=A.Read()
local function installed(tier,condition,slot,id)return{{chrome=id or'kiroshi_optics',tier=tier,condition=condition,slot=slot or'eyes'}}end
assert(A.Level(settings,nil)==0 and A.Level(settings,{})==0,'uninstalled optics gave assistance')
for tier=1,3 do assert(A.Level(settings,installed(tier,100))==tier,'installed optics tier ignored')end
assert(A.Level(settings,installed(3,0))==0 and A.Level(settings,installed(3,nil))==0,'broken/unknown-condition optics granted assistance')
assert(A.Level(settings,installed(3,100,'arms'))==0 and A.Level(settings,installed(3,100,nil,'unknown'))==0,'wrong-slot/unknown chrome granted assistance')
assert(A.Level(settings,installed(2.5,100))==0 and A.Level(settings,installed(9,100))==0,'unknown tier granted assistance')
assert(A.Level(A.Read({ENABLED=false,BASE_LEVEL=3}),installed(3,100))==0,'disabled assistance leaked')
assert(A.Level(A.Read({BASE_LEVEL=2}),{})==2,'configured baseline ignored')
local custom=A.Read({IMPLANTS={optic_custom={SLOT='eyes',TIERS={[2]=3}}},MAX_BOUNCES=1})
assert(A.Level(custom,installed(2,100,'eyes','optic_custom'))==3 and A.Level(custom,installed(3,100))==0,'custom implant map ignored')
assert(A.Profile(custom,3).bounces==1,'custom bounce limit ignored')
local spec={x=100,y=10,z=1,yaw=20,halfLength=1.4,halfWidth=.68}
local function points()
 local p={{-.6,0,true},{.2,0,true}}
 for i=3,16 do p[i]={.7,(i-9)*.045,false}end
 return p
end
local balls=points()
local basic=A.Profile(settings,1);local improved=A.Profile(settings,2);local advanced=A.Profile(settings,3)
local paths,contact=P.Trace(spec,balls,0,.5,basic)
assert(#paths==1 and math.abs(contact[1]-(.2-M.Model.RADIUS*2))<1e-8,'basic estimate ignores first impact')
local outgoing=P.Trace(spec,balls,0,.5,improved);local object=false
for _,leg in ipairs(outgoing)do if leg[5]=='#FFD166CC'then object=true;assert(leg[3]>leg[1],'head-on object moved backwards')end end
assert(object,'tier two lacks object-ball trajectory')
balls[2][2]=.04
local cut=P.Trace(spec,balls,0,.5,improved);local cue=false;object=false
for _,leg in ipairs(cut)do cue=cue or leg[5]=='#78DBF0B0';object=object or leg[5]=='#FFD166CC'end
assert(cue and object,'cut shot lacks separate cue/object outgoing paths')
balls=points();balls[2][3]=false
local low=P.Trace(spec,balls,0,.02,advanced);local high=P.Trace(spec,balls,0,1,advanced)
assert(#high>#low and #high>1,'power or cushion rebounds did not affect estimate')
balls[1][1]=0
local pocket=P.Trace(spec,balls,math.pi/2,1,advanced)
assert(#pocket==1,'preview bounced a side-pocket shot')
assert(#P.Trace(spec,balls,0,.5,A.Profile(settings,0))==0,'level zero drew trajectories')
local geometry,clears
function env.Open77.debugDraw.set(_,g)geometry=g;return true end
function env.Open77.debugDraw.clear()clears=true;geometry=nil;return true end
local worst=0
settings=A.Read({MAX_DISTANCE=6})
for tier=1,3 do
 for angle=-math.pi,math.pi,.13 do
  balls=points();for i=3,16 do balls[i][3]=true end
  local before=balls[1][1];local cost=0
  M.Guide.Reset();debug.sethook(function()cost=cost+100 end,'',100)
  M.Guide.Draw(spec,balls,angle,1000,A.Profile(settings,tier),1)
  debug.sethook();worst=math.max(worst,cost)
  assert(cost<8000,'optical preview exceeded callback budget: '..cost)
  assert(geometry and #geometry.lines<=20,'preview exceeded native geometry budget')
  assert(balls[1][1]==before,'preview mutated the authoritative snapshot')
  for _,line in ipairs(geometry.lines)do for _,p in ipairs({line.a,line.b})do
   assert(p.x==p.x and p.y==p.y and p.z==p.z,'preview produced non-finite geometry')
  end end
 end
end
M.Guide.Draw(spec,balls,0,1100,A.Profile(settings,0),1);assert(clears and not geometry,'implant removal left visible guidance')
-- Untrusted/malformed assistance data never prevents ball playback or grants optics.
local function packet(level)
 return{epoch=1,sequence=1,revision=1,owner=7,readyAt=0,phase='ready',assistance=level,frames={{time=0,balls=points()}}}
end
for _,level in ipairs({false,-1,4,2.5,'3',{}})do local buffer=B.New();assert(B.Push(buffer,packet(level),1000)and buffer.state.assistance==0,'bad grant affected playback or enabled assistance')end
local buffer=B.New();assert(B.Push(buffer,packet(3),1000)and buffer.state.assistance==3,'valid assistance grant lost')
print('pool optical preview: installed tiers/condition/slot, configured grants, impact/outgoing/rebounds/pockets, power, privacy-ready wire and cleanup; worst',worst,'instructions')
