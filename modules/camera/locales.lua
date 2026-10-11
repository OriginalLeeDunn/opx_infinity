--- Player-facing text for the camera styles.
-- @author dop42

local EN = {
	['camera.group'] = 'Camera',
	['camera.style.default'] = 'Game camera',
	['camera.style.shoulder'] = 'Over the shoulder',
	['camera.style.close'] = 'Close',
	['camera.style.centered'] = 'Centered',
	['camera.style.cinematic'] = 'Cinematic',
	['camera.swap'] = 'Switch shoulder',
	['camera.refused'] = 'The camera could not be changed right now.',
	['camera.owned'] = 'Another script is controlling the camera.',
}

local FR = {
	['camera.group'] = 'Caméra',
	['camera.style.default'] = 'Caméra du jeu',
	['camera.style.shoulder'] = "Par-dessus l'épaule",
	['camera.style.close'] = 'Rapprochée',
	['camera.style.centered'] = 'Centrée',
	['camera.style.cinematic'] = 'Cinématique',
	['camera.swap'] = "Changer d'épaule",
	['camera.refused'] = "La caméra n'a pas pu être changée pour l'instant.",
	['camera.owned'] = 'Un autre script contrôle déjà la caméra.',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
