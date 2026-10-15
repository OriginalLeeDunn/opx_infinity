--- Resource manifest: scripts, permissions and reload policy.
-- @author dop42
--
-- One file per line, in dependency order. Globs ARE allowed by the manifest
-- grammar and a `dependencies` directive does exist -- both were believed
-- otherwise here until the schema was read -- but a module's files load in an
-- order that matters, and a glob cannot express it. A file that is both listed
-- here and reached by `require` executes twice, so nothing uses `require`.
--
-- The manifest is Lua syntax, so a comment is legal inside a block as well as
-- here. The resource name is a lowercase slug of letters, digits and
-- underscores, and MUST equal the directory name -- a hyphen is not in the set.
--
-- `reload_policy "reconnect"` because this resource owns WebUI surfaces, and a
-- CEF page is never replaced in place.
--
-- Every permission below was checked against build 2.31.13+op77.75 through the
-- Open77 devkit. The ones that are not self-evident:
--   players.stats.apply   `Open77.players.setArmor`, re-applied after a respawn,
--                         and setHealth / setMaxHealth / setGodMode. The cards
--                         (op77.78) list `players.damage.apply` as an older
--                         spelling the runtime still accepts; the catalogued name
--                         is this one, and `players.stats.read` likewise covers
--                         getHealth. `open77_validate` asks for the damage.*
--                         spellings anyway -- a false positive, see CONTRIBUTING.md
--   player.cyberware.read `Open77.appearance.captureBody` needs it ALONGSIDE
--                         player.appearance.read. Without it every other
--                         player's body goes undrawn, and the static validator
--                         misses it because the call is a pcall reference
--   players.disconnect    only for a connection with no verified identity.
--                         Releasing the gate alone would leave them in bucket 0
--                         with no character, for ever. Not a moderation tool
--   ui.vanilla.hud        hiding the game's own HUD while a player is down
--
-- `players.access` gates `Open77.access`, which is the server-local ban list and
-- NOT the ACL. It was dropped as unused and is back: `opx.admin.moderate.ban`
-- calls it. `Open77.players.all` still needs no permission.

resource "opx_infinity"
version "0.2.0"
-- `>=0.0.1`, which is what all 29 shipped system resources and all 21 of the old
-- opx77_* resources declare -- every resource that has ever installed on this
-- platform. A real range with build metadata (`>=2.31.13+op77.67`) is accepted by
-- the SERVER parser and refused by the client at activation, which surfaces only
-- as `resource_activation_failed` with no server-side trace at all.
open77_version ">=0.0.1"
auto_start true

-- The external client library. DECLARED, not optional: `require("@opx_lib")`
-- answers `module_dependency_not_declared` without this line and
-- `module_dependency_not_running` if the resource is not up, and the platform
-- will not start this resource until it is. `lib/client/lib.lua` loads it once
-- and puts it on `OPX.Lib`; see that file for why only the client half uses it.
dependency "opx_lib"

reload_policy "reconnect"

shared_script "core/shared/main.lua"
-- The glyph vocabulary, before anything that validates a name against it: the
-- toast in `core/client/notify.lua`, `Model.ICONS` and `menu.M.ICONS` all point
-- at this one table rather than each carrying a copy.
shared_script "core/shared/glyphs.lua"
shared_script "core/shared/channels.lua"
shared_script "core/shared/registry.lua"
shared_script "core/shared/lifecycle.lua"
-- The creator surfaces' shared gate and answer shapes, read by
-- `core/server/exports.lua` and `core/client/exports.lua` at the foot of this
-- file. Nothing in it runs at load beyond defining functions.
shared_script "core/shared/exports.lua"

shared_script "config/shared.lua"
server_script "config/server.lua"
client_script "config/client.lua"
shared_script "config/character.lua"
shared_script "config/needs.lua"
shared_script "config/downed.lua"
shared_script "config/weather.lua"
server_script "config/vehicles.lua"
-- Shared, unlike the vehicles config above: the client draws the markers and so
-- reads the radii, the kinds and the marker vocabulary here.
shared_script "config/garages.lua"
-- Shared, and it is the garages machinery in its own file: the MaxTac AV recall
-- pads, gated by a job requirement. Both halves coerce the same rows -- the
-- garages module merges this block into its own map at load -- so a block one
-- half refused must be refused by the other.
shared_script "config/avgarages.lua"
-- Shared, though only the key binding is read on the client: the AV autopilot's
-- flight numbers are the server's alone, and the one thing both halves need is
-- the binding's name and id.
shared_script "config/avdrive.lua"
-- Shared: the client reads the reach, the key, the exit fade and the flight
-- sounds to draw the aircraft door and read a flight; the server re-derives
-- every decision (who may fly what, the distance, the seat) from the same file.
shared_script "config/avdoor.lua"
-- Shared like the garages config: the client draws the headquarters marker and
-- reads the look and the name row's cap here, and both halves must refuse the
-- same rows.
shared_script "config/headquarters.lua"
-- Shared because both halves read it: the client draws a board's marker and
-- reads the radius, the marker vocabulary and the key, and the server re-derives
-- every distance, term and ladder level from the same table.
shared_script "config/jobs.lua"
shared_script "config/skills.lua"
-- Shared, like the clothing config: the client draws the chair markers and
-- reads the look, the reach and the key, and the server re-derives the rest.
shared_script "config/ripperdoc.lua"
-- Shared like the garages config, and for the same reason: the client draws the
-- markers and reads the prices here, and both halves must refuse the same rows.
shared_script "config/dealership.lua"
-- Shared like the two above: the client draws a store's marker and reads the
-- radius and the key here, and both halves must refuse the same rows.
shared_script "config/clothing.lua"
-- Shared like the clothing config: the client draws a branch's marker and reads
-- the radius, the key and the quick amounts; the server re-derives every
-- distance, balance and amount from the same table.
shared_script "config/bank.lua"
-- Shared because both halves read it: the server scores from the law book and
-- the client later shows which division is answering. It must also run before
-- `modules/ncpd/module.lua` declares, which every shared config does.
shared_script "config/ncpd.lua"
shared_script "config/chat.lua"
shared_script "config/appearance.lua"
shared_script "config/inventory.lua"
shared_script "config/hud.lua"
shared_script "config/prompts.lua"
shared_script "config/progress.lua"
shared_script "config/loading.lua"
shared_script "config/target.lua"
shared_script "config/shops.lua"
shared_script "config/animations.lua"
-- Shared like the rest, though only the client half reads it: the camera
-- styles offered on the eye. See modules/camera/module.lua.
shared_script "config/camera.lua"
shared_script "config/elevators.lua"
-- Shared: the client reads the reach, the key and the lockpick timings here,
-- and the server re-derives every one of them. See modules/doorlock/module.lua.
shared_script "config/doorlock.lua"
-- Shared like the garages, dealership and clothing configs above, and for the
-- same reason: the client draws an entrance's marker and reads the radius, the
-- marker vocabulary and the key here. The DESTINATIONS are in it too and the
-- client half never reads them -- it is sent the entrances it may see, already
-- judged, and names a key and a leg back. See modules/teleports/module.lua.
shared_script "config/teleports.lua"
-- Shared: the client reads the refusal windows and the handover bar's length
-- here, and the server re-derives every bound the client thinks it knows.
shared_script "config/crafting.lua"
-- Shared like the crafting config above it: the client draws the two spheres of
-- every armoury and reads their positions here, and both halves must refuse the
-- same rows.
shared_script "config/gunsmith.lua"
shared_script "config/hauling.lua"
-- Shared: the client reads the stations, the reach, the key and the prices it
-- draws here, and the server re-derives every one of them. Before the blips
-- config, which pins its stations. See modules/fuel/module.lua.
shared_script "config/fuel.lua"
-- Shared: the client reads the desks it pins on the eye, the treatment labels and
-- the dispatch key here; the server re-derives every bound. See
-- modules/medical/module.lua.
shared_script "config/medical.lua"
-- Shared: both halves declare the module with its settings; the server
-- re-derives every choice it offers. See modules/contracts/module.lua.
shared_script "config/contracts.lua"
shared_script "config/underworld.lua"
-- Shared: the client draws the access points and brokers it reads here, and the
-- server re-derives every one. See modules/netrunner/module.lua.
shared_script "config/netrunner.lua"
-- Shared: the client draws the station desks and lockers and reads the crime
-- labels and the dispatch key here; the server re-derives every one. See
-- modules/police/module.lua.
shared_script "config/police.lua"
-- Shared: the client places the counter, stash and supplier spheres and the map
-- pins it reads here; the server re-derives every price, recipe and gate. See
-- modules/bar/module.lua.
shared_script "config/bar.lua"
-- Shared: the client reads the company labels and pin colours it draws; the
-- server re-derives every fare, distance and seat. See modules/taxi/module.lua.
shared_script "config/taxi.lua"
-- Shared: the client draws the City Hall desk spheres and the role rows from
-- it; the server re-derives every price, gate and bound. See
-- modules/justice/module.lua.
shared_script "config/justice.lua"
-- Shared: the client draws each station's duty, wardrobe and garage spheres
-- from it; the server re-derives every one. See modules/workplace/module.lua.
shared_script "config/workplace.lua"
-- Shared: the client draws the editor desks it reads here and the break's
-- stingers; the server re-derives every desk and price. See modules/media/module.lua.
shared_script "config/media.lua"
-- Shared: the client reads JOBS to draw the "Send a bill" row and the form's
-- ceiling; the server re-derives every one. See modules/invoices/module.lua.
shared_script "config/invoices.lua"
-- Shared: the client draws each corp's offices, drops, terminals and pickups
-- from it; the server re-derives every one. See modules/corpo/module.lua.
shared_script "config/corpo.lua"
-- Shared: the client reads the talk key and the route here; the server re-derives
-- every channel and gate. See modules/radio/module.lua.
shared_script "config/radio.lua"
-- Shared: the client draws the office terminals and filters its eye rows with
-- the same reads the server re-runs. After `config/character.lua`, whose grade
-- tables (`isBoss`, `bankAuth`) it reads. See modules/business/module.lua.
shared_script "config/business.lua"
-- Shared: the client draws each shop's stash and lot spheres and reads the
-- command names here; the server re-derives every bound. See
-- modules/mechanic/module.lua.
shared_script "config/mechanic.lua"
-- AFTER every config it names, which is the only ordering rule it has: the map
-- pins are sourced from garages, dealership, shops, teleports, gunsmith and
-- hauling, and a reader who finds a category here should already have passed
-- the block it comes from. It holds no coordinate of its own -- see its header
-- for why, and for what actually suppressed the blips before this.
shared_script "config/blips.lua"
-- Shared: the client half reads the sound event names, the participant ceiling
-- and the refusal windows here, and the server re-derives every bound the
-- client thinks it knows. See modules/calls/module.lua.
shared_script "config/calls.lua"
shared_script "config/menu.lua"
shared_script "config/form.lua"
shared_script "config/panel.lua"
shared_script "config/entry.lua"
shared_script "config/spawn.lua"
shared_script "config/admin.lua"
-- SERVER ONLY, unlike every other module's config above it. The theme is the
-- one operator block a client must not hold a copy of: the client is told its
-- colours over the wire, and a local copy would be a second answer to "what does
-- this server look like" sitting on the machine least able to be trusted with
-- one. `Settings` is therefore empty on the client, and the client half reads
-- none of it.
server_script "config/theme.lua"

shared_script "lib/shared/result.lua"
shared_script "lib/shared/table.lua"
shared_script "lib/shared/string.lua"
shared_script "lib/shared/math.lua"
-- The job gate, ahead of every module that asks it a question. A `JOBS` block
-- means one thing wherever it is written, and it is decided there: a hand-kept
-- copy of an access decision is how two surfaces end up disagreeing about who
-- may pass, and this file has been re-written by hand twice since it was
-- factored out, each time losing a branch.
shared_script "lib/shared/anchors.lua"
shared_script "lib/shared/jobgate.lua"
-- The placed-spot vocabulary, ahead of every module that places something. The
-- same argument the job gate makes, about a different decision: `garages` and
-- `dealership` held 334 `diff`-clean identical lines of it, and the copy that
-- drifted would be the one drawing an AV pad at floor height or refusing a spot
-- the other module accepted -- a car you can buy at a pad you cannot recall it
-- at. `clothing`, `teleports` and `elevators` carried cut-down copies.
shared_script "lib/shared/spots.lua"
-- Whether a TweakDB record flies. A fact about the record, so it cannot be the
-- three answers it was -- `garages`, `dealership` and the admin catalogue, over
-- three config keys, one of which guarded neither its argument nor an emptied
-- list. It lived in `lib/shared/text.lua`, which measures and cuts display text
-- and does none of this.
shared_script "lib/shared/vehicle.lua"
shared_script "lib/shared/text.lua"
shared_script "lib/shared/validate.lua"
shared_script "lib/shared/hooks.lua"
shared_script "lib/shared/locale.lua"
shared_script "locales/en.lua"
shared_script "locales/fr.lua"
shared_script "lib/shared/citizenid.lua"

server_script "lib/server/storage.lua"
server_script "lib/server/audit.lua"
server_script "lib/server/life.lua"

-- FIRST in the core server block, because it is the far end of a wire the client
-- half wants available before anything else: `core/client/note.lua` says why a
-- client log line nobody can read is worse than no line at all.
server_script "core/server/note.lua"
server_script "core/server/scheduler.lua"
server_script "core/server/sessions.lua"
server_script "core/server/answer.lua"
server_script "core/server/commands.lua"
server_script "core/server/gate.lua"
server_script "core/server/buckets.lua"
server_script "core/server/tunables.lua"
-- The public server bus: `opx:on:*` raised for OTHER resources to hear. Before
-- every module, because every module that announces something calls it.
server_script "core/server/publish.lua"

client_script "lib/client/lib.lua"
client_script "lib/client/surface.lua"
-- The client half of a placed spot: markers and the key, shared by every spot
-- module. After `lib/shared/spots.lua`, which it extends.
client_script "lib/client/spots.lua"
-- Before anything a module can reach, so `OPX.Note` is already there for a module
-- that fails while it is still coming up.
client_script "core/client/note.lua"
client_script "core/client/scheduler.lua"
client_script "core/client/ui.lua"
-- What `menu`, `form` and `panel` share: the id checks, the payload bound, the
-- slider step, the focus responder and the lifecycle around one open view.
-- After `ui.lua`, whose focus calls it answers with, and before all three.
client_script "lib/client/modal.lua"
client_script "core/client/notify.lua"

shared_script "modules/diagnostics/module.lua"
server_script "modules/diagnostics/server/main.lua"
client_script "modules/diagnostics/client/main.lua"

-- EARLY, and the position is the whole of its scheduling. `Start` yields between
-- modules to reset the instruction budget, so a module twenty places down the
-- list asks its question twenty frames later -- and this one's question is what
-- colour the page is. Asked here, the answer is normally in the client's hands
-- before the page has finished mounting. It depends on nothing and provides one
-- read-only contract, so nothing depends on it being later either.
shared_script "modules/theme/module.lua"
shared_script "modules/theme/shared/palette.lua"
server_script "modules/theme/server/main.lua"
client_script "modules/theme/client/main.lua"

shared_script "modules/character/module.lua"
shared_script "modules/character/locales.lua"
server_script "modules/character/server/storage.lua"
server_script "modules/character/server/state.lua"
server_script "modules/character/server/player.lua"
server_script "modules/character/server/groups.lua"
server_script "modules/character/server/character.lua"
server_script "modules/character/server/main.lua"
client_script "modules/character/client/state.lua"
client_script "modules/character/client/main.lua"

shared_script "modules/appearance/module.lua"
shared_script "modules/appearance/locales.lua"
server_script "modules/appearance/server/storage.lua"
server_script "modules/appearance/server/main.lua"
client_script "modules/appearance/client/snapshot.lua"
client_script "modules/appearance/client/main.lua"
client_script "modules/appearance/client/editor.lua"
client_script "modules/appearance/client/clothing.lua"
client_script "modules/appearance/client/presence.lua"
-- The fitting room's garment names and pictures. `garments.lua` first: it makes the
-- table the generated parts append to. The parts are tools/generate-garments.mjs
-- output, split so no file nears the host's 10,000-instruction load check; a
-- rerun that writes a different number of parts says which lines to change here.
client_script "modules/appearance/client/garments.lua"
client_script "modules/appearance/data/garments-1.lua"
client_script "modules/appearance/data/garments-2.lua"
client_script "modules/appearance/data/garments-3.lua"
client_script "modules/appearance/data/garments-4.lua"
client_script "modules/appearance/data/garments-5.lua"
client_script "modules/appearance/client/wardrobe.lua"
-- The seam's other end. `wardrobe.lua` holds both state machines and draws
-- nothing; this is the only file that knows the appearance panel is a `menu` and
-- the fitting room a `panel`. Both contracts are resolved at Start, so this file
-- has no load-order relationship with either of those modules -- only with
-- `wardrobe.lua`, whose seam it reads.
client_script "modules/appearance/client/view.lua"

shared_script "modules/entry/module.lua"
shared_script "modules/entry/locales.lua"
client_script "modules/entry/client/main.lua"

-- Where a character starts, asked on every join. Depends on `character`, which owns
-- placement; `character` reaches back for it through the contract at the moment it
-- needs it, because declaring the dependency both ways is a cycle.
shared_script "modules/spawn/module.lua"
shared_script "modules/spawn/locales.lua"
server_script "modules/spawn/server/main.lua"
client_script "modules/spawn/client/main.lua"

shared_script "modules/needs/module.lua"
shared_script "modules/needs/locales.lua"
server_script "modules/needs/server/storage.lua"
server_script "modules/needs/server/main.lua"
client_script "modules/needs/client/main.lua"

shared_script "modules/downed/module.lua"
shared_script "modules/downed/locales.lua"
server_script "modules/downed/server/storage.lua"
server_script "modules/downed/server/main.lua"
-- The Trauma Team: the page a distress signal sends, the treatment, the pay.
server_script "modules/downed/server/trauma.lua"
-- The Trauma Team's own AV, for a distress signal no medic took.
server_script "modules/downed/server/team.lua"
client_script "modules/downed/client/main.lua"
-- The seam's other end. `main.lua` owns the state machine and draws nothing;
-- this is the only file that knows the down screen is a CEF page.
client_script "modules/downed/client/view.lua"
-- The medic's side of the Trauma Team: the page, the pin, the row, the bar.
client_script "modules/downed/client/trauma.lua"

shared_script "modules/menu/module.lua"
shared_script "modules/menu/locales.lua"
client_script "modules/menu/client/main.lua"

shared_script "modules/form/module.lua"
shared_script "modules/form/locales.lua"
client_script "modules/form/client/main.lua"

shared_script "modules/panel/module.lua"
shared_script "modules/panel/locales.lua"
client_script "modules/panel/client/main.lua"

shared_script "modules/weather/module.lua"
shared_script "modules/weather/shared/clock.lua"
server_script "modules/weather/server/state.lua"
server_script "modules/weather/server/commands.lua"
server_script "modules/weather/server/population.lua"
server_script "modules/weather/server/main.lua"
client_script "modules/weather/client/main.lua"

shared_script "modules/vehicles/module.lua"
shared_script "modules/vehicles/locales.lua"
server_script "modules/vehicles/server/storage.lua"
server_script "modules/vehicles/server/main.lua"

-- Garages and AV pads. After `vehicles`, which it requires: what comes out of a
-- marker is a vehicle that module already owns, and this one creates none of its
-- own. After `character`, which proves the ownership it asks about.
shared_script "modules/garages/module.lua"
shared_script "modules/garages/locales.lua"
shared_script "modules/garages/shared/access.lua"
server_script "modules/garages/server/storage.lua"
server_script "modules/garages/server/main.lua"
client_script "modules/garages/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/garages/client/exports.lua"

-- Dealerships. After `vehicles`, which owns what a character owns, and after
-- `garages`, whose spots are the destinations a purchase may name. Neither is
-- required: without `vehicles` nothing can be sold and without `garages` a
-- purchase is filed under the vehicles module's own default garage.
shared_script "modules/dealership/module.lua"
shared_script "modules/dealership/locales.lua"
shared_script "modules/dealership/shared/access.lua"
server_script "modules/dealership/server/storage.lua"
server_script "modules/dealership/server/main.lua"
client_script "modules/dealership/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/dealership/client/exports.lua"

-- Clothing stores: a marker whose key puts the appearance module's own fitting
-- room up, with the game's whole clothing catalogue in it. After `garages` and
-- `dealership` because it is the third place-shaped module and shares their
-- vocabulary rather than their subject. `appearance` and `prompts` are optional
-- and not required: without either, the markers still draw and the key still
-- answers -- out loud -- that the room is not there.
shared_script "modules/clothing/module.lua"
shared_script "modules/clothing/locales.lua"
shared_script "modules/clothing/shared/access.lua"
server_script "modules/clothing/server/storage.lua"
server_script "modules/clothing/server/main.lua"
client_script "modules/clothing/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/clothing/client/exports.lua"

-- Bank branches: a marker, a key and a menu that moves money between the
-- account a paycheck is paid into and the cash in hand. The fourth
-- place-shaped module after `garages`, `dealership` and `clothing`, sharing
-- their spot vocabulary. The server half needs the character contract for
-- every transaction; `menu`, `form` and `prompts` are optional client surfaces.
shared_script "modules/bank/module.lua"
shared_script "modules/bank/locales.lua"
shared_script "modules/bank/shared/access.lua"
server_script "modules/bank/server/storage.lua"
server_script "modules/bank/server/main.lua"
client_script "modules/bank/client/main.lua"

-- NCPD and MaxTac headquarters: a marker and a name, designating the station
-- the AV pads and garages around it are placed at. The third place-shaped
-- module, sharing the spots vocabulary with `garages`, `dealership` and
-- `clothing` and no subject with any of them. `prompts` is optional: without
-- it the markers still draw and only the name row is missing. Its client half
-- defines the phases on the module itself, so it wears no `exports.lua`.
shared_script "modules/headquarters/module.lua"
shared_script "modules/headquarters/locales.lua"
shared_script "modules/headquarters/shared/access.lua"
server_script "modules/headquarters/server/storage.lua"
server_script "modules/headquarters/server/main.lua"
client_script "modules/headquarters/client/main.lua"

-- NCPD and MaxTac: the law book, the heat ledger, and the response the two
-- divisions put on the street. After `character`, whose loaded character a heat
-- score is bound to -- and which is the only ownership oracle this module trusts
-- for "which citizen did that".
--
-- The two ends are in different repos on purpose. The CONTENT lives here: the law
-- book, the ledger that charges, the response that stands units in the world, and
-- the commands an operator or a job drives it with. The SEAM lives in
-- `open77-base`: `Open77.prevention.setWanted/.requestAv/.state`, the only way to
-- move a star, since every `PreventionSystem` method is scripted and the ones
-- that raise a stage are private. `client/main.lua` is the one file that speaks
-- to that seam, and it names the half it cannot reach instead of failing
-- silently.
shared_script "modules/ncpd/module.lua"
shared_script "modules/ncpd/locales.lua"
shared_script "modules/ncpd/shared/law.lua"
server_script "modules/ncpd/server/ledger.lua"
-- The scanner feed, before the halves that push traffic into it:
-- `M.Radio.Push` has to exist by the time a stage rises or an aircraft moves.
server_script "modules/ncpd/server/radio.lua"
-- The MaxTac insertion, before `response.lua` because the response is what asks
-- it for an aircraft: `M.Av` has to exist by the time a stage is applied.
server_script "modules/ncpd/server/av.lua"
server_script "modules/ncpd/server/response.lua"
-- The operator's crowd of mortal civilians: bodies a kill can be booked
-- against. Before `main.lua`, which starts it and hands it the charge door.
server_script "modules/ncpd/server/bots.lua"
-- The hit relay: what turns a player's shot at one of the bodies above into
-- damage and so into a death. The platform does not carry that shot to the
-- server on its own. Before `main.lua`, which starts it and hands it the reads.
server_script "modules/ncpd/server/hits.lua"
server_script "modules/ncpd/server/main.lua"
client_script "modules/ncpd/client/main.lua"
-- The relay's client half: the host's own `open77:npcHit`, forwarded.
client_script "modules/ncpd/client/hits.lua"
-- The scanner's two halves: its state and rules, then the view seam that is the
-- only file here that knows the other end is a CEF page (README: the view seam).
client_script "modules/ncpd/client/radio.lua"
client_script "modules/ncpd/client/radioview.lua"

-- The skill tree: the character's own ledger, fed by the jobs bank's funnel
-- (`jobs.Event.PAID`) and drawn as seven trunks of nodes a level's point may
-- buy. Before the jobs scripts are not required -- the hook is one guarded
-- subscription in `Start` -- but after them so the funnel is never subscribed
-- before it exists on a fresh boot.
shared_script "modules/skills/module.lua"
shared_script "modules/skills/locales.lua"
shared_script "modules/ripperdoc/module.lua"
-- The whole base-game tray: shared, because the page is drawn from it on the
-- client and every offer is ruled from it on the server.
shared_script "modules/ripperdoc/shared/cyberware.lua"
shared_script "modules/ripperdoc/locales.lua"
server_script "modules/ripperdoc/server/storage.lua"
server_script "modules/ripperdoc/server/records.lua"
server_script "modules/ripperdoc/server/reader.lua"
server_script "modules/ripperdoc/server/chrome.lua"
server_script "modules/ripperdoc/server/sandevistan.lua"
server_script "modules/ripperdoc/server/effects.lua"
server_script "modules/ripperdoc/server/main.lua"
client_script "modules/ripperdoc/client/main.lua"
client_script "modules/ripperdoc/client/recorder.lua"
client_script "modules/ripperdoc/client/view.lua"
client_script "modules/ripperdoc/client/sandevistan.lua"
server_script "modules/skills/server/storage.lua"
server_script "modules/skills/server/main.lua"
client_script "modules/skills/client/main.lua"
-- The view seam: the only file here that knows the other end is a CEF page.
client_script "modules/skills/client/view.lua"

shared_script "modules/chat/module.lua"
shared_script "modules/chat/locales.lua"
server_script "modules/chat/server/main.lua"
client_script "modules/chat/client/main.lua"
-- The seam's other end. `main.lua` holds the state and draws nothing; this is
-- the only file that knows the view is a CEF page, and it claims the open key.
client_script "modules/chat/client/view.lua"

shared_script "modules/inventory/module.lua"
shared_script "modules/inventory/locales.lua"
shared_script "modules/inventory/shared/common.lua"
shared_script "modules/inventory/data/items.lua"
shared_script "modules/inventory/data/weapons.lua"
shared_script "modules/inventory/shared/catalog.lua"
shared_script "modules/inventory/shared/catalog-1.lua"
shared_script "modules/inventory/shared/catalog-2.lua"
shared_script "modules/inventory/shared/catalog-3.lua"
shared_script "modules/inventory/shared/catalog-4.lua"
shared_script "modules/inventory/shared/catalog-5.lua"
server_script "modules/inventory/server/storage.lua"
server_script "modules/inventory/server/containers.lua"
server_script "modules/inventory/server/players.lua"
server_script "modules/inventory/server/world.lua"
server_script "modules/inventory/server/actions.lua"
server_script "modules/inventory/server/currency.lua"
server_script "modules/inventory/server/weapons.lua"
server_script "modules/inventory/server/requests.lua"
server_script "modules/inventory/server/commands.lua"
server_script "modules/inventory/server/main.lua"
client_script "modules/inventory/client/main.lua"
client_script "modules/inventory/client/world.lua"
client_script "modules/inventory/client/keys.lua"
client_script "modules/inventory/client/slotbar.lua"

shared_script "modules/hud/module.lua"
shared_script "modules/hud/locales.lua"
client_script "modules/hud/client/main.lua"

-- The game's own loading screen, read. Client only, no server half and no
-- dependency: it tells the page when to take the HUD-like views off screen and
-- whether to draw the cover, and raises one public event `hud` counts as a
-- screen in front of it. After `hud` only so the file reads in that order --
-- the event is matched by name, and a load seen before `hud` started is read
-- back by nobody it matters to.
shared_script "modules/loading/module.lua"
shared_script "modules/loading/locales.lua"
client_script "modules/loading/client/main.lua"

shared_script "modules/prompts/module.lua"
shared_script "modules/prompts/locales.lua"
server_script "modules/prompts/server/main.lua"
client_script "modules/prompts/client/main.lua"

shared_script "modules/target/module.lua"
shared_script "modules/target/locales.lua"
shared_script "modules/target/shared/model.lua"
client_script "modules/target/client/main.lua"

shared_script "modules/animations/module.lua"
shared_script "modules/animations/locales.lua"
shared_script "modules/animations/shared/common.lua"
shared_script "modules/animations/shared/catalogue.lua"
shared_script "modules/animations/shared/settings.lua"
server_script "modules/animations/server/service.lua"
-- After `service.lua`, whose offer and rate window it uses; before `commands.lua`,
-- which answers `/e accept` through it.
server_script "modules/animations/server/duo.lua"
server_script "modules/animations/server/commands.lua"
server_script "modules/animations/server/main.lua"
client_script "modules/animations/client/walk.lua"
client_script "modules/animations/client/presenter.lua"
client_script "modules/animations/client/main.lua"
client_script "modules/animations/client/keys.lua"
client_script "modules/animations/client/picker.lua"
client_script "modules/animations/client/duo.lua"
client_script "modules/animations/client/prompt.lua"
client_script "modules/animations/client/exports.lua"

-- The player's own camera styles, on the eye. Client only; after `target`,
-- which carries the rows and is optional. `camera.style` below is its only
-- permission.
shared_script "modules/camera/module.lua"
shared_script "modules/camera/locales.lua"
client_script "modules/camera/client/main.lua"

-- The timed-action bar. AFTER `animations`, whose gesture it starts and stops
-- together with the bar, and after `downed`, which takes it away. Both are
-- declared optional, so the dependency walk would order it correctly wherever
-- this block sat -- it is written here so the file reads in the order it runs.
shared_script "modules/progress/module.lua"
shared_script "modules/progress/locales.lua"
client_script "modules/progress/client/main.lua"
-- The server's door onto a player's bar, which times the client's answer itself.
server_script "modules/progress/server/main.lua"

shared_script "modules/elevators/module.lua"
shared_script "modules/elevators/locales.lua"
shared_script "modules/elevators/shared/access.lua"
server_script "modules/elevators/server/main.lua"
client_script "modules/elevators/client/state.lua"
client_script "modules/elevators/client/main.lua"
client_script "modules/elevators/client/panel.lua"
client_script "modules/elevators/client/door.lua"
client_script "modules/elevators/client/exports.lua"

-- Teleports: operator-placed shortcuts to the parts of the map nobody can walk
-- to, some of them locked to a job. After `elevators`, whose job gate it shares
-- through `lib/shared/jobgate.lua` and whose config vocabulary it copies, and
-- after `downed` and `prompts`, both of which it asks and neither of which it
-- requires. Before `admin`, which stays last.
shared_script "modules/teleports/module.lua"
shared_script "modules/teleports/locales.lua"
shared_script "modules/teleports/shared/access.lua"
server_script "modules/teleports/server/main.lua"
client_script "modules/teleports/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/teleports/client/exports.lua"
-- Hauling. After `target`, whose eye is the ENTIRE entry -- there is no command
-- and no key -- and after `character`, which pays for a delivery. `progress`,
-- `inventory` and `animations` are optional and are all ordered above anyway.
-- Needs no permission of its own: `world.props` and `players.animations.control`
-- are already declared for other modules, and this one adds nothing.
shared_script "modules/hauling/module.lua"
shared_script "modules/hauling/locales.lua"
shared_script "modules/hauling/shared/access.lua"
server_script "modules/hauling/server/claim.lua"
server_script "modules/hauling/server/main.lua"
client_script "modules/hauling/client/main.lua"

-- Vehicle keys. After `vehicles`, whose plate is a key's identity, after
-- `inventory`, whose bag a key lives in and whose catalogue declares the item,
-- and after `target`, whose eye carries the lock row -- all three optional and
-- all three ordered above. Before `admin`, which cuts a key for every vehicle
-- staff spawn. Needs no permission of its own: `Open77.vehicles.setLocked` is
-- `world.vehicles` and `isLocked` on the client is `vehicles.read`, both
-- already declared below.
shared_script "modules/vehiclekeys/module.lua"
shared_script "modules/vehiclekeys/locales.lua"
server_script "modules/vehiclekeys/server/main.lua"
client_script "modules/vehiclekeys/client/main.lua"

-- Door locks, ox_doorlock's port. After `character`, `inventory`, `target`,
-- `prompts`, `form` and `progress`, every one of them optional and every one
-- ordered above, so the file reads in the order it runs. Before `admin`, whose
-- World screen opens the panel by command; the panel itself is the Vue view
-- `ui/src/modules/doorlock`, driven by `client/panel.lua`. `world.doors` is already declared below
-- for the staff door switch; the server half calls `open77_doors` through
-- `Open77.exports.call`, which needs no permission of its own.
shared_script "modules/doorlock/module.lua"
shared_script "modules/doorlock/locales.lua"
shared_script "modules/doorlock/shared/access.lua"
server_script "modules/doorlock/server/storage.lua"
server_script "modules/doorlock/server/backend.lua"
server_script "modules/doorlock/server/main.lua"
client_script "modules/doorlock/client/main.lua"
client_script "modules/doorlock/client/panel.lua"
client_script "modules/doorlock/client/exports.lua"

-- Fuel, ox_fuel's port onto the platform's `fuel` bag field. After `character`,
-- `inventory`, `progress`, `target`, `prompts` and `menu`, every one optional
-- and every one ordered above. `world.vehicles` (the engine cut) and
-- `state.write` (the bag) are declared below already; the client reads the bag
-- and the seat under `vehicles.read`. `blips` pins its stations and `hud` draws
-- its gauge, both through the module at run time, so neither order matters.
shared_script "modules/fuel/module.lua"
shared_script "modules/fuel/locales.lua"
shared_script "modules/fuel/shared/model.lua"
server_script "modules/fuel/server/tanks.lua"
server_script "modules/fuel/server/main.lua"
client_script "modules/fuel/client/main.lua"

-- Taxi: Delamain and indie cab companies, the dispatch board, the server-side
-- meter and street fares. After `character` (required) and `menu` (optional).
-- The seat ledger (`Open77.vehicles.getPlayerSeat`, `vehicles.get`) is
-- `world.vehicles` and the call pins / waypoint `ui.vanilla.map`, both declared
-- below already. `invoices`, `accounts` and `weather` are asked at run time.
shared_script "modules/taxi/module.lua"
shared_script "modules/taxi/locales.lua"
shared_script "modules/taxi/shared/model.lua"
server_script "modules/taxi/server/dispatch.lua"
server_script "modules/taxi/server/main.lua"
client_script "modules/taxi/client/main.lua"

-- Business: the company / gang treasuries (`accounts` v1, which takes over the
-- dealership's `opx77_company_accounts` table as it is) and the boss's HR
-- terminal (`business` v1). After `character` (required: the grades, the
-- roster, SetJob / SetGang and the cash), `menu`, `form` and `target`, all
-- optional and all ordered above. No new permission: the distances are
-- `Open77.players.position`, already declared.
shared_script "modules/business/module.lua"
shared_script "modules/business/locales.lua"
shared_script "modules/business/shared/access.lua"
server_script "modules/business/server/storage.lua"
server_script "modules/business/server/accounts.lua"
server_script "modules/business/server/main.lua"
client_script "modules/business/client/main.lua"

-- Medical services: Trauma Team, the street doc, whoever else a config names.
-- After `downed`, whose bus opens the calls and whose `Revive` stands a patient
-- up, and after `character`, `inventory`, `progress`, `target` and `menu`. The
-- heal goes through `Open77.playerInteractions` (`players.interactions.control`)
-- and the host's health (`players.stats.read` / `players.stats.apply`), all
-- declared below already; the call pins use `ui.vanilla.map`, declared too.
shared_script "modules/medical/module.lua"
shared_script "modules/medical/locales.lua"
shared_script "modules/medical/shared/model.lua"
server_script "modules/medical/server/dispatch.lua"
server_script "modules/medical/server/main.lua"
client_script "modules/medical/client/main.lua"

-- Contracts, the fixer / merc gig board. After `character` (required: the
-- escrow, the payouts and the street cred), `inventory` (the package item,
-- registered at runtime), `target`, `menu` and `form`, all optional and all
-- ordered above. `world.npcs` (the district fixers and the drop-off NPCs) and
-- `ui.vanilla.map` (the merc's waypoint) are declared below already.
shared_script "modules/contracts/module.lua"
shared_script "modules/contracts/locales.lua"
shared_script "modules/contracts/shared/access.lua"
server_script "modules/contracts/server/storage.lua"
server_script "modules/contracts/server/main.lua"
client_script "modules/contracts/client/main.lua"

-- The underworld: dirty money, the black market, drug labs, drugs, robberies,
-- laundering and street deals. After `character` and `inventory` (required),
-- and after every optional module it asks at run time; the labs are `crafting`
-- benches registered from its `Start`, which the dependency walk orders after
-- `crafting` wherever this block sits. `world.npcs` (dealers, clerks) and
-- `players.interactions.control` (street deals) are declared below already;
-- `players.screenfx` is this module's, for a drug's screen effect.
shared_script "modules/underworld/module.lua"
shared_script "modules/underworld/locales.lua"
shared_script "modules/underworld/shared/model.lua"
server_script "modules/underworld/server/storage.lua"
server_script "modules/underworld/server/op.lua"
server_script "modules/underworld/server/main.lua"
server_script "modules/underworld/server/drugs.lua"
client_script "modules/underworld/client/main.lua"

-- Netrunner: networks, breach, daemons, shards and brokers. After `character`,
-- `inventory` (required), `progress`, `target`, `menu`, `downed` and
-- `doorlock` (optional), every one ordered above. No new permission: the
-- alert waypoint is `ui.vanilla.map`, declared below for the map pins.
shared_script "modules/netrunner/module.lua"
shared_script "modules/netrunner/locales.lua"
shared_script "modules/netrunner/shared/access.lua"
server_script "modules/netrunner/server/main.lua"
client_script "modules/netrunner/client/main.lua"

-- Police: NCPD, MaxTac, corpo security. After `character` (required) and every
-- optional module it asks at run time (`downed`, `inventory`, `progress`,
-- `vehicles`, `target`, `menu`, `form`), all ordered above. No new
-- permission: `players.interactions.control` (escort), `players.teleport`
-- (cells), `combat.config` (a cuffed player deals no damage),
-- `players.controls` (the cuffs on the suspect's client), `players.life.read`,
-- `world.vehicles` (impound) and `ui.vanilla.map` (call pins) are declared below.
shared_script "modules/police/module.lua"
shared_script "modules/police/locales.lua"
shared_script "modules/police/shared/access.lua"
server_script "modules/police/server/dispatch.lua"
server_script "modules/police/server/main.lua"
client_script "modules/police/client/main.lua"

-- Bar: bartenders, bars and food stalls. After `character`, `inventory`
-- (required), `progress`, `target` and `menu` (optional), all ordered above;
-- `invoices`, `accounts` and `needs` are asked at run time. No new permission:
-- the serve is `players.interactions.control`, the drunk screen
-- `players.screenfx`, the pins `ui.vanilla.map`, all declared below already.
shared_script "modules/bar/module.lua"
shared_script "modules/bar/locales.lua"
shared_script "modules/bar/shared/model.lua"
server_script "modules/bar/server/main.lua"
client_script "modules/bar/client/main.lua"

-- Justice: licences at City Hall, the criminal record, counsel and the court.
-- After `character` (required), `inventory`, `target`, `menu` and `form`
-- (optional), every one ordered above. No new permission: it reads
-- `players.position` and `time.unix`, neither gated.
shared_script "modules/justice/module.lua"
shared_script "modules/justice/locales.lua"
shared_script "modules/justice/shared/access.lua"
server_script "modules/justice/server/storage.lua"
server_script "modules/justice/server/main.lua"
client_script "modules/justice/client/main.lua"
shared_script "modules/workplace/module.lua"
shared_script "modules/workplace/locales.lua"
shared_script "modules/workplace/shared/access.lua"
server_script "modules/workplace/server/main.lua"
client_script "modules/workplace/client/main.lua"

-- Media: N54 News / WNS / the screamsheet -- breaking news, field photos,
-- stories, the editor desks, the tips line. After `character`, `inventory`
-- (required), `progress`, `target`, `form` and `downed` (optional), every one
-- ordered above. `players.screenshot` below is its own, used only when
-- PHOTO.UPLOAD_URL names somewhere for a real picture to go.
shared_script "modules/media/module.lua"
shared_script "modules/media/locales.lua"
shared_script "modules/media/shared/model.lua"
server_script "modules/media/server/main.lua"
client_script "modules/media/client/main.lua"

-- Invoices: bills between players and companies, with consent. After
-- `character` (required: the purse), `target`, `menu` and `form` (optional),
-- all ordered above. `accounts` (module `business`) is read at run time when it
-- runs. No new permission: `players.position` and `time.unix` need none.
shared_script "modules/invoices/module.lua"
shared_script "modules/invoices/locales.lua"
shared_script "modules/invoices/shared/model.lua"
server_script "modules/invoices/server/storage.lua"
server_script "modules/invoices/server/main.lua"
client_script "modules/invoices/client/main.lua"

-- Corpo: Arasaka / Militech assignments, standing, enclave security and
-- espionage. After `character` (required), `inventory`, `progress`, `target`
-- and `menu` (optional), all ordered above. No new permission: the VIP is a
-- server NPC (`world.npcs`), a detained trespasser is walked out with
-- `players.teleport`, the waypoint is `ui.vanilla.map` -- all declared below.
shared_script "modules/corpo/module.lua"
shared_script "modules/corpo/locales.lua"
shared_script "modules/corpo/shared/access.lua"
server_script "modules/corpo/server/main.lua"
server_script "modules/corpo/server/security.lua"
client_script "modules/corpo/client/main.lua"

-- Radio: service channels on the platform's voice. After `character`
-- (required), `inventory`, `menu` and `downed` (optional), all ordered above.
-- No new permission: `voice.manage` (server memberships), `voice.client` (the
-- talk route) and `input.actions` (the talk key) are declared below already.
shared_script "modules/radio/module.lua"
shared_script "modules/radio/locales.lua"
shared_script "modules/radio/shared/model.lua"
server_script "modules/radio/server/main.lua"
client_script "modules/radio/client/main.lua"

-- Mechanic: workshop repairs, the roadside kit, the call board, the tow and the
-- impound lot. After `character` (required), `vehicles`, `inventory`,
-- `progress`, `target` and `menu` (optional), all ordered above. No new
-- permission: the repair natives (`Open77.vehicles.repair`, `setHealth`) are
-- `world.vehicles` and the call pins `ui.vanilla.map`, both declared below.
shared_script "modules/mechanic/module.lua"
shared_script "modules/mechanic/locales.lua"
shared_script "modules/mechanic/shared/model.lua"
server_script "modules/mechanic/server/dispatch.lua"
server_script "modules/mechanic/server/main.lua"
client_script "modules/mechanic/client/main.lua"

-- Clothing shops. After `appearance`, whose fitting room it opens, and after
-- `target`, whose eye carries its row -- both are ordered above. Before
-- `admin`, which stays last.
shared_script "modules/shops/module.lua"
shared_script "modules/shops/locales.lua"
server_script "modules/shops/server/storage.lua"
server_script "modules/shops/server/main.lua"
client_script "modules/shops/client/main.lua"

-- The shared crafting service. AFTER `inventory`, whose bag the materials come
-- out of and whose catalogue says what a recipe may name, and after `character`,
-- which owns the citizen id an order is filed under and the purse a fee comes
-- from -- both are `requires`. After `menu` and `progress`, which are optional
-- and which the dependency walk would order correctly wherever this block sat;
-- it is written here so the file reads in the order it runs.
shared_script "modules/crafting/module.lua"
shared_script "modules/crafting/locales.lua"
shared_script "modules/crafting/shared/recipes.lua"
server_script "modules/crafting/server/storage.lua"
server_script "modules/crafting/server/main.lua"
client_script "modules/crafting/client/main.lua"

-- Employment: the sign-up board a player reads every job on, the seniority
-- ladder a rank is earned on, and the desk a division's boss manages its roster
-- from. AFTER `character`, which owns every membership, grade, duty state and
-- the `/opx.job` command this module grants ranks through -- a rank gained at a
-- desk is the same rank, arriving on the same client event. `menu` and `prompts`
-- are optional: without either, the markers still draw, the key still works and
-- every command still answers.
shared_script "modules/jobs/module.lua"
shared_script "modules/jobs/locales.lua"
shared_script "modules/jobs/shared/seniority.lua"
-- After `seniority.lua`, whose `Top` the terms reader calls to turn a ladder
-- into a level count.
shared_script "modules/jobs/shared/access.lua"
server_script "modules/jobs/server/storage.lua"
server_script "modules/jobs/server/main.lua"
client_script "modules/jobs/client/main.lua"
-- The lifecycle: the registry calls the module, and `Runtime` is what does the
-- work. Without this file the client half is never built.
client_script "modules/jobs/client/exports.lua"

-- The gunsmith, which is the crafting service's first consumer. AFTER
-- `crafting`, whose benches it registers, and after `target`, whose eye carries
-- its two rows. Before `admin`, which stays last.
shared_script "modules/gunsmith/module.lua"
shared_script "modules/gunsmith/locales.lua"
shared_script "modules/gunsmith/shared/access.lua"
server_script "modules/gunsmith/server/main.lua"
client_script "modules/gunsmith/client/main.lua"

-- AFTER ALL FIVE OF ITS SOURCES, and there is no server half to list. The map
-- pins read the garages, dealership and teleports clients' own published lists
-- and the shops, gunsmith and hauling config blocks, so every module it names
-- is declared above it -- which is what lets its `optional` list be honest
-- rather than a set of names resolved later.
--
-- It reaches into other modules and provides nothing back, exactly like `admin`
-- below, and is placed here for the same reason. It is NOT last only because
-- `admin` genuinely has to be: it lists what every other file registered.
shared_script "modules/blips/module.lua"
client_script "modules/blips/client/main.lua"
-- Holocalls. AFTER `character`, whose citizen id a contact row is filed under
-- and whose charInfo names who is calling -- a `requires`, so the dependency
-- walk would order it correctly wherever this block sat; it is written here so
-- the file reads in the order it runs. After `target` and `menu`, which are
-- optional and carry every row and every entry the feature has. Before `admin`,
-- which stays last.
--
-- `shared/model.lua` before either half: both of them index `M.Model`, and the
-- server's `Init` builds a registry out of it on the first phase.
shared_script "modules/calls/module.lua"
shared_script "modules/calls/locales.lua"
shared_script "modules/calls/shared/model.lua"
server_script "modules/calls/server/main.lua"
client_script "modules/calls/client/main.lua"
-- The seam to the page, after the state half for the reason
-- `modules/downed/client/view.lua` gives: the state half publishes on a local
-- event and this is the only file that knows the other end is a CEF page.
client_script "modules/calls/client/view.lua"

-- LAST of the modules, because it reaches into nearly all of them and provides
-- nothing back. Every contract it uses is optional bar `character`: without the
-- menu, the form or the target eye it logs one line each and all 50 commands
-- still work typed.
shared_script "modules/admin/module.lua"
shared_script "modules/admin/locales.lua"
shared_script "modules/admin/data/vehicles.lua"
shared_script "modules/admin/data/peds.lua"
-- The catalogue is split five ways only because of its size; `-5` finishes it.
shared_script "modules/admin/shared/catalog.lua"
shared_script "modules/admin/shared/catalog-1.lua"
shared_script "modules/admin/shared/catalog-2.lua"
shared_script "modules/admin/shared/catalog-3.lua"
shared_script "modules/admin/shared/catalog-4.lua"
shared_script "modules/admin/shared/catalog-5.lua"
-- The ped allowlist, split the same way and for the same reason; `-4` finishes it.
shared_script "modules/admin/shared/peds.lua"
shared_script "modules/admin/shared/peds-1.lua"
shared_script "modules/admin/shared/peds-2.lua"
shared_script "modules/admin/shared/peds-3.lua"
shared_script "modules/admin/shared/peds-4.lua"

-- `main.lua` is the spine and declares the lifecycle; the rest register into it
-- and are called at Start. `inventory` before `weapons` and `menu`; `menu` last,
-- because its access map lists what every other file registered.
server_script "modules/admin/server/main.lua"
server_script "modules/admin/server/players.lua"
-- After `players.lua`: the body states it pushes carry the worn ped, and the two
-- files call each other by name at run time, never at load.
server_script "modules/admin/server/models.lua"
server_script "modules/admin/server/vehicles.lua"
server_script "modules/admin/server/inventory.lua"
server_script "modules/admin/server/weapons.lua"
server_script "modules/admin/server/world.lua"
server_script "modules/admin/server/tags.lua"
server_script "modules/admin/server/combat.lua"
server_script "modules/admin/server/doors.lua"
-- The staff door onto an ACCOUNT'S CHARACTERS, which outlive the session that
-- `players.lua` acts on. Before `menu.lua`, like every other register: the access
-- map that file sends lists what this one registered.
server_script "modules/admin/server/characters.lua"
-- The same door onto people who are NOT connected, which is a query over every
-- account rather than a read of one. Beside `characters.lua` and before
-- `menu.lua` for the same reason: the access map lists what both registered.
server_script "modules/admin/server/offline.lua"

-- The staff door onto a character's PURSE, beside the one onto their account:
-- both reach rows that outlive the session, so both are their own namespace.
server_script "modules/admin/server/recovery.lua"
server_script "modules/admin/server/menu.lua"

client_script "modules/admin/client/main.lua"
client_script "modules/admin/client/keys.lua"
-- Before the controls: they are the only caller of its transition.
client_script "modules/admin/client/noclip.lua"
client_script "modules/admin/client/controls.lua"
client_script "modules/admin/client/forms.lua"
client_script "modules/admin/client/tags.lua"
client_script "modules/admin/client/tagsview.lua"
client_script "modules/admin/client/combat.lua"
client_script "modules/admin/client/doors.lua"
client_script "modules/admin/client/announce.lua"
client_script "modules/admin/client/menu.lua"
client_script "modules/admin/client/target.lua"

-- The AV autopilot: a seated pilot, one key, and a hull posed to the pilot's
-- own map waypoint and handed back at the hover. LAST AMONG THE MODULES ON
-- PURPOSE: it depends on nothing and nothing depends on it, so its `Start` sits
-- at the end of the boot order and cannot delay any other module's by a frame
-- -- which is how a module added mid-list quietly moves every later module's
-- first scheduled pass. The hull is read through `Open77.vehicles`, the
-- waypoint through `Open77.blips.waypoint` (`ui.vanilla.map`, declared above),
-- and the key survives a server whose vehicles are all admin-spawned.
shared_script "modules/avdrive/module.lua"
shared_script "modules/avdrive/locales.lua"
server_script "modules/avdrive/server/main.lua"
client_script "modules/avdrive/client/main.lua"

-- The aircraft door: board a parked AV you may fly (key F), step out of one
-- behind a native fade, and hear a player-flown MaxTac AV. After `avdrive` for
-- the same reason it sits last: it reads the vehicles module's books and the
-- ncpd module's parked hulls through their contracts and nothing waits on it.
shared_script "modules/avdoor/module.lua"
shared_script "modules/avdoor/locales.lua"
server_script "modules/avdoor/server/main.lua"
server_script "modules/avdoor/server/watch.lua"
-- The landing call: the AV's loudspeaker while it comes down (`CALLOUTS`).
server_script "modules/avdoor/server/callout.lua"
-- Where an AV the server flies comes down: ground, level, flat, open (`LANDING`).
server_script "modules/avdoor/server/landing.lua"
-- The landing pad under an AV the server flies, for records the client does
-- not pad itself (`PADS`): who is told to draw it, and the drawing.
server_script "modules/avdoor/server/pad.lua"
client_script "modules/avdoor/client/main.lua"
client_script "modules/avdoor/client/pad.lua"
-- The landing call, played by each game in its own language (`CALLOUTS`).
client_script "modules/avdoor/client/callout.lua"

server_script "core/server/boot.lua"
client_script "core/client/boot.lua"

-- THE CREATOR SURFACE, LAST ON EACH SIDE: the curated exports another resource
-- calls (`exports.opx_infinity:GetPlayerData(id)`, `Open77.exports.call(...)`).
-- Each wraps contracts the modules above publish, reads them at the moment of
-- the call, and registers at file scope, which the platform supports -- so
-- being last is the whole of its scheduling. Needs no permission: publishing
-- an export and naming its caller are both unrestricted, and every native it
-- reaches is reached through a module that already declares its own below.
server_script "core/server/exports.lua"
client_script "core/client/exports.lua"

-- Server-provided loading screen (FiveM-style). The client renders this page from
-- this resource's verified pack files, in a sandboxed surface over the built-in
-- cover, for the whole of the join -- so this server shows its own screen with its
-- own film on it. It runs before any Lua in this resource does and is driven only by
-- the progress events the client forwards to it.
--
-- THE FILM HAS TO BE A WEBM, AND THAT IS NOT A PREFERENCE. The browser this page runs
-- in (CEF) carries Chromium's free codec set only: no H.264 and no AAC. An MP4 handed
-- to it demuxes and then dies with `DEMUXER_ERROR_NO_SUPPORTED_STREAMS`, which is the
-- demuxer saying the container is fine and no stream in it is playable -- so neither
-- `canPlayType` nor the filename is any guide. VP8/VP9/AV1 plus Opus/Vorbis is what
-- plays, and the page's poster and gradient cover for a clip that cannot.
--
-- `web/**` IS ALSO SIZED. scripting/src/ResourceHost.cpp refuses any web file over
-- 16 MiB with `invalid_web_file:<name>`, and that fails the WHOLE RESOURCE rather than
-- the one file -- an oversized video would not just lose the screen, it would stop this
-- resource loading at all. Both limits are checked by byte count and never trusted.
--
-- THE CLIENT PICKS THE FIRST RESOURCE THAT DECLARES ONE, BY DIRECTORY NAME, so a
-- world that also ships a resource sorting earlier than `opx_infinity` -- anything
-- named `open77_*`, `opx_*`, or `a*` -- supplies the screen instead of this one.
-- Both pages are valid; the losing one is simply never mounted. `web/**` above
-- already ships the page and its video.
loadscreen "web/loading.html"

web_ui_page "web/index.html"
web_ui_auto_create false
web_files { "web/**" }
-- The blip icons, as plain client files: `Open77.blips` takes an SVG only from a
-- path the manifest names in `files`, never a web file or a URL. See
-- `config/blips.lua` (ICON) and `web/blips/LICENSE-LUCIDE.txt`.
files { "web/blips/*.svg" }

-- THE AV LANDING CALL'S VOICE (config/avdoor.lua `CALLOUTS`): "Warning. Clear
-- the area. MaxTac landing." and its Trauma Team twin -- the English lines as
-- PCM `.wav` (22.05 kHz mono, under 200 kB each) and the same lines in other
-- languages as `.mp3` (64 kbit/s, under 60 kB each). Each game plays the line
-- in its own language (`Open77.audio.play3D`, local), or the server plays the
-- English one as network audio (`TRANSPORT = 'network'`). A package sound must
-- be declared here or the host refuses it (`audio_asset_not_declared_or_unsafe`),
-- and a declared file is downloaded with the resource.
files { "audio/*.wav", "audio/*.mp3" }

permissions {
  "network.events",

  -- WRITING a replicated state bag; reading one needs nothing, on either side.
  -- `modules/character/server/state.lua` is the only writer in this resource and
  -- the only reason this line is here.
  --
  -- It is NOT in the op77.76 permission catalogue, and that is expected rather
  -- than a second unchecked guess like the two model names at the bottom of this
  -- block: the catalogue lists what a native HANDLER checks, and the bag writer
  -- checks further down -- `server:Open77.state.player` reports "none checked in
  -- the handler" while its own card says "requires `state.write` to write". An
  -- undeclared permission is answered with `permission_denied:<name>`, never with
  -- a refused manifest, so a host that does not know the name loses the bag and
  -- nothing else.
  "state.write",

  -- `MySQL` IS AN ALIAS OF `Open77.database`, so a grep for the namespace finds
  -- nothing but comments while every character, vehicle and inventory row in the
  -- resource goes through it. Removed on 2026-09-21 on exactly that evidence and
  -- restored the same hour: the server came up with
  -- `permission_denied:database.access` and "nobody will be able to connect".
  -- See the header of `lib/server/storage.lua`, which says so in its second line.
  "database.access",


  "world.environment",

  "world.props",

  -- The hauling sellers: one server-owned NPC per drop-off, ALT then sell.
  -- `open77_permissions world.npcs`: enforced by the server, gates
  -- `Open77.npcs.create`/`remove`.
  "world.npcs",

  -- `Open77.vfx.play`/`stop`/`catalog` and `Open77.sfx.play` are gated on this
  -- one name, and its refusal is SILENT: the native answers `nil,
  -- permission_denied:world.effects`, logs nothing, and the effect simply never
  -- appears. The staff noclip pop is the reason this line is here -- without it
  -- there was no pop at all, and nothing on the server said why.
  "world.effects",

  -- THE SANDEVISTAN'S TIME AND SCREEN (`modules/ripperdoc/client/sandevistan.lua`).
  --   world.timescale  `Open77.world.setTimeScale` on the players AROUND a
  --                    boosted one, for the boost and not a millisecond more --
  --                    and on the owner's own view where the build has no lease
  --   vfx.screen       the owner's own full-screen overlay for the boost
  -- Both are CLIENT permissions, and a refusal only ever costs the one layer it
  -- gates.
  --
  -- NOT `world.dilation`. The client probes for an `Open77.dilation` lease
  -- table, but no published build has one (2.31.13+op77.78 neither lists the
  -- namespace nor enforces the permission, and `open77_validate` refuses the
  -- name as one the runtime does not know). The probe finds nothing and the
  -- owner's whole view slows at SELF_FALLBACK_SCALE through `world.timescale`,
  -- which is what every build does today. Declare it again in the same change
  -- that sees the namespace in the catalogue.
  "world.timescale",
  "vfx.screen",
  -- THE AIRCRAFT DOOR'S EXIT FADE (`modules/avdoor/client/main.lua`):
  -- `Open77.screen.fadeOut`/`fadeIn`, the native quest fade that covers the
  -- platform's one-cut AV exit. A CLIENT permission; refused, the exit is the
  -- same cut it always was and nothing else changes.
  "screen.effects",
  -- THE AV LANDING CALL (`modules/avdoor/server/callout.lua`): the server plays
  -- the loudspeaker voice as network package audio (`Open77.audio.play3D`,
  -- `setPosition`, `destroy`). A SERVER permission; refused, an AV lands with
  -- its own engine sounds and nothing else, and the journal says why once.
  "audio.network",
  -- THE LANDING CALL IN EACH PLAYER'S OWN LANGUAGE (`modules/avdoor/client/
  -- callout.lua`): the game plays the line itself (`Open77.audio.play3D`, local
  -- package audio) in the language its voice-over is set to
  -- (`Open77.session.locale`). CLIENT permissions; refused, that game hears no
  -- landing call, and its log says why once.
  "audio.play",
  "session.locale",

  -- The per-bucket ambient policy, which is what decides whether the engine's
  -- own police -- the units a heat stage spawns and the MaxTac AV -- may exist at
  -- all. `world.npcs` is not the same thing: it lets a server CREATE a body, and
  -- this lets the vanilla prevention system do it. Both are needed for an NCPD
  -- response, and without this one every stage is a star with nothing behind it.
  --
  -- Only `modules/ncpd` writes it, and it asks for police and for NOTHING else:
  -- crowd and traffic are read back and written unchanged, so the empty street
  -- stays empty and only the police axis moves.
  "world.population",

  -- The ripperdoc clinic's four, against the .87 cyberware contract:
  -- `define` registers the clinic's definitions at Start, `read` takes
  -- the `current` record every offer consults ("consult `current` for
  -- slot-empty rules"), `manage` stages the install/remove and mints the
  -- operation id, and `animations.control` seats the patient on the
  -- platform's own portable `chair` workspot.
  --
  -- `identity` is the CHARACTER WORKFLOW's, not the shop's: `wiki/cyberware.md`
  -- runs every implant transaction "on their own already-bound character" and
  -- names the character adapter as the binder -- this server runs no
  -- `open77_appearance` adapter, so `modules/character` binds the key it owns
  -- (and stands down the moment one is present).
  "players.cyberware.define",
  "players.cyberware.read",
  "players.cyberware.manage",
  "players.cyberware.identity",
  -- The chrome that does not need a native adapter: `server/effects.lua` puts
  -- a piece's no-fall-damage on the body with `Open77.players.setFallDamage`
  -- (its health, stamina and armor go through `players.stats.apply`, below).
  "players.life.falldamage",
  -- CLIENT: the base-game menu recorder reads which vanilla menu scenario is
  -- on screen (`Open77.session.menuState`, `open77:menuStateChanged`), and the
  -- chair capture asks what the operator is aiming at
  -- (`Open77.character.aimedEntity` needs `player.aim.read` beside
  -- `world.query`). Client permissions: a refusal lands in the player's own
  -- log, so both paths fall back rather than depend on them.
  "session.menus",
  "player.aim.read",
  "players.animations.control",

  -- The movement kit's and the deck's, against the .87 movement and hacking
  -- contracts. Each of `wiki/dash.md`, `wiki/reflex-overdrive.md` and
  -- `wiki/ground-slam.md` names its own three as the manifest set for its
  -- module, and `wiki/hacking.md`'s "Define abilities and install through
  -- existing cyberware" example block names the deck's three the same way:
  --   define    every grade's definition, registered at Start by
  --             `modules/ripperdoc/server/chrome.lua`. Without these the boot
  --             answers `permission_denied:players.<x>.define` per grade and
  --             the shelf stays empty -- every kit install refused after it
  --   manage    `grant`/`revoke`, the doors `arm`/`disarm` open at install
  --             and remove: for a kit piece the grant IS the installation
  --   read      the `current` reader the grant contract pairs with `manage`
  --             (its `projection.status` is the platform's ready signal)
  --   activate  the upload doors (`hacking.start`/`purge`) a fitted deck's
  --             shots are entitled through as the definition provider
  "players.dash.define",
  "players.dash.manage",
  "players.dash.read",
  "players.reflex.define",
  "players.reflex.manage",
  "players.reflex.read",
  "players.abilities.define",
  "players.abilities.manage",
  "players.abilities.read",
  "players.hacking.define",
  "players.hacking.read",
  "players.hacking.activate",

  -- The police scanner's two, against `wiki/voice.md`: `voice.manage` owns the
  -- radio channels this module creates (channel mutations are resource-owned),
  -- and `voice.client` keys the PTT (`setTransmitting` with a `channel:<id>`
  -- intent), turns the volume knob (`setChannelVolume`) and reads the levels
  -- the TX meter and RX lamp show.
  "voice.manage",
  "voice.client",

  "world.vehicles",

  -- The MaxTac squad is spawned by the SERVER as canonical NPCs, which is what
  -- `world.npcs` gates (`wiki/npcs.md`: "Server mutation requires `world.npcs`").
  -- Without this line every trooper is answered `permission_denied:world.npcs`
  -- and the squad silently never arrives -- the exact empty-street failure the
  -- MaxTac roster exists to prevent.
  "world.npcs",

  -- The wanted level, and the MaxTac AV on top of it. `world.prevention` is the
  -- name the platform gates this on (`Open77.prevention.setWanted` / `.requestAv`
  -- / `.state`), and it is a CLIENT permission: there is no server-side
  -- prevention call to gate, because every `PreventionSystem` method is scripted
  -- and only a client's own script frame may call one.
  --
  -- WHAT "PER PLAYER" MEANS HERE. The engine's wanted level is a scalar on a
  -- singleton system, so the lever has no target argument -- it moves the heat of
  -- the world the calling client is simulating. A per-player wanted level works
  -- only because every player runs their own client, which is why the server
  -- sends the charge to ONE connection and this module keeps the player id in the
  -- payload as its own bookkeeping rather than passing it on. An undeclared name
  -- is answered `permission_denied:<name>`, so a host that does not know it loses
  -- the lever and nothing else.
  "world.prevention",

  "acl.read",

  "players.life.read",
  "players.life.kill",
  "players.life.respawn",
  "players.life.revive",

  "players.stats.apply",

  -- `Open77.effects.screen`, a drug's screen effect, in
  -- `modules/underworld/server/drugs.lua` alone. `open77_permissions
  -- players.screenfx` prints this exact manifest line; server-enforced.
  "players.screenfx",

  -- `Open77.players.requestScreenshot`, at the one call site in `screenshot`
  -- in `modules/media/server/main.lua`, and only when `config/media.lua`
  -- PHOTO.UPLOAD_URL is set: the reporter's client captures its own game view
  -- and POSTs it to that URL. `open77_api server:Open77.players.requestScreenshot`
  -- prints this exact manifest line; server-enforced.
  "players.screenshot",

  -- `Open77.players.teleport`, the ONLY thing in this resource that moves a
  -- living body without killing it. `modules/teleports` is its only caller.
  --
  -- CHECKED IN THE DEVKIT, unlike the two model names at the bottom of this
  -- block: `open77_permissions players.teleport` answers with a card of its own
  -- and prints this exact manifest line, so the name is the catalogue's and not
  -- a guess. The catalogue also says it "gates 0 natives", which is the same
  -- shape `state.write` has above -- the listing counts what a native HANDLER
  -- checks, and this one checks further down. The native's own card says
  -- "Requires `players.teleport`" in as many words.
  --
  -- The native arrived in 2.31.13+op77.67. `modules/teleports/server/main.lua`
  -- never assumes it: it looks the function up before every call and refuses
  -- every trip with `unavailable` when it is absent, saying so once at start.
  "players.teleport",

  "players.disconnect",

  -- THE HOLOCALL EYE-GLOW, one declaration per native handler and both names
  -- out of the op77.76 catalogue rather than off a documentation page --
  -- `open77_api server:Open77.players.setHoloCallEyes` prints this exact
  -- manifest line, and the same for the reader. They arrived in
  -- 2.31.13+op77.63, which is older than the op77.75 this ships against.
  --
  --   players.holocall.control  `Open77.players.setHoloCallEyes`, at the two
  --                             call sites in `modules/calls/server/main.lua`
  --                             that are the ONLY writers: `lightEyes` takes
  --                             and renews a bounded lease for a participant,
  --                             `darkenEyes` gives it back. Nothing else in
  --                             this resource lights an eye
  --   players.holocall.read     `Open77.players.getHoloCallEyes`, at the one
  --                             call site in `eyesOn` in the same file. It is
  --                             the sweep's watchdog and the `Eyes` contract
  --                             entry underneath it: the reader answers for
  --                             EVERY resource at once, so it cannot say whose
  --                             lease is whose -- what it can say is that
  --                             there is none at all, which for a live
  --                             participant is a lease the platform dropped
  --
  -- The lease is BOUNDED AND RENEWED rather than held open, which is a decision
  -- and not a detail; `config/calls.lua`'s EYES block and the header of
  -- `modules/calls/server/main.lua` both say why, and the short version is the
  -- one `modules/animations/client/walk.lua` already learned the hard way.
  --
  -- BOTH CALL SITES ARE ON THE SERVER, so a refusal of either lands in the
  -- server journal and not on the player's machine -- unlike `camera.preview`
  -- and `world.query` above, these two can be verified from the host.
  -- `players.holocall.read` is enforced on the client as well and there is a
  -- client `Open77.players.getHoloCallEyes` behind it; this resource does not
  -- call it. The glow a client needs to know about is its own participation,
  -- and the server already pushes that on `opx:net:calls:state`.
  "players.holocall.control",
  "players.holocall.read",

  -- THE CALL'S AUDIO, and the two halves are two permissions because they are
  -- two runtimes. The owner reported it as "quand il repond a l'appel on s'entend
  -- pas", and the reason was that the feature shipped carrying a call's state and
  -- its presentation and no voice at all.
  --
  -- `voice.manage` is the SERVER's, and every call site is in
  -- `modules/calls/server/main.lua`: `Open77.voice.createChannel` in
  -- `channelOf`, `addPlayer` in `joinVoice`, `removePlayer` in `leaveVoice`,
  -- `removeChannel` in `dropChannel`. Membership is reachability and the server
  -- owns reachability; a client asking to be on a call's channel would be a
  -- client granting itself an ear.
  --
  -- `voice.client` is the CLIENT's, for `Open77.voice.setTransmitting` in
  -- `modules/calls/client/main.lua`. It decides which route this machine's own
  -- frames take, which is local presentation policy and cannot grant anything:
  -- the card for it says in as many words that the server still validates every
  -- recipient and membership. Undeclared, the membership would stand and the
  -- player would HEAR the call while nobody heard them -- half a conversation,
  -- refused silently on their own machine, which is the shape of failure this
  -- manifest's comments keep coming back to.
  --
  -- `modules/radio` uses both too: on the server `createChannel`, `addPlayer`,
  -- `removePlayer`, `setChannelPlayerPermissions` and `removeChannel` for the
  -- service channels; on the client `setTransmitting` while its talk key is held.
  "voice.manage",
  "voice.client",

  "player.appearance.read",
  "player.cyberware.read",
  "player.appearance.edit",
  "player.equipment.read",
  "player.equipment.edit",
  -- `Open77.weapons.get` on the server, which is the only thing that can answer
  -- WHETHER A WEAPON IS ACTUALLY IN HAND. The inventory used to answer that from
  -- its own bookkeeping, and the game holsters a weapon by itself often enough
  -- that the two drifted: pressing Use on a weapon the game had already put away
  -- put it away again. The other four weapon calls this resource makes need no
  -- permission; this one does, and the catalogue confirms the name.
  "player.weapons.read",
  "puppets.present",

  -- THE PERMISSION IS AN ARGUMENT, NOT A NAMESPACE, at the only three call
  -- sites that need these two. `OPX.Lib.Native.Call('camera.orbit',
  -- 'camera.preview', ...)` names the method and the permission as STRINGS, so
  -- `Open77.camera` and `Open77.world` genuinely appear nowhere in this tree
  -- outside comments -- and both of these were removed on 2026-09-21 on exactly
  -- that evidence.
  --
  -- What it broke, reported from the game within the hour: the fitting room's
  -- preview camera stopped turning the body (`camera.orbit` / `camera.clearOrbit`),
  -- and the eye stopped resolving anything the ray had to reach for -- yourself,
  -- the sky (`camera.screenRaycast`).
  --
  -- NOTHING SERVER-SIDE SAID SO. Both are CLIENT permissions, so the refusal
  -- lands in the player's own log; the server journal showed zero
  -- `permission_denied` and a clean boot, which is what they were checked
  -- against. A client permission is verified in the game or not at all.
  "camera.preview",

  -- THE PLAYABLE THIRD-PERSON STYLE (client op77.78): framing, FOV, shoulder,
  -- blend. `modules/camera/client/main.lua` calls
  -- `Open77.camera.configureThirdPerson` and `resetThirdPerson`, both gated by
  -- it. The unforced `Open77.perspective.setThirdPerson(true)` it pairs with
  -- needs no permission; only a FORCED lock would need `perspective.policy`,
  -- and nothing here forces one. A CLIENT permission: a missing line shows up
  -- as `permission_denied:camera.style` in the player's log, not the server's.
  "camera.style",
  "world.query",

  "player.travel",

  "input.actions",

  "players.controls",

  "players.animations.control",
  -- `Open77.players.fade` (FadePlayerScreen): the fade to black around a give up
  -- in `modules/downed/server/main.lua`. The client consumes the relay itself.
  "players.screen",
  -- `Open77.world.setPopulation`: the ambient crowd, traffic and NPC police of
  -- the world bucket, from `config/weather.lua` POPULATION.
  "world.population",
  "animations.presentation",

  -- `Open77.playerInteractions.request` and `cancel`, the platform's two-player
  -- coordinator, in `modules/animations/server/duo.lua` alone: an emote with a
  -- nearby player, started once the invited player has accepted. The card for
  -- `request` (since 2.31.13+op77.63) names this exact permission for both
  -- calls. The reads (`get`, `current`) would need `players.interactions.read`;
  -- nothing here calls them. Needs `open77_player_interactions` running on the
  -- server; without it the native is absent and the feature says so once.
  "players.interactions.control",

  "world.elevators",
  "elevators.read",

  -- `Open77.markers.create`/`remove`: the glowing garage and AV pad markers.
  -- One declaration per native handler, and this is the handler's own name.
  "world.markers",

  "players.stats.read",
  "vehicles.read",
  "voice.client",

  "ui.vanilla.hud",

  -- THE NATIVE LOADING LIFECYCLE, read-only: `Open77.screen.isLoading` and
  -- `Open77.screen.loadingState`, both called from `modules/loading/client/
  -- main.lua` and nowhere else. They tell the page when the game's own loading
  -- screen is up, so the HUD-like views step aside and the cover can go up.
  --
  -- NOT IN THE op77.78 CATALOGUE, like the two model names at the bottom of this
  -- block: the reader is newer than the devkit's build and the name is the one
  -- the platform's own page declares. An undeclared permission is answered
  -- `permission_denied:screen.read`, never a refused manifest, so an older host
  -- that does not know the name loses nothing -- and the module looks the
  -- reader up before every pass, so a client without it is simply quiet.
  --
  -- CLIENT permission: a refusal lands in the player's own log, which is why
  -- the module also puts one `[note]` in the server journal when it sees one.
  "screen.read",

  -- THE MAP PINS. `open77_permissions ui.vanilla.map` answers with a card
  -- naming this exact manifest line and the 22 natives in `Open77.blips` it
  -- gates, so the name is the catalogue's and not a guess.
  --
  -- The call sites, all in `modules/blips/client/main.lua` and all of them
  -- gated on this ONE name:
  --   Open77.blips.create   `create()`, the pin itself
  --   Open77.blips.remove   `remove()`, a spot that went away or moved
  --   Open77.blips.clear    `Runtime.Shutdown`, the whole set at stop
  -- `Open77.blips.sprites` is the one function in the namespace that needs no
  -- permission, and this resource does not call it.
  --
  -- CLIENT PERMISSION, WHICH IS WHY IT IS WORTH READING TWICE. The refusal is
  -- `permission_denied:ui.vanilla.map`, it lands in the PLAYER's own log on the
  -- player's own machine, and the server journal says nothing at all. Undeclared,
  -- the map would simply stay empty -- which is indistinguishable from the bug
  -- this module was written to fix, and is exactly how `camera.preview` and
  -- `world.query` were removed from this block on 2026-09-21 against a clean
  -- server boot and had to be put back within the hour.
  --
  -- That is also why `modules/blips/client/main.lua` spends its first
  -- `OPX.Note` saying how many pins went up: a client permission is verified in
  -- the game or it is not verified, and the operator cannot read the client log.
  "ui.vanilla.map",

  -- The plate above a head. The platform draws it labelled with the displayName
  -- the Master vouches for -- the account gamertag -- and for a while this
  -- resource replaced it with the character's name. Neither belongs over a
  -- stranger's head: never a name to a stranger, the owner's decision.
  -- `modules/character/client/state.lua` hides every remote plate instead.
  --
  -- CLIENT permission: a refusal lands in the player's own log and the server
  -- journal says nothing. Verified in the game, or not verified.
  "ui.nameplates",

  -- The staff module, and only the staff module. Every one of these gates a
  -- single call; none is reachable without passing the ACL first.
  --   players.life.visibility  `setVisible`, for `opx.admin.self.invisible`. The
  --                            `isVisible` READER is players.life.read, which is
  --                            already declared above
  --   players.life.freeze      `setFrozen`, for `opx.admin.player.freeze`; the
  --                            `isFrozen` reader is likewise players.life.read
  --   players.access           `Open77.access.ban`
  --   clipboard.write          `Open77.clipboard.setText`, for
  --                            `opx.admin.self.pos` and the copy-door-id row
  --   combat.config            `Open77.combat.setFriendlyFire`
  --   world.doors              the whole `Open77.doors` table the staff door
  --                            switch reads and writes
  --   world.transform          NOT a transform write -- there is none, a
  --                            placement is kill-then-respawn. It gates
  --                            `Open77.character.bonePosition`, which the staff
  --                            name tags read to sit a tag above the head slot.
  --                            Without it every tag falls back to
  --                            TAGS.HEAD_OFFSET_Z and floats
  "players.life.visibility",
  "players.life.freeze",
  "players.access",
  "clipboard.write",
  "combat.config",
  "world.doors",
  "world.transform",

  -- NOT IN THE op77.76 PERMISSION CATALOGUE, and not on the build this ships
  -- against. `Open77.players.setModel` / `.resetModel` / `.getModel` are
  -- documented at https://open2077.net/docs/player-models and arrived after
  -- op77.76, which is the newest build the devkit knows; this server runs
  -- op77.75. The two names below are the ones that page declares, written
  -- exactly as it writes them, and they are the ONLY lines in this manifest that
  -- were not checked against a catalogue.
  --
  -- `server/models.lua` never assumes they took: it looks the natives up before
  -- every call and refuses with `models_unavailable` when they are absent, so an
  -- older host loses the two model commands and nothing else.
  "players.model.control",
  "players.model.read",
}
