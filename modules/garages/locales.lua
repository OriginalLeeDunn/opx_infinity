--- Player-facing text for the strip row, the list, every refusal and the
--- command help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A garage's LABEL is the operator's own words and lives in config, not
-- here.

local EN = {
	['garages.title'] = 'GARAGES',
	['garages.refused'] = 'That could not be done.',
	['garages.close'] = 'Close',

	['garages.key.use'] = 'Open a garage, or put a vehicle away',
	['garages.prompt.garage'] = 'Open your garage',
	['garages.prompt.avpad'] = 'Open your hangar',
	-- Said at a DOOR rather than at a menu point: one takes a vehicle in and the
	-- other opens a list, and a player who cannot tell them apart drives into the
	-- wrong one.
	['garages.prompt.putAway'] = 'Put your vehicle away',
	['garages.prompt.driveIn'] = 'Drive in to store a vehicle',

	-- The two things a row in the list can be. A garage is in several places
	-- now, so "the car you left here" and "the car you left at the other end of
	-- the city, which will be fetched to here" are different facts about it.
	['garages.menu.title'] = '{garage}',
	['garages.list.here'] = 'Parked here',
	['garages.list.away'] = 'Elsewhere',
	['garages.list.fleet'] = 'Division stock',

	['garages.broughtOut'] = 'Brought out {plate}.',
	['garages.storedAway'] = 'Put away {plate}.',
	['garages.issuedOut'] = 'Issued to you: {plate}.',

	['garages.noSuchSpot'] = 'There is no garage here.',
	['garages.noCharacter'] = 'Your record could not be read.',
	['garages.noPosition'] = 'Your position could not be read.',
	['garages.wrongBucket'] = 'That marker is not the one in front of you.',
	['garages.tooFar'] = 'You are too far from the marker. Stand on it and try again.',
	['garages.landFirst'] = 'Set the aircraft down on the pad first, then put it away.',
	['garages.nothingHere'] = 'You own nothing that comes out here.',
	['garages.notYours'] = 'That vehicle of yours does not come out here.',
	-- EVERY EXIT IS TAKEN. The owner chose a refusal over a queue and over
	-- creating the vehicle inside the car already parked there, so this says what
	-- is wrong and what to do about it rather than apologising.
	['garages.noFreeExit'] =
		'Every exit at {garage} is blocked. Move what is parked there and try again.',
	['garages.rateLimited'] = 'Slow down and try again in a moment.',
	['garages.noVehicles'] = 'Vehicles are unavailable on this server.',

	-- THE DIVISION'S STOCK, and the two refusals an issue earns: a garage that
	-- issues nothing, and a hull the hangar does not fly.
	['garages.fleetNotHere'] = 'This garage issues none of the division\'s aircraft.',
	['garages.fleetNotOffered'] = 'The hangar does not issue that hull.',

	-- THE AV ANNEX'S OWN REFUSALS. A pad of `config/avgarages.lua` is behind the
	-- job gate, and these name the three ways through it a player does not make
	-- -- job, rank or duty -- whichever they were closest to.
	['garages.jobRequired'] = 'That pad is for another crew. You do not hold the job.',
	['garages.gradeTooLow'] = 'That pad needs more rank than you hold.',
	['garages.offDuty'] = 'That pad is for the crew on duty. Clock on and try again.',
	-- A pad whose JOBS names no job: closed, never public.
	['garages.padClosed'] = 'That pad is closed: it is not assigned to any crew.',

	-- THE JOB FLEET (config/garages.lua JOB_VEHICLES): the section a job's own
	-- vehicles are listed under, what each row says, the toasts, the four
	-- refusals a sign-out earns, and the name of every shipped vehicle. {job}
	-- is the job's own name from config/character.lua and is not translated.
	['garages.list.jobSection'] = '{job} service vehicles',
	['garages.list.fleetSection'] = 'Division stock',
	['garages.list.ownSection'] = 'Your vehicles',
	['garages.list.jobReady'] = 'Ready',
	['garages.list.jobOut'] = 'On the street',
	['garages.list.jobHint'] =
		'Signed out to you while you hold the job and are on duty. It cannot be sold, given away or kept.',
	['garages.jobOut'] = 'Signed out: {vehicle}.',
	['garages.jobReturned'] = 'Back to the motor pool: {vehicle}.',
	['garages.jobRecalled'] = '{vehicle} went back to the motor pool: it stays with the job.',
	-- An AV a job's pad issued, taken back when its holder leaves the job.
	['garages.issuedRevoked'] = '{vehicle} ({plate}) went back to the {job} fleet: it stays with the job, and its keys with it.',
	['garages.job.notHere'] = 'That service vehicle does not come out here.',
	['garages.job.required'] = 'That service vehicle belongs to another job.',
	['garages.job.gradeTooLow'] = 'That service vehicle needs a higher rank.',
	['garages.job.offDuty'] = 'Service vehicles are for the crew on duty. Clock on and try again.',

	['garages.job.vehicle.ncpdCortes'] = 'Villefort Cortes patrol car',
	['garages.job.vehicle.ncpdHella'] = 'Archer Hella patrol car',
	['garages.job.vehicle.ncpdApollo'] = 'Brennan Apollo patrol bike',
	['garages.job.vehicle.ncpdEmperor'] = 'Chevalier Emperor patrol SUV',
	['garages.job.vehicle.ncpdMerrimac'] = 'Thorton Merrimac interceptor',
	['garages.job.vehicle.ncpdAv'] = 'NCPD air unit (AV)',
	['garages.job.vehicle.ncpdHellhound'] = 'Militech Hellhound armoured unit',
	['garages.job.vehicle.maxtacAv'] = 'MaxTac AV (Zetatech Surveyor)',
	['garages.job.vehicle.maxtacMerrimac'] = 'MaxTac ground unit (Thorton Merrimac)',

	['garages.help.list'] = 'Show every garage: kind, locations and where it comes from.',
	['garages.help.bring'] = 'Bring your own vehicle out at a garage you are standing at.',
	['garages.help.bringKey'] = 'the garage name; the nearest point when omitted',
	['garages.help.bringPlate'] = 'a plate you own; the first eligible one when omitted',
	['garages.help.export'] = 'Hand over the paste-ready config block for every garage that lives only in the database.',
	['avgarages.help.add'] = 'Capture a MaxTac AV pad where you stand and set it live; answers with the config block to check in.',
	['avgarages.help.addKey'] = 'the pad name; a fresh maxtac_av<N> when omitted',
	['avgarages.help.addLabel'] = 'the pad label; the key when omitted',
	['avgarages.help.remove'] = 'Take a captured AV pad away again. Config pads are config/avgarages.lua\'s to remove.',
	['avgarages.help.removeKey'] = 'the pad name',
}

local FR = {
	['garages.title'] = 'GARAGES',
	['garages.refused'] = "Cela n'a pas pu être fait.",
	['garages.close'] = 'Fermer',

	['garages.key.use'] = 'Ouvrir un garage ou ranger un véhicule',
	['garages.prompt.garage'] = 'Ouvrir votre garage',
	['garages.prompt.avpad'] = 'Ouvrir votre hangar',
	['garages.prompt.putAway'] = 'Ranger votre véhicule',
	['garages.prompt.driveIn'] = 'Entrez pour ranger un véhicule',

	['garages.menu.title'] = '{garage}',
	['garages.list.here'] = 'Garé ici',
	['garages.list.away'] = 'Ailleurs',
	['garages.list.fleet'] = 'Stock de la division',

	['garages.broughtOut'] = 'Sorti : {plate}.',
	['garages.storedAway'] = 'Rangé : {plate}.',
	['garages.issuedOut'] = 'Assigné : {plate}.',

	['garages.noSuchSpot'] = 'Il n’y a pas de garage ici.',
	['garages.noCharacter'] = "Votre fiche n'a pas pu être lue.",
	['garages.noPosition'] = "Votre position n'a pas pu être lue.",
	['garages.wrongBucket'] = "Ce marqueur n'est pas celui devant vous.",
	['garages.tooFar'] = 'Vous êtes trop loin du marqueur. Mettez-vous dessus.',
	['garages.landFirst'] = 'Posez d\'abord l\'appareil sur la plateforme, puis rangez-le.',
	['garages.nothingHere'] = 'Vous ne possédez rien qui sorte ici.',
	['garages.notYours'] = "Ce véhicule ne sort pas ici.",
	['garages.noFreeExit'] =
		'Toutes les sorties de {garage} sont bloquées. Dégagez-en une et réessayez.',
	['garages.rateLimited'] = 'Ralentissez et réessayez dans un instant.',
	['garages.noVehicles'] = 'Les véhicules sont indisponibles sur ce serveur.',

	['garages.fleetNotHere'] = "Ce garage n'assigne aucune machine de la division.",
	['garages.fleetNotOffered'] = "Le hangar n'assigne pas cette coque.",

	['garages.jobRequired'] = 'Ce pad est pour une autre équipe. Vous n’avez pas ce métier.',
	['garages.gradeTooLow'] = 'Ce pad exige un grade supérieur au vôtre.',
	['garages.offDuty'] = 'Ce pad est pour l’équipe en service. Prenez votre service et réessayez.',
	['garages.padClosed'] = 'Ce pad est fermé : il n’est attribué à aucune équipe.',

	['garages.list.jobSection'] = 'Véhicules de service {job}',
	['garages.list.fleetSection'] = 'Stock de la division',
	['garages.list.ownSection'] = 'Vos véhicules',
	['garages.list.jobReady'] = 'Disponible',
	['garages.list.jobOut'] = 'Dans la rue',
	['garages.list.jobHint'] =
		'Prêté tant que vous avez ce métier et êtes en service : ni à vendre, ni à donner, ni à garder.',
	['garages.jobOut'] = 'Sorti du parc : {vehicle}.',
	['garages.jobReturned'] = 'Rendu au parc : {vehicle}.',
	['garages.jobRecalled'] = 'Retour au parc : {vehicle}. Il reste au service.',
	['garages.issuedRevoked'] = 'Retour à la flotte {job} : {vehicle} ({plate}). Il reste au service, ses clés aussi.',
	['garages.job.notHere'] = 'Ce véhicule de service ne sort pas ici.',
	['garages.job.required'] = 'Ce véhicule de service appartient à un autre métier.',
	['garages.job.gradeTooLow'] = 'Ce véhicule de service exige un grade supérieur.',
	['garages.job.offDuty'] = 'Les véhicules de service sont pour l’équipe en service. Prenez votre service et réessayez.',

	['garages.job.vehicle.ncpdCortes'] = 'Voiture de patrouille Villefort Cortes',
	['garages.job.vehicle.ncpdHella'] = 'Voiture de patrouille Archer Hella',
	['garages.job.vehicle.ncpdApollo'] = 'Moto de patrouille Brennan Apollo',
	['garages.job.vehicle.ncpdEmperor'] = 'SUV de patrouille Chevalier Emperor',
	['garages.job.vehicle.ncpdMerrimac'] = 'Intercepteur Thorton Merrimac',
	['garages.job.vehicle.ncpdAv'] = 'Unité aérienne NCPD (AV)',
	['garages.job.vehicle.ncpdHellhound'] = 'Blindé Militech Hellhound',
	['garages.job.vehicle.maxtacAv'] = 'AV MaxTac (Zetatech Surveyor)',
	['garages.job.vehicle.maxtacMerrimac'] = 'Unité au sol MaxTac (Thorton Merrimac)',

	['garages.help.list'] = 'Affiche chaque garage : type, emplacements et origine.',
	['garages.help.bring'] = 'Sort votre propre véhicule à un garage où vous êtes.',
	['garages.help.bringKey'] = 'le nom du garage ; le point le plus proche si omis',
	['garages.help.bringPlate'] = 'une plaque à vous ; la première éligible si omise',
	['garages.help.export'] = 'Donne le bloc de config à coller pour chaque garage présent seulement dans la base.',
	['avgarages.help.add'] = 'Capture un pad AV MaxTac où vous vous tenez et l\'active aussitôt ; répond avec le bloc de config à vérifier.',
	['avgarages.help.addKey'] = 'le nom du pad ; un maxtac_av<N> neuf si omis',
	['avgarages.help.addLabel'] = 'l\'étiquette du pad ; la clé si omise',
	['avgarages.help.remove'] = 'Retire un pad AV capturé. Les pads de config sont à retirer dans config/avgarages.lua.',
	['avgarages.help.removeKey'] = 'le nom du pad',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
