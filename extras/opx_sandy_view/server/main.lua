-- opx_sandy_view, server: says the base game's Sandevistan view is being
-- delivered (the preload does the work; see open77.lua).
AddEventHandler('onResourceStart', function(name)
	if name ~= GetCurrentResourceName() then return end
	print('[opx_sandy_view] the base game\'s Sandevistan screen ships with this world ' ..
		'(r6/scripts/opx_infinity/OpxSandevistanView.reds)')
	-- The ghost trail's parts ride in the preload's own archive: its copies of
	-- V's body files (t0_000_base__full.app and the censored cut) carry them,
	-- and the game loads those by their depot path -- no loader. Up to 1.4.7
	-- they were an ArchiveXL patch, and a player whose game had no ArchiveXL saw
	-- no trail at all; the platform's `archivexl` resource is no longer needed
	-- for it (whatever else in this world may use it).
	print('[opx_sandy_view] the ghost trail ships in this preload\'s own archive ' ..
		'(archive/pc/mod/opx_sandy_ghost.archive: V\'s body files with the parts) -- no ArchiveXL needed')
	-- 1.4.10: the MaxTac AV's records all name the base game's cloaked livery,
	-- which nothing lifts in a session; the second REDscript draws the
	-- airframe's visible one on every player's game.
	print('[opx_sandy_view] the MaxTac AV is drawn in its visible livery on every player\'s game ' ..
		'(r6/scripts/opx_infinity/OpxMaxTacAv.reds)')
	-- 1.4.11: the base game's missions -- phone, quest loot, scanner, tracker,
	-- markers, toasts and V's lines -- given back from the platform's policy.
	print('[opx_sandy_view] the base game\'s missions are playable on every player\'s game ' ..
		'(r6/scripts/opx_infinity/OpxQuests.reds; each client log says whether it runs)')
	-- 1.4.17: Phantom Liberty's main story waits for a switch nothing sets, so
	-- Songbird never calls in a session; Dogtown's people, gate and gigs stay open.
	print('[opx_sandy_view] Phantom Liberty\'s main story waits in this world: Songbird does not call, ' ..
		'Dogtown stays open (archive/pc/mod/opx_songbird.archive: ep1.questphase node [14] reads opx_songbird_on)')
	-- 1.4.18: the game's own minimap, round and at the bottom-right corner
	-- (its frame and HUD slot are data in the archive; the N on the bezel is the
	-- REDscript). The map inside is the game's, moving with the player.
	print('[opx_sandy_view] the minimap is round, at the bottom-right of every player\'s screen ' ..
		'(archive/pc/mod/opx_minimap.archive: the game\'s minimap.inkwidget and prototype_hud.inkhud; ' ..
		'r6/scripts/opx_infinity/OpxMinimap.reds: the N on the bezel)')
end)
