--- Player-facing text for the panel and every refusal.
-- @author dop42
--
-- Log lines, the diagnostic report and the error codes themselves stay in
-- English. A floor's LABEL and REASON are the operator's own words and live in
-- config, not here.

local EN = {
	['elevators.title'] = 'ELEVATORS',
	['elevators.locked'] = 'Locked',
	['elevators.refused'] = 'That floor is not available.',
	['elevators.key.use'] = 'Call the elevator',
	['elevators.prompt'] = 'Take elevator: {place}',
	['elevators.noFloors'] = 'No floor of this elevator is listed.',
	['elevators.noPanel'] = 'The floor list cannot be shown right now.',

	['elevators.noElevatorNearby'] = 'You are not standing at an elevator.',
	['elevators.noSuchElevator'] = 'No such elevator.',
	['elevators.noSuchFloor'] = 'This elevator has no such floor.',
	['elevators.notAdopted'] = 'This elevator is not ready yet. Try again in a moment.',
	['elevators.floorOutOfRange'] = 'This elevator does not serve that floor.',
	['elevators.moveRejected'] = 'The elevator did not respond. Try again.',
	['elevators.notSent'] = 'That request could not be sent.',
	['elevators.rateLimited'] = 'Slow down and try again in a moment.',

	['elevators.noCharacter'] = 'Your character is not loaded yet. Try again in a moment.',
	['elevators.jobStale'] = 'Your record is out of date. Try again in a moment.',
	['elevators.jobRequired'] = 'You do not hold the job this floor asks for.',
	['elevators.gradeTooLow'] = 'Your grade is too low for this floor.',
	['elevators.offDuty'] = 'You must be on duty for this floor.',
	['elevators.downed'] = 'Not while you are down.',

	['elevators.noPosition'] = 'Your position could not be read.',
	['elevators.wrongBucket'] = 'You are not at this elevator. Step up to it and try again.',
	['elevators.tooFar'] = 'You are too far from the elevator.',

	['elevators.help.where'] = 'Show every elevator: its position, floors and adoption.',
	['elevators.help.whereKey'] = 'one of {keys}; every elevator when omitted',
}

local FR = {
	['elevators.title'] = 'ASCENSEURS',
	['elevators.locked'] = 'Verrouillé',
	['elevators.refused'] = "Cet étage n'est pas accessible.",
	['elevators.key.use'] = "Appeler l'ascenseur",
	['elevators.prompt'] = "Prendre l'ascenseur : {place}",
	['elevators.noFloors'] = "Aucun étage de cet ascenseur n'est listé.",
	['elevators.noPanel'] = "La liste des étages ne peut pas s'afficher pour l'instant.",

	['elevators.noElevatorNearby'] = "Vous n'êtes pas devant un ascenseur.",
	['elevators.noSuchElevator'] = "Cet ascenseur n'existe pas.",
	['elevators.noSuchFloor'] = "Cet ascenseur n'a pas cet étage.",
	['elevators.notAdopted'] = "Cet ascenseur n'est pas encore prêt. Patientez un instant.",
	['elevators.floorOutOfRange'] = 'Cet ascenseur ne dessert pas cet étage.',
	['elevators.moveRejected'] = "L'ascenseur ne répond pas. Réessayez.",
	['elevators.notSent'] = "Cette demande n'a pas pu être envoyée.",
	['elevators.rateLimited'] = 'Ralentissez et réessayez dans un instant.',

	['elevators.noCharacter'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['elevators.jobStale'] = "Votre fiche n'est plus à jour. Réessayez dans un instant.",
	['elevators.jobRequired'] = "Vous n'exercez pas le métier demandé pour cet étage.",
	['elevators.gradeTooLow'] = 'Votre grade est trop bas pour cet étage.',
	['elevators.offDuty'] = 'Vous devez être en service pour cet étage.',
	['elevators.downed'] = 'Pas pendant que vous êtes à terre.',

	['elevators.noPosition'] = "Votre position n'a pas pu être lue.",
	['elevators.wrongBucket'] = "Vous n'êtes pas devant cet ascenseur. Approchez-vous et réessayez.",
	['elevators.tooFar'] = "Vous êtes trop loin de l'ascenseur.",

	['elevators.help.where'] = 'Affiche chaque ascenseur : position, étages et adoption.',
	['elevators.help.whereKey'] = 'parmi {keys} ; tous les ascenseurs si omis',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
