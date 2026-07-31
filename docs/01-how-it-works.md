# 01 — How it works

## The inversion

Conventional CI/CD for network devices is **push**: a runner opens a connection
to the device and configures it. This repo is **pull**: the device opens a
connection to GitHub and configures itself.

Everything else follows from that one decision.

| | Push (SSH from CI) | Pull (this repo) |
|---|---|---|
| Needs inbound access | Yes | **No** |
| Works behind CGNAT | No | **Yes** |
| Needs a static IP / DDNS | Yes | **No** |
| CI holds prod credentials | Yes — an SSH key that reaches production | No — CI only writes to GitHub |
| Deploy latency | Seconds | Up to the poll interval (1h default) |
| Router offline at deploy time | Deploy fails, drift begins | Applies when it comes back |
| Secrets exposure | In CI env only | Also in release assets → **repo must be private** |

That last row is the honest cost. Everything above it is the benefit.

The "applies when it comes back" property is underrated: a pull model is
**convergent**. A router that was powered off during your release is not a
missed deploy that someone has to remember to re-run. It catches up on its own.
With a fleet, that difference compounds.

## The pieces

```
        YOU                    GITHUB                      ROUTER
         │                        │                          │
  git push to main ─────────────► │                          │
         │                    (nothing                       │
         │                     happens)                      │
         │                        │                          │
  gh release create v7 ─────────► │                          │
         │                   release.yml                     │
         │                   ├ render .rsc                   │
         │                   │  (inject secrets)             │
         │                   └ attach assets                 │
         │                        │                          │
         │                        │ ◄─── GET /releases/latest│ (hourly)
         │                        │      "tag_name": "v7"    │
         │                        │                          │
         │                        │ ◄─── GET each asset ─────│
         │                        │ ─────────────────────────►
         │                        │                    fetch all,
         │                        │                    verify all,
         │                        │                    snapshot,
         │                        │                    import in order,
         │                        │                    check WAN,
         │                        │                    commit or roll back
```

## The apply state machine

`script_SELF_UPDATE` runs hourly. Each run is one pass through this:

```
  poll api.github.com/repos/<repo>/releases/latest
        │
        ├─ network error ──────────────► log, exit. Retry next hour. No changes.
        │
        ├─ tag == flash/deployed-version ─► event: selfupdate_noop. Exit.
        │
        └─ new tag
              │
              ├─ fetch deploy-manifest.json (from the RELEASE, not from git)
              │
              ├─ PHASE 1 ── fetch EVERY asset to disk. Import nothing.
              │      └─ any fetch failed, or any file missing/zero-length?
              │            └─► event: selfupdate_fetch_incomplete
              │                DELETE the partial files, ABORT.
              │                No flag. No marker. No import. Zero changes.
              │                Retry next hour.
              │
              ├─ PHASE 2 ── all assets verified present
              │      ├─ create flash/deploy-in-progress   (arms the boot watchdog)
              │      ├─ run script_PRE_DEPLOY_SNAPSHOT    (the rollback target)
              │      └─ for each manifest entry, IN ORDER:
              │            ├─ "self": true  → skip, defer (see below)
              │            ├─ action=import → /import
              │            └─ action=upload → leave on disk, don't import
              │
              └─ VERIFY: is there an active default route?
                    ├─ NO  ─► event: selfupdate_fail
                    │         write flash/rollback-marker
                    │         /system backup load <newest pre-deploy>
                    │         ══ REBOOT ══ (boot watchdog takes over)
                    │
                    └─ YES ─► write tag to flash/deployed-version
                              remove flash/deploy-in-progress
                              save confirmed-good-<date> backup
                              event: selfupdate_applied (or _applied_warn)
                              arm one-shot to re-import the self asset
```

### Why fetch-all-then-import

This is the single most important safety property, and it is written in blood.

The hourly poll is not synchronised with your release. If a router polls while
`release.yml` is still uploading assets, a naive fetch-and-import loop imports
whatever arrived first and 404s on the rest. In the incident that motivated
this: the cleanup module imported successfully and wiped the wireless config,
then the module that rebuilds it 404'd. WiFi was down until the next hourly run.

Fetching everything first makes a partial release a **no-op** instead of a
partial apply. Nothing is imported until every byte is on disk.

### Why the self-update agent is imported last, and specially

`script_SELF_UPDATE` cannot `/import` the file that defines it. `/import` runs
`/system script remove [find name="script_SELF_UPDATE"]` — removing the script
that is currently the running job. RouterOS handles that badly.

So its manifest entry is marked `"self": true`. The agent fetches it like
everything else, skips it in the import loop, and — only after the deploy is
confirmed good — arms a one-shot scheduler that imports it 30 seconds later, in
the scheduler's own context.

Being last also means a release that breaks something *else* still leaves a
working pull agent to receive the fix.

## The safety nets

There are three, at different layers, catching different failures.

**Net 1 — fetch verification (PHASE 1).** Catches an incomplete or
still-uploading release. Failure mode caught: partial apply.

**Net 2 — inline WAN check.** Immediately after importing, count active default
routes. Zero means the config just cut the router off. Restore the pre-deploy
backup, reboot. Failure mode caught: config that breaks routing without needing
a reboot.

**Net 3 — boot watchdog** (`engine/02-watchdog.rsc`). Runs on every boot, but
does nothing unless `flash/deploy-in-progress` exists. If it does: 20 checks at
15-second intervals. Three consecutive failures → restore, reboot. Twenty clean
checks → clear the flag, save a confirmed-good backup. Failure mode caught: a
config that only breaks after a reboot, or a router that rebooted mid-deploy
before net 2 could run.

The flag file is what ties them together. Net 2 sets it before importing and
clears it on success; net 3 arms itself only when it finds the flag still set,
which means the last deploy did not complete cleanly.

**A stale flag is dangerous.** If a deploy is interrupted and the flag survives,
the next ordinary reboot will arm the watchdog and can trigger an unwanted
rollback. If you ever recover a deploy by hand, remove the flag —
see [04 — Operations](04-operations.md#recovering-a-half-applied-deploy).

### What the safety nets do NOT catch

The watchdog's health check is "is there a working WAN route". A config change
that keeps WAN up while breaking something you care about — WiFi, a VLAN, the
guest network — passes every check and is committed as good.

One real outage was exactly this: an invalid property value aborted the import
of the wireless module, so no radios were configured. WAN was fine throughout.
Nothing rolled back. The lesson is in
[06 — RouterOS gotchas](06-routeros-gotchas.md): probe unfamiliar syntax on a
live box before it goes in a release.

You can extend the check. The WAN test lives in the `VERIFY` step of
`engine/99-self-update.rsc`; add your own assertions there.

## The manifest

`deploy-manifest.json` is the ordered list of what ships and in what order.

```json
{ "action": "import", "path": "config/10-network.rsc",
  "asset": "config__10-network.rsc", "dst": "config__10-network.rsc" }
```

| Field | Meaning |
|---|---|
| `action` | `import` = fetch and `/import`. `upload` = fetch to disk only (for files another device pulls from this router). |
| `path` | Path in the repo. What CI renders. |
| `asset` | Release asset name. Flat — `/` becomes `__` because release assets have no directories. |
| `dst` | Filename on the router. |
| `self` | Optional. `true` on the self-update agent only. |

It is the single source of truth for three consumers: `release.yml` renders it,
`deploy-local.sh` replays it, and the router executes it. There is deliberately
no second ordered list anywhere — that duplication is how the local path and
the remote path drift apart until they disagree about production.

**The manifest travels with the release.** The router fetches the release's own
copy, so every release applies the order it was built with, not whatever the
router last saw.

## Secret injection

`.rsc` files in git contain `PLACEHOLDER_*` tokens, never values.
`secrets.map` maps each token to an environment variable.
`scripts/render.sh` performs the substitution. Both CI and local deploy call it.

Two details worth knowing:

**Comment lines are not substituted.** Each `.rsc` documents its own
placeholders in its header; without this exclusion the rendered asset would
have your PAT pasted into its comments and the documentation would be
unreadable.

**Optional placeholders survive on purpose.** If `GITOPS_DEADMAN_URL` is unset,
the literal `PLACEHOLDER_DEADMAN_URL` reaches the router, and the script detects
the `PLACEHOLDER_` prefix at runtime and disables that feature quietly. You can
run this whole system with no monitoring configured and add it later, without
editing any script.

Required placeholders are enforced twice: `render.sh` refuses to render without
them, and `render.sh --check` refuses to ship an asset that still contains one.

## Why RouterOS specifically

The design would work for any device that can make an HTTPS request and run a
config file. RouterOS makes it unusually practical:

- `/tool fetch` does HTTPS with custom headers — enough to authenticate to the
  GitHub API and download release assets.
- `:deserialize from=json` parses the API response natively. No jq on-device.
- `/system backup save|load` is a genuine atomic snapshot and restore.
- `/system scheduler` gives you the boot hooks the watchdog needs.

The pieces for a self-updating, self-rolling-back device are all in the base
system. No packages, no container, no agent to install.
