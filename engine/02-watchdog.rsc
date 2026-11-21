# =============================================================================
# routeros-gitops :: engine :: 02-watchdog.rsc
# The boot-time safety net. This is what lets you deploy to a router you
# cannot physically reach.
# =============================================================================
#
# INSTALLS
#   script_WATCHDOG         boot: if a deploy is in flight, watch WAN for 5 min
#   script_STARTUP_ALERT    boot: ship router_boot, report any rollback that happened
#   schedule_WATCHDOG       start-time=startup
#   schedule_STARTUP_ALERT  start-time=startup
#
# THE TWO SAFETY NETS, AND WHY YOU NEED BOTH
#   Net 1 (inline, in 99-self-update.rsc): after importing everything, check the
#          default route. Gone -> restore the pre-deploy backup. Catches config
#          that breaks routing without rebooting.
#   Net 2 (this file): catches the case where the new config takes the router
#          down in a way that only manifests after a reboot — or where the
#          router rebooted mid-deploy and net 1 never got to run.
#
# ACTIVATION
#   script_WATCHDOG does nothing unless flash/deploy-in-progress exists. That
#   flag is created by script_SELF_UPDATE at the start of PHASE 2 and removed on
#   success. So: normal boot = instant exit; boot during/after a deploy = armed.
#
# ROLLBACK TRIGGER
#   3 consecutive failed pings (20 checks x 15s = a 5-minute window).
#   Rollback = /system backup load, which reboots immediately. Nothing after
#   that line in the script ever executes.
#
# BACKUP LOCATION
#   pre-deploy-* (from 01) and confirmed-good-* (saved here on success) live in
#   flash/ when the device has one: the root there is RAM and would be empty
#   by the time this boot-time script looks for a rollback target. Target =
#   newest pre-deploy by numeric key (all digits of the name — RouterOS can't
#   compare strings with < >). confirmed-good retention: newest 2.
#
# WHY PING AND NOT /ping-the-script-way
#   /ping inside a script returns 0 in some RouterOS builds regardless of
#   reality. [/tool ping address=... count=3] returns the received count and is
#   reliable. For a pure "is routing alive" check with no ICMP dependency, use
#   [/ip route print count-only where active=yes dst-address=0.0.0.0/0].
#   Both appear in this system; each is right in its place.
#
# THE uptime > 10m GUARD (do not remove)
#   RouterOS fires a start-time=startup scheduler AT ADD TIME, not only at boot.
#   So importing this file during a live deploy immediately launches the
#   5-minute ping loop — concurrently with the deploy's own fetch/import churn.
#   That concurrency has crashed RouterOS (service malfunction / supout.rif).
#   The guard makes both scripts no-ops unless this really is a fresh boot.
#
# PING TARGETS: PLACEHOLDER_WAN_PING_TARGETS (secrets.map setting, default
#   1.1.1.1,9.9.9.9). A check passes if ANY target answers. Never list a host
#   that your routing pins to a single uplink (recursive check-gateway routes
#   often pin 8.8.8.8 to the primary WAN): with the primary down and the backup
#   up, that host is unreachable and the watchdog would roll back a good deploy.
# =============================================================================

/system scheduler
remove [find name="schedule_WATCHDOG"]
remove [find name="schedule_STARTUP_ALERT"]

/system script
remove [find name="script_WATCHDOG"]
remove [find name="script_STARTUP_ALERT"]

# --- script_WATCHDOG ---------------------------------------------------------
/system script
add name=script_WATCHDOG \
    policy=read,write,test,password,sensitive \
    owner=admin \
    dont-require-permissions=no \
    source="# Fresh-boot guard — see the header of this file before touching it.\
    \n:if ([/system resource get uptime] > 10m) do={\
    \n  :log info \"Watchdog: uptime > 10m, not a fresh boot - skipping (deploy-safe guard).\"\
    \n  :error \"\"\
    \n}\
    \n:if ([:len [/file find name=flash/deploy-in-progress]] = 0) do={\
    \n  :log info \"Watchdog: no deploy flag. Normal boot - exiting.\"\
    \n  :error \"\"\
    \n}\
    \n:global logEvent \"deploy_flag_set\"\
    \n:global logLevel \"info\"\
    \n:global logMessage \"Watchdog armed - deploy flag detected, monitoring WAN for 5 minutes\"\
    \n:do { /system script run script_LOG_EVENT } on-error={}\
    \n\
    \n# fkey: numeric sort key = all digits of a file name, e.g.\
    \n# flash/pre-deploy-2026-11-21-0300.backup -> 202611210300. RouterOS cannot\
    \n# compare strings with < or > (\"cannot compare if string is less than string\"), numbers it can.\
    \n:local fkey do={ :local d \"\"; :for i from=0 to=([:len \$1] - 1) do={ :local c [:pick \$1 \$i (\$i + 1)]; :if (\$c~\"[0-9]\") do={ :set d (\$d . \$c) } }; :return [:tonum \$d] }\
    \n# Identify the rollback target now, while we still can.\
    \n:local allBackups [/file find where name~\"pre-deploy-\"]\
    \n:local backupCount [:len \$allBackups]\
    \n:local latestBackupName \"\"\
    \n:if (\$backupCount = 0) do={\
    \n  :log error \"Watchdog: no pre-deploy backup found - rollback impossible. Monitoring anyway.\"\
    \n} else={\
    \n  :local latestFile [/file get (\$allBackups->(\$backupCount - 1)) name]\
    \n  # Newest = max fkey (ISO date-time digits; flash/ and root alike). on-error\
    \n  # keeps the find-order pick, so a quirk can never cost us the target.\
    \n  :do {\
    \n    :local bestKey [\$fkey \$latestFile]\
    \n    :foreach b in=\$allBackups do={\
    \n      :local bn [/file get \$b name]\
    \n      :local k [\$fkey \$bn]\
    \n      :if (\$k > \$bestKey) do={ :set latestFile \$bn; :set bestKey \$k }\
    \n    }\
    \n  } on-error={}\
    \n  # strip the 7-char \".backup\" extension\
    \n  :set latestBackupName [:pick \$latestFile 0 ([:len \$latestFile] - 7)]\
    \n  :log info (\"Watchdog: rollback target if needed: \" . \$latestBackupName)\
    \n}\
    \n\
    \n:local consecutiveFails 0\
    \n:local checksDone 0\
    \n:local maxChecks 20\
    \n:local maxFails 3\
    \n:local failTimestamp \"\"\
    \n:while (\$checksDone < \$maxChecks) do={\
    \n  :local received 0\
    \n  :foreach t in=[:toarray \"PLACEHOLDER_WAN_PING_TARGETS\"] do={\
    \n    :if (\$received = 0) do={ :do { :set received [/tool ping address=\$t count=3] } on-error={} }\
    \n  }\
    \n  :if (\$received = 0) do={\
    \n    :set consecutiveFails (\$consecutiveFails + 1)\
    \n    :log warning (\"Watchdog: WAN check FAILED. Consecutive: \" . \$consecutiveFails . \"/\" . \$maxFails)\
    \n    :if (\$consecutiveFails = 1) do={\
    \n      :global logEvent \"wan_down\"\
    \n      :global logLevel \"critical\"\
    \n      :global logMessage \"WAN ping failed after deploy (no target answered)\"\
    \n      :do { /system script run script_LOG_EVENT } on-error={}\
    \n    }\
    \n    :if (\$consecutiveFails >= \$maxFails) do={\
    \n      :set failTimestamp ([/system clock get date] . \"T\" . [/system clock get time])\
    \n      :log error (\"Watchdog: ROLLBACK - \" . \$maxFails . \" consecutive WAN failures at \" . \$failTimestamp . \". Loading: \" . \$latestBackupName)\
    \n      # Ship the event BEFORE the restore: backup load reboots instantly.\
    \n      :global logEvent \"rollback_triggered\"\
    \n      :global logLevel \"critical\"\
    \n      :global logMessage (\"Consecutive WAN failures. Restoring backup: \" . \$latestBackupName)\
    \n      :do { /system script run script_LOG_EVENT } on-error={}\
    \n      # Marker survives the reboot so STARTUP_ALERT can report what happened.\
    \n      /file remove [find name=\"flash/rollback-marker\"]\
    \n      /file add name=flash/rollback-marker type=file contents=(\"backup=\" . \$latestBackupName . \" failtime=\" . \$failTimestamp)\
    \n      :if ([:len \$latestBackupName] > 0) do={\
    \n        # ROUTER REBOOTS HERE. No line below this executes.\
    \n        /system backup load name=\$latestBackupName\
    \n      }\
    \n    }\
    \n  } else={\
    \n    :if (\$consecutiveFails > 0) do={\
    \n      :global logEvent \"wan_up\"\
    \n      :global logLevel \"info\"\
    \n      :global logMessage \"WAN recovered after transient failure\"\
    \n      :do { /system script run script_LOG_EVENT } on-error={}\
    \n    }\
    \n    :set consecutiveFails 0\
    \n  }\
    \n  :set checksDone (\$checksDone + 1)\
    \n  :delay 15s\
    \n}\
    \n\
    \n# --- Success: 5 minutes of healthy WAN. Commit the deploy. ---\
    \n:log info \"Watchdog: window complete, WAN healthy. Deploy confirmed good.\"\
    \n/file remove [find name=\"flash/deploy-in-progress\"]\
    \n:global logEvent \"deploy_flag_cleared\"\
    \n:global logLevel \"info\"\
    \n:global logMessage \"Deploy confirmed - WAN healthy for 5 minutes, flag cleared\"\
    \n:do { /system script run script_LOG_EVENT } on-error={}\
    \n:local rawDate [/system clock get date]\
    \n:local rawTime [/system clock get time]\
    \n:local gDateSafe \"\"\
    \n:local gI 0\
    \n:while (\$gI < [:len \$rawDate]) do={\
    \n  :local ch [:pick \$rawDate \$gI (\$gI + 1)]\
    \n  :if (\$ch = \"/\") do={ :set ch \"-\" }\
    \n  :set gDateSafe (\$gDateSafe . \$ch)\
    \n  :set gI (\$gI + 1)\
    \n}\
    \n# Root is RAM on devices with a flash/ dir (wiped on reboot): save there.\
    \n:local bkDir \"\"\
    \n:if ([:len [/file find where name=\"flash\"]] > 0) do={ :set bkDir \"flash/\" }\
    \n:local goodName (\$bkDir . \"confirmed-good-\" . \$gDateSafe . \"-\" . ([:pick \$rawTime 0 2] . [:pick \$rawTime 3 5]))\
    \n:do { /system backup save name=\$goodName dont-encrypt=yes } on-error={ :log warning \"Watchdog: confirmed-good backup failed\" }\
    \n:delay 3s\
    \n# Retention: keep the 2 newest confirmed-good backups (~67 KB each; small units\
    \n# have ~2 MB free flash, and a full disk breaks the next pre-deploy save).\
    \n:local goods [/file find where name~\"confirmed-good-\"]\
    \n:do {\
    \n  :while ([:len \$goods] > 2) do={\
    \n    :local oldest (\$goods->0)\
    \n    :local oldKey [\$fkey [/file get \$oldest name]]\
    \n    :foreach g in=\$goods do={\
    \n      :local k [\$fkey [/file get \$g name]]\
    \n      :if (\$k < \$oldKey) do={ :set oldest \$g; :set oldKey \$k }\
    \n    }\
    \n    :log info (\"Watchdog: pruning old \" . [/file get \$oldest name])\
    \n    /file remove \$oldest\
    \n    :set goods [/file find where name~\"confirmed-good-\"]\
    \n  }\
    \n} on-error={ :log warning \"Watchdog: confirmed-good retention failed\" }\
    \n:log info (\"Watchdog complete: deploy healthy, saved \" . \$goodName)"

# --- script_STARTUP_ALERT ----------------------------------------------------
# Runs on every boot. Ships router_boot. If a rollback marker is present, waits
# for WAN and reports the rollback, then clears the marker and the deploy flag.
/system script
add name=script_STARTUP_ALERT \
    policy=read,write,test \
    owner=admin \
    dont-require-permissions=no \
    source="# Fresh-boot guard — same reason as script_WATCHDOG.\
    \n:if ([/system resource get uptime] > 10m) do={\
    \n  :log info \"Startup alert: uptime > 10m, not a fresh boot - skipping.\"\
    \n  :error \"\"\
    \n}\
    \n:global logEvent \"router_boot\"\
    \n:global logLevel \"info\"\
    \n:global logMessage \"Router has booted\"\
    \n:do { /system script run script_LOG_EVENT } on-error={}\
    \n:if ([:len [/file find name=flash/rollback-marker]] = 0) do={\
    \n  :log info \"Startup alert: no rollback marker. Normal boot.\"\
    \n  :error \"\"\
    \n}\
    \n:local markerContent [/file get [find name=flash/rollback-marker] contents]\
    \n:log info (\"Startup alert: rollback marker found: \" . \$markerContent)\
    \n# Wait up to 3 minutes for WAN so the alert can actually leave the building.\
    \n:local wanUp false\
    \n:local tries 0\
    \n:while ((\$tries < 18) && (!\$wanUp)) do={\
    \n  :foreach t in=[:toarray \"PLACEHOLDER_WAN_PING_TARGETS\"] do={\
    \n    :if (!\$wanUp) do={ :do { :if ([/tool ping address=\$t count=2] > 0) do={ :set wanUp true } } on-error={} }\
    \n  }\
    \n  :if (!\$wanUp) do={ :delay 10s; :set tries (\$tries + 1) }\
    \n}\
    \n:local wanStatus \"UP\"\
    \n:if (!\$wanUp) do={ :set wanStatus \"STILL DOWN\" }\
    \n:global logEvent \"rollback_completed\"\
    \n:global logLevel \"critical\"\
    \n:global logMessage (\"Rollback completed. \" . \$markerContent . \" WAN now: \" . \$wanStatus)\
    \n:do { /system script run script_LOG_EVENT } on-error={}\
    \n/file remove [find name=\"flash/rollback-marker\"]\
    \n/file remove [find name=\"flash/deploy-in-progress\"]\
    \n:log info \"Startup alert: rollback reported, markers cleared.\""

# --- Startup schedulers ------------------------------------------------------
# RouterOS runs startup schedulers alphabetically by name, so
# schedule_STARTUP_ALERT sorts before schedule_WATCHDOG. That ordering is
# intentional: report the boot and any rollback first, then start monitoring.
/system scheduler
add name=schedule_STARTUP_ALERT start-time=startup interval=0 \
    on-event="/system script run script_STARTUP_ALERT" \
    policy=read,write,test

add name=schedule_WATCHDOG start-time=startup interval=0 \
    on-event="/system script run script_WATCHDOG" \
    policy=read,write,test,password,sensitive

:log info "Watchdog installed: script_WATCHDOG + script_STARTUP_ALERT + startup schedulers."
