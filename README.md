<h1 align="center">OPX//77 · opx_infinity</h1>

<p align="center">
  <strong>A serious-roleplay framework for <a href="https://open2077.net">Open77</a>, the Cyberpunk 2077 multiplayer platform: one resource, one WebUI, server-authoritative.</strong>
</p>

<p align="center">
  <a href="https://github.com/opx77-framework/opx_infinity/actions/workflows/check.yml"><img alt="check" src="https://github.com/opx77-framework/opx_infinity/actions/workflows/check.yml/badge.svg?branch=main"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/github/license/opx77-framework/opx_infinity"></a>
  <img alt="Version 0.2.0" src="https://img.shields.io/badge/version-0.2.0-informational">
  <img alt="Status: alpha" src="https://img.shields.io/badge/status-alpha-orange">
  <a href="https://opx77-framework.github.io/opx77_doc/"><img alt="Documentation" src="https://img.shields.io/badge/docs-opx77__doc-c5003c"></a>
  <a href="https://discord.gg/xpSuYgEYsU"><img alt="Discord" src="https://img.shields.io/badge/discord-join-5865F2?logo=discord&logoColor=white"></a>
</p>

<p align="center">
  <a href="https://opx77-framework.github.io/opx77_doc/docs/getting-started/install">Install</a> ·
  <a href="https://opx77-framework.github.io/opx77_doc/">Documentation</a> ·
  <a href="https://opx77-framework.github.io/opx77_doc/docs/creators">For creators</a> ·
  <a href="CONTRIBUTING.md">Contributing</a> ·
  <a href="https://discord.gg/xpSuYgEYsU">Discord</a>
</p>

---

> [!WARNING]
> **Alpha.** OPX//77 runs on a test server and changes quickly. APIs, config keys and
> features may change without notice; it is not production-ready yet.

## What it is

`opx_infinity` is the whole OPX//77 framework in **a single Open77 resource**: a core
runtime, 36 gameplay modules, one Vue WebUI page and one test suite. It replaced
twenty-one `opx77_*` resources in September 2026. Modules talk to each other through
in-process contracts; other resources reach it through a curated set of exports and
public server events.

It is built around three rules:

- **The server decides.** Every request from a client is re-validated on the server
  before money, items, doors or vehicles move.
- **The client stays inside its budget.** Open77 silently kills a client coroutine that
  runs too long, so every hot path is measured by the test suite.
- **Never a name to a stranger.** A character's name is learnt in roleplay; no plate,
  chat line, menu or payload reveals it.

## Images

Inventory and garment pictures and their upload scripts live in
[opx_images](https://github.com/opx77-framework/opx_images). Run its Windows or
Linux script with your Fivemanage API key, then set the account key in the
framework's **server-only** `config/images.lua`. OPX resolves catalogue file names
automatically. Without this setup, no inventory or garment pictures are displayed.
See [image hosting](docs/MANUAL.md#image-cdn) for the required Open77 HTTP setting.

## Features

- **Characters and economy**: accounts and characters, cash and bank, jobs and gangs
  with grades and duty, company accounts, paychecks, needs (hunger, thirst, stamina,
  street cred) decayed on the server.
- **Join flow**: a join screen, the game's character creator, a name, spawn
  locations, appearance and a fitting room.
- **Inventory**: bag, hotbar, stashes, trunks and gloveboxes, ground piles with real
  props, weapons drawn from the bag (including paired weapons and per-hand ammunition on op77.152+), eddies as a bearer item, gives the receiver accepts.
- **Vehicles**: an owned-vehicle registry, keys as inventory items with a real host
  lock, garages with entries and exits, dealerships with showrooms and
  player-to-player sales paid into a company account, and **fuel** (an ox_fuel port:
  tanks the server burns on the platform's `fuel` bag field, pumps paid in cash or
  bank, jerry cans, a gauge on the vehicle dial).
- **Places and world**: clothing stores, teleports, job-gated elevators, map blips,
  server-owned time and weather, and **door locks** (a faithful ox_doorlock port with
  its own staff panel).
- **Jobs and crafting**: crafting benches, gunsmith armouries, a hauling delivery job.
- **Interaction**: target eye, key prompts with one owner per key, progress bars,
  emotes (every platform animation, solo and duo), holocalls and contacts, chat.
- **Interface**: one Vue page with hand-drawn chamfered shapes (HUD, menus, forms, panels, toasts), recoloured
  live from the server's theme, in **English and French**.
- **Cyberarms**: installed Gorilla Arms can use native cosmetic models and two saved RGB colors at a configured ripperdoc clinic (op77.152+; colors remain local).
- **Staff**: an F9 staff panel and eye rows, ACL-scoped commands, staff immunity,
  audit lines for every privileged action.
- **For creators**: server and client exports with a uniform `{ ok, value | error }`
  answer, public `opx:on:*` server events, runtime items, usable items, crafting benches.

Every module, with its commands, settings, events and refusal codes, is documented on
the [docs site](https://opx77-framework.github.io/opx77_doc/docs/opx_infinity).

## Quick start

You need an **Open77 dedicated server**, a **MySQL** database, and both repositories:
[`opx_lib`](https://github.com/opx77-framework/opx_lib) (the client library) and this
one. The full guide is [Install](https://opx77-framework.github.io/opx77_doc/docs/getting-started/install).

1. **Copy the two resources** into the server's resource root. The folder name must
   equal the resource name. The server only needs
   `open77.lua config core lib locales modules web` from this repository.

   ```text
   resources/
     opx_lib/
     opx_infinity/
   ```

2. **Load them in order**: `opx_lib` before `opx_infinity` (it is a declared
   dependency; the platform will not start `opx_infinity` without it).

   ```jsonc
   // server.jsonc
   "resources": {
     "load": [
       // ... the platform's own resources ...
       "opx_lib",
       "opx_infinity"
     ]
   }
   ```

3. **Connect the database.** Tables are created at first boot; there is nothing to import.

   ```jsonc
   // server.jsonc
   "database": { "enabled": true, "connectionString": "Server=...;Database=...;User ID=...;Password=..." }
   ```

4. **Grant staff rights** in the ACL file named by `accessControl.file` (usually
   `acl.jsonc`). A command namespace needs **both** its opener and its `.*` actions:

   ```text
   command.opx.admin          command.opx.admin.*
   command.opx.garages.*      command.opx.dealership.*     command.opx.clothing.*
   command.opx.doorlock       command.opx.doorlock.*
   command.opx.fuel.*
   command.opx.weather.*      command.opx.time             command.opx.time.*
   ```

5. **Restart and read the journal.** A healthy boot ends with one line per module and
   `opx_infinity 0.2.0 up`. `/opx.modules` and `/opx.version` print the same report in
   game. If something is off, see [Troubleshooting](https://opx77-framework.github.io/opx77_doc/docs/getting-started/troubleshooting).

Server toasts (`OPX.Notify`, `OPX.NotifyLocale`) are drawn by this resource's own
overlay, in the configured theme. The platform's `open77_notifications` package is not
needed for them.

## Configuration

Every setting lives in [`config/`](config): one file per module (`config/<module>.lua`)
plus the runtime-wide `shared.lua`, `server.lua` and `client.lua`. Edit, then restart
the resource. Player-facing text is in each module's `locales.lua` and in
[`locales/`](locales).

See [Configure](https://opx77-framework.github.io/opx77_doc/docs/getting-started/configure)
and the **Configuration** table on each module's page.

## Documentation

| | |
|---|---|
| **[Documentation site](https://opx77-framework.github.io/opx77_doc/)** | Install, configure, every module, every export and event, guides. |
| [`docs/MANUAL.md`](docs/MANUAL.md) | The developer manual: the two runtimes, how a module is built, and the reasoning behind each feature's rules. |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Branches, checks before pushing, commit messages, house style. |
| [`ui/README.md`](ui/README.md) | The WebUI design system. Binding for any change under `ui/`. |

## Development

Requirements: **Lua 5.4** (desktop), **Node.js** and npm, and an `opx_lib` checkout.

```bash
# the test suite boots the real manifest on a stub platform (tests/host.lua)
OPX_LIB_PATH=../opx_lib lua tests/run.lua

# syntax check (open77.lua is the manifest DSL, not Lua)
luac -p $(find . -name '*.lua' -not -name 'open77.lua' -not -path './node_modules/*')

# the WebUI: sources in ui/, the shipped bundle is web/index.html (commit it)
npm ci && npm run typecheck && npm run build

# the client budget meter: lists every client call site whose worst resume
# costs more than the figure (the client kills a resume at about 10,000)
OPX_BUDGET_METER=5000 OPX_LIB_PATH=../opx_lib lua tests/run.lua
```

CI ([`check.yml`](.github/workflows/check.yml)) runs the syntax check, the suite against
the real `opx_lib`, the sandbox-globals check (`tools/check-sandbox-globals.py`), and
checks that every Lua file is listed in the manifest and that SQL stays in storage.

## Contributing

Contributions are welcome: bug reports with journal lines, in-game verification of
[`needs-in-game-test`](https://github.com/opx77-framework/opx_infinity/issues?q=is%3Aopen+label%3Aneeds-in-game-test)
issues, translations, documentation and code. Read [`CONTRIBUTING.md`](CONTRIBUTING.md)
first; nothing is pushed to `main` directly. Everyone taking part follows the
[Code of Conduct](https://github.com/opx77-framework/.github/blob/main/CODE_OF_CONDUCT.md).

Questions belong on [Discord](https://discord.gg/xpSuYgEYsU) rather than in issues.

## Security

Please **do not** report vulnerabilities in public issues. Use a
[private security advisory](https://github.com/opx77-framework/opx_infinity/security/advisories/new);
see the [security policy](https://github.com/opx77-framework/.github/blob/main/SECURITY.md).

## License

[MIT](LICENSE). Copyright © 2026 Luís MOUTA.

## Credits

- Built by **dop42** and the OPX//77 contributors.
- Door locks follow [ox_doorlock](https://github.com/overextended/ox_doorlock) by Overextended;
  the documentation is modelled on the [overextended docs](https://github.com/overextended/overextended.github.io).
- Shape geometry derived from [augmented-ui](https://github.com/propjockey/augmented-ui) (BSD-2, notice in `ui/src/design-system/shapes.css`); fonts Rajdhani,
  Saira and IBM Plex Mono via [Fontsource](https://fontsource.org).
- Wardrobe garment pictures: see [`web/images/clothing/ATTRIBUTION.md`](web/images/clothing/ATTRIBUTION.md).
- Runs on [Open77](https://open2077.net).

Support the project on [Tipeee](https://fr.tipeee.com/dop42/).

<sub>OPX//77 is an independent community project and is not affiliated with or endorsed by CD PROJEKT RED.</sub>
