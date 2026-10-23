--- Public recovery and sorting instructions in both supported languages.
-- @author dop42
local M = OPX.Modules.Get('salvage')
local EN = {
	['salvage.collect'] = 'Recover discarded electronics',
	['salvage.bench'] = 'Sort electronic waste',
	['salvage.item'] = 'Discarded electronics',
	['salvage.progress'] = 'Recovering electronic waste',
	['salvage.done'] = 'Recovered electronics. Sort them at the recovery workbench.',
	['salvage.busy'] = 'This stock is being recovered or has not replenished yet.',
	['salvage.refused'] = 'Recovery unavailable. Stay close, with room in your bag.',
	['salvage.electronics'] = 'Recover usable circuits',
	['salvage.scrap'] = 'Strip scrap metal',
}
local FR = {
	['salvage.collect'] = 'Récupérer les appareils électroniques jetés',
	['salvage.bench'] = 'Trier les déchets électroniques',
	['salvage.item'] = 'Appareils électroniques usagés',
	['salvage.progress'] = 'Récupération de déchets électroniques',
	['salvage.done'] = 'Appareils récupérés. Triez-les à l’atelier de récupération.',
	['salvage.busy'] = 'Ce stock est en cours de récupération ou ne s’est pas encore renouvelé.',
	['salvage.refused'] = 'Récupération indisponible. Restez près du point avec de la place dans votre sac.',
	['salvage.electronics'] = 'Récupérer les circuits utilisables',
	['salvage.scrap'] = 'Extraire la ferraille',
}
M.Catalogs = { en = EN, fr = FR }
OPX.Locale.Register('en', EN)
OPX.Locale.Register('fr', FR)
