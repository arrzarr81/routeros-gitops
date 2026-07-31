# 05 — Troubleshooting

Start here, always:

```routeros
/log print where message~"SELF_UPDATE"
/file print where name~"deployed-version"
/file print where name~"deploy-in-progress"
/system scheduler print where name~"SELF_UPDATE"
```

Those four answer most questions: what the agent did, what it thinks is applied,
whether a deploy is stuck, and whether it is even armed.

---

## The release doesn't land

### The agent never runs

**Check:** `/system scheduler print where name="schedule_SELF_UPDATE"`

| What you see | Meaning | Fix |
|---|---|---|
| No such scheduler | The engine was never installed | Re-run `deploy-local.sh` |
| `next-run: startup` | **Dormant** — will not fire until reboot | Remove `start-time=startup` from the scheduler. See below. |
| `next-run: <a time>` | Armed and counting | Look elsewhere |

The dormant case is the nasty one, because the scheduler *exists* and looks
fine. A startup-anchored scheduler doesn't start its interval countdown until
boot, so the agent sits idle indefinitely — and every apply re-adds it, re-arming
the dormancy. `engine/99-self-update.rsc` deliberately uses plain `interval=1h`.

Immediate fix:

```routeros
/system scheduler set [find name=schedule_SELF_UPDATE] start-time="" interval=1h
```

### The agent runs but sees nothing

```routeros
/system script run script_SELF_UPDATE
/log print where message~"SELF_UPDATE"
```

**`release metadata fetch failed`** — the router can't reach the GitHub API.

```routeros
/tool fetch url="https://api.github.com" output=user as-value
/ip dns print                                 ;# resolvers configured?
/ping 8.8.8.8 count=3                         ;# routing works?
/system clock print                           ;# see below
```

A wrong clock breaks TLS certificate validation and every fetch fails with an
error that doesn't mention time. Check it early:

```routeros
/system ntp client set enabled=yes servers=pool.ntp.org
```

**Fetches work but no release is found** — usually the PAT:

- Fine-grained token, **this** repo selected, `Contents: Read-only`
- Not expired
- The repo actually has a **published** release (a draft is invisible to the API)

Verify from your machine with the same token:

```bash
curl -sS -H "Authorization: token $GITOPS_GITHUB_PAT" \
     -H "Accept: application/vnd.github+json" \
     https://api.github.com/repos/OWNER/REPO/releases/latest | jq '.tag_name, (.assets|length)'
```

Empty or an error here means the token, not the router.

### `selfupdate_noop` every time

The tag in `flash/deployed-version` already matches the latest release. Either
it genuinely is current, or the marker was seeded with a tag that was never
applied.

```routeros
/file print detail where name~"deployed-version"
/file remove [find name="flash/deployed-version"]     ;# forces a re-apply next poll
```

### `selfupdate_fetch_incomplete`

The agent found a new tag but couldn't fetch every asset, so it aborted before
importing anything. **The router is untouched — this is the safety net working.**

Usual cause: the poll landed while `release.yml` was still uploading. It will
succeed on the next poll. If it repeats:

```bash
gh run list --workflow=release.yml --limit 3   # did the render actually succeed?
gh release view v8                             # are all manifest assets attached?
```

An asset missing from the release means `release.yml` failed or the manifest
lists a `path` that doesn't exist in the repo.

---

## The release lands but breaks something

### Imports fail: "already have such entry"

A cleanup didn't match what was already there, so the `add` collided — and **a
failed command aborts the entire `/import`**. Everything after it in that file
never ran.

```routeros
/log print where topics~"error"
```

Fix the module to clean up by stable key (interface, name, address) rather than
by comment. See [03 — Writing modules](03-writing-modules.md#clean-up-by-stable-key-not-by-comment).

### The apply stopped mid-way

Log stops after some `SELF_UPDATE: imported ...` line, flag still present, tag
not updated. Something killed the running job — most often a one-shot scheduler
removed while its `on-event` was still executing.

Do **not** re-run the whole deploy. See
[Recovering a half-applied deploy](04-operations.md#recovering-a-half-applied-deploy).

### The router rolled back by itself

```routeros
/log print where message~"ROLLBACK"
/file print where name~"rollback-marker"
```

The new config broke WAN and the safety net restored the previous state. The
router is now on the **old** config while the repo says new.

Fix the module and publish a **new** release. Don't just re-publish the same
one — it will roll back again.

### WiFi (or anything else) is down but WAN is fine

Nothing rolled back, because the health check only tests WAN routing.

```routeros
/log print where message~"starting\\.\\.\\."     ;# which module started last?
```

A module whose "starting..." has no matching "complete..." aborted part-way —
almost always an invalid property value. That exact failure caused a real
outage: an invalid channel-width value aborted the wireless module's import, so
no radios were ever configured, while WAN stayed perfectly healthy the whole
time.

Probe the suspect syntax on the live box before shipping it again:

```routeros
/caps-man channel add name=__probe <the-property-you-are-guessing>
```

To make this class of failure trigger a rollback, extend the health check —
see [03](03-writing-modules.md#extending-the-health-check).

---

## Watchdog problems

### A rollback fired after an ordinary reboot

`flash/deploy-in-progress` was left behind by an interrupted deploy. On the next
boot the watchdog found it, assumed a deploy was in flight, and did its job.

```routeros
/file print where name~"deploy-in-progress"
/file remove [find name="flash/deploy-in-progress"]
```

Always clear this flag when recovering a deploy by hand.

### "no pre-deploy backup found — rollback not possible"

There is no restore target. Usually flash is full.

```routeros
/system resource print                    ;# free-hdd-space
/file print where name~"backup"
/system script run script_BACKUP_PRUNE
```

A full disk breaks `/system backup save`, which breaks the pre-deploy snapshot,
which breaks rollback. That is the failure chain `config/30-backup.rsc` exists
to prevent — keep its prune schedule.

### The watchdog fired during a deploy, not after a boot

RouterOS fires `start-time=startup` schedulers **at add time**, not only at
boot. So importing `02-watchdog.rsc` during a live deploy launches the 5-minute
ping loop concurrently with the deploy's own import churn — which has crashed
RouterOS outright (service malfunction, `supout.rif`).

The `uptime > 10m` guard at the top of both watchdog scripts prevents this.
If you see this behaviour, that guard has been removed. Put it back.

---

## Local deploy problems

**`render.sh: required secret(s) not set`** — a `required=yes` entry in
`secrets.map` has no value. Check `scripts/.env` and that `deploy-local.sh`
sourced it (`./scripts/render.sh --list` shows the table).

**`is not in deploy-manifest.json`** — you passed a path that isn't in the
manifest. Add it there first; the manifest is the source of truth for the local
path too, on purpose.

**SFTP or SSH refused** — check port (2222 after bootstrap, 22 before), user
(`ci-deploy`), and key path:

```bash
ssh -p 2222 -i ~/.ssh/routeros-gitops ci-deploy@10.1.1.1 '/system identity print'
```

**Locked yourself out with a firewall rule** — WebFig on `http://<router-ip>`
usually still works, because the drop rules in the example config target the
`input` chain from non-LAN interfaces. If not, the recovery path is a serial
console or a reset button holding pattern; MikroTik's netinstall is the floor.
This is why you keep an emergency access path even with pull-deploy.

---

## Workflow problems

**"This repository is PUBLIC"** — working as intended. Release assets contain
your secrets in cleartext. Make the repo private:

```bash
gh repo edit --visibility private --accept-visibility-change-consequences
```

**"a REQUIRED placeholder survived"** — a `required=yes` secret is missing from
GitHub Actions secrets. `gh secret list`, then `gh secret set NAME`. The check
exists so a broken asset never reaches a router.

**Assets missing from the release** — check the run log:

```bash
gh run list --workflow=release.yml --limit 5
gh run view <id> --log-failed
```

A manifest entry whose `path` doesn't exist in the repo fails the render step.

---

## Useful one-liners

```routeros
/log print where message~"SELF_UPDATE"                    ;# pull history
/log print where topics~"error"                           ;# recent errors
/system resource print                                    ;# CPU, memory, free flash
/ip route print where dst-address=0.0.0.0/0 active=yes    ;# WAN alive?
/system script print brief                                ;# what's installed
/system scheduler print brief                             ;# what's armed
/file print                                               ;# markers, backups, assets
/tool fetch url="https://api.github.com" output=user as-value   ;# egress + TLS
```

Persistent logs survive reboots only if disk logging is on — installed by
`engine/00-observability.rsc`. Without it, a reboot erases exactly the evidence
that would explain the reboot.
