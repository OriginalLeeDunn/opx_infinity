--- Real scoring, authoritative seats and reset consent; no game or database.
local M, now, people, sessions, packets, cooldowns, result = {}, 10000, {}, {}, {}, {}, nil
for _,id in ipairs({7,8,9}) do
 people[id]={PlayerData={citizenId='POOL'..id},snapshot={fresh=true,bucket=0,position={x=100,y=10,z=1}}};sessions[id]={}
end
local env=setmetatable({OPX={Modules={Get=function() return M end},Config={MODULES={pool={TABLE={enabled=true,x=100,y=10,z=1,yaw=0,bucket=0,halfLength=1.4,halfWidth=.68}}}},
 Text={Clean=function(x)return x end},Now=function()return now end,Sessions=sessions,Life={Down=function(id)return people[id].down end},
 Api={Get=function()return {GetPlayer=function(id)return people[id] end}end},Scheduler={Every=function()return 1 end,Cancel=function()end},
 Cooling=function(id,key,ms)local k=id..key;if cooldowns[k] and now-cooldowns[k]<ms then return true end;cooldowns[k]=now;return false end},
 Open77={players={get=function(id)return people[id].snapshot end},log={warn=function()end}},
 RegisterNetEvent=function()end,TriggerClientEvent=function(_,id,p)if type(p)=='table' then packets[id]=p end end},{__index=_G})
M.Event={STATE='state',NOTICE='notice'};M.Settings={SOLO_SHOTS=2,DUEL_TARGET=2}
for _,file in ipairs({'shared/model','shared/match','server/physics','server/main'}) do assert(loadfile('modules/pool/'..file..'.lua','t',env))() end
local G,P=M.Match,M.Physics
local function clearRack() local result={};for i=2,M.Model.BALLS do result[i]=false end;return result end
local original=P.Step
P.Step=function(balls,spec,dt,contact)
 if result then
  for i,b in ipairs(balls) do b.vx,b.vy=0,0;if result[i]~=nil then b.alive=result[i] end end
  result=nil;return true
 end
 return original(balls,spec,dt,contact)
end
M.Init();M.Start()
local function call(id,action,extra)
 now=now+200
 local p=packets[id] or packets[7]
 local data={epoch=p and p.epoch,revision=p and p.revision}
 for k,v in pairs(extra or {})do data[k]=v end
 return M.Server.Request(id,action,data)
end
local function step()M.Server.Step();return packets[9] or packets[7] or packets[8]end
for _,id in ipairs({7,8,9})do assert(call(id,'watch'))end
local idle=step();assert(idle.game.status=='idle' and G.Read(idle.game))
assert(not call(7,'create',{mode='bogus'}),'unknown mode')
assert(call(7,'create',{mode='duel'}));local lobby=step()
assert(lobby.game.status=='waiting' and lobby.owner==0)
assert(not call(7,'shoot',{angle=0,power=.5}),'lobby shot')
assert(not call(7,'join'),'same player filled two seats')
assert(call(8,'join'));local game=step()
assert(game.game.status=='playing' and game.owner==7 and game.game.players[2]==8 and G.Read(game.game))
assert(not call(9,'join') and not call(9,'create',{mode='practice'}),'third player stole session')
assert(not call(8,'shoot',{angle=0,power=.5}),'non-turn shot')
local stale={epoch=game.epoch,revision=game.revision,angle=0,power=.5}
assert(call(7,'shoot',{angle=0,power=.5,made=99,winner=1}));result={[2]=false};game=step()
assert(game.game.scores[1]==1 and game.owner==7 and game.game.shots==1,'pocket did not keep turn / client outcome trusted')
assert(not call(7,'shoot',stale),'stale shot replay')
assert(call(7,'shoot',{angle=0,power=.5}));result={};game=step()
assert(game.owner==8,'miss did not pass turn')
assert(not call(7,'shoot',{angle=0,power=.5}),'old player kept turn')
assert(call(8,'shoot',{angle=0,power=.5}));result={[1]=false};game=step()
assert(game.owner==7 and game.game.scores[2]==0 and game.frames[#game.frames].balls[1][3],'scratch failed to pass/respot')
assert(call(8,'reset'));game=step()
assert(game.game.resetBy==2 and game.owner==0 and game.game.scores[1]==1,'proposal changed score or allowed shots')
assert(not call(8,'acceptReset') and not call(9,'acceptReset'),'reset did not require other participant')
assert(not call(7,'shoot',{angle=0,power=.5}),'shot during reset consent')
assert(call(7,'declineReset'));game=step();assert(game.owner==7 and game.game.scores[1]==1,'decline changed game')
assert(call(7,'reset'));step();now=now+16000;game=step()
assert(game.game.resetBy==0 and game.game.scores[1]==1,'timeout reset scores')
assert(call(7,'reset'));step();assert(call(8,'acceptReset'));game=step()
assert(game.game.scores[1]==0 and game.game.scores[2]==0 and game.game.shots==0 and game.owner==7,'consensual reset failed')
assert(not call(7,'shoot',stale),'pre-reset command took shot')
assert(call(7,'shoot',{angle=0,power=.5}));result={[2]=false,[3]=false};game=step()
assert(game.game.status=='finished' and game.game.winner==1 and game.owner==0,'duel target did not end')
assert(not call(7,'shoot',{angle=0,power=.5}),'finished game shot')
assert(call(8,'reset'));step();assert(call(7,'acceptReset'));game=step()
assert(call(8,'leave'));game=step()
assert(game.game.status=='finished' and game.game.reason=='forfeit' and game.game.winner==1,'leave did not forfeit')
assert(call(7,'finish'));game=step();assert(game.game.status=='idle')
assert(call(7,'create',{mode='challenge'}));game=step()
assert(call(7,'shoot',{angle=0,power=.5}));result={};game=step()
assert(game.game.status=='playing' and game.game.shots==1)
assert(call(7,'shoot',{angle=0,power=.5}));result={};game=step()
assert(game.game.status=='finished' and game.game.reason=='limit' and game.game.winner==0,'solo shot limit missing')
assert(call(7,'reset'));game=step();assert(game.game.mode=='challenge' and game.game.shots==0)
assert(call(7,'shoot',{angle=0,power=.5}));result=clearRack();game=step()
assert(game.game.winner==1 and game.game.reason=='clear','solo clear failed')
assert(call(7,'finish'));step();assert(call(7,'create',{mode='duel'}));step();assert(call(8,'watch'));step();assert(call(8,'join'));step()
sessions[7]={};game=step()
assert(game.game.status=='finished' and game.game.winner==2,'recycled identity retained seat')
assert(not call(7,'reset'),'new session controlled old seat')
assert(call(8,'finish'));step();assert(call(8,'create',{mode='practice'}));game=step()
assert(call(8,'shoot',{angle=0,power=.5}));result={[2]=false,[3]=false};game=step()
assert(game.phase=='ready' and game.game.scores[1]==2 and game.frames[2].balls[16][3],'two pockets cleared the whole fifteen-ball rack')
assert(call(8,'shoot',{angle=0,power=.5}));result=clearRack();game=step()
assert(game.phase=='rolling','clear did not preserve a smooth between-rack interval')
now=now+400;game=step();assert(game.phase=='ready' and game.game.scores[1]==15,'practice did not rerack/preserve stats')
assert(call(8,'reset'));game=step();assert(game.game.scores[1]==0)
-- Closed metadata rejects impossible nested identities/counts before playback.
local corrupt=G.New('duel',7);assert(G.Join(corrupt,8));corrupt.players[2]=7;assert(not G.Read(corrupt))
local challenge=G.New('challenge',7,{SOLO_SHOTS=1});G.Resolve(challenge,{true,true,true},{{alive=false},{alive=false},{alive=false}})
assert(challenge.status=='finished' and challenge.winner==0 and challenge.reason=='scratch','final scratch won challenge')
print('pool modes: lobby, identity/turn guards, scoring, scratch, reset consent/timeout, solo limits, wins, forfeit and rerack passed')
