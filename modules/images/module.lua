--- CDN picture names are resolved by the server and delivered in bounded pages.
-- @author dop42
-- The credential and API responses never reach a client. No local pictures are
-- bundled; an absent key or unavailable picture leaves the UI's text monogram.
local M = OPX.Modules.Declare{ id = 'images', side = 'both', fatal = false }
M.Event = {
	REQUEST = OPX.Event(OPX.Channel.NET, 'images', 'request'),
	SET = OPX.Event(OPX.Channel.NET, 'images', 'set'),
}
M.Page = { READY = 'images:ready', SET = 'images:set' }
