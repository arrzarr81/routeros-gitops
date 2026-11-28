# =============================================================================
# routeros-gitops :: engine :: 01-pre-deploy-snapshot.rsc
# Installs script_PRE_DEPLOY_SNAPSHOT — the rollback target maker.
# =============================================================================
#
# INSTALL-ONLY BY DESIGN
#   Importing this file ONLY (re)installs the script. It deliberately does NOT
#   take a backup at import time.
#
#   Why: script_SELF_UPDATE already RUNS script_PRE_DEPLOY_SNAPSHOT to make the
#   rollback point, and then imports this asset moments later as part of the
#   same release. When this file also ran /system backup save inline at import,
#   the two back-to-back saves overwhelmed the backup service on a near-full
#   flash unit -> "service malfunction", a supout.rif dump, and a failed import
#   that left a mangled script installed. One save per deploy. Not two.
#
# TO TAKE A SNAPSHOT, RUN THE SCRIPT — never rely on importing this file:
#   /system script run script_PRE_DEPLOY_SNAPSHOT
#
# NAME FORMAT
#   [flash/]pre-deploy-<date>-HHMM   e.g. flash/pre-deploy-2026-07-19-0750
#   The "pre-deploy-" prefix is load-bearing: the watchdog and the self-update
#   rollback path both find the restore target with [/file find where
#   name~"pre-deploy-"] and take the NEWEST by numeric key (digits of the name).
#   Don't rename it.
#
# WHERE: flash/ when the device has a flash directory. On such devices the
#   file root is RAM: /system backup save name=x lands there and is wiped by
#   the very reboot a rollback depends on. See docs/06-routeros-gotchas.md.
#
# dont-encrypt=yes so the backup is loadable without a password — a rollback
# that prompts for a passphrase is not a rollback.
#
# RETENTION: keeps the 3 most recent (by numeric key, not /file find order). Flash on small units is genuinely tight
# and a full disk breaks backup saves, which breaks rollback, which is the one
# thing that must never break.
# =============================================================================

/system script
remove [find name="script_PRE_DEPLOY_SNAPSHOT"]
add name=script_PRE_DEPLOY_SNAPSHOT \
    policy=read,write,test,password,sensitive \
    owner=admin \
    dont-require-permissions=no \
    source=":local rawDate [/system clock get date]\
    \n:local rawTime [/system clock get time]\
    \n# Format-agnostic: handles both legacy \"mmm/dd/yyyy\" and ISO \"yyyy-mm-dd\"\
    \n# Normalise legacy \"mmm/dd/yyyy\" to ISO so the digit sort key stays chronological\
    \n:if ([:pick \$rawDate 3 4] = \"/\") do={ :local mp [:find \"janfebmaraprmayjunjulaugsepoctnovdec\" [:pick \$rawDate 0 3]]; :if ([:typeof \$mp] = \"num\") do={ :local mm [:tostr ((\$mp / 3) + 1)]; :if ([:len \$mm] < 2) do={ :set mm (\"0\" . \$mm) }; :set rawDate ([:pick \$rawDate 7 11] . \"-\" . \$mm . \"-\" . [:pick \$rawDate 4 6]) } }\
    \n:local dateSafe \"\"\
    \n:local i 0\
    \n:while (\$i < [:len \$rawDate]) do={\
    \n  :local ch [:pick \$rawDate \$i (\$i + 1)]\
    \n  :if (\$ch = \"/\") do={ :set ch \"-\" }\
    \n  :set dateSafe (\$dateSafe . \$ch)\
    \n  :set i (\$i + 1)\
    \n}\
    \n:local hhmmSafe ([:pick \$rawTime 0 2] . [:pick \$rawTime 3 5])\
    \n# Root is RAM on devices with a flash/ dir (wiped on reboot): save there.\
    \n:local bkDir \"\"\
    \n:if ([:len [/file find where name=\"flash\"]] > 0) do={ :set bkDir \"flash/\" }\
    \n:local snapshotName (\$bkDir . \"pre-deploy-\" . \$dateSafe . \"-\" . \$hhmmSafe)\
    \n:log info (\"Saving pre-deploy snapshot: \" . \$snapshotName)\
    \n/system backup save name=\$snapshotName dont-encrypt=yes\
    \n:delay 3s\
    \n:log info (\"Snapshot saved: \" . \$snapshotName . \".backup\")\
    \n# fkey: numeric sort key = all digits of a file name, e.g.\
    \n# flash/pre-deploy-2026-11-21-0300.backup -> 202611210300. RouterOS cannot\
    \n# compare strings with < or > (\"cannot compare if string is less than string\"), numbers it can.\
    \n:local fkey do={ :local d \"\"; :for i from=0 to=([:len \$1] - 1) do={ :local c [:pick \$1 \$i (\$i + 1)]; :if (\$c~\"[0-9]\") do={ :set d (\$d . \$c) } }; :return [:tonum \$d] }\
    \n# Prune the OLDEST by key (not /file find order) until maxKeep remain.\
    \n:local allBackups [/file find where name~\"pre-deploy-\" and type=\"backup\"]\
    \n:local maxKeep 3\
    \n:log info (\"Found \" . [:len \$allBackups] . \" pre-deploy backup(s). Keeping \" . \$maxKeep . \" most recent.\")\
    \n:do {\
    \n  :while ([:len \$allBackups] > \$maxKeep) do={\
    \n    :local oldest (\$allBackups->0)\
    \n    :local oldKey [\$fkey [/file get \$oldest name]]\
    \n    :foreach b in=\$allBackups do={\
    \n      :local k [\$fkey [/file get \$b name]]\
    \n      :if (\$k < \$oldKey) do={ :set oldest \$b; :set oldKey \$k }\
    \n    }\
    \n    :log info (\"Pruning old snapshot: \" . [/file get \$oldest name])\
    \n    /file remove \$oldest\
    \n    :set allBackups [/file find where name~\"pre-deploy-\" and type=\"backup\"]\
    \n  }\
    \n} on-error={ :log warning \"Pre-deploy retention failed\" }\
    \n:log info \"Pre-deploy snapshot complete.\""

:log info "script_PRE_DEPLOY_SNAPSHOT installed. Invoke with: /system script run script_PRE_DEPLOY_SNAPSHOT"
