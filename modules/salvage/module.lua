--- Public recovery owns collection; crafting owns durable recycling orders.
-- @author dop42
-- No cash is minted. A shared persistent depletion timer bounds materials even
-- across reconnects and restarts. Collection commits depletion before delivery:
-- a crash can lose one collection, but cannot recreate the same stock twice.
local M = OPX.Modules.Declare{
	id = 'salvage', side = 'both', fatal = false,
	requires = { 'character', 'inventory', 'progress', 'crafting' },
	optional = { 'target', 'menu', 'downed' },
}
M.Event = {
	COLLECT = OPX.Event(OPX.Channel.NET, 'salvage', 'collect'),
	NOTICE = OPX.Event(OPX.Channel.NET, 'salvage', 'notice'),
}
M.ITEM = 'electronic_waste'
M.PREFIX = 'salvage:'
