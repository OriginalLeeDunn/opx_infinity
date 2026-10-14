--- English player-facing text and refusal codes.
-- @author dop42
--
-- Almost every key here is a refusal code: it reaches locale() through a
-- variable, never as a literal, so a rename breaks nothing at load and
-- everything at the moment a player is refused.

OPX.Locale.Register('en', {
	['error.unavailable'] = 'That is not available right now.',
	['error.badRequest'] = 'That request could not be read.',
	['error.payloadRefused'] = 'That answer was too large to display.',
	-- The two codes the PAGE invents when Lua never answers, or answers a failure
	-- with no code of its own (`ui/src/bridge/rpc.ts`). They were registered in
	-- neither catalogue, and `useLocale` answers the key on a miss -- so a request
	-- that timed out printed the literal string `error.rpc_timeout` in the view.
	['error.rpc_timeout'] = 'That took too long. Try again.',
	['error.rpc_failed'] = 'That did not go through.',
	['error.tooFast'] = 'Slow down.',
	['error.noPermission'] = 'You may not do that.',
	['error.incapacitated'] = 'Not while you are down.',
	['money.amount'] = '{amount} {currency}',
	['money.separator'] = ',',
	['money.type.EDDIES'] = '€$',
	['money.type.BANK'] = '€$ (bank)',
	['notify.kind.info'] = 'NOTICE',
	['notify.kind.success'] = 'CONFIRMED',
	['notify.kind.warning'] = 'CAUTION',
	['notify.kind.error'] = 'FAILED',
})

-- The creator surface: what an export answers another resource when it refuses.
-- See core/server/exports.lua and core/client/exports.lua.
OPX.Locale.Register('en', {
	['export.callerDenied'] = 'That resource may not make this call.',
	['export.badArgument'] = 'An argument of that call could not be read.',
	['export.booting'] = 'The server is still starting. Try again in a moment.',
	['export.mustAwait'] = 'That call reaches the database: make it with Open77.exports.call and await it.',
	['export.badValue'] = 'That value is not plain data: booleans, numbers, text and tables of them.',
	['export.tooLarge'] = 'That value is over the size this server allows a resource to store.',
	['export.notSubscribable'] = 'That event is not one another resource may subscribe to.',
	['export.ownerTaken'] = 'That resource is named like a module of this server, whose rows it would share.',
	['export.duplicate'] = 'That exact message was just shown to that player.',
	['export.usableTaken'] = 'Another owner already handles the use of that item.',
})

-- Weather: the status line a player reads, the command usage lines and every
-- refusal code the authority can answer.
OPX.Locale.Register('en', {
	['weather.title'] = 'WEATHER',

	['weather.status'] = 'It is {time}. A day lasts {minutes} real minutes. The sky is {weather}.',
	['weather.status.clockHeld'] = 'The clock is held.',
	['weather.status.scheduleHeld'] = 'The weather schedule is held.',
	['weather.status.nextRoll'] = 'Next roll in {seconds}s.',
	['weather.status.revision'] = 'Revision {revision}.',
	['weather.status.degraded'] = 'No usable weather preset is configured.',

	['weather.presets.header'] = 'weather presets (name / engine preset / weight / seconds):',
	['weather.presets.row'] = '  {name} {preset} w={weight} {min}..{max}s  transition {transition}s',

	['weather.usage.set'] = 'usage: <preset> [transitionSeconds]',
	['weather.usage.next'] = 'usage: no arguments',
	['weather.usage.freeze'] = 'usage: <on|off>',
	['weather.usage.time'] = 'usage: <HH:MM[:SS]>',
	['weather.usage.timeFreeze'] = 'usage: <on|off>',
	['weather.usage.dayLength'] = 'usage: <realMinutes>',
	['weather.usage.wait'] = 'usage: <hours>',

	['weather.error.invalidTime'] = 'That is not a time of day. Use HH:MM or HH:MM:SS.',
	['weather.error.invalidDayLength'] = 'A day lasts between 1 minute and 7 days.',
	['weather.error.dayTooShort'] = 'That day is too short for a client to follow.',
	['weather.error.unknownPreset'] = 'No such weather preset.',
	['weather.error.presetHint'] = 'No such weather preset. Run {command} to see the list.',
	['weather.error.invalidTransition'] = 'A transition lasts between 0 and 300 seconds.',
	['weather.error.noPresets'] = 'No weather preset is configured.',
	['weather.error.unknown'] = 'That could not be done.',
	['weather.error.invalidHours'] = 'Wait between 1 and 23 whole hours.',
	['weather.error.playersOnly'] = 'Only a player in game can move their own clock.',
	['weather.wait.done'] = 'Your clock moves {hours} h ahead, on your game only. The shared hour comes back in 20 minutes.',

	['weather.help.status'] = 'Show the synchronized time and weather.',
	['weather.help.presets'] = 'List the configured weather presets.',
	['weather.help.set'] = 'Cross to a weather preset.',
	['weather.help.set.preset'] = 'one of {names}',
	['weather.help.set.seconds'] = "transition length; omit for the preset's own",
	['weather.help.next'] = 'Roll the weighted weather table now.',
	['weather.help.freeze'] = 'Hold or release the weather schedule.',
	['weather.help.onOff'] = 'on holds it, off lets it run',
	['weather.help.time'] = 'Set the authoritative clock.',
	['weather.help.time.value'] = '24-hour, for example 21:30',
	['weather.help.timeFreeze'] = 'Hold or release the clock.',
	['weather.help.dayLength'] = 'Set how many real minutes a day takes.',
	['weather.help.dayLength.minutes'] = "180 matches the engine's own rate",
	['weather.help.wait'] = "Move your own clock ahead, for a mission's wait.",
	['weather.help.wait.hours'] = 'whole hours, 1 to 23',
})
