// OPX Infinity -- the base game's missions, playable in a multiplayer session.
// opx_sandy_view 1.4.17. (1.4.11: the missions; 1.4.13: Phantom Liberty opened on
// a world that never started it -- see "Phantom Liberty" below; 1.4.14: the
// fullscreen map's steps in the client log -- see "the map log" below; 1.4.15:
// opening the map no longer crashes the game -- see "markers" below; 1.4.16:
// Songbird's call refused, so the expansion's story no longer starts by itself
// on joining -- see "Songbird" below; 1.4.17: the story itself waits -- its main
// quests stay shut, so her holocall scene never plays either -- same section.)
//
// WHY MISSIONS STALLED. Open77's multiplayer policy switches off, for the whole
// session, the pieces of the base game a side job waits on (read from the
// platform's own scripts in `r6/scripts/Open77`, 2.31):
//
//   * the phone: a quest's holocall never rang (`PhoneSystem.OnTriggerCall`
//     returned at once), so the `phonecall_<npc>_with_player` fact a job waits
//     for never moved, and "wait for X's call" waited forever;
//   * loot: no container, body or pickup offered its items, and the ones the
//     player looked at were emptied -- a quest's keycard, shard or package
//     with them;
//   * the scanner: refused, so no clue could be scanned;
//   * objectives: the tracked quest was untracked the moment it was tracked,
//     the tracker was hidden, and every quest marker was denied on the world,
//     the minimap and the map -- the player never saw where to go next;
//   * the quest toasts ("new objective", "quest updated") never showed;
//   * V's own lines in a conversation were cut, voice and subtitle.
//
// WHAT THIS DOES. It puts the base game back for exactly those pieces, in a
// multiplayer session only, by being the OUTERMOST wrapper of the same vanilla
// methods: redscript compiles `r6/scripts/Open77` before `r6/scripts/
// opx_infinity`, and the wrapper compiled last is the one the game calls
// first, so each wrapper below can run the base game's own body instead of
// the platform's refusal (`wrappedMethod()` would reach the platform's
// wrapper first, which returns before the base game). Every body below is
// copied from the 2.31 game scripts. Everything that is not quest content --
// other players' bodies, the loot the server owns, free-roam barks -- stays
// exactly as the platform decided.
//
// SAFE IN THE WRONG ORDER. Only base-game methods are wrapped (never a method
// or a global the platform added), so the scripts compile whichever folder
// comes first; if the platform's wrapper ever ends up outside ours, ours are
// simply never reached. The self-check at the player's attach says which it is
// in the Open77 client log (`opx_sandy_view quests: ...`).
//
// OFF SWITCH: the quest fact `opx_quests_off` set to 1 hands every piece back
// to the platform on the next call.

// ---------------------------------------------------------------- gates ----

public static func OpxQuestsOn(game: GameInstance) -> Bool {
  return Open77MultiplayerPolicyActive() && GetFact(game, n"opx_quests_off") == 0;
}

public static func OpxQuestsOnFor(object: ref<GameObject>) -> Bool {
  return IsDefined(object) && OpxQuestsOn(object.GetGame());
}

// A remote player's body: one of the platform's four proxy records.
public static func OpxQuestsIsPlayerProxy(object: ref<GameObject>) -> Bool {
  let puppet: ref<ScriptedPuppet> = object as ScriptedPuppet;
  if !IsDefined(puppet) {
    return false;
  };
  let record: TweakDBID = puppet.GetRecordID();
  return record == t"Character.Open77ProxyMale" || record == t"Character.Open77ProxyFemale"
    || record == t"Character.Open77ProxyMaleMirror" || record == t"Character.Open77ProxyFemaleMirror";
}

// One line in the Open77 client log. The platform records transitions only,
// so a line repeated back to back is written once.
public static func OpxQuestsTrace(line: String) -> Void {
  Open77PlayerResetTrace("opx_sandy_view quests: " + line);
}

// The session's bookkeeping: when the local body attached, for the phone's
// first seconds (the pristine save's own banners are replayed then).
public class OpxQuestsSystem extends ScriptableSystem {
  public let attachedAt: Float;
  public let calls: Int32;
  public let given: Int32;
  // Records of the quest items handed over after the session emptied their
  // pickup: each at most once a session.
  public let givenIds: array<TweakDBID>;
}

public static func OpxQuestsState(game: GameInstance) -> ref<OpxQuestsSystem> {
  return GameInstance.GetScriptableSystemsContainer(game).Get(n"OpxQuestsSystem") as OpxQuestsSystem;
}

public static func OpxQuestsNow(game: GameInstance) -> Float {
  return EngineTime.ToFloat(GameInstance.GetEngineTime(game));
}

// Settled: the local body has been in the world for 20 s.
public static func OpxQuestsSettled(game: GameInstance) -> Bool {
  let state: ref<OpxQuestsSystem> = OpxQuestsState(game);
  if !IsDefined(state) || state.attachedAt <= 0.0 {
    return false;
  };
  return OpxQuestsNow(game) - state.attachedAt >= 20.0;
}

// ---------------------------------------------------------------- phone ----
// A quest's holocall. The platform returned before the base game; this is the
// base game's own body (2.31 `PhoneSystem.OnTriggerCall`), which rings, shows
// the call and writes the `phonecall_*` fact the quest waits on.
@wrapMethod(PhoneSystem)
private func OnTriggerCall(request: ref<questTriggerCallRequest>) -> Void {
  let game: GameInstance = this.GetGameInstance();
  if !IsDefined(request) || !OpxQuestsOn(game) {
    wrappedMethod(request);
    return;
  };
  // Songbird's call (1.4.16): refused before anything rings -- see "Songbird".
  if OpxQuestsSongbirdRefused(game, request) {
    OpxQuestsTrace("call " + EnumValueToString("questPhoneCallPhase", Cast<Int64>(EnumInt(request.callPhase)))
      + " with songbird refused: the Phantom Liberty story does not start by itself in a session");
    return;
  };
  let contactName: CName;
  let shouldPlayIncomingCallSound: Bool = Equals(request.callPhase, questPhoneCallPhase.IncomingCall);
  if Equals(request.callPhase, questPhoneCallPhase.IncomingCall) || Equals(request.callPhase, questPhoneCallPhase.StartCall) {
    this.ToggleContacts(false);
  };
  if IsNameValid(request.caller) && NotEquals(request.caller, n"player") && NotEquals(request.caller, n"Player") {
    if shouldPlayIncomingCallSound && Equals(request.visuals, questPhoneCallVisuals.Default) {
      GameInstance.GetAudioSystem(game).Play(n"ui_phone_incoming_call");
    };
    contactName = request.caller;
  } else {
    if IsNameValid(request.addressee) && NotEquals(request.addressee, n"player") && NotEquals(request.addressee, n"Player") {
      if shouldPlayIncomingCallSound {
        GameInstance.GetAudioSystem(game).Play(n"ui_phone_initiation_call");
      };
      contactName = request.addressee;
    };
  };
  if IsNameValid(contactName) {
    let state: ref<OpxQuestsSystem> = OpxQuestsState(game);
    if IsDefined(state) {
      state.calls += 1;
    };
    OpxQuestsTrace("call " + EnumValueToString("questPhoneCallPhase", Cast<Int64>(EnumInt(request.callPhase)))
      + " with " + NameToString(contactName));
    this.TriggerCall(request.callMode, Equals(request.callMode, questPhoneCallMode.Audio), contactName,
      Equals(request.caller, n"Player") || Equals(request.caller, n"player"), request.callPhase,
      request.isPlayerTriggered, request.isRejectable, request.showAvatar, request.visuals);
  };
}

// Whether the phone can be used: the base game's own answer (2.31
// `PhoneSystem.IsPhoneEnabled`) instead of the platform's constant false, so
// "call X" steps and text replies work. `opx_quests_probe` is the self-check.
@wrapMethod(PhoneSystem)
public const func IsPhoneEnabled() -> Bool {
  let game: GameInstance = this.GetGameInstance();
  if !OpxQuestsOn(game) {
    return wrappedMethod();
  };
  if GetFact(game, n"opx_quests_probe") == 1 {
    return true;
  };
  if !IsDefined(this.m_PsmBlackboard) || !IsDefined(this.m_Blackboard) {
    return false;
  };
  let blocedByCombat: Bool = this.IsBlockedByCombat();
  let blockedByStatus: Bool = this.IsBlockedByStatus();
  let blockedByTier: Bool = this.IsBlockedByTier();
  let blockedByBlackboard: Bool = this.IsBlockedByBlackboard();
  let blockedByHud: Bool = this.IsBlockedByHUD();
  let blockedByVisiblity: Bool = this.IsBlockedByVisiblity();
  let enabledByQuest: Bool = this.IsEnabledByQuestSystem();
  let enabledByVisiblity: Bool = this.IsEnabledByVisiblity();
  if blocedByCombat {
    return false;
  };
  if enabledByQuest || enabledByVisiblity {
    return true;
  };
  return !blockedByTier && !blockedByBlackboard && !blockedByHud && !blockedByVisiblity && !blockedByStatus;
}

// Holding the phone key: the base game's own body (2.31 `PhoneSystem.
// OnUsePhone`) -- answering a ringing call through it, and the contact list.
// The contact list only opens while it is part of a mission: the tracked
// objective asks for a call or a text (the base game's own `MessengerUtils`
// tests), or the player chose a message banner. The phone key is also this
// server's chat key, and a chat opened with it must not bring the phone up
// with it every time.
public static func OpxQuestsPhoneWanted(game: GameInstance, request: ref<UsePhoneRequest>) -> Bool {
  if IsDefined(request) && request.MessageToOpen != null {
    return true;
  };
  let journal: ref<JournalManager> = GameInstance.GetJournalManager(game);
  if !IsDefined(journal) {
    return false;
  };
  return MessengerUtils.HasQuestImportantCalls(journal) || MessengerUtils.HasQuestImportantMessages(journal);
}

@wrapMethod(PhoneSystem)
private func OnUsePhone(request: ref<UsePhoneRequest>) -> Void {
  let game: GameInstance = this.GetGameInstance();
  if !OpxQuestsOn(game) {
    wrappedMethod(request);
    return;
  };
  if NotEquals(this.m_LastCallInformation.callPhase, questPhoneCallPhase.IncomingCall) && !OpxQuestsPhoneWanted(game, request) {
    wrappedMethod(request);
    return;
  };
  let hash: Int32;
  let localPlayer: wref<GameObject>;
  let notificationEvent: ref<UIInGameNotificationEvent>;
  if this.IsPhoneOpened() {
    return;
  };
  localPlayer = GameInstance.GetPlayerSystem(game).GetLocalPlayerMainGameObject();
  if !IsDefined(localPlayer) {
    return;
  };
  if Equals(this.m_LastCallInformation.callPhase, questPhoneCallPhase.IncomingCall) {
    if this.m_LastCallInformation.isPlayerCalling {
      GameInstance.GetAudioSystem(game).Play(n"ui_phone_incoming_call_stop");
      this.TriggerCall(questPhoneCallMode.Undefined, this.m_LastCallInformation.isAudioCall, this.m_LastCallInformation.contactName, this.m_LastCallInformation.isPlayerCalling, questPhoneCallPhase.EndCall, this.m_LastCallInformation.isPlayerTriggered, this.m_LastCallInformation.isRejectable, this.m_LastCallInformation.showAvatar, this.m_LastCallInformation.visuals);
    } else {
      if Equals(this.m_LastCallInformation.visuals, questPhoneCallVisuals.Default) {
        GameInstance.GetAudioSystem(game).Play(n"ui_phone_incoming_call_positive");
      };
      GameInstance.GetAudioSystem(game).Play(n"ui_phone_incoming_call_stop");
      this.SetPhoneFact(this.m_LastCallInformation.isPlayerCalling, this.m_LastCallInformation.contactName, questPhoneTalkingState.Talking);
    };
  } else {
    if !this.IsPhoneEnabled() {
      GameInstance.GetUISystem(game).QueueEvent(new UIInGameNotificationRemoveEvent());
      notificationEvent = new UIInGameNotificationEvent();
      notificationEvent.m_notificationType = UIInGameNotificationType.CombatRestriction;
      GameInstance.GetUISystem(game).QueueEvent(notificationEvent);
      return;
    };
    if !this.m_ContactsOpen {
      if request.MessageToOpen != null {
        hash = GameInstance.GetJournalManager(game).GetEntryHash(request.MessageToOpen);
        this.m_Blackboard.SetInt(GetAllBlackboardDefs().UI_ComDevice.MessageToOpenHash, hash, true);
      };
      this.ToggleContacts(true);
    };
  };
}

// The answer key. The base game answers when the phone key is RELEASED; on
// this server the same key (T) opens the chat, which takes the keyboard
// before the release reaches the game, so a ringing call was never picked up.
// The PRESS now arms an answer: half a second later, if neither the release
// (the base game answers) nor the reject hold (the base game rejects) came,
// the call is answered with the same request the release sends. Once it is,
// a reject hold that completes afterwards is not let through to overwrite it.
public class OpxQuestsAnswerTick extends DelayCallback {
  public let hud: wref<NewHudPhoneGameController>;
  public func Call() -> Void {
    if IsDefined(this.hud) {
      this.hud.OpxQuestsAnswer();
    };
  }
}

@addField(NewHudPhoneGameController)
public let m_opxQuestsAnswerArmed: Bool;

@addField(NewHudPhoneGameController)
public let m_opxQuestsAnswerFor: CName;

@addField(NewHudPhoneGameController)
public let m_opxQuestsAnswered: CName;

@addMethod(NewHudPhoneGameController)
public func OpxQuestsAnswer() -> Void {
  let contact: CName = this.m_CurrentCallInformation.contactName;
  if !this.m_opxQuestsAnswerArmed || !IsDefined(this.m_PhoneSystem)
      || NotEquals(this.m_CurrentCallInformation.callPhase, questPhoneCallPhase.IncomingCall)
      || NotEquals(contact, this.m_opxQuestsAnswerFor) {
    this.m_opxQuestsAnswerArmed = false;
    return;
  };
  this.m_opxQuestsAnswerArmed = false;
  this.m_opxQuestsAnswered = contact;
  let pickupRequest: ref<PickupPhoneRequest> = new PickupPhoneRequest();
  pickupRequest.CallInformation = this.m_CurrentCallInformation;
  this.m_PhoneSystem.QueueRequest(pickupRequest);
  OpxQuestsTrace("call answered: " + NameToString(contact));
}

@wrapMethod(NewHudPhoneGameController)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  if IsDefined(this.m_player) && OpxQuestsOn(this.m_player.GetGame())
      && Equals(this.m_CurrentCallInformation.callPhase, questPhoneCallPhase.IncomingCall) {
    let actionName: CName = ListenerAction.GetName(action);
    let actionType: gameinputActionType = ListenerAction.GetType(action);
    let contact: CName = this.m_CurrentCallInformation.contactName;
    if Equals(actionName, n"PhoneInteract") {
      if Equals(actionType, gameinputActionType.BUTTON_PRESSED) {
        this.m_opxQuestsAnswerArmed = true;
        this.m_opxQuestsAnswerFor = contact;
        let tick: ref<OpxQuestsAnswerTick> = new OpxQuestsAnswerTick();
        tick.hud = this;
        GameInstance.GetDelaySystem(this.m_player.GetGame()).DelayCallback(tick, 0.5, false);
      } else {
        if Equals(actionType, gameinputActionType.BUTTON_RELEASED) {
          // The base game answers on this release.
          this.m_opxQuestsAnswerArmed = false;
        };
      };
    } else {
      if Equals(actionName, n"PhoneReject") && Equals(actionType, gameinputActionType.BUTTON_HOLD_COMPLETE) {
        if Equals(this.m_opxQuestsAnswered, contact) {
          // Already answered here: a hold completing after that is not a reject.
          return true;
        };
        this.m_opxQuestsAnswerArmed = false;
      };
    };
  };
  return wrappedMethod(action, consumer);
}

// New messages and contacts a quest sends: the base game's own body (2.31
// `NewHudPhoneGameController.OnJournalUpdate`). It reacts to live journal
// changes only, never to what the pristine save already held.
@wrapMethod(NewHudPhoneGameController)
protected cb func OnJournalUpdate(hash: Uint32, className: CName, notifyOption: JournalNotifyOption, changeType: JournalChangeType) -> Bool {
  if !IsDefined(this.m_player) || !OpxQuestsOn(this.m_player.GetGame()) || !IsDefined(this.m_journalMgr) {
    return wrappedMethod(hash, className, notifyOption, changeType);
  };
  let entry: wref<JournalEntry>;
  let state: gameJournalEntryState;
  switch className {
    case n"gameJournalPhoneChoiceEntry":
      entry = this.m_journalMgr.GetEntry(hash);
      state = this.m_journalMgr.GetEntryState(entry);
      if Equals(state, gameJournalEntryState.Active) {
        this.NotifyOrRefreshData(entry, state);
      };
      break;
    case n"gameJournalPhoneMessage":
      entry = this.m_journalMgr.GetEntry(hash);
      state = this.m_journalMgr.GetEntryState(entry);
      if Equals(notifyOption, JournalNotifyOption.Notify) && Equals(state, gameJournalEntryState.Active) && Equals(changeType, JournalChangeType.Direct) {
        this.NotifyOrRefreshData(entry, state);
      };
      break;
    case n"gameJournalContact":
      entry = this.m_journalMgr.GetEntry(hash);
      state = this.m_journalMgr.GetEntryState(entry);
      if Equals(notifyOption, JournalNotifyOption.Notify) && Equals(state, gameJournalEntryState.Active) && Equals(changeType, JournalChangeType.Direct) {
        this.ShowContactUpdate(entry, state);
      };
      break;
    default:
  };
  return true;
}

// The text-message banner, once the body has been in the world for 20 s (the
// platform refused it because the pristine save replays its old banners while
// it attaches). The base game's own body (2.31 `PushSMSNotification`).
@wrapMethod(NewHudPhoneGameController)
public func PushSMSNotification(msgEntry: wref<JournalPhoneMessage>, opt action: ref<GenericNotificationBaseAction>) -> Void {
  if !IsDefined(msgEntry) || !IsDefined(this.m_player) || !IsDefined(this.m_journalMgr)
      || !OpxQuestsOn(this.m_player.GetGame()) || !OpxQuestsSettled(this.m_player.GetGame()) {
    wrappedMethod(msgEntry, action);
    return;
  };
  let notificationData: gameuiGenericNotificationData;
  let msgConversation: wref<JournalPhoneConversation> = this.m_journalMgr.GetParentEntry(msgEntry) as JournalPhoneConversation;
  let msgContact: wref<JournalContact> = this.m_journalMgr.GetParentEntry(msgConversation) as JournalContact;
  let userData: ref<PhoneMessageNotificationViewData> = new PhoneMessageNotificationViewData();
  userData.entryHash = this.m_journalMgr.GetEntryHash(msgEntry);
  userData.threadHash = this.m_journalMgr.GetEntryHash(msgConversation);
  userData.contactHash = this.m_journalMgr.GetEntryHash(msgContact);
  userData.title = msgContact.GetLocalizedName(this.m_journalMgr);
  userData.SMSLocKey = msgEntry.GetText();
  userData.SMSText = GetLocalizedText(msgEntry.GetText());
  userData.action = action;
  userData.animation = n"notification_phone_MSG";
  userData.soundEvent = n"PhoneSmsPopup";
  userData.soundAction = n"OnOpen";
  notificationData.time = 6.70;
  notificationData.widgetLibraryItemName = n"notification_message";
  notificationData.notificationData = userData;
  this.AddNewNotificationData(notificationData);
}

// The phone's own screen: the platform hides its root at attach and again on
// every five-second heartbeat. While the server leaves the `phone` HUD
// component on (config/hud.lua), it is shown again -- hidden in a menu, as the
// base game's own `OnMenuUpdate` does -- right after each of the platform's
// hides (attach, heartbeat), with a tenth-of-a-second watch behind it in case
// this handler hears the heartbeat before the platform's does.
public class OpxQuestsPhoneTick extends DelayCallback {
  public let hud: wref<NewHudPhoneGameController>;
  public func Call() -> Void {
    if IsDefined(this.hud) {
      this.hud.OpxQuestsPhoneTickStep();
    };
  }
}

@addField(NewHudPhoneGameController)
public let m_opxQuestsWatching: Bool;

@addMethod(NewHudPhoneGameController)
public func OpxQuestsPhoneWatch() -> Void {
  if !IsDefined(this.m_player) || !OpxQuestsOn(this.m_player.GetGame()) {
    return;
  };
  this.OpxQuestsPhoneStep();
  if this.m_opxQuestsWatching {
    return;
  };
  this.m_opxQuestsWatching = true;
  let tick: ref<OpxQuestsPhoneTick> = new OpxQuestsPhoneTick();
  tick.hud = this;
  GameInstance.GetDelaySystem(this.m_player.GetGame()).DelayCallback(tick, 0.1, false);
}

// Shows the phone's screen when the platform hid it (as the base game would:
// hidden in a menu).
@addMethod(NewHudPhoneGameController)
public func OpxQuestsPhoneStep() -> Void {
  if !IsDefined(this.m_player) {
    return;
  };
  let root: ref<inkWidget> = this.GetRootWidget();
  if IsDefined(root) && OpxQuestsOn(this.m_player.GetGame()) && Open77HudComponentVisible(8) {
    let inMenu: Bool = IsDefined(this.m_bbUiSystem) && this.m_bbUiSystem.GetBool(this.m_bbUiSystemDef.IsInMenu);
    if NotEquals(root.IsVisible(), !inMenu) {
      root.SetVisible(!inMenu);
    };
  };
}

// The watch's own tick: the step, then the next tick.
@addMethod(NewHudPhoneGameController)
public func OpxQuestsPhoneTickStep() -> Void {
  if !IsDefined(this.m_player) || !OpxQuestsOn(this.m_player.GetGame()) {
    this.m_opxQuestsWatching = false;
    return;
  };
  this.OpxQuestsPhoneStep();
  let tick: ref<OpxQuestsPhoneTick> = new OpxQuestsPhoneTick();
  tick.hud = this;
  GameInstance.GetDelaySystem(this.m_player.GetGame()).DelayCallback(tick, 0.1, false);
}

// The platform's five-second heartbeat, heard here as well: shown again in the
// same dispatch rather than on the next tick (the tick stays, in case this
// handler is ever not the last to hear it).
@addMethod(NewHudPhoneGameController)
protected cb func OnOpxQuestsHudPolicy(evt: ref<Open77VanillaHudPolicyEvent>) -> Bool {
  if IsDefined(evt) && evt.active {
    this.OpxQuestsPhoneWatch();
  };
  return false;
}

// From the start, not only from the first call: the controller holds its
// notifications while its screen is hidden (`SetNotificationPauseWhenHidden`),
// so a text banner would wait for a call that never comes.
@wrapMethod(NewHudPhoneGameController)
protected cb func OnInitialize() -> Bool {
  let result: Bool = wrappedMethod();
  this.OpxQuestsPhoneWatch();
  return result;
}

@wrapMethod(NewHudPhoneGameController)
protected cb func OnPlayerAttach(playerPuppet: ref<GameObject>) -> Bool {
  let result: Bool = wrappedMethod(playerPuppet);
  this.OpxQuestsPhoneWatch();
  return result;
}

@wrapMethod(NewHudPhoneGameController)
protected cb func OnPhoneCall(value: Variant) -> Bool {
  let result: Bool = wrappedMethod(value);
  this.OpxQuestsPhoneWatch();
  return result;
}

@wrapMethod(NewHudPhoneGameController)
protected cb func OnContactsActive(value: Bool) -> Bool {
  let result: Bool = wrappedMethod(value);
  this.OpxQuestsPhoneWatch();
  return result;
}

// -------------------------------------------------------------- tracker ----
// The objective tracker. At the HUD's start the platform untracks what the
// pristine save had tracked and hides the widget; that part is kept (a stale
// objective from the template save is nobody's mission). What changes is
// everything after: a quest the player starts in this session is tracked and
// drawn. The platform's `OnTrackedEntryChanges` hid the widget and untracked
// the entry a tick later; this is the base game's own body (2.31
// `QuestTrackerGameController.OnTrackedEntryChanges`). NEVER track or untrack
// from here: this callback runs inside the journal's TrackEntry, under its
// listener lock (the platform's "Dogtown gate freeze").
@wrapMethod(QuestTrackerGameController)
protected cb func OnTrackedEntryChanges(hash: Uint32, className: CName, notifyOption: JournalNotifyOption, changeType: JournalChangeType) -> Bool {
  let player: ref<GameObject> = this.GetPlayerControlledObject();
  if !OpxQuestsOnFor(player) || !IsDefined(this.m_journalManager) {
    return wrappedMethod(hash, className, notifyOption, changeType);
  };
  let objectiveController: wref<QuestTrackerObjectiveLogicController>;
  let state: gameJournalEntryState = this.m_journalManager.GetEntryState(this.m_journalManager.GetEntry(hash));
  let j: Int32 = 0;
  while j < inkCompoundRef.GetNumChildren(this.m_ObjectiveContainer) {
    objectiveController = inkCompoundRef.GetWidgetByIndex(this.m_ObjectiveContainer, j).GetController() as QuestTrackerObjectiveLogicController;
    if this.m_journalManager.GetEntry(hash) == objectiveController.GetObjectiveEntry() {
      if NotEquals(state, gameJournalEntryState.Succeeded) && NotEquals(state, gameJournalEntryState.Failed) {
        inkCompoundRef.RemoveChildByIndex(this.m_ObjectiveContainer, j);
        j -= 1;
      };
    };
    j += 1;
  };
  this.UpdateTrackerData();
  state = this.m_journalManager.GetEntryState(this.m_journalManager.GetEntry(hash));
  j = 0;
  while j < inkCompoundRef.GetNumChildren(this.m_ObjectiveContainer) {
    objectiveController = inkCompoundRef.GetWidgetByIndex(this.m_ObjectiveContainer, j).GetController() as QuestTrackerObjectiveLogicController;
    if objectiveController.IsReadyToRemove() {
      inkCompoundRef.RemoveChildByIndex(this.m_ObjectiveContainer, j);
      j -= 1;
    } else {
      if this.m_journalManager.GetEntry(hash) == objectiveController.GetObjectiveEntry() {
        if Equals(state, gameJournalEntryState.Succeeded) {
          objectiveController.SetFinished();
        };
        if Equals(state, gameJournalEntryState.Failed) {
          objectiveController.SetFailed();
        };
      };
    };
    j += 1;
  };
  let tracked: wref<JournalQuestObjective> = this.m_journalManager.GetTrackedEntry() as JournalQuestObjective;
  if IsDefined(tracked) {
    OpxQuestsTrace("tracking: " + GetLocalizedText(tracked.GetDescription()));
  };
  this.OpxQuestsTrackerWatch();
  return true;
}

@wrapMethod(QuestTrackerGameController)
protected cb func OnInitialize() -> Bool {
  let result: Bool = wrappedMethod();
  this.OpxQuestsTrackerWatch();
  return result;
}

// The platform hides the tracker again on every five-second heartbeat. While
// the server leaves the `questTracker` HUD component on (config/hud.lua) it is
// shown again right after (on the heartbeat itself, with a tenth-of-a-second
// watch behind it). The base game never hides this root itself; outside a
// cinematic, shown is the base game's own state.
public class OpxQuestsTrackerTick extends DelayCallback {
  public let tracker: wref<QuestTrackerGameController>;
  public func Call() -> Void {
    if IsDefined(this.tracker) {
      this.tracker.OpxQuestsTrackerTickStep();
    };
  }
}

@addField(QuestTrackerGameController)
public let m_opxQuestsWatching: Bool;

@addMethod(QuestTrackerGameController)
public func OpxQuestsTrackerWatch() -> Void {
  let player: ref<GameObject> = this.GetPlayerControlledObject();
  if !OpxQuestsOnFor(player) {
    return;
  };
  this.OpxQuestsTrackerStep();
  if this.m_opxQuestsWatching {
    return;
  };
  this.m_opxQuestsWatching = true;
  let tick: ref<OpxQuestsTrackerTick> = new OpxQuestsTrackerTick();
  tick.tracker = this;
  GameInstance.GetDelaySystem(player.GetGame()).DelayCallback(tick, 0.1, false);
}

// Shown again unless V is in a cinematic (scene tiers 3 to 5, where the base
// game keeps the HUD down).
@addMethod(QuestTrackerGameController)
public func OpxQuestsTrackerStep() -> Void {
  let player: ref<PlayerPuppet> = this.GetPlayerControlledObject() as PlayerPuppet;
  let root: ref<inkWidget> = this.GetRootWidget();
  if !IsDefined(root) || root.IsVisible() || !OpxQuestsOnFor(player) || !Open77HudComponentVisible(7) {
    return;
  };
  let psm: ref<IBlackboard> = player.GetPlayerStateMachineBlackboard();
  if IsDefined(psm) && psm.GetInt(GetAllBlackboardDefs().PlayerStateMachine.HighLevel) >= 3
      && psm.GetInt(GetAllBlackboardDefs().PlayerStateMachine.HighLevel) <= 5 {
    return;
  };
  root.SetVisible(true);
}

@addMethod(QuestTrackerGameController)
public func OpxQuestsTrackerTickStep() -> Void {
  let player: ref<GameObject> = this.GetPlayerControlledObject();
  if !OpxQuestsOnFor(player) {
    this.m_opxQuestsWatching = false;
    return;
  };
  this.OpxQuestsTrackerStep();
  let tick: ref<OpxQuestsTrackerTick> = new OpxQuestsTrackerTick();
  tick.tracker = this;
  GameInstance.GetDelaySystem(player.GetGame()).DelayCallback(tick, 0.1, false);
}

// The platform's heartbeat, heard here as well (see the phone's).
@addMethod(QuestTrackerGameController)
protected cb func OnOpxQuestsHudPolicy(evt: ref<Open77VanillaHudPolicyEvent>) -> Bool {
  if IsDefined(evt) && evt.active {
    this.OpxQuestsTrackerWatch();
  };
  return false;
}

// -------------------------------------------------------------- markers ----
// Quest markers. The platform answers `None` for every base-game marker; a
// quest's own markers (and the scanner's clue markers, and the tracked
// destination) get the base game's profile back, from the base game's own
// body of each `CreateMappinUIProfile` (2.31). Every other base-game marker
// stays hidden, as the platform decided.
//
// THE MAP'S OWN PLAYER ARROW HAS NO DATA BEHIND IT (1.4.15). Opening the
// fullscreen map hard-crashed the game (reported 2026-09-29 from two PCs). The
// crash probe named the function that faulted: the game's native
// `IMappin.GetScriptData` (Cyberpunk2077.exe+0xBF9A48, 2.31), called on a
// `gamemappinsRuntimeMappin` whose data pointer (+0xB8, read by the native at
// once) was null. That marker is the one the fullscreen map makes for the
// player's own arrow: it is drawn from init data (`gameuiWorldMapPlayerInitData`),
// is never registered with the mappin system, and a native read of it -- its
// script data, its kind, anything -- dereferences that null. The base game's
// own body of the map's `CreateMappinUIProfile` never touches the marker (it
// reads the init data only), and the platform's wrapper lets the arrow through
// on its init data BEFORE it touches the marker; this gate read
// `mappin.GetScriptData()` first, on every marker and ahead of the off switch,
// so the game died the moment the map asked for its arrow (about 100 ms after
// the map opened, before `map: marker` could be written and whatever
// `opx_quests_off` said). The order below is the platform's: the arrow on its
// init data first, then what the object's own class answers (nothing is read
// from the object), then the off switch, and only then the marker's data.
public static func OpxQuestsMappin(mappin: wref<IMappin>, mappinVariant: gamedataMappinVariant, customData: ref<MappinControllerCustomData>) -> Bool {
  if !IsDefined(mappin) || !Open77MultiplayerPolicyActive() {
    return false;
  };
  // The fullscreen map's player arrow: no call on the marker at all.
  if IsDefined(customData) && customData.IsA(n"gameuiWorldMapPlayerInitData") {
    return false;
  };
  // Another player or a ping keeps the platform's own path (a class test:
  // nothing is read from the object).
  if mappin.IsExactlyA(n"gamemappinsRemotePlayerMappin") || mappin.IsExactlyA(n"gamemappinsPingSystemMappin") {
    return false;
  };
  if !OpxQuestsOn(GetGameInstance()) {
    return false;
  };
  // From here on the marker's own data is read, so only a marker the mappin
  // system registered gets here. A server's own blip (the platform's
  // `Open77MappinScriptData`) keeps the platform's own path.
  let data: wref<MappinScriptData> = mappin.GetScriptData();
  if IsDefined(data) && data.IsA(n"Open77MappinScriptData") {
    return false;
  };
  if mappin.IsQuestMappin() {
    return true;
  };
  if IsDefined(customData) && IsDefined(customData as MinimapQuestAreaInitData) {
    return true;
  };
  if Equals(mappinVariant, gamedataMappinVariant.FocusClueVariant) && IsDefined(data as GameplayRoleMappinData) {
    return true;
  };
  return false;
}

@wrapMethod(WorldMappinsContainerController)
public func CreateMappinUIProfile(mappin: wref<IMappin>, mappinVariant: gamedataMappinVariant, customData: ref<MappinControllerCustomData>) -> MappinUIProfile {
  if !OpxQuestsMappin(mappin, mappinVariant, customData) {
    return wrappedMethod(mappin, mappinVariant, customData);
  };
  let questAnimationRecord: ref<UIAnimation_Record>;
  let questMappin: wref<QuestMappin>;
  let stealthMappin: wref<StealthMappin>;
  let gameplayRoleData: ref<GameplayRoleMappinData> = mappin.GetScriptData() as GameplayRoleMappinData;
  let defaultRuntimeProfile: TweakDBID = t"WorldMappinUIProfile.Default";
  let defaultWidgetResource: ResRef = r"base\\gameplay\\gui\\widgets\\mappins\\quest\\default_mappin.inkwidget";
  if mappin.IsExactlyA(n"gamemappinsStealthMappin") {
    stealthMappin = mappin as StealthMappin;
    if !stealthMappin.IsCombatNPC() && !stealthMappin.IsPrevention() && !stealthMappin.IsDevice() {
      return MappinUIProfile.None();
    };
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\stealth\\stealth_default_mappin.inkwidget", t"MappinUISpawnProfile.Stealth", t"WorldMappinUIProfile.Stealth");
  };
  if mappin.IsExactlyA(n"gamemappinsStubMappin") {
    return MappinUIProfile.None();
  };
  if mappin.IsExactlyA(n"gamemappinsInteractionMappin") {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", t"WorldMappinUIProfile.Interaction");
  };
  if mappin.IsExactlyA(n"gamemappinsPointOfInterestMappin") {
    if MappinUIUtils.IsMappinServicePoint(mappinVariant) {
      return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", t"WorldMappinUIProfile.ServicePoint");
    };
    if Equals(mappinVariant, gamedataMappinVariant.FixerVariant) {
      return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", t"WorldMappinUIProfile.Fixer");
    };
    if Equals(mappinVariant, gamedataMappinVariant.Zzz12_WorldEncounterVariant) {
      return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.WorldEncounter", defaultRuntimeProfile);
    };
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", defaultRuntimeProfile);
  };
  if Equals(mappinVariant, gamedataMappinVariant.QuickHackVariant) || Equals(mappinVariant, gamedataMappinVariant.Zzz12_QuickHackQueueVariant) {
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\interaction\\quick_hack_mappin.inkwidget", t"MappinUISpawnProfile.LongRange", t"WorldMappinUIProfile.QuickHack");
  };
  if Equals(mappinVariant, gamedataMappinVariant.Zzz15_QuickHackDurationVariant) {
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\interaction\\quick_hack_duration_mappin.inkwidget", t"MappinUISpawnProfile.LongRange", t"WorldMappinUIProfile.QuickHack");
  };
  if Equals(mappinVariant, gamedataMappinVariant.PhoneCallVariant) {
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\interaction\\quick_hack_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
  };
  if Equals(mappinVariant, gamedataMappinVariant.Zzz04_PreventionVehicleVariant) {
    return MappinUIProfile.None();
  };
  if Equals(mappinVariant, gamedataMappinVariant.Zzz11_RoadBlockadeVariant) {
    return MappinUIProfile.None();
  };
  if Equals(mappinVariant, gamedataMappinVariant.VehicleVariant) || Equals(mappinVariant, gamedataMappinVariant.Zzz03_MotorcycleVariant) || Equals(mappinVariant, gamedataMappinVariant.Zzz19_DelamainTaxiVariant) || Equals(mappinVariant, gamedataMappinVariant.Zzz20_DelamainTaxiDestinationVariant) {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.LongRange", t"WorldMappinUIProfile.Vehicle");
  };
  if gameplayRoleData != null {
    if Equals(mappinVariant, gamedataMappinVariant.FocusClueVariant) {
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\gameplay\\gameplay_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"WorldMappinUIProfile.FocusClue");
    };
    if Equals(mappinVariant, gamedataMappinVariant.LootVariant) {
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\gameplay\\gameplay_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"WorldMappinUIProfile.Loot");
    };
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\mappins\\gameplay\\gameplay_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"WorldMappinUIProfile.GameplayRole");
  };
  if Equals(mappinVariant, gamedataMappinVariant.FastTravelVariant) {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", t"WorldMappinUIProfile.FastTravel");
  };
  if Equals(mappinVariant, gamedataMappinVariant.Zzz17_NCARTVariant) {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", t"WorldMappinUIProfile.FastTravel");
  };
  if Equals(mappinVariant, gamedataMappinVariant.ServicePointDropPointVariant) {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.ShortRange", t"WorldMappinUIProfile.DropPoint");
  };
  if Equals(mappinVariant, gamedataMappinVariant.Zzz10_RemoteControlDrivingVariant) {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.Always", t"WorldMappinUIProfile.RemoteControlDriving");
  };
  if mappin.IsQuestMappin() {
    questMappin = mappin as QuestMappin;
    if IsDefined(questMappin) {
      if questMappin.IsUIAnimation() {
        questAnimationRecord = TweakDBInterface.GetUIAnimationRecord(questMappin.GetUIAnimationRecordID());
        if IsDefined(questAnimationRecord) && ResRef.IsValid(questAnimationRecord.WidgetResource()) && NotEquals(questAnimationRecord.AnimationName(), n"None") && IsDefined(questAnimationRecord.ProfileHandle()) {
          return MappinUIProfile.Create(questAnimationRecord.WidgetResource(), t"MappinUISpawnProfile.Always", questAnimationRecord.ProfileHandle().GetID());
        };
      } else {
        return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.Always", t"WorldMappinUIProfile.Quest");
      };
    };
  };
  if customData != null && (customData as TrackedMappinControllerCustomData) != null {
    return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
  };
  return MappinUIProfile.Create(defaultWidgetResource, t"MappinUISpawnProfile.MediumRange", defaultRuntimeProfile);
}

@wrapMethod(MinimapContainerController)
public func CreateMappinUIProfile(mappin: wref<IMappin>, mappinVariant: gamedataMappinVariant, customData: ref<MappinControllerCustomData>) -> MappinUIProfile {
  if !OpxQuestsMappin(mappin, mappinVariant, customData) {
    return wrappedMethod(mappin, mappinVariant, customData);
  };
  let questMappin: wref<QuestMappin>;
  let roleData: ref<GameplayRoleMappinData>;
  let defaultRuntimeProfile: TweakDBID = t"MinimapMappinUIProfile.Default";
  if customData != null && (customData as MinimapQuestAreaInitData) != null {
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_quest_area_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
  };
  if mappin.IsExactlyA(n"gamemappinsPointOfInterestMappin") {
    if Equals(mappinVariant, gamedataMappinVariant.Zzz09_CourierSandboxActivityVariant) {
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_courier_mappin.inkwidget", t"MappinUISpawnProfile.MediumRange", t"MinimapMappinUIProfile.Courier");
    };
    if Equals(mappinVariant, gamedataMappinVariant.Zzz12_WorldEncounterVariant) {
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_world_encounter_mappin.inkwidget", t"MappinUISpawnProfile.WorldEncounter", defaultRuntimeProfile);
    };
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.ShortRange", defaultRuntimeProfile);
  };
  roleData = mappin.GetScriptData() as GameplayRoleMappinData;
  if roleData != null {
    return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_device_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"MinimapMappinUIProfile.GameplayRole");
  };
  switch mappinVariant {
    case gamedataMappinVariant.FastTravelVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.ShortRange", t"MinimapMappinUIProfile.FastTravel");
    case gamedataMappinVariant.Zzz17_NCARTVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.ShortRange", t"MinimapMappinUIProfile.FastTravel");
    case gamedataMappinVariant.ServicePointDropPointVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.ShortRange", t"MinimapMappinUIProfile.DropPoint");
    case gamedataMappinVariant.Zzz19_DelamainTaxiVariant:
    case gamedataMappinVariant.Zzz03_MotorcycleVariant:
    case gamedataMappinVariant.VehicleVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"MinimapMappinUIProfile.Vehicle");
    case gamedataMappinVariant.Zzz04_PreventionVehicleVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_prevention_vehicle.inkwidget", t"MappinUISpawnProfile.Always", t"MinimapMappinUIProfile.PreventionVehicle");
    case gamedataMappinVariant.Zzz11_RoadBlockadeVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_road_blockade.inkwidget", t"MappinUISpawnProfile.Always", t"MinimapMappinUIProfile.PreventionVehicle");
    case gamedataMappinVariant.CustomPositionVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
    case gamedataMappinVariant.Zzz20_DelamainTaxiDestinationVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_delamain_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
    case gamedataMappinVariant.Zzz16_RelicDeviceBasicVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.ShortRange", defaultRuntimeProfile);
    case gamedataMappinVariant.ExclamationMarkVariant:
      if mappin.IsQuestMappin() {
        questMappin = mappin as QuestMappin;
        if IsDefined(questMappin) && questMappin.IsUIAnimation() {
          break;
        };
        if mappin.IsQuestEntityMappin() || mappin.IsQuestNPCMappin() {
          return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_quest_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"MinimapMappinUIProfile.Quest");
        };
      } else {
        if customData != null && (customData as TrackedMappinControllerCustomData) != null {
          return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
        };
      };
      break;
    case gamedataMappinVariant.DefaultQuestVariant:
      if mappin.IsQuestMappin() {
        questMappin = mappin as QuestMappin;
        if IsDefined(questMappin) && questMappin.IsUIAnimation() {
          break;
        };
        if mappin.IsQuestEntityMappin() || mappin.IsQuestNPCMappin() {
          return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_quest_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"MinimapMappinUIProfile.Quest");
        };
      };
      break;
    case gamedataMappinVariant.HazardWarningVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_hazard_warning_mappin.inkwidget", t"MappinUISpawnProfile.ShortRange", defaultRuntimeProfile);
    case gamedataMappinVariant.DynamicEventVariant:
      return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_dynamic_event_mappin.inkwidget", t"MappinUISpawnProfile.MediumRange", defaultRuntimeProfile);
    default:
      if mappin.IsExactlyA(n"gamemappinsStealthMappin") {
        return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_stealth_mappin.inkwidget", t"MappinUISpawnProfile.Stealth", t"MinimapMappinUIProfile.Stealth");
      };
      if mappin.IsExactlyA(n"gamemappinsStubMappin") {
        return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_stub_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
      };
      if customData != null && (customData as TrackedMappinControllerCustomData) != null {
        return MappinUIProfile.Create(r"base\\gameplay\\gui\\widgets\\minimap\\minimap_poi_mappin.inkwidget", t"MappinUISpawnProfile.Always", defaultRuntimeProfile);
      };
  };
  return MappinUIProfile.None();
}

// The fullscreen map's markers. Each one the map asks about is written to the
// log BEFORE it is judged -- from its init data's class and its variant, which
// are read without touching the marker -- so a crash inside the judging names
// the marker that caused it (the first eight of each opening are written).
@addField(WorldMapMenuGameController)
public let m_opxMapMarkers: Int32;

@wrapMethod(WorldMapMenuGameController)
public func CreateMappinUIProfile(mappin: wref<IMappin>, mappinVariant: gamedataMappinVariant, customData: ref<MappinControllerCustomData>) -> MappinUIProfile {
  if this.m_opxMapMarkers < 8 {
    this.m_opxMapMarkers += 1;
    OpxQuestsMapTrace("marker asked " + ToString(this.m_opxMapMarkers) + ": "
      + (IsDefined(customData) ? NameToString(customData.GetClassName()) : "no init data") + ", "
      + EnumValueToString("gamedataMappinVariant", Cast<Int64>(EnumInt(mappinVariant))));
  };
  // A runtime marker -- the player's arrow, the waypoint, a server's blip -- is
  // never a quest marker (its class answers `IsQuestMappin` with no), and the
  // map has no scanner clue: nothing here needs anything from it, so nothing
  // is asked of it. The class test reads the object's type only. The arrow's
  // init data is judged inside the gate, before it touches any marker.
  if !IsDefined(mappin) || mappin.IsExactlyA(n"gamemappinsRuntimeMappin")
      || !OpxQuestsMappin(mappin, mappinVariant, customData) {
    return wrappedMethod(mappin, mappinVariant, customData);
  };
  OpxQuestsMapTrace("marker " + NameToString(mappin.GetClassName()) + ":"
    + EnumValueToString("gamedataMappinVariant", Cast<Int64>(EnumInt(mappinVariant))));
  return MappinUIProfile.Create(r"base\\gameplay\\gui\\fullscreen\\world_map\\mappins\\default_mappin.inkwidget", t"MappinUISpawnProfile.Always", t"MapMappinUIProfile.Default");
}

// ------------------------------------------------------------ the map log ----
// THE FULLSCREEN MAP, STEP BY STEP, IN THE CLIENT LOG (1.4.14). Opening the map
// hard-crashed the game (reported 2026-09-29 from a second PC, reproduced on the
// owner's own). The crash probe's record (`red4ext/logs/open77-crash-probe.log`:
// an access violation, a read at 0x38, in `Cyberpunk2077.exe`) puts it about
// 80-120 ms after the platform's map setup began -- `map:composition=ready` is
// the last line the log holds. The cause was found in 1.4.15 (see "markers"
// above): the marker gate asked the map's own player arrow for its script data,
// and the arrow has none. The steps stay, because the log is what says WHERE a
// crash is, and a crash writes nothing after itself: these lines are the steps,
// in the order the map takes them, each written the moment it happens -- the
// last one in the log after a crash is the step the game died in.
//
//   map: opening            the game started the map's controller
//   map: tooltips hidden 1  the platform's setup got past its first natives
//   map: tooltips hidden 2  ... and past reading the map's tabs and text
//   map: opened             the platform's setup returned
//   map: reading the zoom levels / zoom levels N
//                           the platform's first per-frame tick reached, and
//                           returned from, the read of the map's zoom levels
//   map: scene attaching / scene attached
//                           the map's 3D scene attached to its controller
//   map: marker asked N: <init data class>, <variant>
//                           (1.4.15) the first eight markers the map asked
//                           about, written before each is judged
//   map: marker <class>:<variant>
//                           each quest marker the map was asked to draw
//   map: closed             the map's controller went away
//
// THIS CHANGES NOTHING ON THE MAP. Every wrapper below runs the wrapped method
// and returns exactly what it returned; the only thing added is a line in the
// log, and only in a multiplayer session. A method that is reached more than
// once (the zoom reads run every frame the map is open) is written on its first
// call only.
@addField(WorldMapMenuGameController)
public let m_opxMapZoomSeen: Bool;

@addField(WorldMapMenuGameController)
public let m_opxMapTooltipCalls: Int32;

public static func OpxQuestsMapTrace(line: String) -> Void {
  if Open77MultiplayerPolicyActive() {
    OpxQuestsTrace("map: " + line);
  };
}

@wrapMethod(WorldMapMenuGameController)
protected cb func OnInitialize() -> Bool {
  OpxQuestsMapTrace("opening");
  let result: Bool = wrappedMethod();
  OpxQuestsMapTrace("opened");
  return result;
}

@wrapMethod(WorldMapMenuGameController)
protected cb func OnUninitialize() -> Bool {
  let result: Bool = wrappedMethod();
  OpxQuestsMapTrace("closed");
  return result;
}

@wrapMethod(WorldMapMenuGameController)
protected cb func OnEntityAttached() -> Bool {
  OpxQuestsMapTrace("scene attaching");
  let result: Bool = wrappedMethod();
  OpxQuestsMapTrace("scene attached");
  return result;
}

// The platform's setup hides the tooltips twice: once first thing, and once
// after it has read the map's tabs. The first two calls are written, and they
// split the setup into its early natives, its tabs and text, and its legend and
// framing.
@wrapMethod(WorldMapMenuGameController)
private final func HideAllTooltips() -> Void {
  if this.m_opxMapTooltipCalls < 2 {
    this.m_opxMapTooltipCalls += 1;
    OpxQuestsMapTrace("tooltips hidden " + ToString(this.m_opxMapTooltipCalls));
  };
  wrappedMethod();
}

@wrapMethod(WorldMapMenuGameController)
private final func GetTotalZoomLevels() -> Int32 {
  if this.m_opxMapZoomSeen {
    return wrappedMethod();
  };
  this.m_opxMapZoomSeen = true;
  OpxQuestsMapTrace("reading the zoom levels");
  let levels: Int32 = wrappedMethod();
  OpxQuestsMapTrace("zoom levels " + ToString(levels));
  return levels;
}

// ---------------------------------------------------------- quest toasts ----
// "New quest", "quest updated", "quest completed" and the tracked activity:
// the base game's own bodies (2.31 `JournalNotificationQueue`), which react to
// live journal changes only. The whole toast stack is the `vanillaNotifications`
// HUD component (config/hud.lua).
@wrapMethod(JournalNotificationQueue)
protected cb func OnJournalUpdate(hash: Uint32, className: CName, notifyOption: JournalNotifyOption, changeType: JournalChangeType) -> Bool {
  let player: ref<GameObject> = this.GetPlayerControlledObject();
  if !OpxQuestsOnFor(player) || !IsDefined(this.m_journalMgr) {
    return wrappedMethod(hash, className, notifyOption, changeType);
  };
  let entry: wref<JournalEntry>;
  let entryQuest: wref<JournalQuest>;
  let removeRequest: ref<JournalEntryNotificationRemoveRequestData>;
  let state: gameJournalEntryState;
  let stateFinished: Bool;
  let tarotAddedEvent: ref<TarotCardAdded>;
  let tarotEntry: wref<JournalTarot>;
  switch className {
    case n"gameJournalQuest":
      entry = this.m_journalMgr.GetEntry(hash);
      entryQuest = entry as JournalQuest;
      state = this.m_journalMgr.GetEntryState(entry);
      stateFinished = Equals(state, gameJournalEntryState.Succeeded) || Equals(state, gameJournalEntryState.Failed);
      if Equals(notifyOption, JournalNotifyOption.Notify) && entryQuest != null {
        OpxQuestsTrace("quest " + EnumValueToString("gameJournalEntryState", Cast<Int64>(EnumInt(state))) + ": "
          + entryQuest.GetTitle(this.m_journalMgr));
        this.PushQuestNotification(entryQuest, state);
        if stateFinished {
          removeRequest = new JournalEntryNotificationRemoveRequestData();
          removeRequest.entryHash = Cast<Uint32>(this.m_journalMgr.GetEntryHash(entryQuest));
          this.RemoveNotification(removeRequest);
        };
      };
      break;
    case n"gameJournalTarot":
      entry = this.m_journalMgr.GetEntry(hash);
      tarotEntry = entry as JournalTarot;
      if IsDefined(tarotEntry) {
        tarotAddedEvent = new TarotCardAdded();
        tarotAddedEvent.imagePart = tarotEntry.GetImagePart();
        tarotAddedEvent.cardName = tarotEntry.GetName();
        GameInstance.GetUISystem(player.GetGame()).QueueEvent(tarotAddedEvent);
      };
      break;
    default:
  };
  return true;
}

@wrapMethod(JournalNotificationQueue)
protected cb func OnTrackedMappinUpdated(value: Variant) -> Bool {
  let mappin: wref<IMappin> = FromVariant<ref<IScriptable>>(value) as IMappin;
  // A quest's own marker only: a waypoint or the map's pick-and-travel pin keeps
  // the platform's silence.
  if !OpxQuestsOnFor(this.GetPlayerControlledObject()) || !IsDefined(mappin) || !mappin.IsQuestMappin() {
    return wrappedMethod(value);
  };
  let mappinText: String;
  let notificationData: gameuiGenericNotificationData;
  let objectiveText: String;
  let userData: ref<QuestUpdateNotificationViewData>;
  if IsDefined(mappin) {
    mappinText = NameToString(MappinUIUtils.MappinToString(mappin.GetVariant()));
    objectiveText = NameToString(MappinUIUtils.MappinToObjectiveString(mappin.GetVariant()));
    userData = new QuestUpdateNotificationViewData();
    userData.title = mappinText;
    userData.text = objectiveText;
    userData.soundEvent = n"QuestNewPopup";
    userData.soundAction = n"OnOpen";
    userData.animation = n"notification_new_activity";
    userData.canBeMerged = false;
    userData.priority = EGenericNotificationPriority.Height;
    notificationData.widgetLibraryItemName = n"notification_new_activity";
    notificationData.notificationData = userData;
    notificationData.time = this.m_showDuration;
    this.AddNewNotificationData(notificationData);
  };
  return true;
}

@wrapMethod(JournalNotificationQueue)
protected cb func OnCustomQuestNotificationUpdate(value: Variant) -> Bool {
  if !OpxQuestsOnFor(this.GetPlayerControlledObject()) {
    return wrappedMethod(value);
  };
  let notificationData: gameuiGenericNotificationData;
  let data: CustomQuestNotificationData = FromVariant<CustomQuestNotificationData>(value);
  let userData: ref<QuestUpdateNotificationViewData> = new QuestUpdateNotificationViewData();
  userData.text = GetLocalizedText(data.desc);
  userData.title = GetLocalizedText(data.header);
  userData.soundEvent = n"QuestUpdatePopup";
  userData.soundAction = n"OnOpen";
  userData.animation = n"notification_quest_completed";
  userData.canBeMerged = true;
  notificationData.time = this.m_showDuration;
  notificationData.widgetLibraryItemName = this.m_questNotification;
  notificationData.notificationData = userData;
  this.AddNewNotificationData(notificationData);
  return true;
}

// ----------------------------------------------------------------- loot ----
// A quest's own items. The platform hides every base-game lootable and empties
// the ones the player looks at; for a QUEST owner (a quest container, body,
// bag or pickup -- the base game's own `IsQuest()`: marked by the quest, or
// holding a quest item) the quest's items are offered again, through the base
// game's own bodies. Only the items a mission hands over: anything tagged
// `Quest`, keycards and shards. Weapons, ammunition, consumables and junk stay
// with the server's economy, invisible as the platform decided.
public static func OpxQuestsQuestOwner(owner: ref<GameObject>) -> Bool {
  return IsDefined(owner) && owner.IsQuest() && !OpxQuestsIsPlayerProxy(owner)
    && !Open77LootIsManaged(owner.GetEntityID()) && OpxQuestsOn(owner.GetGame());
}

public static func OpxQuestsQuestItem(itemData: wref<gameItemData>) -> Bool {
  if !IsDefined(itemData) {
    return false;
  };
  if itemData.HasTag(n"Quest") {
    return true;
  };
  let itemType: gamedataItemType = itemData.GetItemType();
  return Equals(itemType, gamedataItemType.Gen_Keycard) || Equals(itemType, gamedataItemType.Gen_Readable);
}

// A pickup lying in the world whose item is a quest item, marked or not yet.
public static func OpxQuestsQuestDrop(drop: ref<gameItemDropObject>) -> Bool {
  if !IsDefined(drop) {
    return false;
  };
  let object: wref<ItemObject> = drop.GetItemObject();
  let quest: Bool = drop.IsQuest()
    || IsDefined(object) && IsDefined(object.GetItemData()) && object.GetItemData().HasTag(n"Quest");
  return quest && !Open77LootIsManaged(drop.GetEntityID()) && OpxQuestsOn(drop.GetGame());
}

@wrapMethod(Inventory)
public func IsChoiceAvailable(itemActionRecord: wref<ItemAction_Record>, requester: ref<GameObject>, ownerEntID: EntityID, itemID: ItemID) -> gameinteractionsELootChoiceType {
  let owner: ref<GameObject> = this.GetEntity() as GameObject;
  if !OpxQuestsQuestOwner(owner) {
    return wrappedMethod(itemActionRecord, requester, ownerEntID, itemID);
  };
  if !IsDefined(itemActionRecord) || !IsDefined(requester) || !ItemID.IsValid(itemID) {
    return gameinteractionsELootChoiceType.Invisible;
  };
  let itemData: wref<gameItemData> = RPGManager.GetItemData(requester.GetGame(), owner, itemID);
  if !OpxQuestsQuestItem(itemData) || IsDefined(TweakDBInterface.GetConsumableItemRecord(ItemID.GetTDBID(itemID))) {
    return gameinteractionsELootChoiceType.Invisible;
  };
  let emptyContext: GetActionsContext;
  let action: ref<BaseItemAction> = ItemActionsHelper.SetupItemAction(requester.GetGame(), requester, itemData, itemActionRecord.GetID(), false);
  if IsDefined(action) && action.IsVisible(emptyContext) {
    return gameinteractionsELootChoiceType.Available;
  };
  return gameinteractionsELootChoiceType.Invisible;
}

@addField(GameObject)
public let m_opxQuestsTakenAt: Float;

@wrapMethod(Inventory)
protected cb func OnInteractionUsed(evt: ref<InteractionChoiceEvent>) -> Bool {
  let gameObject: ref<GameObject> = this.GetEntity() as GameObject;
  if !IsDefined(evt) || !OpxQuestsQuestOwner(gameObject) {
    return wrappedMethod(evt);
  };
  let lootActionWrapper: LootChoiceActionWrapper = LootChoiceActionWrapper.Unwrap(evt);
  if !LootChoiceActionWrapper.IsValid(lootActionWrapper)
      || !OpxQuestsQuestItem(RPGManager.GetItemData(gameObject.GetGame(), gameObject, lootActionWrapper.itemId)) {
    return wrappedMethod(evt);
  };
  // 2.31 `Inventory.OnInteractionUsed` (less the keyboard-lighting cue).
  let broadcaster: ref<StimBroadcasterComponent>;
  let itemData: wref<gameItemData>;
  let player: ref<PlayerPuppet> = evt.activator as PlayerPuppet;
  if IsDefined(player) && player.IsInCombat() && IsDefined(TweakDBInterface.GetConsumableItemRecord(ItemID.GetTDBID(lootActionWrapper.itemId))) {
    return false;
  };
  if LootChoiceActionWrapper.IsIllegal(lootActionWrapper) && IsDefined(evt.activator) {
    broadcaster = evt.activator.GetStimBroadcasterComponent();
    if IsDefined(broadcaster) {
      broadcaster.TriggerSingleBroadcast(gameObject, gamedataStimType.IllegalInteraction);
    };
  };
  gameObject.m_opxQuestsTakenAt = OpxQuestsNow(gameObject.GetGame());
  if IsDefined(evt.activator) {
    evt.activator.m_opxQuestsTakenAt = gameObject.m_opxQuestsTakenAt;
  };
  if RPGManager.ConsumeItem(gameObject, evt) {
    GameInstance.GetAudioSystem(gameObject.GetGame()).PlayItemActionSound(lootActionWrapper.action, RPGManager.GetItemData(gameObject.GetGame(), gameObject, lootActionWrapper.itemId));
    return false;
  };
  itemData = RPGManager.GetItemData(gameObject.GetGame(), gameObject, lootActionWrapper.itemId);
  if Equals(lootActionWrapper.action, n"Learn") {
    ItemActionsHelper.LearnItem(evt.activator, lootActionWrapper.itemId, false);
  };
  if Equals(LootChoiceActionWrapper.IsHandledByCode(lootActionWrapper), false) {
    GameInstance.GetTransactionSystem(gameObject.GetGame()).RemoveItem(gameObject, lootActionWrapper.itemId, 1);
  };
  GameInstance.GetAudioSystem(gameObject.GetGame()).PlayItemActionSound(lootActionWrapper.action, itemData);
  OpxQuestsTrace("took a quest item: " + TDBID.ToStringDEBUG(ItemID.GetTDBID(lootActionWrapper.itemId)));
  return false;
}

// A pickup in the world (2.31 `LootPickupScriptedCondition.Test`, less its
// grenade and healing-charge branch: a quest item is neither).
@wrapMethod(LootPickupScriptedCondition)
public const func Test(activatorObject: wref<GameObject>, hotSpotObject: wref<GameObject>) -> Bool {
  let itemDropObject: ref<gameItemDropObject> = hotSpotObject as gameItemDropObject;
  if !OpxQuestsQuestDrop(itemDropObject) {
    return wrappedMethod(activatorObject, hotSpotObject);
  };
  let player: ref<PlayerPuppet> = activatorObject as PlayerPuppet;
  let itemObject: ref<ItemObject> = itemDropObject.GetItemObject();
  if !IsDefined(player) || !IsDefined(itemObject) || !IsDefined(itemObject.GetItemData()) {
    return true;
  };
  let weaponObject: ref<WeaponObject> = itemObject as WeaponObject;
  if IsDefined(weaponObject) {
    let weaponRecord: ref<WeaponItem_Record> = weaponObject.GetWeaponRecord();
    if IsDefined(weaponRecord) && Equals(weaponRecord.EquipArea().Type(), gamedataEquipmentArea.WeaponHeavy) {
      if player.GetPlayerStateMachineBlackboard().GetBool(GetAllBlackboardDefs().PlayerStateMachine.Carrying) {
        return false;
      };
    };
  };
  return true;
}

@wrapMethod(gameLootContainerBase)
public const func IsContainer() -> Bool {
  if OpxQuestsQuestOwner(this) {
    return !this.IsEmpty() && !this.IsDisabled();
  };
  return wrappedMethod();
}

@wrapMethod(gameItemDropObject)
public const func IsContainer() -> Bool {
  if OpxQuestsQuestDrop(this) {
    return !this.IsEmpty();
  };
  return wrappedMethod();
}

@wrapMethod(gameLootBag)
public const func IsContainer() -> Bool {
  if OpxQuestsQuestOwner(this) {
    return !this.IsEmpty();
  };
  return wrappedMethod();
}

@wrapMethod(ScriptedPuppet)
public const func IsContainer() -> Bool {
  if OpxQuestsQuestOwner(this) {
    return NotEquals(this.m_lootQuality, gamedataQuality.Invalid) && NotEquals(this.m_lootQuality, gamedataQuality.Random);
  };
  return wrappedMethod();
}

// A quest pickup that streams in is not handed to the platform's retirement
// queue at spawn (2.31 `gameItemDropObject.OnItemEntitySpawned`).
@wrapMethod(gameItemDropObject)
protected func OnItemEntitySpawned(entID: EntityID) -> Void {
  let object: wref<ItemObject> = this.GetItemObject();
  if OpxQuestsQuestDrop(this) {
    this.SetQualityRangeInteractionLayerState(true);
    this.EvaluateLootQualityEvent(entID);
    if IsDefined(object) {
      this.m_spawnedItemID = object.GetItemID();
    };
    this.RequestHUDRefresh();
    return;
  };
  wrappedMethod(entID);
}

// The one path left: the platform's own sweep notes EVERY pickup within 40 m of
// the player every couple of seconds and empties it -- a quest's package with
// the rest -- and it is a platform function nothing here can reach. When a
// quest item leaves a pickup near the player and it was not the player taking
// it, it is put into the player's inventory instead of vanishing: the mission
// goes on as if it had been picked up.
// Never a second copy: nothing is given when the player already holds that
// item (they picked it up, or a quest handed it over), when the player took
// something from a quest owner in the last three seconds, or when this record
// was already handed over once this session (a pickup the level streams in
// again and the sweep empties again).
public class OpxQuestsGiveBack extends DelayCallback {
  public let game: GameInstance;
  public let itemID: ItemID;

  public func Call() -> Void {
    let player: ref<GameObject> = GameInstance.GetPlayerSystem(this.game).GetLocalPlayerMainGameObject();
    let state: ref<OpxQuestsSystem> = OpxQuestsState(this.game);
    if !IsDefined(player) || !IsDefined(state) || !OpxQuestsOn(this.game) {
      return;
    };
    let record: TweakDBID = ItemID.GetTDBID(this.itemID);
    if ArrayContains(state.givenIds, record) {
      return;
    };
    if player.m_opxQuestsTakenAt > 0.0 && OpxQuestsNow(this.game) - player.m_opxQuestsTakenAt < 3.0 {
      return;
    };
    let transaction: ref<TransactionSystem> = GameInstance.GetTransactionSystem(this.game);
    if transaction.HasItem(player, this.itemID) || transaction.GetItemQuantity(player, ItemID.FromTDBID(record)) > 0 {
      return;
    };
    if transaction.GiveItem(player, this.itemID, 1) {
      ArrayPush(state.givenIds, record);
      state.given += 1;
      OpxQuestsTrace("the session emptied a quest pickup; its item went to the player instead: "
        + TDBID.ToStringDEBUG(record));
    };
  }
}

@wrapMethod(gameItemDropObject)
protected cb func OnItemRemoveddEvent(evt: ref<ItemBeingRemovedEvent>) -> Bool {
  let quest: Bool = IsDefined(evt) && ItemID.IsValid(evt.itemID) && this.IsQuest()
    && IsDefined(evt.itemData) && evt.itemData.HasTag(n"Quest");
  let result: Bool = wrappedMethod(evt);
  if !quest || Open77LootIsManaged(this.GetEntityID()) || !OpxQuestsOn(this.GetGame()) {
    return result;
  };
  let player: ref<GameObject> = GameInstance.GetPlayerSystem(this.GetGame()).GetLocalPlayerMainGameObject();
  if !IsDefined(player) || Vector4.Distance(player.GetWorldPosition(), this.GetWorldPosition()) > 50.0 {
    return result;
  };
  let back: ref<OpxQuestsGiveBack> = new OpxQuestsGiveBack();
  back.game = this.GetGame();
  back.itemID = evt.itemID;
  GameInstance.GetDelaySystem(this.GetGame()).DelayCallback(back, 0.5, false);
  return result;
}

// -------------------------------------------------------------- scanner ----
// The scanner (clues, braindances, quickhack steps), while the server leaves
// the `scanner` HUD component on (config/hud.lua). The base game's own bodies
// (2.31 `PlayerVisionModeController`, `VisionContextDecisions`); the base game
// still asks for eye cyberware, as it always did. Other players' bodies are
// never scanned or hacked (see the proxy guard below).
public static func OpxQuestsScannerOn(owner: ref<GameObject>) -> Bool {
  return OpxQuestsOnFor(owner) && Open77HudComponentVisible(9);
}

@wrapMethod(PlayerVisionModeController)
protected cb func OnAction(action: ListenerAction, consumer: ListenerActionConsumer) -> Bool {
  if !OpxQuestsScannerOn(this.m_owner) {
    return wrappedMethod(action, consumer);
  };
  let evt: ref<ToggleNewPlayerFlashlightEvent>;
  let time: Float = EngineTime.ToFloat(GameInstance.GetEngineTime(this.m_owner.GetGame()));
  if Equals(ListenerAction.GetName(action), this.m_inputActionsNames.m_buttonToggle) {
    if ListenerAction.GetValue(action) > 0.00 {
      this.m_inputActiveFlags.m_buttonToggle = !this.m_inputActiveFlags.m_buttonToggle;
      if this.m_inputActiveFlags.m_buttonToggle && this.m_inputActiveFlags.m_buttonHold {
        this.m_otherVars.m_toggledDuringHold = true;
      };
    };
    this.VerifyActivation();
  } else {
    if Equals(ListenerAction.GetName(action), this.m_inputActionsNames.m_buttonHold) {
      if !IsFinal() {
        if ListenerAction.IsButtonJustPressed(action) {
          this.m_otherVars.m_buttonHoldPressTime = time;
          if time >= this.m_otherVars.m_buttonHoldTapTime + 0.20 {
            this.m_otherVars.m_buttonHoldTapCount = 0;
          };
          if this.m_otherVars.m_buttonHoldTapCount % 2 == 1 {
            evt = new ToggleNewPlayerFlashlightEvent();
            GetPlayer(this.m_owner.GetGame()).QueueEvent(evt);
            return true;
          };
        } else {
          if ListenerAction.IsButtonJustReleased(action) && time < this.m_otherVars.m_buttonHoldPressTime + 0.20 {
            this.m_otherVars.m_buttonHoldTapTime = time;
            this.m_otherVars.m_buttonHoldTapCount += 1;
          };
        };
      };
      if ListenerAction.GetValue(action) > 0.00 {
        this.m_inputActiveFlags.m_buttonHold = true;
        this.m_otherVars.m_toggledDuringHold = false;
      } else {
        this.m_inputActiveFlags.m_buttonHold = false;
        if !this.m_otherVars.m_toggledDuringHold {
          this.m_inputActiveFlags.m_buttonToggle = false;
        };
      };
      this.VerifyActivation();
    } else {
      if Equals(ListenerAction.GetName(action), this.m_inputActionsNames.m_driverCombatButtonHold) {
        if Equals(ListenerAction.GetType(action), gameinputActionType.BUTTON_PRESSED) {
          if this.IsPlayerInDriverCombat() {
            this.m_inputActiveFlags.m_driverCombatButtonHold = true;
          };
        } else {
          if Equals(ListenerAction.GetType(action), gameinputActionType.BUTTON_RELEASED) {
            this.m_inputActiveFlags.m_driverCombatButtonHold = false;
            this.m_inputActiveFlags.m_driverCombatButtonActivate = false;
          };
        };
        this.VerifyActivation();
      } else {
        if Equals(ListenerAction.GetName(action), this.m_inputActionsNames.m_driverCombatButtonActivate) {
          if ListenerAction.IsButtonJustPressed(action) {
            if this.m_inputActiveFlags.m_driverCombatButtonHold {
              this.m_inputActiveFlags.m_driverCombatButtonActivate = true;
            };
          };
          this.VerifyActivation();
        };
      };
    };
  };
  return false;
}

@wrapMethod(PlayerVisionModeController)
private final func VerifyActivation() -> Void {
  if !OpxQuestsScannerOn(this.m_owner) {
    wrappedMethod();
    return;
  };
  let active: Bool;
  let inputActive: Bool = !this.m_inputActiveFlags.m_driverCombatButtonHold && this.m_inputActiveFlags.m_buttonHold || this.m_inputActiveFlags.m_buttonToggle || this.m_inputActiveFlags.m_driverCombatButtonHold && this.m_inputActiveFlags.m_driverCombatButtonActivate;
  let forced: Bool = this.m_gameplayActiveFlags.m_braindanceActive && !this.m_gameplayActiveFlags.m_braindanceFPP || this.m_gameplayActiveFlags.m_twintoneOverrideShown;
  this.m_gameplayActiveFlags.m_hasNotCybereye = !RPGManager.HasStatFlag(this.m_owner, gamedataStatType.HasCybereye);
  this.m_gameplayActiveFlags.m_isPhotoMode = GameInstance.GetPhotoModeSystem(this.m_owner.GetGame()).IsPhotoModeActive();
  let isScannerVisibility: worlduiEntryVisibility = GameInstance.GetUISystem(this.m_owner.GetGame()).GetHudEntryForcedVisibility(n"scanner");
  let isScannerForceHidden: Bool = Equals(isScannerVisibility, worlduiEntryVisibility.ForceHide);
  if !forced && (!inputActive || this.m_gameplayActiveFlags.m_kerenzikov || this.m_gameplayActiveFlags.m_restrictedScene || this.m_gameplayActiveFlags.m_dead || this.m_gameplayActiveFlags.m_takedown || this.m_gameplayActiveFlags.m_deviceTakeover || this.m_gameplayActiveFlags.m_braindanceActive || this.m_gameplayActiveFlags.m_isBriefingActive || this.m_gameplayActiveFlags.m_veryHardLanding || this.m_gameplayActiveFlags.m_noScanningRestriction || this.m_gameplayActiveFlags.m_hasNotCybereye || this.m_gameplayActiveFlags.m_isPhotoMode || isScannerForceHidden) {
    active = false;
  } else {
    active = true;
  };
  this.InvalidateActivationState(active);
}

@wrapMethod(PlayerVisionModeController)
public final func OnInvalidateActiveState(evt: ref<PlayerVisionModeControllerInvalidateEvent>) -> Void {
  if !IsDefined(evt) || !OpxQuestsScannerOn(this.m_owner) {
    wrappedMethod(evt);
    return;
  };
  if NotEquals(this.m_otherVars.m_active, evt.m_active) {
    this.m_otherVars.m_active = evt.m_active;
    if evt.m_active {
      this.ActivateVisionMode();
    } else {
      this.DeactivateVisionMode();
    };
  };
  this.ProcessFlagsRefreshPolicy();
}

@wrapMethod(VisionContextDecisions)
protected const func EnterCondition(const stateContext: ref<StateContext>, const scriptInterface: ref<StateGameScriptInterface>) -> Bool {
  if !IsDefined(scriptInterface) || !OpxQuestsScannerOn(scriptInterface.executionOwner) {
    return wrappedMethod(stateContext, scriptInterface);
  };
  let vehicleID: EntityID = scriptInterface.localBlackboard.GetEntityID(GetAllBlackboardDefs().PlayerStateMachine.EntityIDVehicleRemoteControlled);
  if EntityID.IsDefined(vehicleID) {
    return false;
  };
  if this.m_isFocusing {
    return true;
  };
  if this.m_visionHoldPressed && !stateContext.GetBoolParameter(n"lockHoldInput", true) {
    return true;
  };
  return false;
}

// Another player's body is never scanned (it is a platform proxy built on a
// base-game character's record) and never hacked.
@wrapMethod(NPCPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  if OpxQuestsIsPlayerProxy(this) && IsDefined(this.m_scanningComponent) && OpxQuestsOnFor(this) {
    this.m_scanningComponent.SetBlocked(true);
  };
  return result;
}

@wrapMethod(ScriptedPuppet)
public const func IsQuickHackAble() -> Bool {
  if OpxQuestsIsPlayerProxy(this) && OpxQuestsOnFor(this) {
    return false;
  };
  return wrappedMethod();
}

// ---------------------------------------------------------------- doors ----
// A door the server's door resource owns drops every lock change made on this
// machine. A quest's own unlock and unseal go through with the platform's own
// public "applying" flag, so the door's state follows the mission ON THIS
// MACHINE; the open and close themselves stay the server's, and the server's
// next push of its own state wins (the fix for that is the server's: no door
// claimed where missions run).
@wrapMethod(DoorControllerPS)
public final func OnQuestForceUnlock(evt: ref<QuestForceUnlock>) -> EntityNotificationType {
  if Open77DoorNetworkManaged(this.GetMyEntityID()) && !this.Open77NetworkApplying && OpxQuestsOn(this.GetGameInstance()) {
    this.Open77NetworkApplying = true;
    let result: EntityNotificationType = wrappedMethod(evt);
    this.Open77NetworkApplying = false;
    OpxQuestsTrace("a quest unlocked a server-owned door");
    return result;
  };
  return wrappedMethod(evt);
}

@wrapMethod(DoorControllerPS)
public final func OnQuestForceUnseal(evt: ref<QuestForceUnseal>) -> EntityNotificationType {
  if Open77DoorNetworkManaged(this.GetMyEntityID()) && !this.Open77NetworkApplying && OpxQuestsOn(this.GetGameInstance()) {
    this.Open77NetworkApplying = true;
    let result: EntityNotificationType = wrappedMethod(evt);
    this.Open77NetworkApplying = false;
    OpxQuestsTrace("a quest unsealed a server-owned door");
    return result;
  };
  return wrappedMethod(evt);
}

// ------------------------------------------------------------ V's lines ----
// V's own lines in a conversation. The platform drops every line V speaks and
// cuts its audio (free-roam barks, and a remote player's body speaking with
// V's voice). While this machine's player is in a conversation or a scene, the
// lines V speaks as a character -- a dialogue line or a holocall -- are shown
// here through the base game's own loop (2.31
// `BaseSubtitlesGameController.ShowDialogLines`), with their speaker, and never
// reach the platform's filter, so neither their subtitle nor their voice is
// cut. Every other line goes through the platform as before: other players'
// bodies stay mute.
@wrapMethod(BaseSubtitlesGameController)
public func ShowDialogLines(const linesToShow: script_ref<array<scnDialogLineData>>) -> Void {
  let player: ref<PlayerPuppet> = this.GetPlayerControlledObject() as PlayerPuppet;
  if !OpxQuestsOnFor(player) {
    wrappedMethod(linesToShow);
    return;
  };
  let scenes: ref<SceneSystemInterface> = GameInstance.GetSceneSystem(player.GetGame()).GetScriptInterface();
  let talking: Bool = IsDefined(scenes)
    && (scenes.IsEntityInDialogue(player.GetEntityID()) || scenes.IsEntityInScene(player.GetEntityID()));
  if !talking {
    wrappedMethod(linesToShow);
    return;
  };
  let others: array<scnDialogLineData>;
  let ours: Int32 = 0;
  let i: Int32 = 0;
  while i < ArraySize(Deref(linesToShow)) {
    let line: scnDialogLineData = Deref(linesToShow)[i];
    let speaker: wref<GameObject> = line.speaker;
    if IsDefined(speaker) && speaker == player
        && (Equals(line.type, scnDialogLineType.Regular) || Equals(line.type, scnDialogLineType.Holocall)) {
      ours += 1;
      // The base game's own test for this line: subtitles switched off in the
      // settings show nothing, then the controller's own display rule, once.
      if !this.m_disabledBySettings && this.ShouldDisplayLine(line) && !ArrayContains(this.m_pendingShowLines, line.id) {
        ArrayPush(this.m_pendingShowLines, line.id);
        this.SpawnDialogLine(line);
      };
    } else {
      ArrayPush(others, line);
    };
    i += 1;
  };
  if ours == 0 {
    wrappedMethod(linesToShow);
    return;
  };
  // The rest through the platform; its loop ends with the base game's own
  // `CalculateVisibility`, which now counts V's lines too.
  wrappedMethod(others);
}

// -------------------------------------------------------- loading screens ----
// Every engine loading screen, in the Open77 client log: when one starts and
// when its bar is full. A player "stuck on a loading screen" is then one of
// two things the log tells apart -- the game's own load never finished, or it
// did and something stayed over it.
@addField(LoadingScreenProgressBarController)
public let m_opxQuestsFull: Bool;

@wrapMethod(LoadingScreenProgressBarController)
public func SetProgress(progress: Float) -> Void {
  wrappedMethod(progress);
  if progress >= 0.999 {
    if !this.m_opxQuestsFull {
      this.m_opxQuestsFull = true;
      OpxQuestsTrace("an engine loading screen reached 100%");
    };
  } else {
    if this.m_opxQuestsFull || progress <= 0.001 {
      this.m_opxQuestsFull = false;
      OpxQuestsTrace("an engine loading screen is up");
    };
  };
}

// -------------------------------------------------------- Phantom Liberty ----
// WHY DOGTOWN WAS EMPTY (reported 2026-09-28 on a female V: "the NPCs are gone
// and I can't start the quest"). Open77 enters every session on one of two
// bundled saves, picked by the body the player chose. The male one,
// `NCMP-Template-M`, has Phantom Liberty under way: `ep1_active = 1`,
// `ep1_side_content = 1`, q301 and q302 done. The female one, `NCMP-Template-F`,
// is a save from just after the prologue, before The Heist, which never started
// it: both facts read 0. In the base game's own graph (2.31,
// `ep1\quest\ep1.questphase` and the phases under `ep1\openworld`) nearly all of
// Dogtown except its crowd and traffic waits on those two facts:
//
//   * `ep1_active`: the story (`ep1_main_quests`: q301 starts with Songbird's
//     holocall and "get to Dogtown"); Dogtown's world, combat and quest
//     communities (the Barghest, the stadium, the markets, the Heavy Hearts);
//     its vendors, world stories and encounters; the expansion's minor quests;
//   * `ep1_side_content`: the combat zone gate; street stories and gigs; air
//     drops and courier runs; convoys, drones and dynamic events; the other
//     vendors; the Heavy Hearts' lights and music.
//
// The base game writes `ep1_active` only once the Voodoo Boys' q110 is reached
// (`q110b`, and a fix-up in `base\quest\bugfixing` for saves past it) or in a
// new Phantom Liberty game, and `ep1_side_content` in q302's squat scene. A
// session starts over from the pristine save every time, so a female V could
// never get that far.
//
// WHAT THIS DOES. On a game with Phantom Liberty (`IsEP1()`), when the local
// body attaches in a session world, each of the two facts that reads 0 is set
// to 1 (the value the male save carries). The base game's graph does the rest:
// the communities spawn, the gate opens, and Songbird calls to start "Dog Eat
// Dog" (from 1.4.16 that call is refused, and from 1.4.17 the story itself
// waits: see "Songbird" below). A world that already has both facts (the male
// save) is left as it is.
// Nothing is saved: the session's world ends with the session. The two lines
// it writes to the client log say what it found, and a minute later whether
// the story started (`q301_started`).
public class OpxQuestsPhantomLibertyTick extends DelayCallback {
  public let game: GameInstance;
  public let report: Bool;
  public func Call() -> Void {
    if this.report {
      OpxQuestsPhantomLibertyReport(this.game);
    } else {
      OpxQuestsPhantomLiberty(this.game);
    };
  }
}

public static func OpxQuestsPhantomLiberty(game: GameInstance) -> Void {
  if !OpxQuestsOn(game) {
    return;
  };
  if !IsEP1() {
    OpxQuestsTrace("Phantom Liberty is not installed on this game: Dogtown stays as the base game has it");
    return;
  };
  let quests: ref<QuestsSystem> = GameInstance.GetQuestsSystem(game);
  let active: Int32 = quests.GetFact(n"ep1_active");
  let side: Int32 = quests.GetFact(n"ep1_side_content");
  if active >= 1 && side >= 1 {
    OpxQuestsTrace("Phantom Liberty: this world already has it (ep1_active " + ToString(active)
      + ", ep1_side_content " + ToString(side) + ")");
    return;
  };
  if active < 1 {
    quests.SetFact(n"ep1_active", 1);
  };
  if side < 1 {
    quests.SetFact(n"ep1_side_content", 1);
  };
  OpxQuestsTrace("Phantom Liberty opened on this world (ep1_active " + ToString(active)
    + " -> 1, ep1_side_content " + ToString(side) + " -> 1): Dogtown's people and its gate (the story waits"
    + " for opx_songbird_on: opx_songbird.archive keeps its main quests shut, and Songbird's call is refused)");
  let tick: ref<OpxQuestsPhantomLibertyTick> = new OpxQuestsPhantomLibertyTick();
  tick.game = game;
  tick.report = true;
  GameInstance.GetDelaySystem(game).DelayCallback(tick, 60.0, false);
}

public static func OpxQuestsPhantomLibertyReport(game: GameInstance) -> Void {
  let quests: ref<QuestsSystem> = GameInstance.GetQuestsSystem(game);
  let started: Int32 = quests.GetFact(n"q301_started");
  let on: Int32 = quests.GetFact(n"opx_songbird_on");
  let verdict: String;
  if started >= 1 {
    verdict = on >= 1 ? "opx_songbird_on is set: Dog Eat Dog began, as the base game has it"
      : "Dog Eat Dog began although opx_songbird_on is not set: this game is not running opx_songbird.archive"
        + " -- boot it through the launcher";
  } else {
    verdict = "the story waits, as it should: Dog Eat Dog has not begun and Songbird has not called";
  };
  OpxQuestsTrace("Phantom Liberty a minute on: ep1_active " + ToString(quests.GetFact(n"ep1_active"))
    + ", ep1_side_content " + ToString(quests.GetFact(n"ep1_side_content"))
    + ", q301_started " + ToString(started) + ", opx_songbird_on " + ToString(on) + " (" + verdict + ")");
}

// ------------------------------------------------------------- Songbird ----
// WHY (reported 2026-10-01: "the Songbird quest keeps popping up when I join,
// saying go to Dogtown"). Opening Phantom Liberty on a female V's world (1.4.13)
// starts its story too: some twenty seconds later Songbird's holocall rings, the
// phone wrapper above lets it through, and the moment the call starts "Dog Eat
// Dog" goes active and is tracked -- "Talk to the mystery caller", then "Go to
// the Dogtown border". A session starts over from the pristine save every time,
// so it came back on every join. A join's client log:
//
//   Phantom Liberty opened on this world (ep1_active 0 -> 1, ...)
//   call IncomingCall with songbird
//   call StartCall with songbird
//   quest Active: LocKey#81863
//   tracking: Talk to the mystery caller.
//   call EndCall with songbird
//   tracking: Go to the Dogtown border.
//
// WHAT THIS DOES. In a session, a call with Songbird (`songbird`, as the caller
// or as the one called) is refused before anything happens: no ringtone, no
// call on screen, no contact list -- the platform's own answer to every call,
// kept for this one. "Dog Eat Dog", which goes active when her call starts,
// never does: nothing is tracked and no toast shows. What 1.4.13 opened stays
// open (Dogtown's people, its gate, its gigs and street stories). On the male
// save, where the story is already under way, a later call of Songbird's is
// refused the same way.
//
// 1.4.17: THE STORY ITSELF WAITS (reported 2026-10-01 12:06 UTC: "still getting
// songbird quest and can hear her"). Refusing the call was not enough: the call
// is the phone system's, but the quest and its holocall SCENE are the quest
// graph's, and that graph went on without the phone. The 12:03 UTC join's log:
//
//   call IncomingCall with songbird refused: ...
//   call StartCall with songbird refused: ...
//   quest Active: LocKey#81863
//   tracking: Talk to the mystery caller.
//   Phantom Liberty a minute on: ..., q301_started 1 (...)
//   tracking: Go to the Dogtown border.
//
// Where the story starts: `ep1\quest\ep1.questphase`, top-level node [14]
// waits for `ep1_active >= 1`, then [16] -> [22] -> [9] `ep1_main_quests`,
// whose q301 waits ten seconds, rings Songbird and plays her holocall scene.
// Every other reader of `ep1_active` (the open world, the minor quests, the
// expansion's additional game elements) is a different node. So this preload
// now carries `archive/pc/mod/opx_songbird.archive`: the game's own
// ep1.questphase with ONE string changed -- node [14] waits for
// `opx_songbird_on >= 1` instead (built from the game's files by
// `tools/songbird/patch.py`, which checks that no other chunk changed). Nothing
// sets that fact, so the main story never starts in a session and no scene of
// hers plays; what 1.4.13 opened stays open. A world whose story is already
// under way (the male save: node [14] passed long ago) is not affected -- the
// call refusal above still holds there. The "a minute on" line says which it
// was: `q301_started 0` and "the story waits, as it should".
//
// SWITCH: the quest fact `opx_songbird_on` set to 1 opens the main quests
// (node [14]) and lets Songbird's calls through again: the story starts as the
// base game has it.
public static func OpxQuestsSongbirdRefused(game: GameInstance, request: ref<questTriggerCallRequest>) -> Bool {
  if GetFact(game, n"opx_songbird_on") != 0 {
    return false;
  };
  return Equals(request.caller, n"songbird") || Equals(request.addressee, n"songbird");
}

// ----------------------------------------------------------- self-check ----
// A few seconds after this machine's body attaches: is this module the
// outermost wrapper (the fixes above run), or is the platform's (they never
// run)? `IsPhoneEnabled` answers true for `opx_quests_probe` only through the
// wrapper above; the platform's answers false. One line in the client log.
public class OpxQuestsCheck extends DelayCallback {
  public let game: GameInstance;
  public func Call() -> Void {
    OpxQuestsSelfCheck(this.game);
  }
}

public static func OpxQuestsSelfCheck(game: GameInstance) -> Void {
  if !Open77MultiplayerPolicyActive() {
    return;
  };
  let phone: ref<PhoneSystem> = GameInstance.GetScriptableSystemsContainer(game).Get(n"PhoneSystem") as PhoneSystem;
  if !IsDefined(phone) {
    OpxQuestsTrace("self-check skipped (no phone system yet)");
    return;
  };
  let quests: ref<QuestsSystem> = GameInstance.GetQuestsSystem(game);
  quests.SetFact(n"opx_quests_probe", 1);
  let outer: Bool = phone.IsPhoneEnabled();
  quests.SetFact(n"opx_quests_probe", 0);
  if GetFact(game, n"opx_quests_off") != 0 {
    OpxQuestsTrace("OFF (the quest fact opx_quests_off is set): the platform's policy decides");
    return;
  };
  if outer {
    OpxQuestsTrace("missions restored in this session (outermost wrapper: phone, loot, scanner, tracker, markers, toasts, V's lines)");
  } else {
    OpxQuestsTrace("NOT restored: the platform's scripts were compiled after this module, so its wrappers run first");
  };
  phone.RefreshPhoneEnabled();
}

@wrapMethod(PlayerPuppet)
protected cb func OnGameAttached() -> Bool {
  let result: Bool = wrappedMethod();
  if this.IsControlledByLocalPeer() && Open77MultiplayerPolicyActive() {
    let game: GameInstance = this.GetGame();
    let state: ref<OpxQuestsSystem> = OpxQuestsState(game);
    if IsDefined(state) {
      state.attachedAt = OpxQuestsNow(game);
    };
    let check: ref<OpxQuestsCheck> = new OpxQuestsCheck();
    check.game = game;
    GameInstance.GetDelaySystem(game).DelayCallback(check, 5.0, false);
    let liberty: ref<OpxQuestsPhantomLibertyTick> = new OpxQuestsPhantomLibertyTick();
    liberty.game = game;
    GameInstance.GetDelaySystem(game).DelayCallback(liberty, 5.0, false);
  };
  return result;
}
