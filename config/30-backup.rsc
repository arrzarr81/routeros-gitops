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
    \n:local base (\"weekly-\" . \$dateSafe)\
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

# Retention. Keeps the N newest of each family and deletes from the START of
# the find list. Note /file find order is insertion order, not sorted by name —
# the date-stamped naming above keeps those equivalent in practice.
add name=script_BACKUP_PRUNE \
    policy=read,write,test \
    owner=admin \
    dont-require-permissions=no \
    source=":local prune do={\
    \n  :local files [/file find where name~\$1]\
    \n  :local n [:len \$files]\
    \n  :if (\$n > \$2) do={\
    \n    :local toDelete (\$n - \$2)\
    \n    :local k 0\
    \n    :while (\$k < \$toDelete) do={\
    \n      :log info (\"Pruning: \" . [/file get (\$files->\$k) name])\
    \n      /file remove (\$files->\$k)\
    \n      :set k (\$k + 1)\
    \n    }\
    \n  }\
    \n}\
    \n\$prune \"weekly-\" 4\
    \n\$prune \"confirmed-good-\" 3\
    \n\$prune \"pre-deploy-\" 3\
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
