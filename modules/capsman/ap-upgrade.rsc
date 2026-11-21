# =============================================================================
# modules/capsman/ap-upgrade.rsc — OPTIONAL. One-shot remote RouterOS upgrade
# of ONE CAPsMAN-managed access point, driven by the router over SSH.
#
# Not in the default manifest. Add it to a site's deploy-manifest.json (before
# the "self" entry) only while an AP upgrade is in progress, then remove it.
#
# WHY
#   An AP on RouterOS 6 never moves to 7 through channel "stable". The one-time
#   channel "upgrade" is the only path. At a remote site nobody can do that by
#   hand, but the router that runs CAPsMAN can log in to the AP over SSH.
#   Proven on hEX PoE (mipsbe, ROS 7.25.1) upgrading cAP ac, wAP ac and
#   wAP 2nD (RBwAP2nDr2, 16 MB flash) from 6.49.6, Nov 2026.
#
# WHAT IT DOES (once per run id, after the deploy flag clears)
#   1. :delay 180s — CAPs drop out of remote-cap while CAPsMAN config is
#      re-imported by the deploy; let them rejoin.
#   2. Finds the AP by base-mac among /caps-man remote-cap state=Run, gets its
#      IP (DHCP lease, else ARP) and current version. Not found -> report, stop.
#   3. Picks the hop from the AP's version and runs ONE ssh-exec line:
#        6.x  FIRST HOP   channel=upgrade, install ONLY if the offer is 7.x,
#                         otherwise put the channel back to stable
#        7.x  SECOND HOP  channel=stable, install ONLY if status is
#                         "New version is available" and the offer is 7.x
#      The SSH session dies when the AP reboots — "ssh error" is expected.
#   4. Waits 7 min, then polls up to 15 min for the AP to be back in Run.
#   5. Ships events via script_LOG_EVENT (event="ap_upgrade"): start,
#      command sent, result "<mac> hop=<h> ip=<ip> before=<v> after=<v>|NOT BACK".
#
# READING THE RESULT
#   after = current 7.x   done
#   after = older 7.x     channel "upgrade" stopped at an intermediate 7.x
#                         (seen: 7.12.1). Bump the run id -> next release does
#                         the second hop automatically.
#   after = before        nothing installed (no 7.x offered / already current /
#                         AP-side command failed)
#   NOT BACK              AP did not rejoin within ~22 min -> someone on site
#
# RISK: no rollback, no remote recovery. ONE AP per release; read the result
# before the next one. Upgrade + reboot + rejoin takes ~7 min.
#
# CONFIGURATION (all required=no in secrets.map; unset -> module disables itself)
#   PLACEHOLDER_AP_UPGRADE_MAC  <- GITOPS_AP_UPGRADE_MAC  (variable) AP base-mac, AA:BB:CC:DD:EE:FF
#   PLACEHOLDER_AP_UPGRADE_RUN  <- GITOPS_AP_UPGRADE_RUN  (variable) run id, [A-Za-z0-9-] only.
#       The marker flash/ap-upgrade-<run>-done makes each run fire at most
#       once, even if it crashes. NEVER reuse a run id: the marker is still on
#       the router and the script silently removes itself. To run again (next
#       AP, second hop) set a NEW run id and publish a release.
#   PLACEHOLDER_AP_USER         <- GITOPS_AP_USER         (secret) SSH user on the AP
#   PLACEHOLDER_AP_PASSWORD     <- GITOPS_AP_PASSWORD     (secret) its password.
#       Must not contain " \ or $ (pasted into a script source string).
#
# Test the credentials first with a read-only ssh-exec (e.g.
# `/system ssh-exec address=<ap-ip> user=... password=... command="/system resource print"`)
# — a wrong password costs you a whole release cycle.
#
# REQUIRES: engine/00-observability.rsc (script_LOG_EVENT), RouterOS 7 on the
# controller (/system ssh-exec with password=), CAPsMAN v1 (/caps-man).
# NOTE: every $ inside source= is escaped as \$. The AP-side commands use none.
# The scheduler is left in place after the run (its on-event is a no-op once the
# marker exists) and removed by the next import: removing a scheduler from inside
# its own on-event kills the job that is running in its context.
# =============================================================================

/system scheduler
remove [find name="schedule_AP_UPGRADE"]

/system script
remove [find name="script_AP_UPGRADE"]
add dont-require-permissions=yes name=script_AP_UPGRADE owner=admin policy=read,write,policy,test,password,sensitive source="\
:global logEvent\r\n\
:global logLevel\r\n\
:global logMessage\r\n\
:local apUser \"PLACEHOLDER_AP_USER\"\r\n\
:local apPassword \"PLACEHOLDER_AP_PASSWORD\"\r\n\
:local targetMAC \"PLACEHOLDER_AP_UPGRADE_MAC\"\r\n\
:delay 180s\r\n\
:local before \"\"\r\n\
:foreach c in=[/caps-man remote-cap find where state=\"Run\"] do={\r\n\
:if ([:tostr [/caps-man remote-cap get \$c base-mac]] = \$targetMAC) do={ :set before [:tostr [/caps-man remote-cap get \$c version]] }\r\n\
}\r\n\
:local capIP \"\"\r\n\
:do { :set capIP [:tostr [/ip dhcp-server lease get [find mac-address=\$targetMAC] address]] } on-error={}\r\n\
:if ([:len \$capIP] = 0) do={\r\n\
:do { :set capIP [:tostr [/ip arp get [find mac-address=\$targetMAC] address]] } on-error={}\r\n\
}\r\n\
:local hop \"\"\r\n\
:local apCmd \"\"\r\n\
:if ([:pick \$before 0 2] = \"6.\") do={\r\n\
:set hop \"first\"\r\n\
:set apCmd \"/system package update set channel=upgrade; /system package update check-for-updates; :delay 20s; :if ([:pick [/system package update get latest-version] 0 2] = \\\"7.\\\") do={ /system package update install } else={ /system package update set channel=stable }\"\r\n\
}\r\n\
:if ([:pick \$before 0 2] = \"7.\") do={\r\n\
:set hop \"second\"\r\n\
:set apCmd \"/system package update set channel=stable; /system package update check-for-updates; :delay 20s; :if ([/system package update get status] = \\\"New version is available\\\" and [:pick [/system package update get latest-version] 0 2] = \\\"7.\\\") do={ /system package update install }\"\r\n\
}\r\n\
:local msg \"\"\r\n\
:if ([:len \$before] = 0 or [:len \$capIP] = 0 or [:len \$apCmd] = 0) do={\r\n\
:set msg (\$targetMAC . \" not in state Run, no IP or unsupported version (ip=\" . \$capIP . \" version=\" . \$before . \"), nothing sent to the AP\")\r\n\
} else={\r\n\
:log info (\"AP_UPGRADE: start \" . \$targetMAC . \" hop=\" . \$hop . \" ip=\" . \$capIP . \" before=\" . \$before)\r\n\
:set logEvent \"ap_upgrade\"\r\n\
:set logLevel \"info\"\r\n\
:set logMessage (\"AP upgrade: start \" . \$targetMAC . \" hop=\" . \$hop . \" ip=\" . \$capIP . \" before=\" . \$before)\r\n\
:do { /system script run script_LOG_EVENT } on-error={}\r\n\
:local r \"error (expected if the AP rebooted mid-session)\"\r\n\
:do {\r\n\
/system ssh-exec address=\$capIP user=\$apUser password=\$apPassword command=\$apCmd\r\n\
:set r \"returned\"\r\n\
} on-error={}\r\n\
:log info (\"AP_UPGRADE: command sent, ssh \" . \$r)\r\n\
:set logEvent \"ap_upgrade\"\r\n\
:set logLevel \"info\"\r\n\
:set logMessage (\"AP upgrade: command sent to \" . \$targetMAC . \", ssh \" . \$r . \", waiting for the AP to rejoin\")\r\n\
:do { /system script run script_LOG_EVENT } on-error={}\r\n\
:delay 420s\r\n\
:local after \"\"\r\n\
:local tries 0\r\n\
:while (\$tries < 30 and [:len \$after] = 0) do={\r\n\
:foreach c in=[/caps-man remote-cap find where state=\"Run\"] do={\r\n\
:if ([:tostr [/caps-man remote-cap get \$c base-mac]] = \$targetMAC) do={ :set after [:tostr [/caps-man remote-cap get \$c version]] }\r\n\
}\r\n\
:if ([:len \$after] = 0) do={ :delay 30s }\r\n\
:set tries (\$tries + 1)\r\n\
}\r\n\
:if ([:len \$after] = 0) do={ :set after \"NOT BACK in CAPsMAN after 22 min\" }\r\n\
:set msg (\$targetMAC . \" hop=\" . \$hop . \" ip=\" . \$capIP . \" before=\" . \$before . \" after=\" . \$after)\r\n\
}\r\n\
:log info (\"AP_UPGRADE: \" . \$msg)\r\n\
:set logEvent \"ap_upgrade\"\r\n\
:set logLevel \"info\"\r\n\
:set logMessage (\"AP upgrade: result \" . \$msg)\r\n\
:do { /system script run script_LOG_EVENT } on-error={}"

:if ("PLACEHOLDER_AP_UPGRADE_MAC" ~ "^PLACEHOLDER_" or "PLACEHOLDER_AP_UPGRADE_RUN" ~ "^PLACEHOLDER_" or "PLACEHOLDER_AP_USER" ~ "^PLACEHOLDER_" or "PLACEHOLDER_AP_PASSWORD" ~ "^PLACEHOLDER_") do={
  /system script remove [find name="script_AP_UPGRADE"]
  :log warning "AP_UPGRADE: not configured (AP_UPGRADE_MAC / AP_UPGRADE_RUN / AP_USER / AP_PASSWORD), module disabled"
} else={
  :if ([:len [/file find name="flash/ap-upgrade-PLACEHOLDER_AP_UPGRADE_RUN-done"]] > 0) do={
    /system script remove [find name="script_AP_UPGRADE"]
    :log info "AP_UPGRADE: run PLACEHOLDER_AP_UPGRADE_RUN already done (marker present), script cleared"
  } else={
    /system scheduler add name=schedule_AP_UPGRADE interval=5m start-time=00:02:00 policy=read,write,policy,test,password,sensitive on-event=":if ([:len [/file find name=\"flash/deploy-in-progress\"]] = 0 and [:len [/file find name=\"flash/ap-upgrade-PLACEHOLDER_AP_UPGRADE_RUN-done\"]] = 0 and [:len [/system script find name=\"script_AP_UPGRADE\"]] > 0) do={ /file add name=flash/ap-upgrade-PLACEHOLDER_AP_UPGRADE_RUN-done type=file contents=done; :do { /system script run script_AP_UPGRADE } on-error={ :log warning \"AP_UPGRADE: script failed\" }; /system script remove [find name=\"script_AP_UPGRADE\"] }"
    :log info "AP_UPGRADE: run PLACEHOLDER_AP_UPGRADE_RUN scheduled, fires once after the deploy flag clears"
  }
}
