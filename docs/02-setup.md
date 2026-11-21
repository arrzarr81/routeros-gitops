# 02 — Setup

First-time setup, with a verification step after each stage. Roughly twenty
minutes. Do it with the router on your LAN, before it goes to its final home.

## Before you start

| Requirement | Notes |
|---|---|
| MikroTik router, RouterOS 7 | Any model. Tested on hEX PoE (mipsbe) and Chateau (ARM64). |
| A machine with `gh`, `jq`, `ssh` | macOS or Linux. `gh auth login` done. |
| LAN access to the router | Factory default is `192.168.88.1`, user `admin`, no password. |
| Outbound HTTPS from the router | To `api.github.com` and `objects.githubusercontent.com`. |

> **The router will be renumbered.** `config/10-network.rsc` as shipped moves the
> LAN to `10.1.1.0/24`. Read step 3 before running anything.

---

## Step 1 — Create your private repo

```bash
gh repo create my-network-config --private --clone \
  --template <owner>/routeros-gitops
cd my-network-config
```

**Private is mandatory, not a preference.** Release assets are rendered with
your secrets in cleartext; on a public repo they are world-readable with no
authentication. `release.yml` and `bootstrap.sh` both refuse to run against a
public repository.

If you cloned rather than templated, set visibility explicitly:

```bash
gh repo edit --visibility private --accept-visibility-change-consequences
gh repo view --json visibility -q .visibility     # must print PRIVATE
```

**Verify:** `PRIVATE`. Do not continue otherwise.

---

## Step 2 — Create the GitHub PAT

The router uses this token to read your releases. Create it at
<https://github.com/settings/personal-access-tokens>:

| Setting | Value |
|---|---|
| Type | **Fine-grained** personal access token |
| Resource owner | You, or the org owning the repo |
| Repository access | **Only select repositories** → this one |
| Repository permissions | **Contents: Read-only**. Nothing else. |
| Expiration | Set one. Renewing is a release away. |

Scope it as if it will leak, because it lives in cleartext in a script on the
router and in every release asset. With `Contents: Read-only` on one private
repo, the worst case is that someone reads your config.

Now fill in credentials:

```bash
cp scripts/.env.example scripts/.env
$EDITOR scripts/.env
```

Required: `GITOPS_GITHUB_REPO` (as `owner/repo`) and `GITOPS_GITHUB_PAT`.
Optional but strongly recommended: `GITOPS_DEADMAN_URL` — a free
[healthchecks.io](https://healthchecks.io) check takes two minutes and is the
only thing that will tell you the router has stopped existing.

**Verify:**

```bash
./scripts/render.sh --list      # the placeholder table
grep -c . scripts/.env          # sanity: it's not empty
git status --short              # scripts/.env must NOT appear — it's gitignored
```

---

## Step 3 — Adapt the config to your site

**Do this before deploying anything.** `config/10-network.rsc` is a working
example, not a default. As shipped it will:

- rename the router to `gitops-router`
- move the LAN to `10.1.1.0/24` (you will lose your session)
- put `ether2-5` in a bridge and make `ether1` a DHCP WAN client
- create an isolated guest network on `192.168.89.0/24`
- replace the firewall rules

Open it and change at minimum:

```routeros
/system identity set name=gitops-router          # ← per site
add address=10.1.1.1/24 interface=bridge-lan     # ← your subnet
add interface=ether1 ...                         # ← your WAN interface
add bridge=bridge-lan interface=ether2           # ← your LAN ports
```

If your WAN is PPPoE or LTE rather than DHCP, replace section 1 and make sure
the right interface ends up in the `WAN` interface list.

Read the three ordering rules in the file header. They are not stylistic —
each corresponds to a way this configuration can lock you out.

Don't want the example config at all? Remove the three `config/*` entries from
`deploy-manifest.json` and delete the files. The engine works alone; see
[03 — Writing modules](03-writing-modules.md).

**Verify:** you can explain what each section of `10-network.rsc` will do to
this specific router. If not, keep reading it.

---

## Step 4 — Provision the router

```bash
./scripts/bootstrap.sh --ip 192.168.88.1
```

This generates an ed25519 deploy key, creates a `ci-deploy` user bound to that
key, moves SSH to port 2222, disables telnet/ftp/api, and pushes your `.env`
values into GitHub Actions secrets.

**Verify:**

```bash
ssh -p 2222 -i ~/.ssh/routeros-gitops ci-deploy@192.168.88.1 '/system identity print'
gh secret list        # GITOPS_GITHUB_PAT and friends present
```

`gh secret list` shows names and timestamps only — secrets are write-only. To
see what a router is actually running, download a rendered asset (see
[04 — Operations](04-operations.md)).

---

## Step 5 — First deploy, over the LAN

This is the **only** time you deploy this way. After it, the router pulls.

```bash
./scripts/deploy-local.sh --dry-run          # render everything, upload nothing
```

Inspect the rendered output it points at. Confirm the placeholders were
substituted and the config says what you meant. Then:

```bash
./scripts/deploy-local.sh --ip 192.168.88.1
```

You will lose the SSH session when the network module applies — that is
expected. Reconnect on the new address.

**Verify** (on the new LAN address):

```bash
ssh -p 2222 -i ~/.ssh/routeros-gitops ci-deploy@10.1.1.1

/system script print brief
#   expect: script_LOG_EVENT, script_HEARTBEAT, script_DEADMAN_PING,
#           script_PRE_DEPLOY_SNAPSHOT, script_WATCHDOG, script_STARTUP_ALERT,
#           script_SELF_UPDATE, script_UPGRADE, script_UPDATE   (no script_REBOOT)

/system scheduler print brief
#   expect: schedule_SELF_UPDATE with interval=1h and a real next-run time.
#   If next-run says "startup", the agent is dormant — see docs/05.

/ip route print where dst-address=0.0.0.0/0 active=yes    # WAN is up
/file print where name~"deploy-in-progress"               # must be EMPTY
```

That last one matters: a leftover flag arms the watchdog on the next reboot and
can trigger a rollback you didn't ask for.

---

## Step 6 — Prove the pull path works

Still on the LAN, where you can fix it if it doesn't.

```bash
git add -A && git commit -m "initial config" && git push
gh release create v1 --generate-notes
gh run watch                      # wait for release.yml to finish
```

**Wait for the workflow to complete before expecting a pull.** A router that
polls mid-upload gets an incomplete release, correctly refuses to apply it, and
retries next hour — safe, but confusing if you're watching.

```bash
gh release view v1                # assets listed, including deploy-manifest.json
```

Now trigger a pull rather than waiting an hour — read
[Forcing an immediate pull](04-operations.md#forcing-an-immediate-pull) first,
because removing the one-shot scheduler too early kills the running import.

**Verify:**

```routeros
/file print where name~"deployed-version"     # contents should be v1
/log print where message~"SELF_UPDATE"        # expect ": v1 applied cleanly"
```

Seeing `v1 applied cleanly` means the whole loop works: CI rendered, the router
polled, fetched, imported, verified WAN, and committed. **That is the moment
the router becomes remote-manageable.**

---

## Step 7 — Optional: seed the version marker

If you provisioned locally from the same commit a release already points at,
tell the router so its first poll is a clean no-op:

```routeros
/file add name=flash/deployed-version type=file contents=v1
```

Skip it and the first poll simply re-applies the latest release once. Every
module is idempotent, so that is harmless — just noisier.

---

## Step 8 — Ship it

The router now needs only outbound HTTPS. No port-forward, no DHCP reservation,
no VPN, no static IP.

Before it leaves:

- [ ] `schedule_SELF_UPDATE` exists, `interval=1h`, real `next-run`
- [ ] `flash/deployed-version` matches the current release tag
- [ ] `flash/deploy-in-progress` does **not** exist
- [ ] at least one `pre-deploy-*.backup` on disk (the rollback target)
- [ ] your dead-man's switch has received a ping
- [ ] you have a way in for emergencies — `/ip cloud` DDNS plus the mgmt SSH
      rule, or an out-of-band path. Pull-deploy is not a substitute for a
      recovery path when a release cannot fix the problem.

---

## What next

- [04 — Operations](04-operations.md) — the daily loop, rollback, forcing a pull
- [03 — Writing modules](03-writing-modules.md) — adding your own config
- [05 — Troubleshooting](05-troubleshooting.md) — when a release doesn't land

### Adding a second router

Point it at the same repo and it converges to the same release. For per-site
differences, either give each site its own private repo from this template, or
branch the config inside one module on `[/system identity get name]`. The first
is simpler and keeps blast radius small; the second scales better once the
fleet is genuinely uniform.
