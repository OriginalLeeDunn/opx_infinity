--- The player's own third-person camera: a few framings to choose from on ALT.
-- @author dop42
--
-- THE OWNER: "proposer cela via alt sur sois et plusieurs types de cam, style
-- Hogwarts Legacy etc., en gros rendre la caméra plus dynamique".
--
-- WHAT THE PLATFORM OFFERS, since client op77.78: `Open77.camera.
-- configureThirdPerson`, a resource-owned STYLE on the playable third-person
-- rig -- framing, anchor, FOV, which shoulder, a blend time, and a wider lens
-- while running and sprinting. The rig does all of it: there is no camera
-- created here and no loop moving one, and "more dynamic" is the rig's own
-- run/sprint/aim response plus a smooth blend between styles.
--
-- THE CLAIM IS EXCLUSIVE AND THE PLATFORM HOLDS IT. One resource owns the
-- style at a time; another resource's style answers `camera_style_owned` and
-- is not overwritten. Stop, reload and teardown release ours automatically.
--
-- CLIENT ONLY, and nothing about it is authoritative: it is the player's own
-- view of their own body. The choice is kept on their machine
-- (`OPX.Lib.Store`), per server, and nothing crosses the wire.
--
-- `target` is optional ON PURPOSE and named for the same reason
-- `animations` names it: without it the styles are unreachable, which is a
-- missing convenience rather than a broken module -- but `Resolve` orders by
-- what is declared, and an undeclared eye would start after us and answer nil.

local M = OPX.Modules.Declare{
	id = 'camera',
	side = 'client',
	fatal = false,
	optional = { 'target' },
}
