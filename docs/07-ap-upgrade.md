# 07 — Remote AP upgrade (RouterOS 6 → 7), optional module

`modules/capsman/ap-upgrade.rsc` lets the router that runs CAPsMAN upgrade one
of its access points over SSH — for sites where nobody can do it by hand and
the only way in is a GitHub Release.

Proven on a hEX PoE (mipsbe, RouterOS 7.25.1) upgrading cAP ac, wAP ac and
wAP 2nD (RBwAP2nDr2, 16 MB flash) from 6.49.6 to 7.25.1, November 2026.

## Why a module for this

An AP on RouterOS 6 never moves to 7 through channel `stable`; it stays on
6.49.x forever. The one-time channel `upgrade` is the only path, and it may stop
at an intermediate 7.x (seen: 7.12.1). Then a second pass on channel `stable`
takes it to the current release. The module picks the right pass from the AP's
version, so you never edit RouterOS code between passes:

| AP version | pass   | AP-side command |
|------------|--------|-----------------|
| `6.x`      | first  | channel `upgrade`, install **only** if the offer is `7.x`, else back to `stable` |
| `7.x`      | second | channel `stable`, install **only** if status is `New version is available` and the offer is `7.x` |

## Setup (per router repo)

```bash
gh secret   set GITOPS_AP_USER          # SSH user on the APs
gh secret   set GITOPS_AP_PASSWORD      # must not contain " \ or $
gh variable set GITOPS_AP_UPGRADE_MAC  --body "AA:BB:CC:DD:EE:FF"   # AP base-mac
gh variable set GITOPS_AP_UPGRADE_RUN  --body "1"                    # run id
```

Add the module to `deploy-manifest.json`, before the `"self": true` entry:

```json
{ "action": "import", "path": "gitops/modules/capsman/ap-upgrade.rsc",
  "asset": "module__ap-upgrade.rsc", "dst": "module__ap-upgrade.rsc" }
```

Test the credentials once before the first upgrade, read-only, e.g. from the
router: `/system ssh-exec address=<ap-ip> user=... password=... command="/system resource print"`.
A wrong password costs a whole release cycle.

## One AP per release

```
1. set GITOPS_AP_UPGRADE_MAC (the AP) and a NEW GITOPS_AP_UPGRADE_RUN
2. gh release create vNN
3. wait: router pulls (hourly) -> deploy -> ~5 min -> :delay 180s
         -> upgrade + reboot ~7 min -> result
4. read event=ap_upgrade "result <mac> hop=<first|second> ip=… before=… after=…"
5. next AP, or second pass for the same AP: new run id, new release
```

| result               | meaning |
|----------------------|---------|
| `after` = current 7.x | done |
| `after` = older 7.x   | `upgrade` channel stopped early → new run id, same MAC → second pass |
| `after` = `before`    | nothing installed: no 7.x offered, already current, or the AP-side command failed |
| `NOT BACK`            | the AP did not rejoin CAPsMAN within ~22 min → someone on site |

When all APs are done, **remove the module from the manifest** — every release
that carries it also carries the AP password.

## How it stays safe inside a normal deploy

- The scheduler fires only when there is no `flash/deploy-in-progress` flag, no
  marker `flash/ap-upgrade-<run>-done`, and the script exists. It writes the
  marker **before** running, so a run fires at most once even if it crashes.
- Re-importing with the marker present removes the script at once. That is why
  a run id must **never** be reused — the module would silently do nothing.
- The AP is found by base-mac among `/caps-man remote-cap where state="Run"`;
  IP from the DHCP lease, else ARP. Not found → it reports and sends nothing.
- `ssh error` after "command sent" is expected: the AP reboots mid-session.
- The scheduler is not removed from inside its own on-event (that kills the
  running job); the next import removes it.

## Limits

- CAPsMAN v1 (`/caps-man`) on the controller, RouterOS 7 (`ssh-exec password=`).
- No rollback and no remote recovery for the AP.
- Requires `engine/00-observability.rsc` (`script_LOG_EVENT`) to see results.
- The generalized module (automatic pass, run id variable) is not yet
  hardware-tested in this exact form; the AP-side commands and the router-side
  flow are the ones proven on the hEX.
