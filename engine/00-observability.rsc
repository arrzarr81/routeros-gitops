# =============================================================================
# routeros-gitops :: engine :: 00-observability.rsc
# Structured event logging + heartbeat. Imported FIRST — everything else calls it.
# =============================================================================
#
# INSTALLS
#   script_LOG_EVENT      POSTs one structured JSON event to your log sink.
#   script_HEARTBEAT      POSTs router vitals as JSON every minute.
#   script_DEADMAN_PING   POSTs plain-text vitals to a dead-man's-switch URL.
#   schedule_HEARTBEAT    every 1m -> script_HEARTBEAT
#   schedule_DEADMAN      every 1m -> script_DEADMAN_PING
#   plus rolling on-disk logging of warning/error/critical.
#
# WHY A DEAD-MAN'S SWITCH
#   Every other signal here is push-on-event: if the router dies, you get
#   silence, and silence looks exactly like "nothing happened". A dead-man's
#   switch (healthchecks.io, Cronitor, Better Uptime — anything that alerts on
#   a MISSING ping) turns silence into a page. With a pull-deploy router you
#   cannot reach, this is the single most valuable thing in this file.
#
# CALLING IT FROM YOUR OWN SCRIPTS
#   :global logEvent "wan_down"
#   :global logLevel "critical"          # info | warning | critical
#   :global logMessage "Human readable text"
#   :do { /system script run script_LOG_EVENT } on-error={ :log warning "LOG_EVENT failed" }
#
#   Always wrap the call in :do{}on-error={} — a logging failure must never
#   abort the caller. Monitoring is not allowed to take the router down.
#
# PLACEHOLDERS (see secrets.map)
#   PLACEHOLDER_LOG_INGEST_URL     e.g. https://<id>.<region>.betterstackdata.com
#   PLACEHOLDER_LOG_INGEST_TOKEN   bearer token for that endpoint
#   PLACEHOLDER_DEADMAN_URL        e.g. https://hc-ping.com/<uuid>
#
#   All three are OPTIONAL. If a placeholder is left unsubstituted, the script
#   detects the literal "PLACEHOLDER_" prefix and exits quietly instead of
#   spamming the log with failed fetches. You can run this whole system with no
#   monitoring at all and add it later.
#
# EVENT ID CONVENTION
#   <subsystem>_<what_happened>, past tense or state:
#     selfupdate_start / selfupdate_applied / selfupdate_fail
#     deploy_flag_set / deploy_flag_cleared / rollback_triggered
#     wan_up / wan_down / router_boot
#     maint_upgrade_start / maint_upgrade_fail / maint_reboot_start
#   Keep them stable — dashboards and alert rules are built on these strings.
#
# NOTE ON source="..." : every runtime $var is written \$var and every quote \".
#   RouterOS interpolates $ inside source= at parse time. See docs/06-routeros-gotchas.md.
# =============================================================================

/system scheduler
remove [find name="schedule_HEARTBEAT"]
remove [find name="schedule_DEADMAN"]

/system script
remove [find name="script_LOG_EVENT"]
remove [find name="script_HEARTBEAT"]
remove [find name="script_DEADMAN_PING"]

# --- script_LOG_EVENT --------------------------------------------------------
# Reads three globals set by the caller, POSTs one JSON line, returns.
/system script
add name=script_LOG_EVENT \
    policy=read,write,test \
    owner=admin \
    dont-require-permissions=no \
    source=":local sinkUrl \"PLACEHOLDER_LOG_INGEST_URL\"\
    \n:local sinkToken \"PLACEHOLDER_LOG_INGEST_TOKEN\"\
    \n:if (\$sinkUrl ~ \"^PLACEHOLDER_\") do={ :error \"log sink not configured\" }\
    \n:global logEvent\
    \n:global logLevel\
    \n:global logMessage\
    \n:local event \$logEvent\
    \n:local level \$logLevel\
    \n:local message \$logMessage\
    \n:local hostname [/system identity get name]\
    \n:local ts ([/system clock get date] . \"T\" . [/system clock get time])\
    \n:local payload (\"{\\\"level\\\":\\\"\" . \$level . \"\\\",\\\"event\\\":\\\"\" . \$event . \"\\\",\\\"message\\\":\\\"\" . \$message . \"\\\",\\\"timestamp\\\":\\\"\" . \$ts . \"\\\",\\\"hostname\\\":\\\"\" . \$hostname . \"\\\"}\")\
    \n:do {\
    \n  /tool fetch url=\$sinkUrl http-method=post \\\
    \n    http-header-field=(\"Authorization:Bearer \" . \$sinkToken . \",Content-Type:application/json\") \\\
    \n    http-data=\$payload output=none\
    \n} on-error={ :log warning \"LOG_EVENT: log shipping failed\" }"

# --- script_HEARTBEAT --------------------------------------------------------
# One JSON document per minute with everything you want to graph.
# ADD YOUR OWN FIELDS HERE — this is the natural extension point. Examples:
#   :local capsOnline [/caps-man remote-cap print count-only where state=Run]
#   :local wifiClients [/interface wifi registration-table print count-only]
#   :local lteSignal [/interface lte monitor lte1 once as-value]
# then append them to \$payload in the same \\\"key\\\":value style.
/system script
add name=script_HEARTBEAT \
    policy=read,test \
    owner=admin \
    dont-require-permissions=no \
    source=":local sinkUrl \"PLACEHOLDER_LOG_INGEST_URL\"\
    \n:local sinkToken \"PLACEHOLDER_LOG_INGEST_TOKEN\"\
    \n:if (\$sinkUrl ~ \"^PLACEHOLDER_\") do={ :error \"log sink not configured\" }\
    \n:local hostname [/system identity get name]\
    \n:local uptime [/system resource get uptime]\
    \n:local freeMem [/system resource get free-memory]\
    \n:local totalMem [/system resource get total-memory]\
    \n:local freeHdd [/system resource get free-hdd-space]\
    \n:local totalHdd [/system resource get total-hdd-space]\
    \n:local cpuLoad [/system resource get cpu-load]\
    \n:local wanRoutes [/ip route print count-only where active=yes dst-address=0.0.0.0/0]\
    \n# Which uplink carries traffic right now: the active default route with the\
    \n# lowest distance. active_wan = its comment (e.g. FIBER / LTE), else gateway.\
    \n:local activeWan \"\"\
    \n:local wanGw \"\"\
    \n:local wanIf \"\"\
    \n:do {\
    \n  :local best \"\"\
    \n  :local bestDist 256\
    \n  :foreach r in=[/ip route find where active=yes dst-address=0.0.0.0/0] do={\
    \n    :local d [/ip route get \$r distance]\
    \n    :if (\$d < \$bestDist) do={ :set bestDist \$d; :set best \$r }\
    \n  }\
    \n  :if (\$bestDist < 256) do={\
    \n    :set activeWan [:tostr [/ip route get \$best comment]]\
    \n    :set wanGw [:tostr [/ip route get \$best immediate-gw]]\
    \n    :if ([:len \$activeWan] = 0) do={ :set activeWan [:tostr [/ip route get \$best gateway]] }\
    \n    :local pct [:find \$wanGw \"%\"]\
    \n    :if ([:typeof \$pct] = \"num\") do={ :set wanIf [:pick \$wanGw (\$pct + 1) [:len \$wanGw]]; :set wanGw [:pick \$wanGw 0 \$pct] }\
    \n  }\
    \n} on-error={}\
    \n:local rosVersion [/system resource get version]\
    \n:local relVersion \"\"\
    \n:do { :set relVersion [/file get [find name=\"flash/deployed-version\"] contents] } on-error={}\
    \n:local freeMB (\$freeMem / 1048576)\
    \n:local totalMB (\$totalMem / 1048576)\
    \n:local hddFreeMB (\$freeHdd / 1048576)\
    \n:local hddTotalMB (\$totalHdd / 1048576)\
    \n:local payload (\"{\\\"level\\\":\\\"info\\\",\\\"message\\\":\\\"heartbeat\\\",\\\"cpu_load\\\":\" . \$cpuLoad . \",\\\"mem_free_mb\\\":\" . \$freeMB . \",\\\"mem_total_mb\\\":\" . \$totalMB . \",\\\"hdd_free_mb\\\":\" . \$hddFreeMB . \",\\\"hdd_total_mb\\\":\" . \$hddTotalMB . \",\\\"wan_routes\\\":\" . \$wanRoutes . \",\\\"active_wan\\\":\\\"\" . \$activeWan . \"\\\",\\\"wan_gateway\\\":\\\"\" . \$wanGw . \"\\\",\\\"wan_interface\\\":\\\"\" . \$wanIf . \"\\\",\\\"hostname\\\":\\\"\" . \$hostname . \"\\\",\\\"uptime\\\":\\\"\" . \$uptime . \"\\\",\\\"routeros_version\\\":\\\"\" . \$rosVersion . \"\\\",\\\"release_version\\\":\\\"\" . \$relVersion . \"\\\"}\")\
    \n:do { /tool fetch url=\$sinkUrl http-method=post http-header-field=(\"Authorization:Bearer \" . \$sinkToken . \",Content-Type:application/json\") http-data=\$payload output=none } on-error={ :log warning \"HEARTBEAT: shipping failed\" }"

# --- script_DEADMAN_PING -----------------------------------------------------
# Pings the success URL while WAN is up, and <url>/fail when the default route
# is gone. If the router dies outright, neither arrives and the switch fires.
/system script
add name=script_DEADMAN_PING \
    policy=read,test \
    owner=admin \
    dont-require-permissions=no \
    source=":local hcUrl \"PLACEHOLDER_DEADMAN_URL\"\
    \n:if (\$hcUrl ~ \"^PLACEHOLDER_\") do={ :error \"deadman url not configured\" }\
    \n:local hostname [/system identity get name]\
    \n:local uptime [/system resource get uptime]\
    \n:local cpuLoad [/system resource get cpu-load]\
    \n:local version [/system resource get version]\
    \n:local relVersion \"\"\
    \n:do { :set relVersion [/file get [find name=\"flash/deployed-version\"] contents] } on-error={}\
    \n:local wanRoutes [/ip route print count-only where active=yes dst-address=0.0.0.0/0]\
    \n:local body (\"Router: \" . \$hostname . \"\\nUptime: \" . \$uptime . \"\\nRouterOS: \" . \$version . \"\\nRelease: \" . \$relVersion . \"\\nCPU: \" . \$cpuLoad . \"%\\nWAN routes: \" . \$wanRoutes)\
    \n:if (\$wanRoutes = 0) do={\
    \n  :do { /tool fetch url=(\$hcUrl . \"/fail\") http-method=post http-data=(\"WAN DOWN\\n\" . \$body) output=user } on-error={ :log warning \"DEADMAN: fail-ping failed\" }\
    \n} else={\
    \n  :do { /tool fetch url=\$hcUrl http-method=post http-data=\$body output=user } on-error={ :log warning \"DEADMAN: ping failed\" }\
    \n}"

/system scheduler
# Fixed time-of-day offsets, NOT start-time=startup. A startup-anchored
# interval scheduler sits at next-run=startup and never counts down until the
# next reboot; it only looked fine while a nightly reboot woke it every day.
# On a router that reboots only for updates, heartbeat would go silent after
# every deploy. Offsets also keep the two away from :00 and from each other.
add name=schedule_HEARTBEAT interval=1m start-time=00:00:20 \
    on-event="/system script run script_HEARTBEAT" policy=read,test
add name=schedule_DEADMAN interval=1m start-time=00:00:40 \
    on-event="/system script run script_DEADMAN_PING" policy=read,test

# --- Persistent on-disk logging ----------------------------------------------
# RouterOS keeps logs in RAM by default: a reboot erases exactly the evidence
# you need to explain the reboot. This writes warning/error/critical to flash
# as a rolling buffer, so post-mortem is possible after a rollback.
# 2000 lines x 2 files: 65535 lines could fill the 16 MB flash of small boards
# (hEX), and a full flash breaks backups, snapshots and the deploy flag files.
# Guard the rule removal on the action existing: when no action is named
# "disklog", [find action="disklog"] does NOT return nothing — the unknown name
# resolves to action *0 ("memory"), so it matches every memory rule, including
# the defaults ("can not remove default rules" aborts the import) and any
# site rules that log to memory. default=no is a second fence.
/system logging
:if ([:len [/system logging action find where name="disklog"]] > 0) do={ /system logging remove [find where action="disklog" default=no] }

# File in flash/ when the device has one: the root there is RAM, and a log in
# RAM is gone after exactly the reboot it was meant to explain.
/system logging action
:do { remove [find name="disklog"] } on-error={}
:do { :local f "router-log"; :if ([:len [/file find where name="flash"]] > 0) do={ :set f "flash/router-log" }; /system logging action add name="disklog" target=disk disk-file-name=$f disk-lines-per-file=2000 disk-file-count=2 }

/system logging
add action=disklog topics=warning
add action=disklog topics=error
add action=disklog topics=critical

:log info "Observability installed: script_LOG_EVENT + script_HEARTBEAT + script_DEADMAN_PING + disk logging."
