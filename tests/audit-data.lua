-- Explicit schema checks for shipped locale and generated catalogue data.
local files = {
	'modules/admin/locales.lua',
	'modules/animations/locales.lua',
	'modules/appearance/locales.lua',
	'modules/bar/locales.lua',
	'modules/business/locales.lua',
	'modules/calls/locales.lua',
	'modules/camera/locales.lua',
	'modules/character/locales.lua',
	'modules/chat/locales.lua',
	'modules/clothing/locales.lua',
	'modules/contracts/locales.lua',
	'modules/corpo/locales.lua',
	'modules/crafting/locales.lua',
	'modules/dealership/locales.lua',
	'modules/doorlock/locales.lua',
	'modules/downed/locales.lua',
	'modules/elevators/locales.lua',
	'modules/entry/locales.lua',
	'modules/form/locales.lua',
	'modules/fuel/locales.lua',
	'modules/garages/locales.lua',
	'modules/gunsmith/locales.lua',
	'modules/hauling/locales.lua',
	'modules/hud/locales.lua',
	'modules/inventory/locales.lua',
	'modules/invoices/locales.lua',
	'modules/justice/locales.lua',
	'modules/loading/locales.lua',
	'modules/mechanic/locales.lua',
	'modules/media/locales.lua',
	'modules/medical/locales.lua',
	'modules/menu/locales.lua',
	'modules/needs/locales.lua',
	'modules/netrunner/locales.lua',
	'modules/panel/locales.lua',
	'modules/police/locales.lua',
	'modules/progress/locales.lua',
	'modules/prompts/locales.lua',
	'modules/radio/locales.lua',
	'modules/ripperdoc/locales.lua',
	'modules/shops/locales.lua',
	'modules/spawn/locales.lua',
	'modules/target/locales.lua',
	'modules/taxi/locales.lua',
	'modules/teleports/locales.lua',
	'modules/underworld/locales.lua',
	'modules/vehiclekeys/locales.lua',
	'modules/vehicles/locales.lua',
	'modules/workplace/locales.lua',
}
local modules = { admin = { Data = {} }, appearance = { Data = { GARMENTS = {} } } }
local registered = {}
local env = setmetatable({ OPX = {
 Modules = { Get = function(name) modules[name] = modules[name] or {}; return modules[name] end },
 Locale = { Register = function(language, entries)
  assert(type(language) == 'string' and type(entries) == 'table')
  registered[language] = registered[language] or {}
  for key, value in pairs(entries) do
   assert(type(key) == 'string' and key ~= '' and type(value) == 'string', tostring(key))
   assert(utf8.len(value), 'invalid UTF-8: ' .. key)
   assert(registered[language][key] == nil, 'duplicate locale key: ' .. language .. ':' .. key)
   registered[language][key] = value
  end
 end },
}}, { __index = _G })
for _, path in ipairs(files) do assert(loadfile(path, 't', env))() end
local function placeholders(value)
 local names = {}
 for name in value:gmatch('{([%w_]+)}') do names[name] = true end
 return names
end
for key, value in pairs(registered.en) do
 local en, fr = placeholders(value), placeholders(registered.fr[key] or '')
 for name in pairs(en) do assert(fr[name], 'missing French placeholder: ' .. key .. ':' .. name) end
 for name in pairs(fr) do assert(en[name], 'missing English placeholder: ' .. key .. ':' .. name) end
end
local localeCount = 0
for key, value in pairs(registered.en) do
 assert(registered.fr[key] ~= nil, 'missing French locale: ' .. key)
 localeCount = localeCount + 1
end
for key in pairs(registered.fr) do assert(registered.en[key] ~= nil, 'missing English locale: ' .. key) end
for _, path in ipairs({ 'modules/admin/data/peds.lua', 'modules/admin/data/vehicles.lua' }) do
 assert(loadfile(path, 't', env))()
end
local function checkCatalog(data, groupsName, rowsName, groupField, prefix)
 local groups, names, records = {}, {}, {}
 for _, group in ipairs(data[groupsName]) do
  assert(type(group.KEY) == 'string' and group.KEY:match('^[%w_%-]+$'))
  assert(not groups[group.KEY], 'duplicate group: ' .. group.KEY)
  groups[group.KEY] = true
 end
 for _, row in ipairs(data[rowsName]) do
  assert(type(row.NAME) == 'string' and #row.NAME <= 32 and row.NAME:match('^[%w_%-]+$'), tostring(row.NAME))
  assert(type(row.LABEL) == 'string' and utf8.len(row.LABEL), row.NAME)
  assert(type(row.RECORD) == 'string' and row.RECORD:match(prefix), row.NAME)
  assert(groups[row[groupField]], row.NAME .. ': unknown group')
  assert(not names[row.NAME:lower()] and not records[row.RECORD:lower()], 'duplicate catalogue row: ' .. row.NAME)
  names[row.NAME:lower()], records[row.RECORD:lower()] = true, true
 end
 return #data[rowsName]
end
local pedCount = checkCatalog(modules.admin.Data.PEDS, 'FAMILIES', 'PEDS', 'FAMILY', '^Character%.[%w_%.%-]+$')
local vehicleCount = checkCatalog(modules.admin.Data.VEHICLES, 'CLASSES', 'VEHICLES', 'CLASS', '^[%w_%.]+$')
local garments, garmentCount = {}, 0
local images = {}
for part = 1, 5 do
 assert(loadfile(('modules/appearance/data/garments-%d.lua'):format(part), 't', env))()
end
for _, part in ipairs(modules.appearance.Data.GARMENTS) do
 for record, row in pairs(part) do
  assert(type(record) == 'string' and record:match('^Items%.[%w_%.]+$'), tostring(record))
  assert(not garments[record], 'duplicate garment: ' .. record)
  garments[record] = true
  garmentCount = garmentCount + 1
  assert(type(row.NAME) == 'string' and row.NAME ~= '' and #row.NAME <= 120 and utf8.len(row.NAME), record .. ': name')
  for _, family in ipairs({ 'FEMALE', 'MALE' }) do
   local image = row[family]
   if image ~= nil then
    assert(type(image) == 'string' and image:match('^[a-f0-9]+%.webp$') and #image <= 80, record .. ': image')
    if not images[image] then
     local file = assert(io.open('ui/public/images/clothing/' .. image, 'rb'), record .. ': missing image')
     file:close()
     images[image] = true
    end
   end
  end
 end
end
print(('PASS data schema: %d bilingual locale keys, %d peds, %d vehicles, %d garments'):format(localeCount, pedCount, vehicleCount, garmentCount))
