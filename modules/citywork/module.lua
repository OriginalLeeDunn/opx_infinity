--- Two public trades share the existing persistent gig and payout ledger.
-- @author dop42
local M = OPX.Modules.Declare{
	id = 'citywork', side = 'both', fatal = false,
	requires = { 'character', 'inventory', 'contracts', 'progress' },
	optional = { 'target', 'menu', 'downed' },
}
M.Event = {
	REQUEST = OPX.Event(OPX.Channel.NET, 'citywork', 'request'),
	VIEW = OPX.Event(OPX.Channel.NET, 'citywork', 'view'),
}
M.Types = { courier = 'shard_delivery', technician = 'relay_maintenance' }
M.ITEM = 'citywork_sealed_module'
