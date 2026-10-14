# Contributing to opx_infinity

Thanks for helping. This file is the workflow and the house style for this
repository. The design record — the two runtimes, how a module is built, and why each
feature's rules are what they are — is [`docs/MANUAL.md`](docs/MANUAL.md); read the
sections that touch your change. The reviewer rules are also on the docs site:
[Contributing](https://opx77-framework.github.io/opx77_doc/docs/guides/contributing).

Questions go to [Discord](https://discord.gg/xpSuYgEYsU). Vulnerabilities go through a
[private security advisory](https://github.com/opx77-framework/opx_infinity/security/advisories/new),
never a public issue. Everyone follows the
[Code of Conduct](https://github.com/opx77-framework/.github/blob/main/CODE_OF_CONDUCT.md).

## Branches and pull requests

**Nothing is pushed to `main` directly.** Branch, push the branch, open a pull
request. `main` is what the test server is expected to be able to run.

```
feat/<thing>     a new capability
fix/<thing>      a defect
audit/<thing>    a sweep across the codebase
docs/<thing>     documentation only
```

For anything larger than a fix, open or comment on an issue first and agree on the
approach. Fill in the pull request template: what changed, why it was wrong before,
which checks you ran, and whether it was **verified in game** — if not, say what still
needs a live check and add the `needs-in-game-test` label.

Update the documentation site ([opx77_doc](https://github.com/opx77-framework/opx77_doc))
in the same change, or open an issue there: a new command, config key, export, event
or refusal code that is not documented is not finished.

## Before you push

From the repository root, with `opx_lib` checked out next to it:

```bash
OPX_LIB_PATH=../opx_lib lua tests/run.lua           # must be green
luac -p $(find . -name '*.lua' -not -name 'open77.lua' -not -path './node_modules/*')
npm ci && npm run typecheck && npm run build        # only if ui/ changed
```

- `tests/run.lua` boots the real manifest against a stub platform (`tests/host.lua`)
  in desktop Lua 5.4, with no game and no database. It loads the **real** `opx_lib`
  from `OPX_LIB_PATH`, not a stub. It also fails on a global the sandbox removes, a
  client-only global such as `require` reached from server code, a module hanging its
  internals off `OPX`, and a manifest that disagrees with the tree.
- `open77.lua` is the manifest DSL, not Lua — `auto_start true` does not parse — so
  it is excluded from the syntax check. **Every Lua file must be listed in the
  manifest** or CI fails: a file nobody listed never loads, and nothing else tells you.
- `npm run build` writes `web/index.html`, which **is** the shipped bundle. Commit it
  with the `ui/` change. The sources under `ui/` never leave the repository.
- CI (`.github/workflows/check.yml`) also runs `tools/check-sandbox-globals.py` (no
  `setmetatable` in a script the client loads, no `require` in one the server loads),
  and refuses SQL outside `lib/server/storage.lua` and `modules/<id>/server/storage.lua`.

### The client budget meter

The client kills a coroutine resume that runs past its instruction budget (about
10,000 VM instructions), **silently, mid-operation**. Desktop Lua has no such limit, so
a green suite does not prove a handler fits. Run the opt-in meter on any client change:

```bash
OPX_BUDGET_METER=5000 OPX_LIB_PATH=../opx_lib lua tests/run.lua
```

At the end it lists every client call site whose worst single resume cost more than
the figure, dearest first: thread resumes, net events, page handlers, event handlers,
key mappings and scheduler jobs. A site on the list is a resume the platform may kill:
split it. To pin a fix, `tests/run.lua` has `callCost(fn, ...)` and
`resumeCost(env, control, start, rounds)`, which count exactly and let a check fail at
the old cost.

### `open77_validate`: what it gets wrong here

The devkit validator (checked against 2.31.13+op77.78) reports errors on `main` that
are not runtime problems. Read past these; treat anything else it says as real.

- **`loadscreen`, `web_ui_page`, `web_ui_auto_create` "unknown directive".** Its
  manifest schema is incomplete. `web_ui_page` is in the server-resources guide's own
  example and the `Open77.webui.default` card; `loadscreen` is what
  `Open77.session.loadScreen` (since op77.11) reports; `web_ui_auto_create false` is
  the convention every opx77 resource uses to create its surface itself. All three
  run in production.
- **`require` in `lib/client/lib.lua` "is nil in the sandbox".** That rule is the
  *server* sandbox. The file is a `client_script`, and the client has `require`
  (the `require` card and the lua-modules guide; `@dependency` since client
  op77.67).
- **`players.damage.apply` / `players.damage.read` "required but not declared".**
  The cards for `setArmor`, `setHealth`, `setMaxHealth`, `setGodMode` and
  `getHealth` list the damage.* names only as an older spelling the runtime still
  accepts; the catalogued names, `players.stats.apply` and `players.stats.read`, are
  declared. Do not add the old spellings. The suite's "permissions the code needs"
  section checks every gated call against the manifest, with either spelling.
- **`Open77.players.setModel` "is in no published server build"**: true, and
  handled. `modules/admin/server/models.lua` looks the natives up before every call,
  the two model commands answer `models_unavailable`, and the server logs one line.
  Tracked in [#110](https://github.com/opx77-framework/opx_infinity/issues/110).

## Commit messages

```
<area>: <what is true now, in plain lowercase words>

Why it was wrong before. If it failed silently, what a player saw.
```

`<area>` is the module or folder: `inventory`, `doorlock`, `shops`, `ui`, `core`,
`tests`, `README`... Several areas are joined with a comma (`tests, README: ...`).
Examples from the history:

```
inventory: a give asks the receiver; an item's needs move on the server
shops: a share code is worn in that shop's fitting room, billed at its prices
ui: a yield between the locale copy and its key list
```

Say what changed and **why it was wrong before**. A reader six months out needs the
argument, not the diff — they can read the diff. If a change fixes something that was
failing silently, say what the symptom looked like from the game, because that is what
somebody will search for.

## House style

### Lua

- **Lua 5.4, not CfxLua**: no vector literals, no backtick hashes, no `?.`, no `+=`.
- **Tabs** in `.lua`; two spaces elsewhere; LF, UTF-8 (see `.editorconfig`).
- **Single quotes**; double quotes only around a string that contains an apostrophe.
- **Annotation blocks.** Every file opens with a `---` summary line and
  `-- @author <name>`, then a comment block that carries the **argument** — why the
  file is shaped this way — not a restatement of the code. Public functions get a
  `---` summary and `-- @param` / `-- @return` where they help:

  ```lua
  --- Server half: the authority on every need, its decay, and the save paths.
  -- @author dop42
  --
  -- THE SERVER OWNS THE VALUES. ...

  --- Loads the stored needs of the character a player has loaded, once. Yields.
  -- @return table|nil the record
  ```

- **One file per manifest line**, in load order; never glob scripts.
- **Modules talk through contracts** (`OPX.Api.Provide` / `OPX.Api.Get`), never by
  reaching into each other's files or tables. Nothing new goes on `OPX` without a
  reason (the suite keeps the list).
- **Read settings late**: `OPX.Config.MODULES[id]` inside a phase, not at file scope.
- **Answer, don't raise.** Prefer a refusal with a named, branchable code over a silent
  fallback. Most functions answer a `Result` — `{ ok = true, value }` or
  `{ ok = false, error, detail }` — because a function that legitimately answers `nil`
  cannot use Lua's `value, reason` convention without ambiguity.
- **Repeating work** goes through `OPX.Scheduler.Every`, not a hand-written loop.
- **SQL** only in the storage bridge and a module's own `server/storage.lua`.

### The rules a reviewer will hold you to

- **Server-authoritative.** Anything arriving on `opx:net:` is a request from a machine
  the player owns. Re-read position, bucket, job, money and inventory from the host
  and the contracts, and re-validate every field before believing it.
- **Client budget.** No loop over a list of unknown size inside one resume: chunk it,
  yield, or move it to its own thread. Run the meter.
- **Never a name to a stranger.** In roleplay a name is learnt by meeting someone. No
  plate, chat line, toast, menu row, offer or payload carries a character's name to a
  player who has not been given it; say where the person stands
  (*To your left · 1.2 m*) or use a server id. The data is removed **at the server**,
  not hidden on the page.
- **English and French, together.** Player-facing text comes from `locale(key, params)`.
  Each `modules/<id>/locales.lua` (and `locales/en.lua` / `locales/fr.lua`) registers
  `en` **and** `fr` with the same keys and the same `{placeholders}`. Logs and error
  codes stay in English. Never rename a key: it may be a code on the wire.
- **Never guess a native.** Open77's API is not in anybody's training data: look it up
  with the Open77 devkit, and if it does not return it for the build you target, it
  does not exist — or say it is *unverified* when the devkit lags the live server.
  Declare its permission in `open77.lua` in the same change.

### The WebUI

Read [`ui/README.md`](ui/README.md) first — it is binding. augmented-ui is the
foundation, not a decoration. One page, two layers: `overlay` never takes focus,
`modal` does. `open77_pause` owns Escape — never bind it. **Hard-code no colour**: the
server's theme reaches the page as CSS custom properties; a literal colour is a surface
the operator cannot recolour.

## Deploying to the test server

Archive from the **commit**, not the working tree, then restart and read the journal
back in the same change — a green suite says nothing about the running server. See
[docs/MANUAL.md, "Deploying"](docs/MANUAL.md#deploying). Never `DROP DATABASE`; empty
tables instead, after a `mysqldump`.

## Licence

By contributing you agree that your contribution is licensed under the
[MIT License](LICENSE) of this repository.
