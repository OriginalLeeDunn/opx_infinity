--- Original practice prototype. No wagers, XP or imported nc_pool code/assets.
-- @author dop42
local M = OPX.Modules.Declare{
	id = 'pool', side = 'both', fatal = false,
	requires = { 'character' }, optional = { 'target', 'prompts', 'downed', 'inventory' },
}
M.Event = {
	REQUEST = OPX.Event(OPX.Channel.NET, 'pool', 'request'),
	STATE = OPX.Event(OPX.Channel.NET, 'pool', 'state'),
	NOTICE = OPX.Event(OPX.Channel.NET, 'pool', 'notice'),
}
