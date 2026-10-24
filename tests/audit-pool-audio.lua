--- Authoritative audio contacts deduplicate and follow the delayed ball timeline.
local M, calls = {Settings={AUDIO_VOLUME=.5}}, {}
local env=setmetatable({OPX={Modules={Get=function()return M end},Note=function()end},Open77={exports={callSync=function(resource,name,events)
 assert(resource=='opx_pool_assets');calls[#calls+1]={name=name,events=events};return true
end}}},{__index=_G})
for _,f in ipairs({'shared/model','client/audio'})do assert(loadfile('modules/pool/'..f..'.lua','t',env))()end
local A=M.Audio
local spec={x=10,y=20,z=1,yaw=0}
local buffer={offset=1000,lastTime=200}
local function e(id,time)return{id=id,time=time,kind='ball',x=.1,y=.2,volume=.8}end
A.Queue({epoch=1,sounds={e(1,0)}},buffer);A.Frame(spec,1500);assert(#calls==0,'join replayed old sound')
A.Queue({epoch=1,sounds={e(1,0),e(2,100)}},buffer)
A.Frame(spec,1199);assert(#calls==0,'audio led the delayed ball motion')
A.Frame(spec,1200);assert(#calls==1 and #calls[1].events==1 and math.abs(calls[1].events[1].volume-.4)<1e-9)
A.Queue({epoch=1,sounds={e(2,100)}},buffer);A.Frame(spec,1400);assert(#calls==1,'duplicate contact replayed')
A.Queue({epoch=1,sounds={e(3,120),e(3,121)}},buffer);A.Frame(spec,1400);assert(#calls==1,'invalid batch partly played')
local many={};for i=3,14 do many[#many+1]=e(i,120+i)end
A.Queue({epoch=1,sounds=many},buffer);A.Frame(spec,1500)
assert(#calls[2].events==4,'audio batch exceeded bound')
A.Clear();assert(calls[#calls].name=='pool_audio_clear')
local before=#calls
A.Queue({epoch=2,sounds={}},buffer);A.Queue({epoch=2,sounds={e(1,50)}},buffer);A.Frame(spec,1200)
assert(#calls==before+1 and #calls[#calls].events==1,'rerack did not reset contact watermark')
A.Clear();M.Settings.AUDIO_VOLUME=0
A.Queue({epoch=3,sounds={}},buffer);A.Queue({epoch=3,sounds={e(1,50)}},buffer)
before=#calls;A.Frame(spec,1200);assert(#calls==before,'muted table played audio')
print('pool audio: delayed timeline, join/replay suppression, atomic batches, bounded voices and mute passed')
