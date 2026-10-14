--- Player-facing text for the rows, the bars and every refusal.
-- @author dop42
--
-- Log lines, the diagnostic and the refusal CODES themselves stay in English. A
-- site's LABEL and its TARGET wording are the operator's own words and live in
-- `config/hauling.lua`, not here.
--
-- `hauling.refused.generic` is load-bearing and not a filler. Several refusals a
-- player can see come straight off the host -- `Open77.props.attach` alone
-- answers eleven different reasons and the set grows with the platform -- so
-- there will never be a key for every one. The client checks `OPX.Locale.Exists`
-- and falls back here, because `locale` answers the KEY ITSELF for a string
-- nobody wrote and `hauling.refused.invalid_attachment_bone` on a player's screen
-- is worse than a sentence.

local EN = {
	['hauling.row.pickup'] = 'Pick up the crate',
	['hauling.row.pickupHint'] = 'Heavy. Get it into a vehicle.',
	['hauling.row.load'] = 'Load the crate',
	['hauling.row.sell'] = 'Sell the crates',
	['hauling.key.drop'] = 'Hauling: put the crate down',
	['hauling.hint.drop'] = 'Press {key} to put the crate down.',

	['hauling.bar.pickup'] = 'Lifting the crate',
	['hauling.bar.load'] = 'Loading the crate',
	['hauling.bar.deliver'] = 'Selling the crates',

	['hauling.paid'] = 'Sold {count} crate(s) at {dropoff}. Paid {amount}.',

	['hauling.refused.generic'] = 'That did not work.',
	['hauling.refused.no_such_crate'] = 'That crate is not there any more.',
	['hauling.refused.already_claimed'] = 'Somebody got to it first.',
	['hauling.refused.already_carrying'] = 'Your hands are full.',
	['hauling.refused.stale_revision'] = 'That crate moved. Try it again.',
	['hauling.refused.claim_expired'] = 'You took too long, so the crate went back.',
	['hauling.refused.carry_dropped'] = 'You put the crate down to get in. Load it into the trunk to take it along.',
	['hauling.refused.carry_ended'] = 'You are no longer carrying the crate.',
	['hauling.refused.too_soon'] = 'Too fast. Try again.',
	['hauling.refused.too_far'] = 'You are too far away.',
	['hauling.refused.wrong_bucket'] = 'That is not here.',
	['hauling.refused.no_position'] = 'Your position could not be read.',
	['hauling.refused.not_carrying'] = 'You are not carrying anything.',
	['hauling.refused.no_such_vehicle'] = 'That vehicle is not there.',
	['hauling.refused.trunk_full'] = 'The trunk is full.',
	['hauling.refused.not_your_trunk'] = 'That trunk is not yours.',
	['hauling.refused.no_trunk'] = 'That vehicle has no trunk.',
	['hauling.refused.trunk_locked'] = 'The vehicle is locked.',
	['hauling.refused.trunk_refused'] = 'The crate would not go in the trunk.',
	['hauling.refused.no_inventory'] = 'Inventories are not available.',
	['hauling.refused.no_crates'] = 'You have no crates for this buyer, in your bag or in a vehicle parked here.',
	['hauling.refused.no_such_seller'] = 'This buyer is not buying.',
	-- ONE SENTENCE FOR THE WHOLE HOST SET. `Open77.props.attach` answers eleven
	-- codes and grows with the platform, and each of them names a platform
	-- concept -- a bone, an attachment parent, a bucket -- that means nothing to
	-- a player. The server journals its own reason and sends this instead, so
	-- there is no longer a code here that only `generic` can catch.
	['hauling.refused.attach_refused'] = 'The crate would not go there.',
	['hauling.refused.not_paid'] = 'The sale could not be paid. Nothing was taken.',
	['hauling.refused.not_paid_lost'] = 'The sale could not be paid, and some crates could not be put back. Staff have the record to refund you.',
	['hauling.refused.nothing_running'] = 'You were not doing anything.',
	['hauling.refused.busy'] = 'Not while you are loading it.',
	['hauling.refused.rate_limited'] = 'Slow down and try again in a moment.',
	['hauling.refused.no_character'] = 'Your character is not loaded yet. Try again in a moment.',
	['hauling.refused.job_required'] = 'You do not hold the job this site asks for.',
	['hauling.refused.grade_too_low'] = 'Your grade is too low for this site.',
	-- The two codes the shared job gate can answer that this module's own copy of
	-- the rule never could: a site with ON_DUTY set, and a character record that
	-- could not be read fresh enough to decide on.
	['hauling.refused.off_duty'] = 'You would have to be on duty.',
	['hauling.refused.job_stale'] = 'Your record could not be read. Try again.',
	['hauling.refused.no_such_site'] = 'No such site.',
	['hauling.refused.no_carry_config'] = 'Hauling is not set up on this server.',
}

local FR = {
	['hauling.row.pickup'] = 'Ramasser la caisse',
	['hauling.row.pickupHint'] = 'Lourde. À mettre dans un véhicule.',
	['hauling.row.load'] = 'Charger la caisse',
	['hauling.row.sell'] = 'Vendre les caisses',
	['hauling.key.drop'] = 'Transport : poser la caisse',
	['hauling.hint.drop'] = 'Appuyez sur {key} pour poser la caisse.',

	['hauling.bar.pickup'] = 'Levage de la caisse',
	['hauling.bar.load'] = 'Chargement de la caisse',
	['hauling.bar.deliver'] = 'Vente des caisses',

	['hauling.paid'] = '{count} caisse(s) vendue(s) à {dropoff}. Vous touchez {amount}.',

	['hauling.refused.generic'] = "Cela n'a pas fonctionné.",
	['hauling.refused.no_such_crate'] = "Cette caisse n'est plus là.",
	['hauling.refused.already_claimed'] = "Quelqu'un vous a devancé.",
	['hauling.refused.already_carrying'] = 'Vous avez déjà les mains prises.',
	['hauling.refused.stale_revision'] = 'Cette caisse a bougé. Réessayez.',
	['hauling.refused.claim_expired'] = 'Vous avez trop attendu : la caisse est repartie.',
	['hauling.refused.carry_dropped'] = "Vous posez la caisse pour monter. Chargez-la dans le coffre pour l'emporter.",
	['hauling.refused.carry_ended'] = 'Vous ne portez plus la caisse.',

	['hauling.refused.too_soon'] = 'Trop rapide. Réessayez.',
	['hauling.refused.too_far'] = 'Vous êtes trop loin.',
	['hauling.refused.wrong_bucket'] = "Ce n'est pas ici.",
	['hauling.refused.no_position'] = "Votre position n'a pas pu être lue.",
	['hauling.refused.not_carrying'] = 'Vous ne portez rien.',
	['hauling.refused.no_such_vehicle'] = "Ce véhicule n'est plus là.",
	['hauling.refused.trunk_full'] = 'Le coffre est plein.',
	['hauling.refused.not_your_trunk'] = "Ce coffre n'est pas à vous.",
	['hauling.refused.no_trunk'] = "Ce véhicule n'a pas de coffre.",
	['hauling.refused.trunk_locked'] = 'Le véhicule est verrouillé.',
	['hauling.refused.trunk_refused'] = "La caisse n'a pas pu entrer dans le coffre.",
	['hauling.refused.no_inventory'] = "Les inventaires ne sont pas disponibles.",
	['hauling.refused.no_crates'] = "Vous n'avez aucune caisse pour cet acheteur, ni sur vous ni dans un véhicule garé ici.",
	['hauling.refused.no_such_seller'] = "Cet acheteur n'achète pas.",
	['hauling.refused.attach_refused'] = "La caisse n'a pas pu être posée là.",
	['hauling.refused.not_paid'] = "La vente n'a pas pu être payée. Rien n'a été pris.",
	['hauling.refused.not_paid_lost'] = "La vente n'a pas pu être payée et certaines caisses n'ont pas pu être rendues. Le staff a de quoi vous rembourser.",
	['hauling.refused.nothing_running'] = 'Vous ne faisiez rien.',
	['hauling.refused.busy'] = 'Pas pendant le chargement.',
	['hauling.refused.rate_limited'] = 'Ralentissez et réessayez dans un instant.',
	['hauling.refused.no_character'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['hauling.refused.job_required'] = "Vous n'exercez pas le métier demandé sur ce site.",
	['hauling.refused.grade_too_low'] = 'Votre grade est trop bas pour ce site.',
	['hauling.refused.off_duty'] = 'Il faudrait être en service.',
	['hauling.refused.job_stale'] = "Votre fiche n'a pas pu être lue. Réessayez.",
	['hauling.refused.no_such_site'] = "Ce site n'existe pas.",
	['hauling.refused.no_carry_config'] = "Le transport n'est pas configuré sur ce serveur.",
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
