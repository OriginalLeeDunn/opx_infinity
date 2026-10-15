# Jobs & commands — full chart, review notes, in-game test checklist

Three catalogues own this area, and every chart below says which one it reads:

| Catalogue | File | Owns |
|---|---|---|
| EMPLOYMENT | `config/character.lua` `JOBS` | the job's name, grades, pay, boss seat |
| TERMS | `config/jobs.lua` `JOBS`/`BOARDS` | where it is joined, who may join, how long a rank takes |
| SURFACES | `config/*.lua` (`COMMANDS`, `JOBS`, `ON_DUTY`) | stations, doors, shops and typed commands tied to a job |

`docs/jobs.md` is the job reference and `docs/commands.md` is the command
reference; this file is the **cross-chart**: which job touches which commands
and surfaces, what the test suite already proves, and exactly what still needs
eyes on a live client.

---

## 1. Master job chart

| Job key | Label | Grades (boss) | Ladder (min) | Sign-up | Pay while off duty | On the air (NCPD alerts) |
|---|---|---|---|---|---|---|
| `ncpd` | NCPD | Cadet→Officer→Detective→**Captain** | 90/360/1080 | open | yes | yes |
| `maxtac` | MaxTac | Operator→**Squad Lead** | 240 | **approval** (needs NCPD grade 2; granted at desk) | yes | yes |
| `trauma` | Trauma Team | Paramedic→Trauma Specialist→Team Lead→**Regional Director** | 120/480/1200 | open | yes | no |
| `ripperdoc` | Ripperdoc | Apprentice→Ripperdoc→**Chrome Surgeon** | 120/480 | open | no (clock in) | no |
| `merc` | Mercenary | Street Merc→Solo→Edgerunner→**Legend** | 60/300/900 | open | always on duty | no |
| `fixer` | Fixer | Runner→Broker→**Fixer** | 60/300 | open | always on duty | no |
| `netrunner` | Netrunner | Script Kiddie→Netrunner→**Blackwall Diver** | 60/300 | open | no (clock in) | no |
| `corp` | Corporate | Intern→Associate→**Director** | 120/480 | open | no (clock in) | no |
| `nomad` | Nomad | Drifter→Clan Runner→**Road Warden** | 60/300 | open | always on duty | no |
| `unemployed` | Unemployed | Freelancer | — | default job | yes | no |
| `arasaka` | Arasaka (hidden) | 4 grades | — | **not offered on any board** — `/opx.job <p> arasaka <g>` only | — | no |
| `militech` | Militech (hidden) | — | — | ditto | — | no |
| `cabbie` | Delamain Driver (hidden) | — | — | ditto | — | no |
| `bartender` | Bartender (hidden) | — | — | ditto | — | no |

Boss seats carry `bankAuth` (NCPD Captain, Trauma Director, Chrome Surgeon,
Fixer, Corporate Director, Arasaka/Militech/Bartender tops) — replicated, **nothing consumes it yet**.

## 2. Job → commands chart

### 2a. Commands a job-holder runs (gameplay)

| Command | NCPD | MaxTac | Trauma | Ripperdoc | Merc | Fixer | Netrunner | Corp | Nomad | Gate |
|---|---|---|---|---|---|---|---|---|---|---|
| `/opx.duty` | ✔ | ✔ | ✔ | ✔ | — (always on) | — (always on) | ✔ | ✔ | — (always on) | everyone |
| **E on signup board** (sign up / work this job / hand in your notice / standing) | ✔ | shows only; a hired operator **works** it here | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | everyone, 4 m radius |
| **E on boss desk** (hire/promote/demote/fire) | Captain | Squad Lead | Regional Director | — no desk ships | — | — | — | — | — | **boss grade**, candidate within 8 m. Only `jobs_desk_city`, `jobs_desk_maxtac` and `jobs_desk_trauma` ship; the other bosses use the commands below, or place a desk with `/opx.jobs.add boss <job>` |
| `/opx.jobs.hire/promote/demote/fire <job> <id>` | boss | boss | boss | boss | boss | boss | boss | boss | boss | boss grade, no ACL |
| `/opx.jobs.join/leave/roster/rank` | operator | operator | operator | operator | operator | operator | operator | operator | operator | ACL `command.opx.jobs.*` |
| `/opx.ncpd.status/report/heat/clear/laws` | ✔ | ✔ | — | — | — | — | — | — | — | ACL (all `restricted`) |
| `/opx.ncpd.av` (the engine's AV route — spawns nothing on this build; `/opx.ncpd.heat 5` flies it) | ✔ | ✔ | — | — | — | — | — | — | — | ACL |
| `/opx.ncpd.board [seat]` (AV crew seat) | on duty, **division rule** | on duty, division rule | — | — | — | — | — | — | — | job ∈ MAXTAC `OPT_IN.JOBS` **and on duty**, or right `opx.ncpd.maxtac` |
| AV pad garage (MaxTac AV recall) | — | ✔ | — | — | — | — | — | — | — | `avgarages` `JOBS = { maxtac = 0 }`, `ON_DUTY = true` |
| AV autopilot (avdrive) | via seat | ✔ | — | — | — | — | — | — | — | pilot of a piloted AV |
| `/opx.clinic.*` tray (fit/repair chrome) | patient | patient | patient | **rip works here** | patient | patient | patient | patient | patient | interaction; ripperdoc job is scene-only |
| `/opx.withdraw` | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | ✔ | everyone |

### 2b. Job-gated SURFACES (not commands)

| Surface | File | Gate |
|---|---|---|
| Dispatch board + radio call-outs | `config/ncpd.lua` `ALERTS` | primary job ∈ {`ncpd`,`maxtac`} **and on duty** |
| MaxTac AV summon + seats | `config/ncpd.lua` `MAXTAC.OPT_IN` | right `opx.ncpd.maxtac` or job = `maxtac`; seats also need duty |
| Uniforms at the tailors (`LOOKS`) | `config/shops.lua` | NCPD patrol set + issue suit `ncpd = 0` + `ON_DUTY`; MaxTac field kit `maxtac = 0` + `ON_DUTY`; Trauma Team outfit `trauma = 0` + `ON_DUTY` — free, offered at a `SHOPS` counter (Jinguji, Second-hand Watson) |
| Gunsmith counter (police) | `config/gunsmith.lua` | door `ncpd = 1` / `maxtac = 0` + `ON_DUTY`; service and patrol rounds at the door's own rank, marksman rounds NCPD Detective+ |
| Gunsmith counter (corpo) | `config/gunsmith.lua` | `arasaka = 0` + `ON_DUTY` |
| Elevators — NCPD HQ | `config/elevators.lua` | Bullpen `ncpd 0`/`maxtac 0`; Holding `ncpd 1` + duty; Evidence `ncpd 2` + duty |
| Elevators — Arasaka Tower | `config/elevators.lua` | Analytics `arasaka 0`; Counterintel `arasaka 2`/`militech 3`; Executive `arasaka 3` + duty |
| Elevators — back rooms | `config/elevators.lua` | `ripperdoc 1`/`trauma 2`; Booths `fixer 0`/`merc 2`; Cellar `fixer 2` |
| Teleport to corpo floor | `config/teleports.lua` | `arasaka = 2` + `ON_DUTY` — **a disabled example at 0,0,0** |
| Skill trees | `config/skills.lua` | seven trunks, fed by the work each names: NCPD ← `ncpd`; MaxTac ← `maxtac`; Corp ← `corp` (+ `arasaka`/`militech`); Nomad ← `nomad` (+ `cabbie`); Street ← every other job (`JOBS = nil`); Ripperdoc ← `ripperdoc`/`trauma`; **Fixer** (the top, Night City Legend) ← `fixer`/`merc`. Staff lever `/opx.skills.level` (restricted) |
| Hauling sites | `config/hauling.lua` | open by default; `JOBS = { nomad = 0 }` whitelists, `ON_DUTY` narrows |
| Dealership floor | `config/dealership.lua` | **public — anybody may buy.** (`COMPANY.JOBS`/`GANGS` are bank toggles, not gates; see R7) |

### 2c. Operator / setup commands (per job area)

| Area | Commands | Gate |
|---|---|---|
| Job boards | `/opx.jobs.add [signup\|boss] [key] <job>` · `.remove` · `.list` | ACL |
| HQ stations | `/opx.headquarters.add [key] [label]` · `.remove` · `.list` | ACL |
| MaxTac AV pads | `/opx.avgarages.add` · `/opx.avgarages.remove` | ACL (**new, undeployed**) |
| Garages | `/opx.garages.list` · `.bring` · `.export` (add/remove **gone** — config only) | ACL |
| Dealership | `/opx.dealership.add/remove/list` · `.stock`/`.buy` (anyone) | ACL / open |
| Clothing | `/opx.clothing.add/remove/list` | ACL |
| Ripperdoc clinic | `/opx.clinic.add/remove/list/tune/diag/record` | ACL |
| Staff back door | `/opx.job <p> <job> [grade]` (incl. MaxTac/boss seats) · `/opx.group` · `/opx.where` | ACL |

---

## 3. Review notes — what is proven, what is not

Legend: **[S]** = covered by the Lua suite (`tests/run.lua`, 3832 checks green,
EXIT=0). **[G]** = needs a live in-game client session. **[D]** = needs
deployment to the node first.

| # | Area | Proven | Review notes |
|---|---|---|---|
| R1 | ~~Job gates & `ncpd_maxtac`~~ **RESOLVED 2026-09-26 — dead config, stripped** | [S] | `ncpd_maxtac` was a draft division name kept in four gate lists (`avgarages` `JOBS`, `ALERTS.JOBS`, `MAXTAC.OPT_IN.JOBS`, `BOARDING.JOBS`) "for the old characters". Evidence says dead: the character catalogue never defined it, and no character row in any database on the box holds it — both RP schemas (prod + staging), live **and** soft-deleted, queried directly. Stripped from all four lists; the ncpd suite now pins the decision with a regression: a job name no catalogue defines does **not** open the AV seats, while `maxtac` does. In game this reduces to the normal check: a real `maxtac` trooper sees the dispatch board and boards the AV (checklist items 9–11). |
| R2 | Jobs: boards & ladder [S] | suite covers terms, ladder (banks only, never promotes), desk actions, capture shadows config | **[G]** Marker draw distance (150 m) and E-prompt at 4 m on a live map; **[G]** the hire scene — candidate within 8 m of the desk or the hire is refused with the right message; **[G]** MaxTac sign-up refusal text ("needs NCPD Detective") vs plain no; **[G]** a full bank does NOT promote (auto-promotion was removed by the owner): the row reads `x / y to <rank>` and only the boss can promote. |
| R3 | Pay & duty [S] logic | **[G]** Paycheck lands every 10 min into the bank while on duty; and for `offDutyPay` jobs (NCPD/MaxTac/Trauma/unemployed) while clocked off; **[G]** Merc/Fixer keep banking seniority with no shift to clock; **[G]** `/opx.duty` cooldown + refusal when a job has no shift. Watch `/opx.where` money before/after a tick. |
| R4 | NCPD heat & AV [S] ledger | **[G]** Crime → wanted stage climbs; `/opx.ncpd.report <law> <p>` moves score→stage with division named; **[G]** dispatch board toast ONCE per `COOLDOWN_MS` per suspect, on the screens of on-duty `ALERTS.JOBS` only (off-duty officer sees nothing); **[G]** `/opx.ncpd.av` spawns the MaxTac AV (client-side spawn) and `/opx.ncpd.board` seats a player — refusal reasons (`not_boarding`/`too_far`/`no_seat`/off duty) must read differently. |
| R5 | avgarages capture [S 17 checks] | **[D][G]** The new `/opx.avgarages.add` (capture + facing = recall yaw) is suite-green but **not deployed** to staging. In game: stand on the pad spot, face the recall direction, run it, check the answer line `maxtac_av1 = { … KIND = "avpad" … HEADING = … }`, paste into `config/avgarages.lua`; then as an on-duty MaxTac operator recall an AV at the pad and confirm it arrives **facing the captured heading** (270° test). Also confirm `uncapture` refuses config pads and unmasks a shadowed config row. |
| R6 | avdrive autopilot [S] | **[G]** MaxTac AV is pilotable; autopilot flies to the map waypoint and lands; leaving the pilot seat cancels it (`avdrive.pilotLeft`). No typed command — verify the prompt/keybind only. |
| R7 | ~~Dealership `JOBS = true`~~ **RESOLVED 2026-09-26 — false positive in this chart, config is correct** | [S] | The `JOBS = true` at `config/dealership.lua:275` is **not a gate** — it sits inside `COMPANY` ("which groups have a company bank") and is one of two **toggles**: `COMPANY.JOBS ~= false` means "a seller's company may be their JOB", `COMPANY.GANGS` is its pair, and `EXCLUDED` names the absence-of-a-group rows. Readers expect a boolean there and get one; the dealership has no job gate at all (anybody buys). The misreading survived because nothing pinned the toggle semantics — now pinned: `dealership: COMPANY.JOBS is a toggle and not a job gate` (job wins over gang, `false` falls back to the gang, `EXCLUDED` skips, both-off is a boot warning), plus a comment in the config heading off the same mistake. |
| R8 | Ripperdoc equip [S 3832 incl. 12 defs] | **[G]** The full live equip flow was never seen on a real client: fit a platform implant (Gorilla Arms), an ability (Sandevistan), and body chrome; verify the trade-in upgrade, capacity refusal text, durability bands (WORN/FAILING/BREAKS) and a ripperdoc repair. `/opx.clinic.diag` is the first stop for any "chrome record not ready". |
| R9 | Clinic chair capture [S] | **[G]** Aim-at-Viktor's-chair capture snaps to the city's chair; `/opx.clinic.tune` nudges the seat within ±2 m; away from any chair `CHAIR_PROP` spawns one. Candidate log lines (`[ripperdoc] chair candidate …`) exist to debug wrong snaps. |
| R10 | HQ stations [S] | **[G]** Capture draws marker + name strip for everyone at once, survives restart only after the config line is pasted; bucket handling (`BUCKET = 0`) in a bucketed server. Plus the **new map blip** (see §5 test) once deployed. |
| R11 | Garages legacy [S] | **[G]** `/opx.garages.export` prints the 18 DB-only garages as a config block (8 KB message chunking is suite-checked) — run it once on staging and paste the result into `config/garages.lua` so they survive a DB reset. `/opx.garages.bring` summons a stored vehicle. |
| R12 | ACL shape | [S] registration | **[G]** `acl.jsonc` grants actually match the typed names on the deployed node (jobs `join/leave/roster/rank` and all capture commands are `command.<name>`). A wrong grant shows as a bland refusal — check the server journal. |
| R13 | Hidden jobs | [S] catalogue | **[G]** `/opx.job 3 arasaka 2` then ride the Arasaka elevator (Counterintel) and the corpo gunsmith counter with duty on — these surfaces have never been exercised because no board offers the job. Same for `militech` (Counterintel floor) and `bartender`/`delamain` (pay only). |
| R14 | Hauling sites | [S] | **[G]** Default open hauling job runs without a job; add `JOBS = { nomad = 0 }` to one site and confirm the whitelist + `ON_DUTY` narrowing actually refuse the wrong holder. |
| R15 | EAC capability bit | header edited | `CapabilityAnticheatActive` is `1ULL << 6` in `_wt-tv-eac` `Protocol.hpp` — **needs the next client rebuild**; until then old clients report the anticheat capability on bit 1 and the server (2.31.15+op77.105) reads bit 6. Verify post-rebuild with a connecting client + `open77_anticheat` `ready -- enforce=on`. |

---

## 4. In-game test checklist

Run on a **staging server** with two clients (one admin,
one civilian) where a test needs a counterpart. Tick as you go; every item names
its expected result.

### A. Jobs & pay
1. ☐ Stand within 4 m of the EMPLOYMENT board, press **E** → board lists 9 jobs with YOUR standing on each (MaxTac row shows the approval terms, not a join button).
2. ☐ Join **NCPD** as Cadet → grade 0 appears in `/opx.where`; `/opx.duty` toggles duty (2 s cooldown).
3. ☐ (Fast ladder test) set `LADDER = { [1] = 1.0 }` in staging `config/jobs.lua`, restart, clock in, wait 1 min → the board reads `1 / 1 to Officer` and the rank does NOT move; the Captain promotes at the desk. Revert after.
4. ☐ Wait one 10-minute paycheck while on duty → bank rises by the grade's `payment`. Clock off and confirm NCPD still pays (`offDutyPay`), and that a Ripperdoc does **not**.
5. ☐ As NCPD Captain (boss), stand a second player within 8 m of the NCPD desk → **E** desk, hire → candidate at grade 0. Promote → demote → fire, each with the 2 s roster cooldown respected; the promoted player stays on the clock.
6. ☐ The desk's hire press refuses a candidate >8 m away (`jobs.candidateAway`). The typed `/opx.jobs.hire ncpd 3` names a connection and does **not** measure the distance, by design.
7. ☐ MaxTac row as a Cadet → "Needs NCPD Detective or above"; as a Detective → "By invitation only". `/opx.job <id> maxtac 1` seats a first Squad Lead, who hires the Detective at the MaxTac desk; the Detective then picks **Work this job** on the MaxTac row at the office.

### B. NCPD / MaxTac
8. ☐ As civilian, commit a crime; as on-duty NCPD, watch the dispatch board toast fire **once** (one suspect climbing stages = one toast per `COOLDOWN_MS`), positions rounded to 10 m.
9. ☐ Off-duty officer sees/heard **nothing** (no radio call-out, no board).
10. ☐ `/opx.ncpd.report <law> <p>` → score/stage readout; `/opx.ncpd.status` shows stage + division; `/opx.ncpd.clear` wipes it.
11. ☐ `/opx.ncpd.heat 5` on a test player → the server flies the MaxTac AV in (`/opx.ncpd.av` alone asks the engine route, which spawns nothing on this build); `/opx.ncpd.board` takes a seat; second call for the same player → `no_seat`/`not_boarding` reasons read distinctly.
12. ☐ Pilot the AV (avdrive) → autopilot to a map waypoint, lands, hands control back; leaving the seat cancels autopilot.

### C. AV pads (new capture command — deploy first)
13. ☐ `/opx.avgarages.add` at the staging pad spot facing 270° → answer contains `maxtac_av1 = { LABEL = …, KIND = "avpad"` + `HEADING = 270.0`; DB row present (`report()` labels it `captured`).
14. ☐ On-duty MaxTac recall at that pad → AV arrives **facing 270°**. Non-MaxTac / off-duty → refused.
15. ☐ `/opx.avgarages.remove maxtac_av1` → pad gone, config row of a shadowed key visible again; removing a **config** pad → "comes from config" refusal.

### D. Ripperdoc
16. ☐ `/opx.clinic.add` aimed at Viktor's chair → snaps to the city chair (check `[ripperdoc] chair candidate` log if it snaps wrong); `/opx.clinic.tune viktor 0 0 0 180` turns the seat.
17. ☐ Fit: Gorilla Arms (platform implant), Sandevistan (ability), Subdermal Armor (body chrome) — each completes, capacity refusal text shows free capacity when over-filled.
18. ☐ Upgrade a fitted piece to a better grade → trade-in price applied. Wear a piece to BREAKS (or set `DURABILITY` fast on staging) → ripperdoc repair at `REPAIR_FRACTION` price.
19. ☐ `/opx.clinic.diag` on a fresh join → names binding/body/projection state instead of a bare "not ready".

### E. HQ & blips
20. ☐ `/opx.headquarters.add test_hq "TEST HQ"` → marker + strip for both clients immediately; answer line pasted into `config/headquarters.lua` survives a restart (captured-only does not).
21. ☐ HQ map blip (`BLIP` block in `config/headquarters.lua`, per station): the pinned station shows on the fullscreen map with its configured sprite/icon+color (needs a current Open77 client build for `color`/`icon`); a station with no `BLIP` block shows no pin; editing the look and restarting re-syncs (pin remade, no duplicates); removing the HQ removes the pin. An ICON also needs `files { "assets/blips/*.svg" }` in `open77.lua`.
22. ☐ `/opx.headquarters.remove test_hq` un-masks a shadowed config key.

### F. Corpo / misc surfaces
23. ☐ `/opx.job <id> arasaka 2` + duty on → Arasaka elevator Counterintel floor opens; gunsmith counter works at `arasaka 0`. `militech 3` also passes Counterintel.
24. ☐ Dealership: `/opx.dealership.stock` as anyone; buy at the dealer with an unemployed character (R7 is resolved — there is no job gate; the only "refusal" is `dealership.noCompany` on the SELLER side, which is the company bank, not access).
25. ☐ Hauling: run one job un-jobbed; whitelist a site to `nomad` and confirm refusals.
26. ☐ `/opx.garages.export` on staging → paste the 18 DB-only garages into `config/garages.lua`; `/opx.garages.bring` one out.

### G. ACL & protocol
27. ☐ Fresh `acl.jsonc` on staging: every `command.<name>` grant in §2c resolves (each command answers, none die with a bland refusal); a clean player is refused all of them.
28. ☐ After the next EAC client rebuild (bit 6): connect, confirm `open77_anticheat` reads `ready -- enforce=on` and the server logs the anticheat capability.

---

## 5. Chart maintenance

- Typed command names live in `config/*.lua` `COMMANDS` blocks (and
  `modules/admin/module.lua` `M.Command` for staff). Renaming there renames the
  line and the ACL grant together.
- Job gates are data, not code: `JOBS = { job = grade }` + `ON_DUTY = true` in
  the surface's config row. New gates need no module changes.
- After any in-game pass, fold findings back into `docs/jobs.md` /
  `docs/commands.md` and tick the §4 items here.
