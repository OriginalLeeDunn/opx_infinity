--- Server-only Fivemanage credential; clients receive public image URLs only.
-- @author dop42
-- Upload with opx_images using the same account, then set this key and restart OPX.
-- Open77's HTTP bridge must allow api.fivemanage.com (see docs/MANUAL.md).
OPX.Config.MODULES.images = {
	API_KEY = '',
}
