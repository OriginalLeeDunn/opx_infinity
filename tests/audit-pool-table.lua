--- Real table menu rows, viewed revision, consent choices and ownership cleanup.
local M, opened, closed, sent = {}, nil, nil, nil
local menu={Open=function(spec)opened=spec;return{ok=true,value={handle=42}}end,Close=function(handle)closed=handle end}
local env=setmetatable({OPX={Modules={Get=function()return M end},Api={Get=function()return menu end},Note=function()end,Toast={Locale=function()end}},
 Open77={players={localId=function()return 7 end}},locale=function(key)return key end},{__index=_G})
for _,f in ipairs({'shared/model','shared/match','client/table'})do assert(loadfile('modules/pool/'..f..'.lua','t',env))()end
local G,T=M.Match,M.TableMenu
local glyphEnv={OPX={}};assert(loadfile('core/shared/glyphs.lua','t',glyphEnv))()
local state={epoch=4,revision=9,owner=0,phase='ready',game=G.New('practice')}
assert(T.Open(state,{label='Pool'},function(action,data,stamp)sent={action=action,data=data,stamp=stamp}end))
assert(#opened.items==3 and opened.items[1].data.mode=='practice' and opened.items[2].data.mode=='challenge' and opened.items[3].data.mode=='duel')
for _,row in ipairs(opened.items) do assert(glyphEnv.OPX.Glyphs[row.icon],'mode row has no supported icon') end
state.revision=10
opened.on({action='open',data=opened.items[3].data})
assert(sent==nil,'submenu navigation dispatched a command')
assert(opened.closeOnSelect==true and opened.items[3].close==nil,'mode row became a close-only item')
opened.on({action='select',data=opened.items[3].data})
assert(sent.action=='create' and sent.data.mode=='duel' and sent.stamp.revision==9,'menu action replaced viewed revision')
state.game=G.New('duel',8);local rows=T.Rows(state,7);assert(#rows==1 and rows[1].data.action=='join')
G.Join(state.game,7);state.game.resetBy=1
rows=T.Rows(state,7);assert(rows[1].icon=='refresh' and rows[1].data.action=='acceptReset' and rows[1].confirm==true,'opponent reset lacks explicit consent')
local foreign=T.Rows(state,9);assert(#foreign==1 and foreign[1].disabled and foreign[1].icon=='lock','spectator received reset controls')
state.game=G.New('practice',7);state.owner=7
assert(T.Open(state,{label='Pool'},function()end));T.Close();assert(closed==42,'table menu did not close its own handle')
print('pool menu: mode choices, join, stale viewed revision, reset consent and close ownership passed')
