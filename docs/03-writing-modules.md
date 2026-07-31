# 03 — Writing your own modules

A "module" is one `.rsc` file listed in `deploy-manifest.json`. This is where
your actual network configuration lives.

## Adding one

```bash
$EDITOR config/40-vpn.rsc
```

Add it to `deploy-manifest.json` — **position in this array is apply order**:

```json
{ "action": "import", "path": "config/40-vpn.rsc",
  "asset": "config__40-vpn.rsc", "dst": "config__40-vpn.rsc" }
```

Keep the `engine/99-self-update.rsc` entry last. Test locally, then ship:

```bash
./scripts/deploy-local.sh --dry-run config/40-vpn.rsc
git commit -am "add vpn module" && git push
gh release create v9 --generate-notes
```

Naming: `NN-name.rsc` where `NN` matches manifest position. The number is
documentation for humans; the manifest is what executes.

---

## The idempotency contract

**Every module must converge, not accumulate.** The router re-imports the whole
manifest on every release. A module that only adds will duplicate its own
config on the second release — duplicate firewall rules, duplicate schedulers,
duplicate addresses.

Remove before you add:

```routeros
/system script
remove [find name="script_MY_THING"]
add name=script_MY_THING policy=read,write,test source="..."

/ip firewall filter
remove [find comment~"^mymodule:"]
add action=accept chain=input protocol=tcp dst-port=443 comment="mymodule: https"
```

### Clean up by stable key, not by comment

This is the single most common way to break an import.

```routeros
# WRONG — misses an entry created by hand or by a factory default
/interface bridge port
remove [find comment="LAN Port"]
add bridge=bridge-lan interface=ether2 comment="LAN Port"

# RIGHT — matches the thing itself
/interface bridge port
remove [find interface="ether2"]
add bridge=bridge-lan interface=ether2 comment="mymodule: LAN port"
```

Why it matters: if the cleanup misses an entry, the `add` fails with *"already
have such entry"*. In RouterOS **a failed command aborts the entire `/import`**.
Everything after it in that file never runs, and the router is left
half-configured. Match on interface, name, address, or list membership —
something intrinsic.

Prefixing your own comments (`mymodule:`) and cleaning with a regex
(`[find comment~"^mymodule:"]`) is a good pattern for rules you fully own, but
it only works when nothing else could have created an identical entry.

### Test idempotency before shipping

```bash
./scripts/deploy-local.sh config/40-vpn.rsc
./scripts/deploy-local.sh config/40-vpn.rsc      # second run
```

Then count what you created. If a second import doubles anything, it is not
idempotent. Fix it before it reaches a router you can't reach.

---

## Using secrets

Never put a credential in a `.rsc` file. Use a placeholder:

```routeros
:local apiKey "PLACEHOLDER_MY_API_KEY"
```

1. **Declare it** in `secrets.map`:

   ```
   PLACEHOLDER_MY_API_KEY   GITOPS_MY_API_KEY   yes   description of what it is
   ```

   `yes` = deploys fail without it. `no` = the literal placeholder ships and
   your script disables that feature at runtime.

2. **Add it to the workflow** `env:` block in `.github/workflows/release.yml`:

   ```yaml
   GITOPS_MY_API_KEY: ${{ secrets.GITOPS_MY_API_KEY }}
   ```

   The `GITOPS_` prefix is not decoration — GitHub Actions strips the `GITHUB_`
   prefix from env vars, so a variable named `GITHUB_PAT` silently arrives empty.

3. **Set it**: `gh secret set GITOPS_MY_API_KEY`

4. **Add it** to `scripts/.env.example` and your local `scripts/.env`.

### Optional secrets that degrade gracefully

For an optional integration, guard on the placeholder prefix so an unconfigured
feature is silent rather than noisy:

```routeros
:local apiUrl "PLACEHOLDER_MY_API_URL"
:if ($apiUrl ~ "^PLACEHOLDER_") do={ :error "my-api not configured" }
```

`engine/00-observability.rsc` does exactly this for all three of its
placeholders, which is why the whole system runs with no monitoring set up.

### GitHub secrets are the source of truth

`scripts/.env` is read only by `bootstrap.sh` and `deploy-local.sh`. A deployed
router gets its values from release assets rendered with GitHub Actions secrets.

- Editing `.env` changes **nothing** on a deployed router.
- To rotate: `gh secret set X`, then publish a release.
- `.env` drifts silently. In one real deployment a WiFi password was wrong in
  `.env` for months while the router happily ran the correct value from the
  secret — found only during a re-provisioning that pushed the stale one.
- To see what is actually deployed, download the rendered asset:

  ```bash
  gh release download v9 --pattern 'config__40-vpn.rsc'
  ```

---

## Structuring a module

```routeros
# =============================================================================
# What this configures, and for which hardware.
# =============================================================================
#
# WHY: the non-obvious reasons. Future-you deleting a line because it looks
# redundant is the most likely cause of your next outage.
#
# PLACEHOLDERS: PLACEHOLDER_X  (see secrets.map)
# REQUIRES: script_LOG_EVENT (engine/00-observability.rsc)
# =============================================================================

:log info "config/40-vpn: starting..."

# --- Idempotent cleanup (stable keys) ---
...

# --- Configuration ---
...

:log info "config/40-vpn: complete."
```

The opening and closing log lines are worth the two seconds. When you are
reading `/log print` after a failed deploy, the last "starting..." with no
matching "complete." tells you exactly which module died.

### Emitting events

```routeros
:global logEvent "vpn_tunnel_down"
:global logLevel "critical"
:global logMessage "Site-to-site tunnel is down"
:do { /system script run script_LOG_EVENT } on-error={ :log warning "LOG_EVENT failed" }
```

Always wrap it in `:do{}on-error={}`. A logging failure must never abort the
caller — monitoring is not allowed to take the router down.

Convention: `<subsystem>_<what_happened>`. Keep event IDs stable; dashboards and
alert rules are built on those exact strings.

---

## Script policies

RouterOS scripts declare the permissions they need. Two rules that cause silent,
baffling failures:

**Superset rule.** A script can only grant a child script the policies it holds
itself. `script_SELF_UPDATE` imports modules that declare `password` (needed for
`/system backup save|load` and `/export`). If `script_SELF_UPDATE` lacked
`password`, RouterOS would mark those children **invalid and blank their
source** — the watchdog would silently cease to exist. That is why the policy
sets in `engine/99-self-update.rsc` look over-broad. They aren't.

**Minimum sets:**

| Doing | Needs |
|---|---|
| Reading config, sending a `/tool fetch` | `read,test` |
| Changing config | `read,write,test` |
| `/system backup save` or `load`, `/export` | `+ password,sensitive` |
| `/system reboot` | `+ reboot` |
| `/import` of files | `+ ftp,policy` |

---

## Extending the health check

The self-update agent's success test is "does an active default route exist".
That misses a config which keeps WAN up while breaking something you care about.

To assert more, edit the `VERIFY` step in `engine/99-self-update.rsc` — the
`:local wan [...]` line and the condition below it. For example, also require
that a wireless interface is running, or that a tunnel is up. Anything that
evaluates false there triggers the same automatic restore-and-reboot.

Be conservative: a health check that is flaky will roll back good deploys, which
is worse than the failure it was meant to catch.

---

## Modules for downstream devices

A router can carry files for devices that have no internet access of their own —
access points, switches behind it.

Use `"action": "upload"`. The file is fetched to the router and **not**
imported:

```json
{ "action": "upload", "path": "ap/ap-config.rsc",
  "asset": "ap__ap-config.rsc", "dst": "flash/ap/ap-config.rsc" }
```

Use `flash/` in `dst` so it survives a power cycle on models where the root
filesystem is a ramdisk.

Then push it onward from a script on the router, over `/system ssh-exec`, or let
the downstream device pull it from the router's own FTP service
(`ftp://<router-ip>/ap/ap-config.rsc`).

Note: a downstream device **cannot** fetch from your GitHub raw URLs — the repo
is private and the device has no credentials. Relaying through the router is the
way.
