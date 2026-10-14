--- Player-facing text owned by the vehicles module.
-- @author dop42
--
-- Every key here is a refusal code or a confirmation: it reaches `locale()`
-- through a variable, never as a literal, so a rename breaks nothing at load and
-- everything at the moment a player is refused. Both halves need them: the
-- server renders a toast, and the client renders the code `OPX.Refuse` carries.

OPX.Locale.Register('en', {
	['vehicle.notFound'] = 'No vehicle carries that plate.',
	['vehicle.limit'] = 'You already own the maximum number of vehicles.',
	['vehicle.spawned'] = 'Vehicle {plate} brought out.',
	['vehicle.stored'] = 'Vehicle {plate} put away.',
	['vehicle.notSpawned'] = 'That vehicle is not out.',
	['vehicle.noPosition'] = 'Your position could not be read.',
	['vehicle.spawnRefused'] = 'The vehicle could not be created.',
	['vehicle.storeRefused'] = 'That vehicle could not be put away. It is still out.',
	['vehicle.occupied'] = 'Somebody is sitting in that vehicle. It cannot be moved.',
	-- A second request for a plate whose spawn is already in flight. Not an
	-- error the player caused: it is the answer the loser of a double-press gets
	-- now that a plate is claimed before it is created.
	['vehicle.busy'] = 'That vehicle is already being brought out.',
	['vehicle.registering'] = 'Another vehicle is being registered for this character. Try again in a moment.',
	['vehicle.badRecord'] = 'That vehicle record cannot be used.',
	['vehicle.plateExhausted'] = 'No free plate could be drawn. Try again.',
	['vehicle.notLoggedIn'] = 'Your character is not loaded yet. Try again in a moment.',
	['vehicle.impounded'] = 'That vehicle is impounded.',
	['vehicle.badState'] = 'That is not a state a vehicle can be put in.',
})

OPX.Locale.Register('fr', {
	['vehicle.notFound'] = 'Aucun véhicule ne porte cette plaque.',
	['vehicle.limit'] = 'Vous possédez déjà le nombre maximum de véhicules.',
	['vehicle.spawned'] = 'Véhicule {plate} sorti.',
	['vehicle.stored'] = 'Véhicule {plate} rangé.',
	['vehicle.notSpawned'] = "Ce véhicule n'est pas sorti.",
	['vehicle.noPosition'] = "Votre position n'a pas pu être lue.",
	['vehicle.spawnRefused'] = "Le véhicule n'a pas pu être créé.",
	['vehicle.storeRefused'] = "Ce véhicule n'a pas pu être rangé. Il est toujours sorti.",
	['vehicle.occupied'] = 'Quelqu\'un est assis dans ce véhicule. Impossible de le déplacer.',
	['vehicle.busy'] = 'Ce véhicule est déjà en train de sortir.',
	['vehicle.registering'] = "Un autre véhicule est en cours d'enregistrement pour ce personnage. Réessayez dans un instant.",
	['vehicle.badRecord'] = 'Ce véhicule ne peut pas être utilisé.',
	['vehicle.plateExhausted'] = "Aucune plaque libre n'a pu être tirée. Réessayez.",
	['vehicle.notLoggedIn'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['vehicle.impounded'] = 'Ce véhicule est à la fourrière.',
	['vehicle.badState'] = "Ce n'est pas un état possible pour un véhicule.",
})
