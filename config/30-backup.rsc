# =============================================================================
# routeros-gitops :: config :: 30-backup.rsc   [EXAMPLE — EDIT AS NEEDED]
# Routine on-box backups + retention. Separate from the deploy safety net.
# =============================================================================
#
# TWO KINDS OF BACKUP, AND YOU WANT BOTH
#   * BINARY  (/system backup save)  — exact, restores in one command, but is
#     tied to this device model and RouterOS version. This is what a rollback
#     loads. Not human-readable, not diffable.
#   * TEXT    (/export)              — readable, diffable, portable to another
#     device. Cannot be "loaded"; you import it. This is what you actually read
#     when you need to know what changed.
#
# WHAT THIS FILE DOES
#   script_BACKUP_WEEKLY  Sunday 04:00 — one binary + one text export
#   script_BACKUP_PRUNE   daily 04:30  — enforce retention on both
#
# WHY RETENTION MATTERS MORE THAN YOU THINK
#   Small RouterBOARDs have very little flash. A full disk breaks
#   /system backup save. That breaks the pre-deploy snapshot. That breaks
#   rollback. The one job of this file is to make sure the safety net still has
#   room to exist. Keep the prune schedule.
#
# NOTE: this deliberately does NOT ship backups off-box. Doing so needs
# credentials (FTP/SFTP/S3) and every option is site-specific. See
# docs/04-operations.md for how to add one using the placeholder mechanism, and
# note that a config export contains your PSKs and secrets in cleartext — an
# off-box copy is a secret in itself. The engine's confirmed-good backups are
# your practical recovery path; this file is your history.
#
# `/export` here uses `hide-sensitive` so the text copy is safe to eyeball over
# a shoulder. Drop that flag if you want a genuinely restorable text export —
# and then treat the file accordingly.
# =============================================================================

/system scheduler
remove [find name="schedule_BACKUP_WEEKLY"]
remove [find name="schedule_BACKUP_PRUNE"]

/system script
remove [find name="script_BACKUP_WEEKLY"]
remove [find name="script_BACKUP_PRUNE"]

/system script
add name=script_BACKUP_WEEKLY \
    policy=read,write,test,password,sensitive \
    owner=admin \
    dont-require-permissions=no \
    source=":local rawDate [/system clock get date]\
    \n:local dateSafe \"\"\
    \n:local i 0\
    \n:while (\$i < [:len \$rawDate]) do={\
    \n  :local ch [:pick \$rawDate \$i (\$i + 1)]\
    \n  :if (\$ch = \"/\") do={ :set ch \"-\" }\
    \n  :set dateSafe (\$dateSafe . \$ch)\
    \n  :set i (\$i + 1)\
    \n}\
    \n:local bkDir \"\"\
    \n:if ([:len [/file find where name=\"flash\"]] > 0) do={ :set bkDir \"flash/\" }\
    \n:local base (\$bkDir . \"weekly-\" . \$dateSafe)\
    \n:do {\
    \n  /system backup save name=\$base dont-encrypt=yes\
    \n  :delay 3s\
    \n  /export file=\$base hide-sensitive\
    \n  :delay 3s\
    \n  :log info (\"Weekly backup saved: \" . \$base . \".backup + \" . \$base . \".rsc\")\
    \n  :global logEvent \"backup_weekly_ok\"\
    \n  :global logLevel \"info\"\
    \n  :global logMessage (\"Weekly backup saved: \" . \$base)\
    \n} on-error={\
    \n  :log error \"Weekly backup FAILED (disk full?)\"\
    \n  :global logEvent \"backup_weekly_fail\"\
    \n  :global logLevel \"critical\"\
    \n  :global logMessage \"Weekly backup failed - check free flash space\"\
    \n}\
    \n:do { /system script run script_LOG_EVENT } on-error={}"

# Retention. Keeps the N newest of each family and deletes the OLDEST by numeric
# key (all digits of the file name -> :tonum), same approach as the engine.
# RouterOS cannot compare strings with < or > ("cannot compare if string is less
# than string"), and /file find order is not chronological. Paths include bkDir
# (flash/ when present), the same place the engine and the weekly script save.
# weekly-* is pruned per extension (.backup / .rsc), so "2" means two weekly
# pairs. confirmed-good x2 matches the engine's own retention.
add name=script_BACKUP_PRUNE \
    policy=read,write,test \
    owner=admin \
    dont-require-permissions=no \
    source=":local bkDir \"\"\
    \n:if ([:len [/file find where name=\"flash\"]] > 0) do={ :set bkDir \"flash/\" }\
    \n:local prune do={\
    \n  :local fkey do={ :local d \"\"; :for i from=0 to=([:len \$1] - 1) do={ :local c [:pick \$1 \$i (\$i + 1)]; :if (\$c~\"[0-9]\") do={ :set d (\$d . \$c) } }; :return [:tonum \$d] }\
    \n  :local files [/file find where name~\$1]\
    \n  :while ([:len \$files] > \$2) do={\
    \n    :local oldest (\$files->0)\
    \n    :local oldKey [\$fkey [/file get \$oldest name]]\
    \n    :foreach f in=\$files do={\
    \n      :local k [\$fkey [/file get \$f name]]\
    \n      :if (\$k < \$oldKey) do={ :set oldest \$f; :set oldKey \$k }\
    \n    }\
    \n    :log info (\"Pruning: \" . [/file get \$oldest name])\
    \n    /file remove \$oldest\
    \n    :set files [/file find where name~\$1]\
    \n  }\
    \n}\
    \n:do { \$prune (\"^\" . \$bkDir . \"weekly-.*backup\\\$\") 2 } on-error={ :log warning \"Prune weekly .backup failed\" }\
    \n:do { \$prune (\"^\" . \$bkDir . \"weekly-.*rsc\\\$\") 2 } on-error={ :log warning \"Prune weekly .rsc failed\" }\
    \n:do { \$prune (\"^\" . \$bkDir . \"confirmed-good-\") 2 } on-error={ :log warning \"Prune confirmed-good failed\" }\
    \n:do { \$prune (\"^\" . \$bkDir . \"pre-deploy-\") 3 } on-error={ :log warning \"Prune pre-deploy failed\" }\
    \n:local freeHdd [/system resource get free-hdd-space]\
    \n:local freeKB (\$freeHdd / 1024)\
    \n:log info (\"Backup prune complete. Free flash: \" . \$freeKB . \" KiB\")\
    \n:if (\$freeKB < 2048) do={\
    \n  :log error (\"LOW FLASH: only \" . \$freeKB . \" KiB free - backups and rollback are at risk\")\
    \n  :global logEvent \"flash_low\"\
    \n  :global logLevel \"critical\"\
    \n  :global logMessage (\"Low flash: \" . \$freeKB . \" KiB free\")\
    \n  :do { /system script run script_LOG_EVENT } on-error={}\
    \n}"

/system scheduler
# Weekly: interval=7d anchored by the first run at the given time.
add name=schedule_BACKUP_WEEKLY interval=7d start-time="04:00:00" \
    on-event="/system script run script_BACKUP_WEEKLY" policy=read,write,test,password,sensitive
add name=schedule_BACKUP_PRUNE  interval=1d start-time="04:30:00" \
    on-event="/system script run script_BACKUP_PRUNE"  policy=read,write,test

:log info "config/30-backup: weekly backup 04:00 + daily prune 04:30 installed."
