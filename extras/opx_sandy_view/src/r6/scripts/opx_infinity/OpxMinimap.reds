// opx_sandy_view 1.4.21 -- the round minimap's north badge, moved; and a report.
//
// THE MINIMAP ITSELF IS DATA, NOT THIS FILE. `archive/pc/mod/opx_minimap.archive`
// carries the game's own minimap.inkwidget with its mask, its backing and its
// frame drawn from `opx\ui\minimap\opx_minimap.inkatlas` (a disc, a bezel ring, a
// rim glow, an N badge), the district name shown above the circle, and the
// game's own prototype_hud.inkhud with the minimap's entry anchored to the
// bottom-right corner. The map inside the circle is the game's: its streets, its
// pins, its GPS line, moving and turning with the player exactly as before.
// Nothing here draws anything.
//
// WHAT THIS FILE DOES: it moves the N. The minimap turns with the camera, so
// north is wherever the camera is not looking. The badge is an image of the
// library itself (the square's old corner `fluff`, retextured in the archive,
// hidden until placed here), and this keeps it on the bezel where north is, 30
// times a second. It is MOVED, not rotated: the letter stays upright.
//
// NORTH IS THE MAP'S OWN ROTATION + 90 DEGREES: the game's geometry has north to
// the right when unrotated (every logged sample: map rotation = -heading - 90).
// The camera heading is the fallback when the map reports no rotation.
//
// THE WHITE SQUARE OF 1.4.18-1.4.20 WAS THE TEXTURE, NOT THIS FILE. The game's
// UI textures are premultiplied (colour x alpha, black where transparent) and
// it blends every UI image as  tex.rgb * tint + dst * (1 - tex.a); the atlas
// stored white in its transparent pixels, so each 450-unit frame image ADDED its
// tint over its whole square (red bezel + cyan zone ring = white). 1.4.21's
// atlas is premultiplied (archive only). This file has touched no texture since
// 1.4.20: the frame is the archive's alone, and this only REPORTS, two and ten
// seconds after the player attaches, what each part of it says (`opx_sandy_view
// minimap: frame at 2 s: mask disc true, ...`), with a part of the game's own
// atlas as the yardstick. The combat and autodrive glows sit at opacity 0 until
// a fight or autodrive; 1.4.20 reported the combat one `false`, and the hidden
// `weathericon` (the game's own atlas, a part it surely has) now says whether
// an image not yet drawn reports false for that reason alone.
//
// OFF SWITCH: the quest fact `opx_minimap_off` set to 1 hides the badge on the
// next tick (the round frame is the archive's and stays).

public func OpxMinimapTrace(line: String) -> Void {
  Open77PlayerResetTrace("opx_sandy_view minimap: " + line);
}

public class OpxMinimapNorthTick extends DelayCallback {
  public let controller: wref<MinimapContainerController>;

  public func Call() -> Void {
    if IsDefined(this.controller) {
      this.controller.OpxMinimapTick();
    };
  }
}

@addField(MinimapContainerController)
private let m_opxNorthTick: ref<OpxMinimapNorthTick>;

@addField(MinimapContainerController)
private let m_opxNorthTicks: Int32;

@addField(MinimapContainerController)
private let m_opxNorthRunning: Bool;

// The bezel's radius in the minimap's own units (the frame is 450 across, the
// band sits 4-15 units in from the edge).
@addMethod(MinimapContainerController)
private func OpxMinimapRadius() -> Float {
  return 214.0;
}

@addMethod(MinimapContainerController)
private func OpxMinimapBadge() -> wref<inkWidget> {
  return this.GetWidget(n"MiniMapContainer/fluff");
}

@addMethod(MinimapContainerController)
private func OpxMinimapStart() -> Void {
  let player: ref<GameObject>;
  if this.m_opxNorthRunning || !IsDefined(this.OpxMinimapBadge()) {
    return;
  };
  player = this.GetPlayerControlledObject();
  if !IsDefined(player) {
    return;
  };
  if !IsDefined(this.m_opxNorthTick) {
    this.m_opxNorthTick = new OpxMinimapNorthTick();
    this.m_opxNorthTick.controller = this;
  };
  this.m_opxNorthTicks = 0;
  this.m_opxNorthRunning = true;
  OpxMinimapTrace("north badge on the bezel, radius " + FloatToString(this.OpxMinimapRadius()) + " (the library's own image, MiniMapContainer/fluff)");
  GameInstance.GetDelaySystem(player.GetGame()).DelayCallback(this.m_opxNorthTick, 0.05, false);
}

// The map's own rotation, when the game turns a container rather than the
// geometry inside it; 0 when it does not.
@addMethod(MinimapContainerController)
private func OpxMinimapMapRotation() -> Float {
  let widget: wref<inkWidget>;
  widget = this.GetWidget(n"MiniMapContainer/maskedContainer/geometryCache/geometrySpawnContainer");
  if IsDefined(widget) && AbsF(widget.GetRotation()) > 0.01 {
    return widget.GetRotation();
  };
  widget = this.GetWidget(n"MiniMapContainer/maskedContainer/geometryCache");
  if IsDefined(widget) && AbsF(widget.GetRotation()) > 0.01 {
    return widget.GetRotation();
  };
  return 0.0;
}

// Whether the map itself is on screen: Open77's HUD policy hides the map's own
// widgets when a resource takes the minimap away (the badge among them).
@addMethod(MinimapContainerController)
private func OpxMinimapMapShown() -> Bool {
  let container: wref<inkWidget> = this.GetWidget(n"MiniMapContainer");
  let masked: wref<inkWidget> = this.GetWidget(n"MiniMapContainer/maskedContainer");
  return IsDefined(container) && container.IsVisible() && (!IsDefined(masked) || masked.IsVisible());
}

// One image of the frame, as it reports itself. Reads only.
@addMethod(MinimapContainerController)
private func OpxMinimapImageState(path: CName, part: CName) -> String {
  let image: wref<inkImage> = this.GetWidget(path) as inkImage;
  if !IsDefined(image) {
    return "missing";
  };
  return BoolToString(image.IsTexturePartExist(part)) + " (" + NameToString(image.GetTexturePart()) + ")";
}

@addMethod(MinimapContainerController)
private func OpxMinimapReport(when: String) -> Void {
  let mask: wref<inkMask> = this.GetWidget(n"MiniMapContainer/maskedContainer/mask") as inkMask;
  let maskState: String = "missing";
  if IsDefined(mask) {
    maskState = BoolToString(mask.IsTexturePartExist(n"disc")) + " (" + NameToString(mask.GetTexturePart()) + ")";
  };
  OpxMinimapTrace("frame at " + when + ": mask disc " + maskState
    + ", backing disc " + this.OpxMinimapImageState(n"MiniMapContainer/bgColorFiller", n"disc")
    + ", bezel ring " + this.OpxMinimapImageState(n"MiniMapContainer/bar", n"ring")
    + ", glow " + this.OpxMinimapImageState(n"MiniMapContainer/combatBorderHighlight", n"glow")
    + ", autodrive glow " + this.OpxMinimapImageState(n"MiniMapContainer/autoDriveBorderHighlight", n"glow")
    + ", zone ring " + this.OpxMinimapImageState(n"MiniMapContainer/zoneVignette/border", n"ring")
    + ", badge north " + this.OpxMinimapImageState(n"MiniMapContainer/fluff", n"north")
    + "; the game's own atlas for comparison: dots gridRect " + this.OpxMinimapImageState(n"MiniMapContainer/bg_dots", n"gridRect")
    + ", hidden weathericon gear " + this.OpxMinimapImageState(n"MiniMapContainer/weathericon", n"gear"));
}

@addMethod(MinimapContainerController)
public func OpxMinimapTick() -> Void {
  let badge: wref<inkWidget> = this.OpxMinimapBadge();
  let player: ref<GameObject> = this.GetPlayerControlledObject();
  let game: GameInstance;
  let forward: Vector4;
  let heading: Float;
  let mapRotation: Float;
  let angle: Float;
  let radius: Float = this.OpxMinimapRadius();
  if !IsDefined(badge) || !IsDefined(player) {
    this.m_opxNorthRunning = false;
    return;
  };
  game = player.GetGame();
  if this.m_opxNorthTicks == 60 {
    this.OpxMinimapReport("2 s");
  };
  if this.m_opxNorthTicks == 300 {
    this.OpxMinimapReport("10 s");
  };
  if GetFact(game, n"opx_minimap_off") != 0 || !this.OpxMinimapMapShown() {
    badge.SetVisible(false);
  } else {
    forward = GameInstance.GetCameraSystem(game).GetActiveCameraForward();
    // 0 = north (+Y), clockwise towards east (+X), in radians.
    heading = AtanF(forward.X, forward.Y);
    mapRotation = this.OpxMinimapMapRotation();
    if AbsF(mapRotation) > 0.01 {
      // The game's geometry has north to the right when unrotated, and turns it
      // by `mapRotation` degrees (clockwise): north is at mapRotation + 90.
      angle = Deg2Rad(mapRotation + 90.0);
    } else {
      angle = -heading;
    };
    badge.SetTranslation(radius * SinF(angle), -radius * CosF(angle));
    badge.SetVisible(true);
    if this.m_opxNorthTicks < 300 && this.m_opxNorthTicks % 60 == 0 {
      OpxMinimapTrace("heading " + FloatToStringPrec(Rad2Deg(heading), 1) + " deg, map rotation "
        + FloatToStringPrec(mapRotation, 1) + " deg, N at " + FloatToStringPrec(Rad2Deg(angle), 1)
        + " deg (camera says " + FloatToStringPrec(-Rad2Deg(heading), 1) + ")");
    };
  };
  this.m_opxNorthTicks += 1;
  GameInstance.GetDelaySystem(game).DelayCallback(this.m_opxNorthTick, 0.033, false);
}

@wrapMethod(MinimapContainerController)
protected cb func OnPlayerAttach(player: ref<GameObject>) -> Bool {
  let result: Bool = wrappedMethod(player);
  this.OpxMinimapStart();
  return result;
}
