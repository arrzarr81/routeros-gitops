# 04 — Operations

## The daily loop

```bash
$EDITOR config/10-network.rsc
git commit -am "guest: raise cap to 50M"
git push                              # nothing deploys

gh release create v8 --generate-notes # this deploys
```

Within the hour, every router polling this repo applies it. Done.

Use tags you can order at a glance (`v1`, `v2`, …). The tag string is what the
router stores in `flash/deployed-version` and compares on every poll.

---

## Do not hand-edit a deployed router

Even on the LAN. Even when it's a one-line fix. Even when it works.

- **It is transient.** The next hourly poll re-imports the manifest from the
  last release and silently reverts you. The change looks fixed and un-fixes
  itself within the hour — which is a genuinely awful thing to debug.
- **It bypasses every safety net.** No pre-deploy snapshot, no watchdog, no
  automatic rollback. A live edit that kills WAN has nothing underneath it.
- **It leaves no trail.** Nothing to roll back to, no record of what changed.
- **It creates drift.** The moment the repo stops describing the router, the
  repo stops being useful.

Check whether pull-deploy is live before touching anything:

```bash
ssh ... '/system scheduler print where name="schedule_SELF_UPDATE"'
ssh ... '/file print where name~"deployed-version"'
```

Scheduler present → ship a release.

**The one legitimate live edit** is a throwaway probe to confirm a diagnosis
before committing — checking that a property value is even valid, for instance.
Do it, say out loud that it's a probe, then ship the release anyway. The release
re-applying the same value is your confirmation the pipeline carries it.

---

## Rolling back

Publish a release pointing at an older commit:

```bash
git log --oneline
gh release create v9 --target <older-sha> --generate-notes \
  --notes "Rollback to the state before v8"
```

The router converges to it next hour. Same mechanism, no router access.

Do not delete the bad release to "undo" it — the router compares tags, and
deleting the newest release makes it see an *older* tag as latest, which is
confusing rather than corrective. Always roll forward to a new tag.

**The router also rolls back on its own** when a deploy breaks WAN, restoring a
binary backup and rebooting. When that happens the router is running the *old
config* while the repo says *new*. Fix the module and ship a new release —
otherwise the next poll re-applies the broken one and it rolls back again.

---

## Forcing an immediate pull

Don't wait an hour. **But read the warning below first — this section describes
a step that has caused a real outage.**

### First: wait for the render workflow

```bash
gh run list --workflow=release.yml --limit 1   # must show: completed  success
gh release view v8                             # assets present
```

Pulling before that gets a release with no assets. The agent will refuse it and
retry — safe, but you'll have learned nothing.

### Then: fire the agent from a one-shot scheduler

**Never** do this with a piped SSH command:

```bash
# WRONG
ssh ... '/system script run script_SELF_UPDATE'
```

A full apply takes minutes. If the SSH session drops, the import aborts
mid-run, leaving the router half-configured with the watchdog flag still set.

Instead, add a scheduler so the job runs in the router's own context:

```routeros
/system scheduler add name=force-pull start-time=00:00:00 interval=1m \
  policy=ftp,reboot,read,write,policy,test,password,sensitive \
  on-event="/system script run script_SELF_UPDATE"
```

`start-time=startup` is **not** reliable for this — on some RouterOS 7 builds it
does not fire at add time. Use a real time with a short interval and wait for
`next-run`; confirm with `run-count=1`.

### ⚠️ Then: do NOT remove the scheduler while it is still running

> A scheduler's `on-event` runs **in the scheduler's context**.
> `/system scheduler remove` **kills the running job instantly, mid-import.**
>
> This caused a real WiFi outage. Someone deleted the one-shot at the
> one-minute mark to stop it re-firing. That terminated `script_SELF_UPDATE`
> between two modules — the cleanup module had already wiped the wireless
> config, and the module that rebuilds it never ran. Result: no WiFi, and a log
> that simply stops after the last successful import with no error at all.
>
> **Never judge "done" by elapsed time.** A full apply on low-end hardware takes
> several minutes: backups plus a dozen imports.

Wait for the markers, then remove it:

```routeros
/file print where name~"deployed-version"      ;# contents = the new tag?
/file print where name~"deploy-in-progress"    ;# gone?
/log print where message~"SELF_UPDATE"         ;# "<tag> applied cleanly"?
```

All three, then:

```routeros
/system scheduler remove [find name=force-pull]
```

### Watching from outside

```bash
watch -n 20 'ssh -p 2222 -i ~/.ssh/routeros-gitops ci-deploy@ROUTER \
  "/log print where message~\"SELF_UPDATE\""'
```

Expected sequence: `selfupdate_start` → `selfupdate_applied`.
`selfupdate_noop` means the marker already matches the tag — nothing was pulled.

---

## Recovering a half-applied deploy

Symptom: the log stops mid-import, `flash/deploy-in-progress` still exists,
`flash/deployed-version` still shows the old tag.

**The assets are already on the router.** Do not re-run the whole thing — you'd
re-run destructive cleanup modules for no reason.

1. Find where it stopped:

   ```routeros
   /log print where message~"SELF_UPDATE: imported"
   ```

2. Resume at the **next** manifest entry, by name:

   ```routeros
   /import verbose=no file-name=config__10-network.rsc
   /import verbose=no file-name=config__20-maintenance.rsc
   ```

3. Finish what the interrupted script would have done:

   ```routeros
   /ip route print count-only where active=yes dst-address=0.0.0.0/0   ;# must be > 0
   /file remove [find name="flash/deployed-version"]
   /file add name=flash/deployed-version type=file contents=v8
   /file remove [find name="flash/deploy-in-progress"]
   ```

**Step 3's last line is not optional.** A stale `deploy-in-progress` flag arms
the boot watchdog, and the next ordinary reboot can trigger a rollback you never
asked for.

---

## Checking what a router is actually running

```routeros
/file print where name~"deployed-version"        ;# the applied release tag
/log print where message~"SELF_UPDATE"           ;# recent pull history
/system scheduler print where name~"SELF_UPDATE" ;# is the agent armed?
/file print where name~"pre-deploy-"             ;# rollback targets available
/file print where name~"confirmed-good-"         ;# last known-good states
```

To see the **rendered** config a release actually shipped — with secrets
substituted, which is what the router imported:

```bash
gh release download v8 --pattern 'config__10-network.rsc'
```

This is the only way to inspect a deployed secret value. GitHub secrets are
write-only; `gh secret list` shows names, never values.

---

## Rotating a credential

```bash
gh secret set GITOPS_GITHUB_PAT          # paste the new value
$EDITOR scripts/.env                     # keep local in sync — it drifts otherwise
gh release create v10 --generate-notes   # routers converge within the hour
```

Ordering matters for the PAT specifically: the router uses the **old** token to
fetch the release containing the **new** one. So revoke the old token only after
you've confirmed the routers have applied the release that carries its
replacement. Revoke first and you've cut off the only channel that could deliver
the fix.

---

## Adding routers

Any router pointed at the same repo converges to the same release. Run
[setup](02-setup.md) for each.

For per-site differences, pick one:

- **A private repo per site** (from this template). Simple, small blast radius,
  a bad release can only hurt one site. Best until you have several sites.
- **One repo, branch on identity** inside a module:

  ```routeros
  :local site [/system identity get name]
  :if ($site = "site-warsaw") do={ /ip address add address=10.2.0.1/24 ... }
  ```

  Scales better once the fleet is genuinely uniform, at the cost of every
  release touching every site.

---

## Changing the poll interval

In `engine/99-self-update.rsc`:

```routeros
add name=schedule_SELF_UPDATE interval=1h ...
```

`15m` for faster convergence, `6h` to be gentler on the API. Do not add
`start-time=startup`: a startup-anchored scheduler reports `next-run=startup`
and does not begin counting until the router reboots — the agent sits dormant,
and every apply re-arms that dormancy. The comment in the file says the same
thing; it is there because it happened.

Rate limits are not a concern: authenticated GitHub API requests allow 5000/hour
per token, and one router at `interval=1h` uses 24 per day.
