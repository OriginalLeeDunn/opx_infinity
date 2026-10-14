// OPX Infinity -- the base game's own Sandevistan, for the ripperdoc's
// Sandevistans (opx_infinity, modules/ripperdoc/client/sandevistan.lua), on the
// player's own machine. opx_sandy_view 1.4.17.
//
// WHAT THE BASE GAME DOES. `SandevistanEvents.OnEnter` (2.31):
//
//   1. `SetCameraTimeDilationCurve(n"Sandevistan")` -- the camera samples the
//      clock through the Sandevistan's own curve;
//   2. `SetTimeDilationGlobal(n"sandevistan", <the implant's scale>, 999)`,
//      which for the reason `sandevistan` first calls
//      `SetIgnoreTimeDilationOnLocalPlayerZero(true)`: the WORLD slows -- NPCs,
//      traffic, physics, particles, sound -- and V does not;
//   3. the keyboard's `SlowMotion` lighting;
//   4. on exit, `UnsetTimeDilation(n"sandevistan", n"SandevistanEaseOut")`.
//
// WHO DOES WHAT HERE. A multiplayer session refuses every scripted dilation
// but one: a time-scale CLAIM (`Open77.world.setTimeScale`), which the platform
// writes on the global layer under the reason `open77:<resource>` and which
// stands the session's dilation guard down while it is live. The owner's own
// Sandevistan is claimed by THIS resource's client script (`opx_sandy_view`),
// so its reason -- `open77:opx_sandy_view` -- is the owner's alone: players
// slowed AROUND the owner run opx_infinity's claim and are not exempted.
//
// THE CLAIM'S VALUE SAYS WHAT IT IS. Below 0.99 it is a boost. From 0.99 to
// just under 1 it is a MESSAGE from this resource's client script -- a Lua
// resource has no other way to reach this script -- held for 600 ms at
// `0.999 - code / 10000` (the world 0.1 % slower for half a second): code 1
// asks for the Militech Apogee Sandevistan in the Operating System slot, 0 for
// none (codes 0-9 are the real item's); code 10 (1.4.9) asks for this machine's
// player's development maxed (see `OpxSandevistanDevelop`). A code is taken
// only when two samples in a row agree, so an ease can never be read as one.
//
// WHAT RUNS WHERE (1.4.0). Everything that has to happen on time runs on the
// game's delay system, in real time, one watch per body, each holding its own
// state (the engine attaches bodies on several worker threads at once, so
// nothing is shared between them -- 1.3.0 shared one list and crashed):
//
//   * the OWNER's watch (V): exempt from the world's dilation while the boost
//     holds (asserted every 100 ms), the keyboard lit, both handed back the
//     moment it ends; and the real item;
//   * the THIRD-PERSON MODEL's watch: Open77's self view draws V in third
//     person as a body of its own (`Character.Open77ProxyMaleMirror` /
//     `...FemaleMirror`, an NPCPuppet on V's TPP template, standing where V
//     stands, parked hidden on V in first person). For the boost it gets V's
//     exemption (an individual dilation of 1.0 that ignores the global one)
//     and, while the camera really stands behind it, Adam Smasher's own
//     Sandevistan played on it by the names its template authors:
//     `eye_glow_gold`. (Until 1.4.3 also his NPC Sandevistan's screen-space
//     echoes, `fx_sandevistan_left` / `_right` and `fx_sandevistan_versus_loop`:
//     they smear copies of the SCREEN around the body, which next to the real
//     ghost read as broken clones in the wrong place; 1.4.4 plays none of them
//     and only stops them, in case an older build started them.)
//
// The stamina machine's per-frame update still asserts V's exemption every
// frame it runs and asks for the camera curve -- the one thing only a player
// state machine can do -- but nothing depends on it running: in a session it
// does not run every frame (1.3.1's log showed it see a boost start and never
// see it end).
//
// THE REAL ITEM. Open77 has no API that installs a base-game operating system
// on a player (its equipment API answers `invalid_record` for the Apogee), so
// the owner's watch does it with the base game's own equipment system, the way
// Open77's own script bridge fits a weapon: the item is looked up in the
// inventory BY ITS RECORD (1.4.1 asked for `ItemID.FromTDBID(record)`, an id the
// inventory never holds -- a given item gets a seed of its own -- so the base
// game's `EquipRequest` gave a new Apogee on every try and fitted none, and the
// log said "not in the inventory"), given once if there is none, fitted with
// `OnGameplayEquipRequest` on that very id, and read back from the slot. It is
// checked once a second, fitted again if something took it off (five tries per
// request, then it says why not), and taken off and out of the inventory --
// every copy of that record -- when the ripperdoc says none. What was asked for
// survives a new body (quest fact `opx_sandy_wear`); what this file fitted is
// remembered too (`opx_sandy_fitted`). While it is fitted, the base game's own
// Sandevistan activation is off (`SandevistanDecisions.EnterCondition`): the
// key and the slowdown stay the ripperdoc's.
//
// SMASHER'S GHOST TRAIL -- ON THE PLAYER'S OWN MODEL (1.4.2). The afterimages
// Adam Smasher leaves when he dashes under his Sandevistan are his meshes drawn
// with the base game's `base\fx\_shaders\sandevistan_multilayer.mt`, switched
// on by `ch_smasher_sandevistan_high.effect`'s `customParameter0` tracks: the
// shader draws the copies BEHIND a body that moves, so the trail shows while
// the body runs, dashes or jumps, and a body that stands still covers its own
// ghost. This resource's archive (V's own body files, `t0_000_base__full.app`
// and its censored cut, with the parts added -- up to 1.4.7 an ArchiveXL patch
// of them) gives every player body the SAME shader on the player's OWN silhouette: parts of V's own third-person
// body (torso, legs, feet), arms and hands and base head (rigid on `Head`),
// each wearing the appearance `opx_sandy_ghost` (`opx_sandy_ghost.mi`: the
// shader with Smasher's armour layers) -- switched OFF -- and the effect
// spawner `opx_sandy_ghost_fx`, with a trigger that drives nothing
// (`opx_sandy_ghost_on`). Up to 1.4.5 one set of four parts
// (`opx_sandy_ghost_body`, `_arm_l`, `_arm_r`, `_head`); from 1.4.6 four
// layers of them (`opx_sandy_ghost1_*` .. `opx_sandy_ghost4_*`); from 1.4.9
// twelve (`opx_sandy_ghost1_*` .. `opx_sandy_ghost12_*`, 48 parts).
//
// 1.4.2, after 1.4.1 switched its parts on and drew nothing: the parts are
// V's own garment components (V's meshes are garment meshes), the material is
// the unmasked one every working copy of it outside Smasher's own files uses,
// and the effects are the archive's own: Smasher's peak held for 30 s without
// a loop (1.4.2 shipped a fade-in and a hold of it; 1.4.5 plays one held from
// its first frame, below). The effect starts AFTER the parts come on, a part
// that is already on is never switched again (1.4.1 switched every half
// second, which may rebuild what the effect drives). Every lighting says what
// the body really carries: how many parts, of what class
// (1.4.2's are `entGarmentSkinnedMeshComponent`; anything else is an old
// archive), how many the engine says are on, and whether the spawner is there.
//
//   * the owner's third-person model: its watch, while the camera stands
//     behind it (never in first person, where the parts would fill the view);
//   * every other client's copy of the boosted player -- every client the
//     boosted body is streamed to, i.e. everybody near it: opx_infinity's look
//     plays the trigger by name on that body for the whole boost; the body's
//     own callback below answers it with a watch of its own that switches the
//     parts on as soon as the body has them (a body still being dressed has
//     none yet), keeps its afterimages placed, and ends with the trigger.
//
// 1.4.3 (a test build) un-hid every part it switched on, every step --
// Open77's self view parks the third-person model with `TemporaryHide(true)`
// on every skinned mesh and lifts only what it hid, by name, so parts switched
// on afterwards could stay hidden -- and the ghost DREW: the player's
// screenshots showed its body (moved 1 m aside by a probe) beside V's, with
// the NPC Sandevistan's screen-space echoes smeared over the whole picture.
//
// 1.4.4 un-hid a part only for its first 0.6 s, dropped the probes and the NPC
// Sandevistan's screen-space echoes on the owner's model, and started the
// trail at 0.1 of Smasher's strength (the smallest of five): the player saw no
// ghost at all. The guess it tested -- that a body exempt from the world's
// slowdown reads too fast -- does not hold: the base game's own Sandevistan
// exempts V the same way (`SetIgnoreTimeDilationOnLocalPlayerZero(true)`),
// and ESDE plays Smasher's full (1.5, 1) on V's body in single player with the
// same shader, the same Smasher armour layers and the same kind of parts
// (garment components, switched off, no shadows).
//
// 1.4.5 was that setup, with each link that could have failed made robust --
// Smasher's full (1.5, 1), the effect held from its first frame to its last
// and started three times, the parts un-hidden every step -- and its log says
// every step ran (parts 4 of 4 on, the trail started at 0.3 s, 1 s and 2.6 s),
// and the player saw no trail: whatever breaks it, the shader's own copies do
// not show on this body.
//
// 1.4.6 therefore draws the afterimages itself: FOUR LAYERS of the ghost's
// parts (the archive's 16), each placed every frame where the body was 0.08,
// 0.16, 0.24 and 0.32 s before -- the path it really ran -- in this frame's
// pose, as Smasher's own copies are. What draws them is the part itself (the
// material's first pass), moved by its own placement and un-hidden every
// frame: 1.4.3's screenshots showed exactly that on screen (its body part,
// moved 1 m aside by `SetLocalPosition`, beside V). Smasher's effect is no
// longer played.
//
// 1.4.7: 1.4.6's afterimages were never placed -- its next-frame ticker ran
// twice in half a second and stopped ("2 frames in 0.58 s"), and not one
// layer was shown while the player sprinted 9 m/s. The ticker is now a 5 ms
// timed callback, the kind every watch in this file runs on, and the watch
// that lit the body places them too, every tenth of a second. The player
// confirmed the trail on their own third-person model.
//
// 1.4.8: a second player saw no trail -- not on the boosted player, not on
// their own model -- and their log said why: "0 of 16 parts (none), its
// effect spawner MISSING". Their game runs no ArchiveXL (RED4ext loaded one
// plugin, Open77), so the patch that gave player bodies the parts never ran
// there. The archive now carries V's two body files themselves, the base
// game's own with the parts added, which the game loads by their depot path
// with no plugin at all; the `.xl` is gone. Also:
//   * every other player's copy of the boosted body is exempt from this
//     machine's dilation for the boost (the same individual dilation the
//     owner's model gets), so a player slowed by the boost sees the owner at
//     full speed in a slowed world, as the owner sees themselves;
//   * the third-person model says, when it attaches, how many ghost parts
//     this game gives player bodies -- 16 of 16, or 0 and why;
//   * the afterimage lines read the farthest one's part back from the engine
//     (`GetLocalToWorld`), so "shown" is measured where the engine drew it.
//
// 1.4.9: Adam Smasher's trail, more aggressive, with way more clones: TWELVE
// layers (the archive's 48 parts, `opx_sandy_ghost1_*` .. `opx_sandy_ghost12_*`,
// every new layer an exact copy of the first four's parts) placed 0.045 s
// apart -- the farthest where the body was 0.54 s before -- and a layer shows
// once it is more than 0.2 m from the body (hidden again under 0.1 m, the
// same 0.1 m of hysteresis as before); the history is kept for the farthest
// one, and the model's readiness line expects all 48 parts (an older archive's
// 16 is said as such). How a layer is placed, shown, un-hidden and kept clear
// of the camera is unchanged. Also:
//   * boosts of up to 40 s (level-scaled) plus their ease, 45 s: the watch of
//     another player's boosted body gave up at 30 s ("the boost outlived its
//     ceiling": trail off, full speed off), and the individual dilation that
//     keeps the owner's model and a boosted body at full speed lapsed at 30 s
//     (set again within a tenth of a second). Both now last 60 s
//     (`OpxSandevistanBoostCeiling`); the owner's claim is the client
//     script's, capped at 45 s;
//   * code 10 of the clock message maxes the base game's own development on
//     this machine -- level, street cred, attributes, skills, perk and relic
//     points -- with the base game's own `PlayerDevelopmentData`, once per
//     request, remembered for the session (quest fact `opx_sandy_develop`)
//     and applied again on a new body (`OpxSandevistanDevelop`).
//
// 1.4.10: nothing in this script changed. The afterimages had no arms or
// hands: V's arm meshes read an external material from
// `preloadExternalMaterials` (they keep their own as
// `preloadLocalMaterialInstances`), and the archive listed the ghost's in
// `externalMaterials` -- fixed in the archive's four arm meshes. The
// package's second script, `OpxMaxTacAv.reds`, draws the MaxTac AV in its
// visible livery.
//
// 1.4.11: THE USER IS REALLY FASTER. The boost slowed the owner's world and
// kept V at real time, and the platform's reflex overdrive (the grant behind
// every ripperdoc Sandevistan) raises `MaxSpeed` by 1.25 or 1.55 -- so to
// everyone watching, a Sandevistan user ran barely faster than anybody else
// ("people using the sandevistan need a speed boost, one that is faster",
// 2026-09-28). While the boost holds, the owner's watch now puts one more
// multiplier on V's own `MaxSpeed` (`OpxSandevistanSpeedBoost`, x1.5 on top of
// the overdrive's), through the base game's stats system, and takes it off
// the moment the boost ends -- on V's own machine, so every player sees V
// cover the ground that much faster. The package's third script,
// `OpxQuests.reds`, makes the base game's missions playable.

// WHAT IT SAYS. Each change is one line in the Open77 client log, through the
// platform's REDscript trace (`Open77 pristine player bootstrap trace: ...`,
// written only when the text changes): `opx_sandy_view owner: ...`,
// `opx_sandy_view model: ...`, `opx_sandy_view real item: ...`,
// `opx_sandy_view ghost: ...`, `opx_sandy_view afterimages: ...` (how often
// they are placed, and how many show), `opx_sandy_view curve: ...` and
// `opx_sandy_view development: ...` (what the maximum changed, before -> after).

@wrapMethod(StaminaTransition)
protected final func OnUpdate(timeDelta: Float, stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
  wrappedMethod(timeDelta, stateContext, scriptInterface);
  OpxSandevistanView(stateContext, scriptInterface);
}

// Every NPC body that attaches: its own record, read once, and nothing else.
@wrapMethod(NPCPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  let record: TweakDBID = this.GetRecordID();
  if record == t"Character.Open77ProxyMaleMirror" || record == t"Character.Open77ProxyFemaleMirror" {
    OpxSandevistanModelWatch(this);
  };
  return result;
}

// The local player's body: the exemption a finished boost left behind is
// handed back, and the owner's watch starts.
@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  if !this.IsControlledByLocalPeer() {
    return result;
  };
  let time: ref<TimeSystem> = GameInstance.GetTimeSystem(this.GetGame());
  if IsDefined(time) && OpxSandevistanClaimScale(time) >= 0.99 && !time.IsTimeDilationActive(n"sandevistan") {
    time.SetIgnoreTimeDilationOnLocalPlayerZero(false);
  };
  OpxSandevistanOwnerWatch(this);
  return result;
}

// The base game's own activation, off while the ripperdoc's real item is
// fitted: the key and the slowdown are the ripperdoc's.
@wrapMethod(SandevistanDecisions)
protected final const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if GetFact(scriptInterface.GetGame(), n"opx_sandy_wear") != 0 {
    return false;
  };
  return wrappedMethod(stateContext, scriptInterface);
}

// The owner's claim as the engine holds it: 1.0 when there is none.
public static func OpxSandevistanClaimScale(time: ref<TimeSystem>) -> Float {
  if !IsDefined(time) || !time.IsTimeDilationActive(n"open77:opx_sandy_view") {
    return 1.0;
  };
  return time.GetActiveTimeDilation(n"open77:opx_sandy_view");
}

// The client script's message in the claim, or -1: `0.999 - code / 10000`.
public static func OpxSandevistanClaimCode(scale: Float) -> Int32 {
  if scale < 0.99 || scale >= 0.9995 {
    return -1;
  };
  let code: Int32 = RoundF((0.999 - scale) * 10000.0);
  if code < 0 || code > OpxSandevistanDevelopCode() {
    return -1;
  };
  if AbsF(scale - (0.999 - Cast<Float>(code) * 0.0001)) > 0.00003 {
    return -1;
  };
  // Only a code this file knows: the development maxed (10), none (0), or an
  // item it can fit (1-9).
  if code == OpxSandevistanDevelopCode() {
    return code;
  };
  if code != 0 && !TDBID.IsValid(OpxSandevistanWearRecord(code)) {
    return -1;
  };
  return code;
}

// The code that asks for this machine's player's development maxed (1.4.9):
// past the real item's 0-9, so the two never meet.
public static func OpxSandevistanDevelopCode() -> Int32 {
  return 10;
}

// Seconds past the longest boost: the ripperdoc runs a Sandevistan for up to
// 40 s (level-scaled), 45 s with its ease -- the owner's claim is capped there
// (client/main.lua, MAX_MS) -- and nothing below may end before it. The watch
// of another player's boosted body gives up here, and the individual dilation
// that keeps a body at full speed lasts this long (up to 1.4.8: 30 s, over a
// boost of at most 15.5 s).
public static func OpxSandevistanBoostCeiling() -> Float {
  return 60.0;
}

// The base-game item a code asks for.
public static func OpxSandevistanWearRecord(code: Int32) -> TweakDBID {
  if code == 1 {
    return t"Items.AdvancedSandevistanApogee";
  };
  return TDBID.None();
}

public static func OpxSandevistanWearName(code: Int32) -> String {
  if code == 1 {
    return "Items.AdvancedSandevistanApogee (Militech Apogee Sandevistan)";
  };
  return "none";
}

// ── V, every frame the stamina machine runs ────────────────────────────────

// The state bits kept in the state context: 1 boost, 2 lease live, 4 V
// exempted here, 16 the camera curve asked for (once per boost), 32 the
// camera took it.
public static func OpxSandevistanView(stateContext: ref<StateContext>, scriptInterface: ref<StateGameScriptInterface>) -> Void {
  if !IsDefined(stateContext) || !IsDefined(scriptInterface) {
    return;
  };
  let time: ref<TimeSystem> = scriptInterface.GetTimeSystem();
  if !IsDefined(time) {
    return;
  };
  let boost: Bool = OpxSandevistanClaimScale(time) < 0.99;
  let leased: Bool = time.IsTimeDilationActive(n"sandevistan");
  let before: Int32 = stateContext.GetIntParameter(n"opxSandevistanState", true);
  if !boost && !leased && before == 0 {
    return;
  };
  let exempt: Bool = (before & 4) != 0;
  let asked: Bool = (before & 16) != 0;
  let took: Bool = (before & 32) != 0;
  if boost {
    // Every frame, not once: vanilla's own clean-ups reset the flag.
    time.SetIgnoreTimeDilationOnLocalPlayerZero(true);
    exempt = true;
  } else {
    if exempt {
      time.SetIgnoreTimeDilationOnLocalPlayerZero(false);
      exempt = false;
    };
  };
  if boost || leased {
    if !asked {
      asked = true;
      took = scriptInterface.SetCameraTimeDilationCurve(n"Sandevistan");
      if took {
        Open77PlayerResetTrace("opx_sandy_view curve: the camera took the base game's Sandevistan curve");
      } else {
        Open77PlayerResetTrace("opx_sandy_view curve: the camera refused the base game's Sandevistan curve");
      };
    };
  } else {
    asked = false;
    took = false;
  };
  let after: Int32 = 0;
  if boost || leased {
    if boost { after += 1; };
    if leased { after += 2; };
    if exempt { after += 4; };
    if asked { after += 16; };
    if took { after += 32; };
  };
  if after != before {
    stateContext.SetPermanentIntParameter(n"opxSandevistanState", after, true);
  };
}

// ── the owner's watch ──────────────────────────────────────────────────────

// `state` bits: 1 boost, 2 V exempted, 4 the engine says V ignores the world's
// dilation, 8 the keyboard lit. `developIn`: seconds until the development is
// maxed on this body (below 0: nothing pending), `developTries` how often it
// found no development data yet, `developWhy` what the line says asked for it.
public class OpxSandevistanOwnerTick extends DelayCallback {
  public let player: wref<PlayerPuppet>;
  public let game: GameInstance;
  public let state: Int32;
  public let code: Int32;
  public let codeSeen: Int32;
  public let wearIn: Float;
  public let tries: Int32;
  public let triedFor: Int32;
  public let said: String;
  public let developIn: Float;
  public let developTries: Int32;
  public let developWhy: String;

  public func Call() -> Void {
    OpxSandevistanOwnerStep(this);
  }
}

public static func OpxSandevistanOwnerWatch(player: ref<PlayerPuppet>) -> Void {
  let tick: ref<OpxSandevistanOwnerTick> = new OpxSandevistanOwnerTick();
  tick.player = player;
  tick.game = player.GetGame();
  tick.code = -1;
  tick.triedFor = -1;
  tick.wearIn = 1.0;
  // A new body: the development maxed earlier this session (quest fact
  // `opx_sandy_develop`) is applied to it again, a second after it attaches.
  tick.developIn = 1.0;
  tick.developWhy = "again on a new body, as asked earlier this session";
  GameInstance.GetDelaySystem(tick.game).DelayCallback(tick, 0.25, false);
}

// 1.4.11: how much faster V runs while the boost holds, on top of the
// platform's own overdrive multiplier. The base game's stats system applies it
// (`gameStatModifierType.Multiplier` on `MaxSpeed`, the stat the platform's
// overdrive raises too).
public static func OpxSandevistanSpeedBoost() -> Float {
  return 1.5;
}

@addField(PlayerPuppet)
public let m_opxSandySpeed: ref<gameStatModifierData>;

// Puts the boost's speed on V, or takes it off. True when it changed.
public static func OpxSandevistanSpeed(player: ref<PlayerPuppet>, on: Bool) -> Bool {
  let stats: ref<StatsSystem> = GameInstance.GetStatsSystem(player.GetGame());
  if !IsDefined(stats) {
    return false;
  };
  let id: StatsObjectID = Cast<StatsObjectID>(player.GetEntityID());
  if on {
    if IsDefined(player.m_opxSandySpeed) {
      return false;
    };
    let speed: ref<gameStatModifierData> = RPGManager.CreateStatModifier(gamedataStatType.MaxSpeed,
      gameStatModifierType.Multiplier, OpxSandevistanSpeedBoost());
    if !stats.AddModifier(id, speed) {
      return false;
    };
    player.m_opxSandySpeed = speed;
    return true;
  };
  if !IsDefined(player.m_opxSandySpeed) {
    return false;
  };
  stats.RemoveModifier(id, player.m_opxSandySpeed);
  player.m_opxSandySpeed = null;
  return true;
}

public static func OpxSandevistanOwnerStep(tick: ref<OpxSandevistanOwnerTick>) -> Void {
  let player: ref<PlayerPuppet> = tick.player;
  // Gone, or detached: this watch ends here (an attach starts a new one).
  if !IsDefined(player) || !player.IsAttached() {
    return;
  };
  let time: ref<TimeSystem> = GameInstance.GetTimeSystem(tick.game);
  let scale: Float = OpxSandevistanClaimScale(time);
  let boost: Bool = scale < 0.99;
  let interval: Float = 0.25;
  let chroma: ref<RazerChromaEffectsSystem> = GameInstance.GetRazerChromaEffectsSystem(tick.game);
  let exempt: Bool = false;
  let lit: Bool = (tick.state & 8) != 0;
  if boost {
    interval = 0.10;
    time.SetIgnoreTimeDilationOnLocalPlayerZero(true);
    exempt = true;
    if !lit && IsDefined(chroma) {
      chroma.PlayAnimation(n"SlowMotion", true);
      lit = true;
    };
  } else {
    if (tick.state & 2) != 0 && IsDefined(time) {
      time.SetIgnoreTimeDilationOnLocalPlayerZero(false);
    };
    if lit {
      if IsDefined(chroma) {
        chroma.StopAnimation(n"SlowMotion");
      };
      lit = false;
    };
  };
  // 1.4.11: V's own speed, for as long as the boost holds -- and never past it.
  if OpxSandevistanSpeed(player, boost) {
    Open77PlayerResetTrace("opx_sandy_view owner: speed " + (boost ? "x" + FloatToStringPrec(OpxSandevistanSpeedBoost(), 2) + " on" : "back to normal")
      + " -- MaxSpeed " + FloatToStringPrec(GameInstance.GetStatsSystem(tick.game).GetStatValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatType.MaxSpeed), 2));
  };
  let ignoring: Bool = player.IsIgnoringGlobalTimeDilation() || player.IsIgnoringTimeDilation();
  let state: Int32 = 0;
  if boost {
    state += 1;
    if exempt { state += 2; };
    if ignoring { state += 4; };
    if lit { state += 8; };
  };
  if state != tick.state {
    let line: String;
    if state == 0 {
      line = "opx_sandy_view owner: the boost is over, V runs with the world again";
    } else {
      line = "opx_sandy_view owner: boost on, world " + FloatToStringPrec(scale, 2)
        + ", V exempted " + BoolToString(exempt)
        + ", engine says V ignores the world's dilation " + BoolToString(ignoring)
        + ", keyboard " + BoolToString(lit);
    };
    tick.state = state;
    Open77PlayerResetTrace(line);
  };
  // The client script's message: taken when two samples in a row agree.
  let code: Int32 = OpxSandevistanClaimCode(scale);
  if code >= 0 {
    if code == tick.code {
      tick.codeSeen += 1;
    } else {
      tick.code = code;
      tick.codeSeen = 1;
    };
    if tick.codeSeen == 2 && code == OpxSandevistanDevelopCode() {
      // The development maxed: once for this request, now, and remembered
      // for the session so that a new body gets it too.
      GameInstance.GetQuestsSystem(tick.game).SetFact(n"opx_sandy_develop", code);
      tick.developIn = 0.0;
      tick.developTries = 0;
      tick.developWhy = "asked for";
    };
    if tick.codeSeen == 2 && code != OpxSandevistanDevelopCode() && GetFact(tick.game, n"opx_sandy_wear") != code {
      GameInstance.GetQuestsSystem(tick.game).SetFact(n"opx_sandy_wear", code);
      tick.tries = 0;
      tick.wearIn = 0.0;
    };
  } else {
    tick.code = -1;
    tick.codeSeen = 0;
  };
  // The real item, once a second.
  tick.wearIn -= interval;
  if tick.wearIn <= 0.0 {
    tick.wearIn = 1.0;
    OpxSandevistanWear(tick, player);
  };
  // The development maxed, when due: once per request, and once per new body
  // while the session remembers it; a body with no development data yet is
  // asked again a second later, five times.
  if tick.developIn >= 0.0 {
    tick.developIn -= interval;
    if tick.developIn <= 0.0 {
      tick.developIn = -1.0;
      if GetFact(tick.game, n"opx_sandy_develop") == OpxSandevistanDevelopCode() {
        tick.developTries += 1;
        if !OpxSandevistanDevelop(player, tick.developWhy) {
          if tick.developTries < 5 {
            tick.developIn = 1.0;
          } else {
            Open77PlayerResetTrace("opx_sandy_view development: NOT maxed (" + tick.developWhy
              + ") -- the base game has no development data for this body after 5 tries");
          };
        };
      };
    };
  };
  let next: ref<OpxSandevistanOwnerTick> = new OpxSandevistanOwnerTick();
  next.player = tick.player;
  next.game = tick.game;
  next.state = tick.state;
  next.code = tick.code;
  next.codeSeen = tick.codeSeen;
  next.wearIn = tick.wearIn;
  next.tries = tick.tries;
  next.triedFor = tick.triedFor;
  next.said = tick.said;
  next.developIn = tick.developIn;
  next.developTries = tick.developTries;
  next.developWhy = tick.developWhy;
  GameInstance.GetDelaySystem(tick.game).DelayCallback(next, interval, false);
}

// One line per change of what the real item is doing.
public static func OpxSandevistanWearSay(tick: ref<OpxSandevistanOwnerTick>, line: String) -> Void {
  if NotEquals(line, tick.said) {
    tick.said = line;
    Open77PlayerResetTrace(line);
  };
}

public static func OpxSandevistanWear(tick: ref<OpxSandevistanOwnerTick>, player: ref<PlayerPuppet>) -> Void {
  let want: Int32 = GetFact(tick.game, n"opx_sandy_wear");
  let fitted: Int32 = GetFact(tick.game, n"opx_sandy_fitted");
  if want == 0 && fitted == 0 {
    return;
  };
  let data: ref<EquipmentSystemPlayerData> = EquipmentSystem.GetData(player);
  let transactions: ref<TransactionSystem> = GameInstance.GetTransactionSystem(tick.game);
  if !IsDefined(data) || !IsDefined(transactions) {
    OpxSandevistanWearSay(tick, "opx_sandy_view real item: the base game's equipment system is not ready yet");
    return;
  };
  let current: ItemID = data.GetActiveItem(gamedataEquipmentArea.SystemReplacementCW);
  let currentRecord: TweakDBID = ItemID.GetTDBID(current);
  let wanted: TweakDBID = OpxSandevistanWearRecord(want);
  if want != 0 && TDBID.IsValid(wanted) {
    if ItemID.IsValid(current) && currentRecord == wanted {
      if fitted != want {
        GameInstance.GetQuestsSystem(tick.game).SetFact(n"opx_sandy_fitted", want);
      };
      OpxSandevistanWearSay(tick, "opx_sandy_view real item: " + OpxSandevistanWearName(want)
        + " is fitted in the Operating System slot");
      return;
    };
    if tick.triedFor != want {
      tick.triedFor = want;
      tick.tries = 0;
    };
    // The one this file holds, looked up by its record: an id made from the
    // record is not the one the inventory holds (a given item gets its own
    // seed), which is why 1.4.1's `EquipRequest` gave a new one on every try.
    let item: ItemID = OpxSandevistanOwned(player, transactions, wanted);
    if tick.tries >= 5 {
      let level: Float = GameInstance.GetStatsSystem(tick.game).GetStatValue(Cast<StatsObjectID>(player.GetEntityID()), gamedataStatType.Level);
      let why: String = "not in the inventory: the base game gave none";
      if ItemID.IsValid(item) {
        let itemData: wref<gameItemData> = transactions.GetItemData(player, item);
        if IsDefined(itemData) {
          why = "the base game refused it: equippable " + BoolToString(data.IsEquippable(itemData))
            + ", item level " + FloatToStringPrec(itemData.GetStatValueByType(gamedataStatType.Level), 0)
            + ", V's level " + FloatToStringPrec(level, 0);
        };
      };
      OpxSandevistanWearSay(tick, "opx_sandy_view real item: " + OpxSandevistanWearName(want)
        + " is NOT fitted after 5 tries (" + why + ")");
      return;
    };
    tick.tries += 1;
    let gave: Bool = false;
    if !ItemID.IsValid(item) {
      gave = transactions.GiveItem(player, ItemID.FromTDBID(wanted), 1);
      item = OpxSandevistanOwned(player, transactions, wanted);
    };
    if !ItemID.IsValid(item) {
      OpxSandevistanWearSay(tick, "opx_sandy_view real item: the base game's inventory has no "
        + OpxSandevistanWearName(want) + " to fit (it answered the gift " + BoolToString(gave)
        + ", try " + IntToString(tick.tries) + ")");
      return;
    };
    // Fitted on that very id, now, the way Open77's own bridge fits a weapon.
    let request: ref<GameplayEquipRequest> = new GameplayEquipRequest();
    request.owner = player;
    request.itemID = item;
    request.slotIndex = 0;
    request.addToInventory = false;
    request.blockUpdateWeaponActiveSlots = true;
    request.forceEquipWeapon = false;
    data.OnGameplayEquipRequest(request);
    let now: ItemID = data.GetActiveItem(gamedataEquipmentArea.SystemReplacementCW);
    if ItemID.IsValid(now) && ItemID.GetTDBID(now) == wanted {
      GameInstance.GetQuestsSystem(tick.game).SetFact(n"opx_sandy_fitted", want);
      OpxSandevistanWearSay(tick, "opx_sandy_view real item: " + OpxSandevistanWearName(want)
        + " is fitted in the Operating System slot (try " + IntToString(tick.tries) + ")");
    } else {
      OpxSandevistanWearSay(tick, "opx_sandy_view real item: fitting " + OpxSandevistanWearName(want)
        + " in the Operating System slot (try " + IntToString(tick.tries) + ", " + (gave ? "given now" : "already in the inventory") + ")");
    };
    return;
  };
  // Nothing asked for: what this file fitted comes off, then out of the
  // inventory -- every copy of that record, and nothing else.
  let gone: TweakDBID = OpxSandevistanWearRecord(fitted);
  if !TDBID.IsValid(gone) {
    GameInstance.GetQuestsSystem(tick.game).SetFact(n"opx_sandy_fitted", 0);
    return;
  };
  if ItemID.IsValid(current) && currentRecord == gone {
    let unequip: ref<UnequipRequest> = new UnequipRequest();
    unequip.owner = player;
    unequip.areaType = gamedataEquipmentArea.SystemReplacementCW;
    unequip.slotIndex = 0;
    EquipmentSystem.GetInstance(player).QueueRequest(unequip);
    OpxSandevistanWearSay(tick, "opx_sandy_view real item: taking " + OpxSandevistanWearName(fitted)
      + " off -- the ripperdoc says this player holds none");
    return;
  };
  let copies: Int32 = OpxSandevistanOwnedCount(player, transactions, gone);
  if copies > 0 {
    transactions.RemoveItemByTDBID(player, gone, copies, true);
  };
  GameInstance.GetQuestsSystem(tick.game).SetFact(n"opx_sandy_fitted", 0);
  OpxSandevistanWearSay(tick, "opx_sandy_view real item: " + OpxSandevistanWearName(fitted)
    + " taken off and out of the inventory (" + IntToString(copies) + " cop" + (copies == 1 ? "y" : "ies") + ")");
}

// The first item of a record in V's inventory, or none.
public static func OpxSandevistanOwned(player: ref<PlayerPuppet>, transactions: ref<TransactionSystem>, record: TweakDBID) -> ItemID {
  let items: array<wref<gameItemData>>;
  if !transactions.GetItemList(player, items) {
    return ItemID.None();
  };
  let i: Int32 = 0;
  while i < ArraySize(items) {
    if IsDefined(items[i]) && ItemID.GetTDBID(items[i].GetID()) == record && items[i].GetQuantity() > 0 {
      return items[i].GetID();
    };
    i += 1;
  };
  return ItemID.None();
}

// How many items of a record V holds.
public static func OpxSandevistanOwnedCount(player: ref<PlayerPuppet>, transactions: ref<TransactionSystem>, record: TweakDBID) -> Int32 {
  let items: array<wref<gameItemData>>;
  if !transactions.GetItemList(player, items) {
    return 0;
  };
  let count: Int32 = 0;
  let i: Int32 = 0;
  while i < ArraySize(items) {
    if IsDefined(items[i]) && ItemID.GetTDBID(items[i].GetID()) == record {
      count += items[i].GetQuantity();
    };
    i += 1;
  };
  return count;
}

// ── the base game's development, maxed (1.4.9) ─────────────────────────────
//
// An admin's "max all levels" on the server also maxes the BASE GAME's own
// development on the admin's machine: the client script's `develop(10)` holds
// code 10 in the clock, and the owner's watch answers it here, with the base
// game's own `PlayerDevelopmentData` and the game's own maxima:
//
//   1. the five attributes (Body = `Strength`, Reflexes, Technical Ability,
//      Intelligence, Cool) to their record's cap (`BaseStats.<type>`, `Max()`:
//      20) -- first, since a skill tied to an attribute is capped by it and a
//      perk's tier asks for attribute points;
//   2. Level, Street Cred and the five skills (Solo, Shinobi, Engineer,
//      Netrunner, Headhunter) to their record's `maxLevel`
//      (`GetProficiencyAbsoluteMaxLevel`: 60, 50, 60), through `SetLevel` with
//      `isDebug` -- the level-ups' own points are not given, step 4 gives them;
//   3. the relic points to their maximum: the Espionage proficiency to its
//      `maxLevel` through `SetLevel` without `isDebug`, which is how the base
//      game's own relic terminals give them (each level one relic point);
//   4. perk points: as many as buying every perk of the five attribute trees
//      costs (`NewPerks.<attribute>AttributeData`, one point a level), less
//      the levels already bought and the points unspent.
//
// Nothing already at its maximum is touched, and one line says what changed,
// before -> after. Answers false when the body has no development data yet.
public static func OpxSandevistanDevelop(player: ref<PlayerPuppet>, why: String) -> Bool {
  if !IsDefined(player) {
    return false;
  };
  let data: ref<PlayerDevelopmentData> = PlayerDevelopmentSystem.GetData(player);
  if !IsDefined(data) {
    return false;
  };
  let changed: String = "";
  // 1. The attributes.
  let attributes: array<gamedataStatType> = [gamedataStatType.Strength, gamedataStatType.Reflexes,
    gamedataStatType.TechnicalAbility, gamedataStatType.Intelligence, gamedataStatType.Cool];
  let attributeNames: array<String> = ["body", "reflexes", "technical ability", "intelligence", "cool"];
  let i: Int32 = 0;
  while i < ArraySize(attributes) {
    let most: Float = 20.0;
    let record: ref<Stat_Record> = data.GetAttributeRecord(attributes[i]);
    if IsDefined(record) && record.Max() > 0.0 {
      most = record.Max();
    };
    let before: Float = data.GetAttributeValue(attributes[i]);
    if before < most {
      data.SetAttribute(attributes[i], most);
      changed += OpxSandevistanDevelopSaid(attributeNames[i], RoundF(before), RoundF(data.GetAttributeValue(attributes[i])));
    };
    i += 1;
  };
  // 2. Level, Street Cred and the skills.
  let levels: array<gamedataProficiencyType> = [gamedataProficiencyType.Level, gamedataProficiencyType.StreetCred,
    gamedataProficiencyType.StrengthSkill, gamedataProficiencyType.ReflexesSkill,
    gamedataProficiencyType.TechnicalAbilitySkill, gamedataProficiencyType.IntelligenceSkill,
    gamedataProficiencyType.CoolSkill];
  let levelNames: array<String> = ["level", "street cred", "solo", "shinobi", "engineer", "netrunner", "headhunter"];
  i = 0;
  while i < ArraySize(levels) {
    let level: Int32 = data.GetProficiencyLevel(levels[i]);
    let top: Int32 = data.GetProficiencyAbsoluteMaxLevel(levels[i]);
    if level >= 0 && level < top {
      data.SetLevel(levels[i], top, telemetryLevelGainReason.IsDebug, true);
      changed += OpxSandevistanDevelopSaid(levelNames[i], level, data.GetProficiencyLevel(levels[i]));
    };
    i += 1;
  };
  // 3. The relic points.
  let relic: Int32 = data.GetProficiencyLevel(gamedataProficiencyType.Espionage);
  let relicTop: Int32 = data.GetProficiencyAbsoluteMaxLevel(gamedataProficiencyType.Espionage);
  if relic >= 0 && relic < relicTop {
    let relicPoints: Int32 = data.GetDevPoints(gamedataDevelopmentPointType.Espionage);
    data.SetLevel(gamedataProficiencyType.Espionage, relicTop, telemetryLevelGainReason.IsDebug, false);
    changed += OpxSandevistanDevelopSaid("relic points", relicPoints, data.GetDevPoints(gamedataDevelopmentPointType.Espionage))
      + " (relic level " + IntToString(relic) + " -> " + IntToString(data.GetProficiencyLevel(gamedataProficiencyType.Espionage)) + ")";
  };
  // 4. The perk points.
  let trees: array<gamedataAttributeDataType> = [gamedataAttributeDataType.BodyAttributeData,
    gamedataAttributeDataType.ReflexesAttributeData, gamedataAttributeDataType.TechnicalAbilityAttributeData,
    gamedataAttributeDataType.IntelligenceAttributeData, gamedataAttributeDataType.CoolAttributeData];
  let perks: array<wref<NewPerk_Record>>;
  let cost: Int32 = 0;
  let bought: Int32 = 0;
  i = 0;
  while i < ArraySize(trees) {
    let tree: ref<AttributeData_Record> = RPGManager.GetAttributeDataRecord(trees[i]);
    if IsDefined(tree) {
      ArrayClear(perks);
      tree.Perks(perks);
      let j: Int32 = 0;
      while j < ArraySize(perks) {
        if IsDefined(perks[j]) {
          cost += perks[j].GetLevelsCount();
          bought += data.IsNewPerkBought(perks[j].Type());
        };
        j += 1;
      };
    };
    i += 1;
  };
  let perkPoints: Int32 = data.GetDevPoints(gamedataDevelopmentPointType.Primary);
  if cost - bought > perkPoints {
    data.AddDevelopmentPoints(cost - bought - perkPoints, gamedataDevelopmentPointType.Primary);
    changed += OpxSandevistanDevelopSaid("perk points", perkPoints, data.GetDevPoints(gamedataDevelopmentPointType.Primary))
      + " (every perk: " + IntToString(cost) + ", " + IntToString(bought) + " bought)";
  };
  if StrLen(changed) == 0 {
    Open77PlayerResetTrace("opx_sandy_view development: maxed on this machine (" + why
      + ") -- nothing changed, already at every maximum");
  } else {
    Open77PlayerResetTrace("opx_sandy_view development: maxed on this machine (" + why + ") -- "
      + StrRight(changed, StrLen(changed) - 2));
  };
  return true;
}

// One change of the development line: ", name before -> after".
public static func OpxSandevistanDevelopSaid(name: String, before: Int32, after: Int32) -> String {
  return ", " + name + " " + IntToString(before) + " -> " + IntToString(after);
}

// ── the third-person model's watch ─────────────────────────────────────────

// `state` bits: 1 the boost is on, 2 the body stands on V, 4 the camera stands
// behind it, 8 the engine says it ignores the world's dilation, 16 Smasher's
// look on it, 32 his ghost trail on it.
public class OpxSandevistanModelTick extends DelayCallback {
  public let body: wref<NPCPuppet>;
  public let game: GameInstance;
  public let state: Int32;
  public let ghost: Int32;
  public let startLeft: Float;
  public let started: Bool;
  public let exempted: Bool;
  public let lit: Bool;
  public let third: Bool;
  // This lighting's ghost: when its parts came on and how far its effects got.
  public let run: ref<OpxSandyGhostRun>;
  // Steps left to find the ghost's parts on this body (said once; see
  // `OpxSandyGhostReadyStep`).
  public let checks: Int32;

  public func Call() -> Void {
    OpxSandevistanModelStep(this);
  }
}

public static func OpxSandevistanModelWatch(body: ref<NPCPuppet>) -> Void {
  let tick: ref<OpxSandevistanModelTick> = new OpxSandevistanModelTick();
  tick.body = body;
  tick.game = body.GetGame();
  tick.checks = 20;
  GameInstance.GetDelaySystem(tick.game).DelayCallback(tick, 0.25, false);
}

public static func OpxSandevistanModelStep(tick: ref<OpxSandevistanModelTick>) -> Void {
  let body: ref<NPCPuppet> = tick.body;
  // Gone, or detached: this watch ends here (an attach starts a new one).
  if !IsDefined(body) || !body.IsAttached() {
    return;
  };
  if tick.checks > 0 {
    tick.checks = OpxSandyGhostReadyStep(body, tick.checks);
  };
  let time: ref<TimeSystem> = GameInstance.GetTimeSystem(tick.game);
  let claimed: Bool = OpxSandevistanClaimScale(time) < 0.99;
  let interval: Float = 0.25;
  let onV: Bool = false;
  let ignoring: Bool = false;
  if claimed {
    interval = 0.10;
    if (tick.state & 1) == 0 {
      tick.startLeft = 3.0;
      tick.started = false;
    };
    // The same exemption V has, asserted again whenever the engine no
    // longer holds it, and long enough for the longest boost (up to 1.4.8 it
    // lapsed after 30 s).
    if !body.HasIndividualTimeDilation(n"opx_sandy_view") {
      body.SetIndividualTimeDilation(n"opx_sandy_view", 1.0, OpxSandevistanBoostCeiling(), n"None", n"None", true, true);
    };
    tick.exempted = true;
    ignoring = body.IsIgnoringGlobalTimeDilation();
    let player: ref<PlayerPuppet> = GetPlayer(tick.game);
    if IsDefined(player) {
      // Lit only on V (0.6 m), and kept lit within 3 m: a dash or a sprint
      // puts the model a step behind V for a frame, and the trail is at its
      // best exactly then -- it must not go out and start again.
      onV = OpxSandevistanStandsOnV(player.GetWorldPosition(), body.GetWorldPosition(), tick.lit ? 3.0 : 0.6);
      tick.third = OpxSandevistanCameraBehind(player, tick.third);
    };
    if tick.third && onV {
      if !tick.lit {
        GameObjectEffectHelper.StartEffectEvent(body, n"eye_glow_gold");
        tick.run = OpxSandyGhostLight(body, "the owner's third-person model");
        tick.lit = true;
      };
      // The ghost: its parts kept on and its effects started in order, every
      // step (see `OpxSandyGhostDrive`).
      tick.ghost = OpxSandyGhostDrive(body, tick.run, interval, "the owner's third-person model");
    } else {
      // First person again: off at once (its eyes would glow in the camera,
      // and the ghost's parts stand where the camera is).
      if tick.lit {
        OpxSandevistanModelUnlight(body);
        tick.lit = false;
        tick.ghost = 0;
        tick.run = null;
      };
    };
    if tick.startLeft > 0.0 {
      tick.startLeft -= interval;
      if tick.startLeft <= 0.0 && tick.started {
        GameObjectEffectHelper.StopEffectEvent(body, n"fx_sandevistan_left");
        GameObjectEffectHelper.StopEffectEvent(body, n"fx_sandevistan_right");
      };
    };
  } else {
    if tick.lit || tick.started {
      OpxSandevistanModelUnlight(body);
    };
    if tick.exempted {
      body.UnsetIndividualTimeDilation();
    };
    tick.lit = false;
    tick.ghost = 0;
    tick.run = null;
    tick.started = false;
    tick.exempted = false;
    tick.startLeft = 0.0;
  };
  let state: Int32 = 0;
  if claimed {
    state += 1;
    if onV { state += 2; };
    if tick.third { state += 4; };
    if ignoring { state += 8; };
    if tick.lit { state += 16; };
    if tick.ghost > 0 { state += 32; };
  };
  if state != tick.state {
    let line: String;
    if state == 0 {
      line = "opx_sandy_view model: the boost is over, the third-person model runs with the world again";
    } else {
      line = "opx_sandy_view model: third-person model on V " + BoolToString(onV)
        + ", camera behind it " + BoolToString(tick.third)
        + ", exempt from the world's dilation " + BoolToString(ignoring)
        + ", Smasher's look on it " + BoolToString(tick.lit)
        + ", his ghost trail " + IntToString(tick.ghost) + " of " + IntToString(OpxSandyGhostCount()) + " parts";
    };
    tick.state = state;
    Open77PlayerResetTrace(line);
  };
  let next: ref<OpxSandevistanModelTick> = new OpxSandevistanModelTick();
  next.body = tick.body;
  next.game = tick.game;
  next.state = tick.state;
  next.startLeft = tick.startLeft;
  next.started = tick.started;
  next.exempted = tick.exempted;
  next.lit = tick.lit;
  next.ghost = tick.ghost;
  next.third = tick.third;
  next.run = tick.run;
  next.checks = tick.checks;
  GameInstance.GetDelaySystem(tick.game).DelayCallback(next, interval, false);
}

// Whether this game gives player bodies the ghost's parts, said once per
// third-person model: as soon as ALL of them are there (all 48: they come with
// the body's appearance, so on its first steps), or -- five seconds of steps
// without all of them -- how many it has and why that can be (an older
// archive's copy of V's body has 16: only its layers can show). Answers the
// checks left (0: said).
public static func OpxSandyGhostReadyStep(body: ref<NPCPuppet>, checks: Int32) -> Int32 {
  let found: Int32 = body.OpxSandyGhostFound();
  let expected: Int32 = OpxSandyGhostCount();
  if found >= expected {
    Open77PlayerResetTrace("opx_sandy_view ghost: this game gives player bodies the ghost trail's parts -- the third-person model has "
      + IntToString(found) + " of " + IntToString(expected) + " (opx_sandy_ghost.archive's copy of V's body)");
    return 0;
  };
  if checks <= 1 {
    if found > 0 {
      Open77PlayerResetTrace("opx_sandy_view ghost: the third-person model has only " + IntToString(found) + " of "
        + IntToString(expected) + " ghost parts -- this game loads an OLDER opx_sandy_ghost.archive's copy of V's body (1.4.6-1.4.8's had 16): only the layers it has will show");
    } else {
      Open77PlayerResetTrace("opx_sandy_view ghost: the third-person model has 0 of " + IntToString(expected)
        + " ghost parts -- this game does not load opx_sandy_ghost.archive's copy of V's body (not installed, or another archive's copy of t0_000_base__full.app comes first): no ghost trail on this machine");
    };
    return 0;
  };
  return checks - 1;
}

public static func OpxSandevistanModelUnlight(body: ref<NPCPuppet>) -> Void {
  OpxSandyGhostOff(body);
  GameObjectEffectHelper.StopEffectEvent(body, n"fx_sandevistan_versus_loop");
  GameObjectEffectHelper.StopEffectEvent(body, n"eye_glow_gold");
  GameObjectEffectHelper.StopEffectEvent(body, n"fx_sandevistan_left");
  GameObjectEffectHelper.StopEffectEvent(body, n"fx_sandevistan_right");
}

// A body standing on V: within `across` metres of V's feet across, and at
// V's height.
public static func OpxSandevistanStandsOnV(feet: Vector4, position: Vector4, across: Float) -> Bool {
  let dx: Float = position.X - feet.X;
  let dy: Float = position.Y - feet.Y;
  let dz: Float = position.Z - feet.Z;
  return dx * dx + dy * dy <= across * across && dz >= -1.0 && dz <= 1.0;
}

// Whether the camera stands off V's body: its distance to the upright line
// through V's feet, with hysteresis so an arm shortened by a wall does not
// flicker the look.
public static func OpxSandevistanCameraBehind(player: ref<PlayerPuppet>, was: Bool) -> Bool {
  let camera: Transform;
  let cameras: ref<CameraSystem> = GameInstance.GetCameraSystem(player.GetGame());
  if !IsDefined(cameras) || !cameras.GetActiveCameraWorldTransform(camera) {
    return was;
  };
  let eye: Vector4 = Transform.GetPosition(camera);
  let feet: Vector4 = player.GetWorldPosition();
  let dx: Float = eye.X - feet.X;
  let dy: Float = eye.Y - feet.Y;
  let dz: Float = eye.Z - feet.Z;
  let beyond: Float = 0.0;
  if dz < 0.0 {
    beyond = -dz;
  } else {
    if dz > 2.1 {
      beyond = dz - 2.1;
    };
  };
  let away: Float = SqrtF(dx * dx + dy * dy + beyond * beyond);
  if was {
    return away > 0.45;
  };
  return away > 0.75;
}

// ── Smasher's ghost trail, on the player's own model ───────────────────────
//
// TWELVE AFTERIMAGES (1.4.9; 1.4.6-1.4.8: four, 0.08 s apart, shown from
// 0.35 m), placed by this file every frame (a 5 ms ticker of the delay system,
// `OpxSandyTrailTicker`). The archive gives every player body twelve layers of
// the ghost -- `opx_sandy_ghost1_body` / `_arm_l` / `_arm_r` / `_head` up to
// `opx_sandy_ghost12_*`, V's own body, arms and head in Smasher's Sandevistan
// look, all switched off. A lit body keeps a short history of where it stood
// (its world position and turn, every frame), and layer k is placed where the
// body was k x 0.045 s before (the farthest, 0.54 s) -- its parts moved there
// by their own placement (`SetLocalPosition` / `SetLocalOrientation`, relative
// to the body), each in the body's pose of this frame, as Smasher's own copies
// are. A layer shows once it is more than 0.2 m from the body (hidden again
// under 0.1 m), so a body that stands still has none and a sprint leaves
// twelve, about 0.4 m apart, along the path it really ran.

// How many layers the archive gives a body (build.py's and merge.py's LAYERS).
public static func OpxSandyTrailLayers() -> Int32 {
  return 12;
}

// Seconds between one afterimage and the next.
public static func OpxSandyTrailSpacing() -> Float {
  return 0.045;
}

// Metres from the body at which a layer shows, and back under which it hides
// (the same 0.1 m of hysteresis 1.4.6-1.4.8 had, at 0.35 / 0.25 m).
public static func OpxSandyTrailShowAt() -> Float {
  return 0.2;
}

public static func OpxSandyTrailHideAt() -> Float {
  return 0.1;
}

// No afterimage stands closer than this to the camera (its middle, a metre
// above its feet): the third-person camera trails the body within the reach
// of the farther afterimages, and a body drawn inside the lens fills the screen.
public static func OpxSandyTrailClearOfCamera() -> Float {
  return 0.9;
}

// Layer `layer`'s four parts (1 = the nearest afterimage, 12 the farthest).
public static func OpxSandyLayerParts(layer: Int32) -> array<CName> {
  if layer <= 1 {
    return [n"opx_sandy_ghost1_body", n"opx_sandy_ghost1_arm_l", n"opx_sandy_ghost1_arm_r", n"opx_sandy_ghost1_head"];
  };
  if layer == 2 {
    return [n"opx_sandy_ghost2_body", n"opx_sandy_ghost2_arm_l", n"opx_sandy_ghost2_arm_r", n"opx_sandy_ghost2_head"];
  };
  if layer == 3 {
    return [n"opx_sandy_ghost3_body", n"opx_sandy_ghost3_arm_l", n"opx_sandy_ghost3_arm_r", n"opx_sandy_ghost3_head"];
  };
  if layer == 4 {
    return [n"opx_sandy_ghost4_body", n"opx_sandy_ghost4_arm_l", n"opx_sandy_ghost4_arm_r", n"opx_sandy_ghost4_head"];
  };
  if layer == 5 {
    return [n"opx_sandy_ghost5_body", n"opx_sandy_ghost5_arm_l", n"opx_sandy_ghost5_arm_r", n"opx_sandy_ghost5_head"];
  };
  if layer == 6 {
    return [n"opx_sandy_ghost6_body", n"opx_sandy_ghost6_arm_l", n"opx_sandy_ghost6_arm_r", n"opx_sandy_ghost6_head"];
  };
  if layer == 7 {
    return [n"opx_sandy_ghost7_body", n"opx_sandy_ghost7_arm_l", n"opx_sandy_ghost7_arm_r", n"opx_sandy_ghost7_head"];
  };
  if layer == 8 {
    return [n"opx_sandy_ghost8_body", n"opx_sandy_ghost8_arm_l", n"opx_sandy_ghost8_arm_r", n"opx_sandy_ghost8_head"];
  };
  if layer == 9 {
    return [n"opx_sandy_ghost9_body", n"opx_sandy_ghost9_arm_l", n"opx_sandy_ghost9_arm_r", n"opx_sandy_ghost9_head"];
  };
  if layer == 10 {
    return [n"opx_sandy_ghost10_body", n"opx_sandy_ghost10_arm_l", n"opx_sandy_ghost10_arm_r", n"opx_sandy_ghost10_head"];
  };
  if layer == 11 {
    return [n"opx_sandy_ghost11_body", n"opx_sandy_ghost11_arm_l", n"opx_sandy_ghost11_arm_r", n"opx_sandy_ghost11_head"];
  };
  return [n"opx_sandy_ghost12_body", n"opx_sandy_ghost12_arm_l", n"opx_sandy_ghost12_arm_r", n"opx_sandy_ghost12_head"];
}

// Every part of every layer.
public static func OpxSandyGhostParts() -> array<CName> {
  let parts: array<CName>;
  let layer: Int32 = 1;
  while layer <= OpxSandyTrailLayers() {
    let some: array<CName> = OpxSandyLayerParts(layer);
    let i: Int32 = 0;
    while i < ArraySize(some) {
      ArrayPush(parts, some[i]);
      i += 1;
    };
    layer += 1;
  };
  return parts;
}

public static func OpxSandyGhostCount() -> Int32 {
  let parts: array<CName> = OpxSandyGhostParts();
  return ArraySize(parts);
}

// Switches every part on or off on any body the archive dressed -- the owner's
// third-person model or another client's copy of a boosted player; answers how
// many parts the body has (0: this game does not load the archive's copy of V's
// body, or the body is not a player's). A part already as asked is left alone.
@addMethod(GameObject)
public final func OpxSandyGhostSet(on: Bool) -> Int32 {
  return this.OpxSandyPartsSet(OpxSandyGhostParts(), on, false);
}

// The same for any list of the archive's parts. `unhide`: a part switched on is
// also un-hidden (`TemporaryHide(false)`) by this call.
@addMethod(GameObject)
public final func OpxSandyPartsSet(parts: array<CName>, on: Bool, unhide: Bool) -> Int32 {
  let found: Int32 = 0;
  let i: Int32 = 0;
  while i < ArraySize(parts) {
    let component: ref<IComponent> = this.FindComponentByName(parts[i]);
    if IsDefined(component) {
      if NotEquals(component.IsEnabled(), on) {
        component.Toggle(on);
      };
      if on && unhide {
        let visual: ref<IVisualComponent> = component as IVisualComponent;
        if IsDefined(visual) {
          visual.TemporaryHide(false);
        };
      };
      found += 1;
    };
    i += 1;
  };
  return found;
}

// One layer, this frame: shown where it belongs, or hidden inside the body.
// Shown = moved (position and turn relative to the body), switched on if
// something switched it off, and UN-HIDDEN, every frame: Open77 hides every
// skinned mesh of a body while it dresses it (every player's body) or parks it
// (the owner's third-person model) and lifts only its own record, and 1.4.3's
// parts drew only once un-hidden. Hidden = moved back onto the body and hidden
// (`TemporaryHide(true)`), switched on all the same, so the next frame that
// wants it has nothing to build.
@addMethod(GameObject)
public final func OpxSandyLayerPlace(layer: Int32, show: Bool, placed: Vector4, turned: Quaternion) -> Int32 {
  let parts: array<CName> = OpxSandyLayerParts(layer);
  let found: Int32 = 0;
  let i: Int32 = 0;
  while i < ArraySize(parts) {
    let visual: ref<IVisualComponent> = this.FindComponentByName(parts[i]) as IVisualComponent;
    if IsDefined(visual) {
      found += 1;
      if show {
        visual.SetLocalPosition(placed);
        visual.SetLocalOrientation(turned);
        if !visual.IsEnabled() {
          visual.Toggle(true);
        };
        visual.TemporaryHide(false);
      } else {
        visual.SetLocalPosition(new Vector4(0.0, 0.0, 0.0, 1.0));
        visual.SetLocalOrientation(new Quaternion(0.0, 0.0, 0.0, 1.0));
        visual.TemporaryHide(true);
      };
    };
    i += 1;
  };
  return found;
}

// Where the engine really placed layer `layer` (its body part), in metres from
// the body: its component's own world transform, read back. -1 without it.
@addMethod(GameObject)
public final func OpxSandyLayerReadBack(layer: Int32) -> Float {
  let parts: array<CName> = OpxSandyLayerParts(layer);
  let visual: ref<IVisualComponent> = this.FindComponentByName(parts[0]) as IVisualComponent;
  if !IsDefined(visual) {
    return -1.0;
  };
  let away: Vector4 = Matrix.GetTranslation(visual.GetLocalToWorld()) - this.GetWorldPosition();
  away.W = 0.0;
  return Vector4.Length(away);
}

// How many parts the body has, touching none.
@addMethod(GameObject)
public final func OpxSandyGhostFound() -> Int32 {
  let parts: array<CName> = OpxSandyGhostParts();
  let found: Int32 = 0;
  let i: Int32 = 0;
  while i < ArraySize(parts) {
    if IsDefined(this.FindComponentByName(parts[i])) {
      found += 1;
    };
    i += 1;
  };
  return found;
}

// What the archive really put on this body, in one line: how many parts, of
// what class (V's own garments, `entGarmentSkinnedMeshComponent`; any other
// class is an older archive), how many the engine says are on, and whether the
// effect spawner came with them.
@addMethod(GameObject)
public final func OpxSandyGhostWhat() -> String {
  let parts: array<CName> = OpxSandyGhostParts();
  let found: Int32 = 0;
  let lit: Int32 = 0;
  let kind: String = "none";
  let i: Int32 = 0;
  while i < ArraySize(parts) {
    let component: ref<IComponent> = this.FindComponentByName(parts[i]);
    if IsDefined(component) {
      found += 1;
      if component.IsEnabled() {
        lit += 1;
      };
      kind = NameToString(component.GetClassName());
    };
    i += 1;
  };
  let spawner: ref<IComponent> = this.FindComponentByName(n"opx_sandy_ghost_fx");
  return IntToString(found) + " of " + IntToString(ArraySize(parts)) + " parts (" + kind + "), "
    + IntToString(lit) + " switched on, its effect spawner " + (IsDefined(spawner) ? "there" : "MISSING");
}

// ── The afterimages' history, kept every frame ─────────────────────────────

// One lit body's afterimages: where it stood, frame by frame, for as long as
// the farthest afterimage needs and a quarter second more (12 x 0.045 s +
// 0.25 s: about 0.8 s), and which layers show.
public class OpxSandyTrail extends IScriptable {
  public let body: wref<GameObject>;
  public let id: EntityID;
  public let who: String;
  public let times: array<Float>;
  public let places: array<Vector4>;
  public let turns: array<Quaternion>;
  public let shown: array<Bool>;
  public let showing: Int32;
  public let saidShowing: Int32;
  public let saidAt: Float;
  public let saidRate: Int32;
  public let frames: Int32;
  public let since: Float;
}

// Every lit body's afterimages, on the local player, and the ticker that
// places them: a TIMED callback of the delay system, 5 ms and not slowed by
// the world's dilation (so it comes back on the next frame), which schedules
// the next one for as long as any body is kept -- the same kind of timer every
// watch in this file runs on. (The stamina machine's update does not run every
// frame in a session -- 1.3.1's log saw a boost start and never end -- and
// 1.4.6's next-frame callback ran twice in half a second and stopped: its log
// says "2 frames in 0.58 s", and no afterimage was ever placed.) The watch
// that lit the body also places them itself, every tenth of a second, in case
// the ticker stops.
@addField(PlayerPuppet)
public let opxSandyTrails: array<ref<OpxSandyTrail>>;

@addField(PlayerPuppet)
public let opxSandyTrailClock: Float;

@addField(PlayerPuppet)
public let opxSandyTrailTicking: Bool;

@addField(PlayerPuppet)
public let opxSandyTrailStarted: Float;

public class OpxSandyTrailTicker extends DelayCallback {
  public let player: wref<PlayerPuppet>;

  public func Call() -> Void {
    let player: ref<PlayerPuppet> = this.player;
    if !IsDefined(player) {
      return;
    };
    OpxSandyTrailFrame(player);
    if ArraySize(player.opxSandyTrails) > 0 {
      let next: ref<OpxSandyTrailTicker> = new OpxSandyTrailTicker();
      next.player = player;
      GameInstance.GetDelaySystem(player.GetGame()).DelayCallback(next, 0.005, false);
    } else {
      player.opxSandyTrailTicking = false;
    };
  }
}

// The ticker running: started when it is not, and started again when neither
// a frame it placed nor its own start is within the last half second (a
// ticker the game dropped).
public static func OpxSandyTrailTick(player: ref<PlayerPuppet>) -> Void {
  let now: Float = EngineTime.ToFloat(GameInstance.GetEngineTime(player.GetGame()));
  if player.opxSandyTrailTicking && (now - player.opxSandyTrailClock < 0.5 || now - player.opxSandyTrailStarted < 0.5) {
    return;
  };
  player.opxSandyTrailTicking = true;
  player.opxSandyTrailStarted = now;
  let ticker: ref<OpxSandyTrailTicker> = new OpxSandyTrailTicker();
  ticker.player = player;
  GameInstance.GetDelaySystem(player.GetGame()).DelayCallback(ticker, 0.005, false);
}

// Starts keeping a body's afterimages (a body already kept is left alone).
public static func OpxSandyTrailOn(body: ref<GameObject>, who: String) -> Void {
  let player: ref<PlayerPuppet> = GetPlayer(body.GetGame());
  if !IsDefined(player) {
    return;
  };
  let id: EntityID = body.GetEntityID();
  let i: Int32 = 0;
  while i < ArraySize(player.opxSandyTrails) {
    if Equals(player.opxSandyTrails[i].id, id) {
      OpxSandyTrailTick(player);
      return;
    };
    i += 1;
  };
  let trail: ref<OpxSandyTrail> = new OpxSandyTrail();
  trail.body = body;
  trail.id = id;
  trail.who = who;
  trail.saidShowing = -1;
  let layer: Int32 = 0;
  while layer < OpxSandyTrailLayers() {
    ArrayPush(trail.shown, false);
    layer += 1;
  };
  ArrayPush(player.opxSandyTrails, trail);
  OpxSandyTrailTick(player);
}

// Stops keeping a body's afterimages.
public static func OpxSandyTrailOff(body: ref<GameObject>) -> Void {
  let player: ref<PlayerPuppet> = GetPlayer(body.GetGame());
  if !IsDefined(player) {
    return;
  };
  let id: EntityID = body.GetEntityID();
  let i: Int32 = ArraySize(player.opxSandyTrails) - 1;
  while i >= 0 {
    if Equals(player.opxSandyTrails[i].id, id) {
      ArrayErase(player.opxSandyTrails, i);
    };
    i -= 1;
  };
}

// Every frame (the ticker, and every tenth of a second the watch that lit the
// body): every kept body's history and layers. Once per frame however often
// it is called; a body gone or detached is dropped.
public static func OpxSandyTrailFrame(player: ref<PlayerPuppet>) -> Void {
  if !IsDefined(player) || ArraySize(player.opxSandyTrails) == 0 {
    return;
  };
  let now: Float = EngineTime.ToFloat(GameInstance.GetEngineTime(player.GetGame()));
  if now <= player.opxSandyTrailClock {
    return;
  };
  player.opxSandyTrailClock = now;
  // Where this machine's camera is, this frame.
  let eye: Vector4 = new Vector4(0.0, 0.0, 0.0, 1.0);
  let hasEye: Bool = false;
  let camera: Transform;
  let cameras: ref<CameraSystem> = GameInstance.GetCameraSystem(player.GetGame());
  if IsDefined(cameras) && cameras.GetActiveCameraWorldTransform(camera) {
    eye = Transform.GetPosition(camera);
    hasEye = true;
  };
  let i: Int32 = ArraySize(player.opxSandyTrails) - 1;
  while i >= 0 {
    let trail: ref<OpxSandyTrail> = player.opxSandyTrails[i];
    let body: ref<GameObject> = trail.body;
    if !IsDefined(body) || !body.IsAttached() {
      ArrayErase(player.opxSandyTrails, i);
    } else {
      OpxSandyTrailStep(trail, body, now, eye, hasEye);
    };
    i -= 1;
  };
}

// One frame of one body: this frame's place and turn recorded, then each layer
// placed where the body was `layer` x 0.045 s ago (between the two frames
// around that moment), relative to where it is now -- and not shown where it
// would stand in the camera.
public static func OpxSandyTrailStep(trail: ref<OpxSandyTrail>, body: ref<GameObject>, now: Float, eye: Vector4, hasEye: Bool) -> Void {
  let here: Vector4 = body.GetWorldPosition();
  let turn: Quaternion = body.GetWorldOrientation();
  let count: Int32 = ArraySize(trail.times);
  if count > 0 {
    let jump: Vector4 = here - trail.places[count - 1];
    jump.W = 0.0;
    // More than 4 m in one frame is a teleport, not a run: start again.
    if Vector4.Length(jump) > 4.0 {
      ArrayClear(trail.times);
      ArrayClear(trail.places);
      ArrayClear(trail.turns);
    };
  };
  ArrayPush(trail.times, now);
  ArrayPush(trail.places, here);
  ArrayPush(trail.turns, turn);
  // Only as much history as the farthest afterimage needs.
  let keep: Float = now - (Cast<Float>(OpxSandyTrailLayers()) * OpxSandyTrailSpacing() + 0.25);
  while ArraySize(trail.times) > 2 && trail.times[1] < keep {
    ArrayErase(trail.times, 0);
    ArrayErase(trail.places, 0);
    ArrayErase(trail.turns, 0);
  };
  // Twice -- half a second and three seconds after the body was lit: how
  // often this really runs (the frames placed in that time).
  trail.frames += 1;
  if trail.frames == 1 {
    trail.since = now;
  };
  if (trail.saidRate == 0 && now - trail.since >= 0.5) || (trail.saidRate == 1 && now - trail.since >= 3.0) {
    trail.saidRate += 1;
    Open77PlayerResetTrace("opx_sandy_view afterimages: " + trail.who + " -- placed "
      + IntToString(trail.frames) + " times in " + FloatToStringPrec(now - trail.since, 2) + " s, "
      + IntToString(trail.showing) + " of " + IntToString(OpxSandyTrailLayers()) + " showing");
  };
  let showing: Int32 = 0;
  let farthest: Float = 0.0;
  let farShown: Float = 0.0;
  let farLayer: Int32 = 0;
  let layer: Int32 = 1;
  while layer <= OpxSandyTrailLayers() {
    let at: Float = now - Cast<Float>(layer) * OpxSandyTrailSpacing();
    let show: Bool = false;
    let placed: Vector4 = new Vector4(0.0, 0.0, 0.0, 1.0);
    let turned: Quaternion = new Quaternion(0.0, 0.0, 0.0, 1.0);
    let reach: Float = 0.0;
    if trail.times[0] <= at {
      let k: Int32 = ArraySize(trail.times) - 1;
      while k > 0 && trail.times[k] > at {
        k -= 1;
      };
      let past: Vector4 = trail.places[k];
      if k + 1 < ArraySize(trail.times) {
        let span: Float = trail.times[k + 1] - trail.times[k];
        if span > 0.0001 {
          past = Vector4.Lerp(trail.places[k], trail.places[k + 1], (at - trail.times[k]) / span);
        };
      };
      let away: Vector4 = past - here;
      away.W = 0.0;
      let distance: Float = Vector4.Length(away);
      if trail.shown[layer - 1] {
        show = distance > OpxSandyTrailHideAt();
      } else {
        show = distance > OpxSandyTrailShowAt();
      };
      if show && hasEye {
        let middle: Vector4 = past;
        middle.Z += 1.0;
        let fromEye: Vector4 = middle - eye;
        fromEye.W = 0.0;
        if Vector4.Length(fromEye) < OpxSandyTrailClearOfCamera() {
          show = false;
        };
      };
      placed = Quaternion.TransformInverse(turn, away);
      placed.W = 1.0;
      turned = Quaternion.Conjugate(turn) * trail.turns[k];
      reach = distance;
      if distance > farthest {
        farthest = distance;
      };
    };
    trail.shown[layer - 1] = show;
    body.OpxSandyLayerPlace(layer, show, placed, turned);
    if show {
      showing += 1;
      if reach > farShown {
        farShown = reach;
        farLayer = layer;
      };
    };
    layer += 1;
  };
  trail.showing = showing;
  // Said when the number of afterimages changes, at most twice a second.
  if showing != trail.saidShowing && now - trail.saidAt >= 0.5 {
    trail.saidShowing = showing;
    trail.saidAt = now;
    // The farthest one SHOWN, read back from the engine: where its part really
    // stands (the frame before this one's placement, at most).
    let drawn: String = "";
    if farLayer > 0 {
      drawn = "; the engine has the farthest shown " + FloatToStringPrec(body.OpxSandyLayerReadBack(farLayer), 2)
        + " m from the body (asked " + FloatToStringPrec(farShown, 2) + " m)";
    };
    Open77PlayerResetTrace("opx_sandy_view afterimages: " + trail.who + " -- " + IntToString(showing) + " of "
      + IntToString(OpxSandyTrailLayers()) + " shown, the farthest " + FloatToStringPrec(farthest, 2)
      + " m behind" + drawn);
  };
}

// ── Lighting a body ─────────────────────────────────────────────────────────

// One lighting of the ghost on one body: how many parts it had.
public class OpxSandyGhostRun extends IScriptable {
  public let who: String;
  public let parts: Int32;
}

// Every part on and hidden inside the body, and the body's afterimages kept
// from this frame on; says what the body carries.
public static func OpxSandyGhostLight(body: ref<GameObject>, who: String) -> ref<OpxSandyGhostRun> {
  let run: ref<OpxSandyGhostRun> = new OpxSandyGhostRun();
  run.who = who;
  run.parts = body.OpxSandyGhostSet(true);
  let layer: Int32 = 1;
  while layer <= OpxSandyTrailLayers() {
    body.OpxSandyLayerPlace(layer, false, new Vector4(0.0, 0.0, 0.0, 1.0), new Quaternion(0.0, 0.0, 0.0, 1.0));
    layer += 1;
  };
  OpxSandyTrailOn(body, who);
  Open77PlayerResetTrace("opx_sandy_view ghost: " + who + " lit -- " + body.OpxSandyGhostWhat()
    + "; " + IntToString(OpxSandyTrailLayers()) + " afterimages, " + FloatToStringPrec(OpxSandyTrailSpacing(), 3)
    + " s apart, shown from " + FloatToStringPrec(OpxSandyTrailShowAt(), 2) + " m, placed every frame");
  return run;
}

// One step of a lit ghost (every tenth of a second): every part kept on (only
// a part that went off is switched), and the body kept in the local player's
// list (a new player body starts an empty one). A body re-dressed in the
// middle of a boost has NEW parts: said, and simply placed from the next frame.
// Answers how many parts the body has.
public static func OpxSandyGhostDrive(body: ref<GameObject>, run: ref<OpxSandyGhostRun>, interval: Float, who: String) -> Int32 {
  if !IsDefined(run) {
    return 0;
  };
  let parts: Int32 = body.OpxSandyGhostSet(true);
  if parts != run.parts {
    Open77PlayerResetTrace("opx_sandy_view ghost: " + who + " now has " + IntToString(parts)
      + " parts (re-dressed?) -- " + body.OpxSandyGhostWhat());
    run.parts = parts;
  };
  OpxSandyTrailOn(body, who);
  // Placed from here too, at this watch's own cadence (every tenth of a
  // second): a frame the ticker already placed is not placed twice.
  OpxSandyTrailFrame(GetPlayer(body.GetGame()));
  return parts;
}

// The afterimages no longer kept, then every part off.
public static func OpxSandyGhostOff(body: ref<GameObject>) -> Void {
  OpxSandyTrailOff(body);
  body.OpxSandyGhostSet(false);
}

// Another client's copy of a boosted player: opx_infinity's look plays the
// trigger on it for the whole boost, and stops it at the end. The trigger's
// generation lives on the body itself, so a watch can tell that it was
// superseded or ended; nothing is shared between bodies.
@addField(NPCPuppet)
public let opxSandyGhostGen: Int32;

@addField(NPCPuppet)
public let opxSandyGhostWanted: Bool;

// `run` is the ghost once the body has its parts; `said` whether the "not
// dressed yet" line was written; `left` the watch's own ceiling in seconds
// (`OpxSandevistanBoostCeiling`, past the longest boost -- 40 s and its ease;
// up to 1.4.8 it was 30 s, which a boost of 40 s would have outlived; the
// trigger's end is what normally ends it); `pace` what the last line said of
// this machine's clock and the body's exemption (see `OpxSandyGhostPace`).
public class OpxSandyGhostTick extends DelayCallback {
  public let body: wref<NPCPuppet>;
  public let game: GameInstance;
  public let gen: Int32;
  public let run: ref<OpxSandyGhostRun>;
  public let said: Bool;
  public let left: Float;
  public let pace: String;

  public func Call() -> Void {
    OpxSandyGhostStep(this);
  }
}

public static func OpxSandyGhostWatch(body: ref<NPCPuppet>, gen: Int32) -> Void {
  let tick: ref<OpxSandyGhostTick> = new OpxSandyGhostTick();
  tick.body = body;
  tick.game = body.GetGame();
  tick.gen = gen;
  tick.left = OpxSandevistanBoostCeiling();
  OpxSandyGhostStep(tick);
}

public static func OpxSandyGhostStep(tick: ref<OpxSandyGhostTick>) -> Void {
  let body: ref<NPCPuppet> = tick.body;
  if !IsDefined(body) {
    return;
  };
  // Superseded by a newer trigger, or the trigger ended: that one owns it.
  if body.opxSandyGhostGen != tick.gen || !body.opxSandyGhostWanted {
    return;
  };
  if !body.IsAttached() || tick.left <= 0.0 {
    body.opxSandyGhostWanted = false;
    OpxSandyGhostOff(body);
    OpxSandyGhostUnpace(body);
    Open77PlayerResetTrace("opx_sandy_view ghost: the boosted player's ghost trail is off (the body left, or the boost outlived its ceiling)");
    return;
  };
  // The boosted body keeps its own pace on this machine (see `OpxSandyGhostPace`).
  tick.pace = OpxSandyGhostPace(body, tick.game, tick.pace);
  let interval: Float = 0.25;
  // A body seated in a vehicle carries no ghost: Open77 hides every remote
  // occupant of an AV, and parts un-hidden there would stand in an invisible
  // body. Off while seated, lit again once out.
  if VehicleComponent.IsMountedToVehicle(tick.game, body) {
    if IsDefined(tick.run) {
      OpxSandyGhostOff(body);
      tick.run = null;
      Open77PlayerResetTrace("opx_sandy_view ghost: the boosted player is seated in a vehicle -- ghost trail off until they are out");
    };
  } else {
    if !IsDefined(tick.run) {
      if body.OpxSandyGhostFound() > 0 {
        tick.run = OpxSandyGhostLight(body, "a boosted player's body");
      } else {
        if !tick.said {
          tick.said = true;
          Open77PlayerResetTrace("opx_sandy_view ghost: a boosted player's body has no ghost parts yet -- still dressing, or this game does not load opx_sandy_ghost.archive's copy of V's body (looking again every quarter second)");
        };
      };
    };
    if IsDefined(tick.run) {
      interval = 0.1;
      OpxSandyGhostDrive(body, tick.run, interval, "a boosted player's body");
    };
  };
  let next: ref<OpxSandyGhostTick> = new OpxSandyGhostTick();
  next.body = tick.body;
  next.game = tick.game;
  next.gen = tick.gen;
  next.run = tick.run;
  next.said = tick.said;
  next.left = tick.left - interval;
  next.pace = tick.pace;
  GameInstance.GetDelaySystem(tick.game).DelayCallback(next, interval, false);
}

// THE OWNER AT FULL SPEED, ON A MACHINE THEIR BOOST SLOWS. opx_infinity slows
// every player near a boost (its own time-scale claim, reason
// `open77:opx_infinity`: the world and that player's own body), and on that
// machine the boosted player's body is just another body of the world -- it
// would run in slow motion too. So for the boost it gets the exemption the
// owner's own third-person model gets (an individual dilation of 1.0 that
// ignores the global one): everyone near a Sandevistan sees its owner at full
// speed in a slowed world, as the owner sees themselves. Harmless on a machine
// the boost does not slow. Said on every change of what this machine's clock
// is, with the answer the engine gives about the body; answers what it said.
public static func OpxSandyGhostPace(body: ref<NPCPuppet>, game: GameInstance, said: String) -> String {
  if !body.HasIndividualTimeDilation(n"opx_sandy_view") {
    body.SetIndividualTimeDilation(n"opx_sandy_view", 1.0, OpxSandevistanBoostCeiling(), n"None", n"None", true, true);
  };
  let time: ref<TimeSystem> = GameInstance.GetTimeSystem(game);
  let clock: String = "not slowed by it (out of its range, or its slowdown not here yet)";
  if IsDefined(time) && time.IsTimeDilationActive(n"open77:opx_infinity") {
    clock = "slowed by it, world " + FloatToStringPrec(time.GetActiveTimeDilation(n"open77:opx_infinity"), 2);
  };
  let line: String = "opx_sandy_view ghost: the boosted player's body keeps full speed on this machine (exempt from its dilation: "
    + BoolToString(body.IsIgnoringGlobalTimeDilation()) + "); this machine is " + clock;
  if NotEquals(line, said) {
    Open77PlayerResetTrace(line);
  };
  return line;
}

// The boost is over on this machine: the body runs with its world again.
public static func OpxSandyGhostUnpace(body: ref<NPCPuppet>) -> Void {
  if body.HasIndividualTimeDilation(n"opx_sandy_view") {
    body.UnsetIndividualTimeDilation();
  };
}

@addMethod(NPCPuppet)
protected cb func OnOpxSandyGhostSpawn(evt: ref<entSpawnEffectEvent>) -> Bool {
  if Equals(evt.effectName, n"opx_sandy_ghost_on") {
    this.opxSandyGhostGen += 1;
    this.opxSandyGhostWanted = true;
    OpxSandyGhostWatch(this, this.opxSandyGhostGen);
  };
  return false;
}

@addMethod(NPCPuppet)
protected cb func OnOpxSandyGhostKill(evt: ref<entKillEffectEvent>) -> Bool {
  if Equals(evt.effectName, n"opx_sandy_ghost_on") {
    this.opxSandyGhostGen += 1;
    this.opxSandyGhostWanted = false;
    OpxSandyGhostOff(this);
    OpxSandyGhostUnpace(this);
    Open77PlayerResetTrace("opx_sandy_view ghost: the boosted player's ghost trail is off");
  };
  return false;
}
