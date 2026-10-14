--- Player-facing text owned by the vehicle keys module.
-- @author dop42
--
-- Both halves need them: the server renders every answer as a toast, and the
-- client renders the row. The item's own name and description are the inventory
-- module's (`inventory.item.vehicle_key`), because the catalogue owns what an
-- item is called.

OPX.Locale.Register('en', {
	['vehiclekeys.row.toggle'] = 'Lock / unlock',
	['vehiclekeys.row.lock'] = 'Lock vehicle',
	['vehiclekeys.row.unlock'] = 'Unlock vehicle',
	['vehiclekeys.locked'] = '{label}: locked.',
	['vehiclekeys.unlocked'] = '{label}: unlocked.',
	['vehiclekeys.noKey'] = 'You have no key to this vehicle.',
	['vehiclekeys.noVehicle'] = 'That vehicle is not there.',
	['vehiclekeys.notOut'] = 'The vehicle this key opens is not out.',
	['vehiclekeys.tooFar'] = 'You are too far from the vehicle.',
	['vehiclekeys.lockRefused'] = 'The lock did not answer. Try again.',
	['vehiclekeys.noRoom'] = 'No room in your bag for the key to {label}.',
	['vehiclekeys.unavailable'] = 'Keys are not available on this server right now.',
	['vehiclekeys.tooFast'] = 'Slow down.',
})

OPX.Locale.Register('fr', {
	['vehiclekeys.row.toggle'] = 'Verrouiller / déverrouiller',
	['vehiclekeys.row.lock'] = 'Verrouiller le véhicule',
	['vehiclekeys.row.unlock'] = 'Déverrouiller le véhicule',
	['vehiclekeys.locked'] = '{label} : verrouillé.',
	['vehiclekeys.unlocked'] = '{label} : déverrouillé.',
	['vehiclekeys.noKey'] = "Vous n'avez pas la clé de ce véhicule.",
	['vehiclekeys.noVehicle'] = "Ce véhicule n'est pas là.",
	['vehiclekeys.notOut'] = "Le véhicule que cette clé ouvre n'est pas sorti.",
	['vehiclekeys.tooFar'] = 'Vous êtes trop loin du véhicule.',
	['vehiclekeys.lockRefused'] = "Le verrou n'a pas répondu. Réessayez.",
	['vehiclekeys.noRoom'] = 'Pas de place dans votre sac pour la clé de {label}.',
	['vehiclekeys.unavailable'] = 'Les clés ne sont pas disponibles sur ce serveur pour le moment.',
	['vehiclekeys.tooFast'] = 'Doucement.',
})
