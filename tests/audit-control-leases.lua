--- The three existing control owners and pool must compose in one resource VM.
local state, refusals, OPX = {}, {}, {}
local env = { OPX=OPX, Open77={players={}}, type=type, pairs=pairs, ipairs=ipairs, table=table, pcall=pcall }
for _,name in ipairs({'allowShoot','allowAim','allowInteraction','freezeRotation','freezePosition','allowWeapons','allowJump','allowDodge'}) do
	env.Open77.players[name]=function(value)
		if refusals[name] then return false end
		state[name]=value; return true
	end
end
assert(loadfile('lib/client/controls.lua','t',env))()
local C=OPX.Controls
assert(C.Set('police',{'allowShoot','allowAim','allowJump'},true))
assert(C.Set('pool',{'allowShoot','allowAim','freezeRotation'},true))
assert(C.Set('target',{'allowShoot','allowAim','freezeRotation','allowInteraction'},true))
assert(C.Set('target',{'allowShoot','allowAim','freezeRotation','allowInteraction'},false))
assert(state.allowShoot==false and state.allowAim==false and state.freezeRotation==true and state.allowInteraction==true)
assert(C.Set('pool',{'allowShoot','allowAim','freezeRotation'},false))
assert(state.allowShoot==false and state.allowAim==false and state.freezeRotation==false)
assert(C.Set('hauling',{'allowShoot','allowAim','allowJump','allowWeapons'},true))
assert(C.Set('police',{'allowShoot','allowAim','allowJump'},false))
assert(state.allowShoot==false and state.allowJump==false and state.allowWeapons==false)
assert(C.Set('hauling',{'allowShoot','allowAim','allowJump','allowWeapons'},false))
assert(state.allowShoot==true and state.allowJump==true and state.allowWeapons==true)
refusals.freezeRotation=true
assert(not C.Set('pool',{'allowShoot','freezeRotation'},true))
assert(state.allowShoot==true, 'partial claim did not roll back')
refusals.freezeRotation=nil
assert(C.Set('police',{'allowShoot'},true))
refusals.freezeRotation=true
assert(not C.Set('pool',{'allowShoot','freezeRotation'},true))
assert(state.allowShoot==false, 'failed claim released another owner')
assert(C.Set('cinema',{'freezePosition'},true))
assert(C.Set('pool',{'freezePosition'},true))
assert(C.Set('pool',{'freezePosition'},false) and state.freezePosition==true,'pool released another module freeze')
assert(C.Set('cinema',{'freezePosition'},false) and state.freezePosition==false)
print('control leases: target/pool/cuffs/carry ownership, partial refusal and rollback passed')
