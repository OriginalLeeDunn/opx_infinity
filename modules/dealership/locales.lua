--- Player-facing text for the strip row, the buy list, every refusal and the
--- command help.
-- @author XEROX710
--
-- Log lines, the diagnostic listing and the error codes themselves stay in
-- English. A dealer's LABEL and a car's name are the operator's own words and
-- live in config, not here -- which is why the price arrives already formatted
-- and no currency is named in these strings.

local EN = {
	['dealership.title'] = 'DEALERSHIP',
	['dealership.refused'] = 'That could not be done.',

	['dealership.key.use'] = 'Open the dealership',
	['dealership.prompt.garage'] = 'Browse vehicles',
	['dealership.prompt.avpad'] = 'Browse AVs',

	['dealership.close'] = 'Close',
	['dealership.back'] = 'Back',
	['dealership.deliverHere'] = 'Buy, deliver here',

	['dealership.bought'] = 'You bought {model}. Plate {plate}.',
	['dealership.handOverBlocked'] =
		'Every spot beside the dealer is taken, so your car is waiting for you in {garage}.',
	['dealership.handOverFailed'] = 'Your car could not be brought round, so it is waiting for you in {garage}.',
	['dealership.defaultGarage'] = 'your garage',

	['dealership.noSuchSpot'] = 'There is no dealership here.',
	['dealership.noSuchEntry'] = 'That is not something this dealership sells.',
	['dealership.notSold'] = 'This dealership does not sell that.',
	['dealership.noSuchGarage'] = 'That is not a garage of yours you can deliver to.',
	['dealership.nothingForSale'] = 'This dealership has nothing in stock.',
	['dealership.noList'] = 'The list could not be opened. Use the buy command instead.',
	['dealership.noCharacter'] = 'Your character is not loaded yet. Try again in a moment.',
	['dealership.noPosition'] = 'Your position could not be read.',
	['dealership.wrongBucket'] = 'You are not at this marker. Step onto it and try again.',
	['dealership.tooFar'] = 'You are too far from the dealer. Stand on the marker and try again.',
	['dealership.cannotAfford'] = 'You cannot afford that.',
	['dealership.noCurrency'] = 'Prices on this server are in a currency that does not exist here. ' ..
		'Tell an operator.',
	['dealership.paymentFailed'] = 'The payment was refused.',
	['dealership.registerFailed'] = 'That vehicle could not be stored, so it was not sold.',
	['dealership.noVehicles'] = 'Vehicles are unavailable on this server.',

	-- Selling face to face, and the two ends of it: the salesperson who offers
	-- and the buyer who answers.
	['dealership.target.sell'] = 'Sell them a vehicle',
	['dealership.offerSent'] = 'Offer sent. They have to accept it themselves.',
	['dealership.offerAccept'] = 'Buy it',
	['dealership.offerDecline'] = 'No thanks',
	['dealership.offerDeclined'] = 'They turned the offer down.',
	['dealership.offerExpired'] = 'The offer was not answered in time.',
	-- No seller's name in any of these: never a name to a stranger.
	['dealership.offerWaiting'] = 'You are being offered a {model}. It opens when you close this list.',
	['dealership.sellerNoCompany'] = 'The seller can no longer sell for that company.',
	['dealership.noOffer'] = 'There is no offer waiting for you.',
	['dealership.noCompany'] =
		'You have no job or gang to sell for, so there is nowhere to pay the money in.',
	['dealership.noSuchBuyer'] = 'That is not somebody you can sell to.',
	['dealership.notInZone'] = 'You have to be inside a dealership to do that.',
	['dealership.buyerNotInZone'] = 'They are not inside the dealership.',
	['dealership.buyerGone'] = 'They are no longer here.',
	['dealership.sellerGone'] = 'The seller is no longer here.',
	['dealership.commission'] = 'You earned {amount} on the {model}.',
	['dealership.soldNoCut'] = 'Sale done: {model}. The whole price went to the company.',

	['dealership.menu.title'] = '{dealer}',
	['dealership.menu.deliver'] = 'Buy the {model}: choose a garage',
	['dealership.menu.pay'] = 'You pay {price}',
	['dealership.menu.sell'] = 'Sell to the person in front of you (#{id})',
	['dealership.menu.sellHint'] = 'They have to accept the offer themselves.',
	['dealership.menu.offer'] = 'Buy the {model}?',
	['dealership.menu.offerHint'] = 'Offered to you for {price}',
	['dealership.dest.none'] = 'Your default garage',

	['dealership.help.list'] = 'Show every dealership and showroom car: kind, position and origin.',
	['dealership.help.stock'] = 'Show what is for sale, and which kind of dealer sells it.',
	['dealership.help.buy'] = 'Buy a model while standing on a dealership marker.',
	['dealership.help.buyKey'] = 'the stock key, as the stock command lists it',
	['dealership.help.buyGarage'] = 'the garage to deliver it to; your default when omitted',
}

local FR = {
	['dealership.title'] = 'CONCESSION',
	['dealership.refused'] = "Cela n'a pas pu être fait.",

	['dealership.key.use'] = 'Ouvrir la concession',
	['dealership.prompt.garage'] = 'Parcourir les véhicules',
	['dealership.prompt.avpad'] = 'Parcourir les AV',

	['dealership.close'] = 'Fermer',
	['dealership.back'] = 'Retour',
	['dealership.deliverHere'] = 'Acheter, livrer ici',

	['dealership.bought'] = 'Vous avez acheté : {model}. Plaque {plate}.',
	['dealership.handOverBlocked'] =
		'Toutes les places près du vendeur sont prises : votre véhicule vous attend dans {garage}.',
	['dealership.handOverFailed'] = "Votre véhicule n'a pas pu être avancé : il vous attend dans {garage}.",
	['dealership.defaultGarage'] = 'votre garage',

	['dealership.noSuchSpot'] = "Il n'y a pas de concession ici.",
	['dealership.noSuchEntry'] = "Cette concession ne vend pas cela.",
	['dealership.notSold'] = 'Cette concession ne vend pas cela.',
	['dealership.noSuchGarage'] = "Ce n'est pas un de vos garages où livrer.",
	['dealership.nothingForSale'] = "Cette concession n'a rien en stock.",
	['dealership.noList'] = "La liste n'a pas pu être ouverte. Utilisez la commande d'achat.",
	['dealership.noCharacter'] = "Votre personnage n'est pas encore chargé. Réessayez dans un instant.",
	['dealership.noPosition'] = "Votre position n'a pas pu être lue.",
	['dealership.wrongBucket'] = "Vous n'êtes pas sur ce marqueur. Placez-vous dessus et réessayez.",
	['dealership.tooFar'] = 'Vous êtes trop loin du concessionnaire. Mettez-vous sur le marqueur.',
	['dealership.cannotAfford'] = 'Vous ne pouvez pas vous le permettre.',
	['dealership.noCurrency'] = "Les prix de ce serveur sont dans une monnaie qui n'existe pas ici. " ..
		'Prévenez un opérateur.',
	['dealership.paymentFailed'] = 'Le paiement a été refusé.',
	['dealership.registerFailed'] = "Ce véhicule n'a pas pu être enregistré, il ne vous a donc pas été vendu.",
	['dealership.noVehicles'] = 'Les véhicules sont indisponibles sur ce serveur.',

	['dealership.target.sell'] = 'Lui vendre un véhicule',
	['dealership.offerSent'] = "Offre envoyée. La personne doit l'accepter elle-même.",
	['dealership.offerAccept'] = 'Acheter',
	['dealership.offerDecline'] = 'Non merci',
	['dealership.offerDeclined'] = "L'offre a été refusée.",
	['dealership.offerExpired'] = "L'offre n'a pas eu de réponse à temps.",
	['dealership.offerWaiting'] = "On vous propose : {model}. L'offre s'ouvrira quand vous fermerez cette liste.",
	['dealership.sellerNoCompany'] = 'Le vendeur ne vend plus pour cette entreprise.',
	['dealership.noOffer'] = "Aucune offre ne vous attend.",
	['dealership.noCompany'] =
		"Vous n'avez ni emploi ni gang pour vendre : l'argent n'aurait nulle part où aller.",
	['dealership.noSuchBuyer'] = "Ce n'est pas quelqu'un à qui vous pouvez vendre.",
	['dealership.notInZone'] = 'Vous devez être dans une concession pour faire cela.',
	['dealership.buyerNotInZone'] = "Cette personne n'est pas dans la concession.",
	['dealership.buyerGone'] = "Cette personne n'est plus là.",
	['dealership.sellerGone'] = "Le vendeur n'est plus là.",
	['dealership.commission'] = 'Vous avez gagné {amount} sur la vente : {model}.',
	['dealership.soldNoCut'] = "Vente conclue : {model}. Tout le prix est allé à l'entreprise.",

	['dealership.menu.title'] = '{dealer}',
	['dealership.menu.deliver'] = 'Acheter : {model} — choisissez un garage',
	['dealership.menu.pay'] = 'Vous payez {price}',
	['dealership.menu.sell'] = 'Vendre à la personne en face de vous (#{id})',
	['dealership.menu.sellHint'] = "La personne doit accepter l'offre elle-même.",
	['dealership.menu.offer'] = 'Acheter : {model} ?',
	['dealership.menu.offerHint'] = 'On vous la propose pour {price}',
	['dealership.dest.none'] = 'Votre garage par défaut',

	['dealership.help.list'] = "Affiche chaque concession et véhicule d'exposition : type, position et origine.",
	['dealership.help.stock'] = 'Affiche ce qui est en vente et quel type de concessionnaire le vend.',
	['dealership.help.buy'] = 'Achète un modèle en étant sur un marqueur de concession.',
	['dealership.help.buyKey'] = 'la clé du stock, telle que la commande stock la liste',
	['dealership.help.buyGarage'] = 'le garage où livrer ; votre garage par défaut si omis',
}

OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
