# 08 — Optional module: WiFi / CAP / LTE telemetry

`modules/telemetry/telemetry.rsc` adds dashboard data the engine heartbeat does
not have: WiFi client counts, CAPsMAN CAPs, per-client signal, and LTE radio
quality. It is **optional** and not in the default manifest — the engine stays
model-agnostic, a site opts in.

It is **read-only**: print / get / monitor commands only. It never changes
wireless, CAPsMAN, LTE or interface config.

## Enabling it on a site

1. The log sink must be configured (`GITOPS_LOG_INGEST_URL` +
   `GITOPS_LOG_INGEST_TOKEN`, the same ones `script_HEARTBEAT` uses). Without
   them the module installs the script but no scheduler.
2. Add the module to the site's `deploy-manifest.json`, after the engine
   `00`–`10` entries and before the `self` entry:

   ```json
   { "action": "import", "path": "gitops/modules/telemetry/telemetry.rsc",
     "asset": "module__telemetry.rsc", "dst": "module__telemetry.rsc" }
   ```

3. Optional: guest SSIDs. Set `GITOPS_TELEMETRY_GUEST_SSID_RE` (GitHub variable,
   or a line in the site `secrets.map`) to a RouterOS regex, e.g. `^GUEST`.
   Clients on matching SSIDs count as `guest_clients`, everyone else as
   `home_clients`. Unset = all home. No `"`, `\` or `$` in the value.
4. Ship a release (or `deploy-local.sh gitops/modules/telemetry/telemetry.rsc`
   for first provisioning; delete the uploaded `module__telemetry.rsc` after,
   it contains the sink token).
5. Register the new fields on the log source (Better Stack: metrics/labels via
   API — a field that is not registered never reaches a chart).

To disable: remove the manifest entry and run once
`/system scheduler remove [find name="schedule_TELEMETRY"]; /system script remove [find name="script_TELEMETRY"]`.

## What runs

One script, `script_TELEMETRY`, one scheduler every minute at `:50`
(heartbeat is `:20`, deadman `:40`). Fixed start-time, never `startup`.
Footprint: ~7 KB script, no files. One HTTPS POST per minute, one or two more
every 5 / 15 minutes.

| When | `message` | Shape |
|---|---|---|
| every minute | `telemetry` | one JSON object |
| minute % 5 = 1 | `wifi_client` | one JSON **array**, one object per associated client (nothing sent with 0 clients) |
| minute % 15 = 2 | `cap_version` | one JSON array, one object per CAP (CAPsMAN backends only) |

Arrays keep it to one request per run; Better Stack stores each element as a
row. A sink that does not accept JSON arrays needs a per-object POST loop.

## Run-time detection (no names hardcoded)

| `wifi_backend` | Condition | Commands |
|---|---|---|
| `capsman` | `/caps-man manager` enabled (legacy `wireless` package) | `/caps-man remote-cap` (state=Run), `/caps-man registration-table` |
| `wifi` | `/interface wifi` has interfaces (new `wifi` package) | `/interface wifi capsman remote-cap`, `/interface wifi registration-table`; SSID from the interface's `configuration.ssid` |
| `wireless` | local `/interface wireless` only | `/interface wireless registration-table` |
| `none` | none of the above | no WiFi fields |

Backend commands run through `[:parse]`, so a device whose package lacks a menu
does not make the whole script fail to parse.

LTE: the **first running interface of type `lte`**. None → `lte_present=0` and
no `lte_*` fields. A modem that answers without signal keys (no SIM, radio off)
→ `lte_present=0`, the keys it did return are still sent.

## Fields

**Missing values are omitted, never sent as 0** — a chart shows a gap, not a
fake "0 dBm" (an earlier LTE script sent 0 on monitor errors).

`message=telemetry` (field names follow a common WiFi/CAP + LTE dashboard
layout, so chart SQL ports between routers by changing only `{{source}}`):

| Field | Type | Source |
|---|---|---|
| `hostname` | label | `/system identity` |
| `wifi_backend` | label | detection above |
| `caps_online` | metric | CAPs in Run (capsman / wifi backends) |
| `total_clients`, `home_clients`, `guest_clients` | metric | registration table rows, split by guest SSID regex |
| `lte_present` | metric | 1 = modem returned rssi/rsrp, else 0 |
| `lte_iface` | label | interface name |
| `lte_rssi`, `lte_rsrp` | metric | dBm, `/interface lte monitor <if> once as-value` |
| `lte_sinr` | metric | dB |
| `lte_rsrq` | metric | dB, decimal. **as-value is in 0.1 dB** (`-135` = the `-13.5dB` that `print` shows), converted |
| `lte_cqi` | metric | 0–15 |
| `lte_rx_kbps`, `lte_tx_kbps` | metric | `/interface monitor-traffic <if> once` bps / 1000 |
| `lte_band` | label | `primary-band` up to `@` (e.g. `B20`) |
| `lte_cell` | label | `current-cellid` |
| `lte_operator`, `lte_status`, `lte_data_class` | label | `current-operator`, `registration-status`, `data-class` |

IMEI / IMSI / ICCID are never sent.

`message=wifi_client`: `client_mac`, `client_host` + `client_ip` (DHCP lease, if
any), `client_ssid`, `client_radio` (registration-table `interface`),
`client_signal` (dBm: `rx-signal` / `signal` / `signal-strength`).

`message=cap_version`: `cap_name` (CAP identity, else its CAPsMAN name),
`cap_version`, `cap_board`, `cap_mac`.

On Better Stack the per-event labels should be gated on `message` so generic
keys never leak between event types, e.g.
`if(JSONExtractString(raw,'message')='wifi_client', JSONExtractString(raw,'client_mac'), NULL)`.

## Not covered

- Ethernet link speed per port / per CAP uplink (a `link_status` report) — not
  in this module yet.
- LTE delivered by an external box on an ethernet WAN is invisible here
  (`lte_present=0`); that box would have to run the module itself.
- The `wifi` backend (new package) branch is written from the RouterOS docs and
  has not been run on hardware yet; `capsman` was verified on RouterOS 7.25.1.
