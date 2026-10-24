--- Full-rack solo and two-player modes. No wagers, XP or imported nc_pool gameplay code. Visuals live in opx_pool_assets.
-- @author dop42
local M = OPX.Modules.Declare{
	id = 'pool', side = 'both', fatal = false,
	requires = { 'character' }, optional = { 'target', 'prompts', 'downed', 'inventory', 'menu' },
}
M.Event = {
	REQUEST = OPX.Event(OPX.Channel.NET, 'pool', 'request'),
	STATE = OPX.Event(OPX.Channel.NET, 'pool', 'state'),
	NOTICE = OPX.Event(OPX.Channel.NET, 'pool', 'notice'),
}
