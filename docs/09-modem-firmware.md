# 09 — LTE modem firmware (optional module)

`modules/lte/modem-firmware.rsc` keeps the firmware of built-in or attached LTE modems
current with `/interface lte firmware-upgrade`. It is separate from the RouterBOARD
firmware, which `engine/10-maintenance.rsc` handles.

## Enable

Add to the site's `deploy-manifest.json` after the engine entries, before `self`:

```json
{ "action": "import", "path": "gitops/modules/lte/modem-firmware.rsc",
  "asset": "module__modem-firmware.rsc", "dst": "module__modem-firmware.rsc" }
```

Settings (defaults in `secrets.map`, override in the site's `secrets.map` or as GitHub variables):

| Placeholder | Default | Meaning |
|---|---|---|
| `PLACEHOLDER_MODEM_FW_MODE` | `notify` | `notify` = only report a newer version; `auto` = install it |
| `PLACEHOLDER_MODEM_FW_START_DATE` | `2026-11-28` | first run; its weekday is the weekly run day (a Saturday) |
| `PLACEHOLDER_MODEM_FW_START_TIME` | `08:00:00` | run time; keep it after the nightly maintenance window |
| `PLACEHOLDER_MODEM_FW_PING_TARGET` | `1.1.1.1` | reachability check after an upgrade |

Pick the run day so that someone can reach the device if the modem does not come back.

## Behaviour

For every enabled `lte` interface, once a week:

1. Skip (event `modem_fw_skip`) if uptime < 1 h, a deploy flag exists, or the interface is not running.
2. `firmware-upgrade <iface> as-value` → `installed` vs `latest`. Check fails → `modem_fw_unsupported`.
   Equal → `modem_fw_current`. Newer and `notify` → `modem_fw_available`.
3. `auto`: `modem_fw_upgrade_start` is sent **before** the upgrade (the link drops), then
   `firmware-upgrade <iface> upgrade=yes`.
4. Wait up to 15 min for the interface to run and a ping to succeed → `modem_fw_upgraded`
   (or `modem_fw_failed` if the version did not change).
5. Not back: `modem_fw_recovery` + interface disable/enable, wait 5 min; still down →
   `modem_fw_recovery_reboot` and one reboot. The script never runs at startup, so it cannot loop.

Single-WAN LTE routers: the events before the drop are the only ones that leave the device
while it upgrades. A dead-man's-switch (`PLACEHOLDER_DEADMAN_URL`) covers the case where it never returns.

## Gotchas

- Some modems behind `/interface lte` are not served by the vendor's firmware server: expect
  `modem_fw_unsupported` and use `notify` there.
- Check free storage on 16 MB devices before the first upgrade.
- Some modems hang after a soft reboot and need a power cycle. On such hardware use `notify`.
