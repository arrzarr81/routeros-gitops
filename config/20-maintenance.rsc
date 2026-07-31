# =============================================================================
# routeros-gitops :: config :: 20-maintenance.rsc   [EXAMPLE — EDIT AS NEEDED]
# Unattended RouterOS + RouterBOARD firmware updates.
# =============================================================================
#
# INSTALLS
#   script_UPGRADE / schedule_UPGRADE   03:00  stage RouterBOARD firmware
#   script_UPDATE  / schedule_UPDATE    03:05  install RouterOS packages
#   script_REBOOT  / schedule_REBOOT    03:10  reboot, applying both
#
# WHY THREE STEPS, TWENTY MINUTES APART
#   RouterOS stages package and firmware updates and only applies them on
#   reboot. Doing all three in one script risks the reboot firing before the
#   download finished. Spacing them makes each step independently observable in
#   the log, and lets you stagger downstream devices (access points, switches)
#   at 03:20+ so the router is fully back before they start pulling.
#
# THIS IS A REBOOT EVERY NIGHT. That is a deliberate choice for an unattended
# site: a router that reboots cleanly every 24h fails predictably at 03:10
# rather than unpredictably at 19:00. If you don't want it, delete the REBOOT
# scheduler — updates then apply at the next reboot you do trigger.
#
# TWO API DETAILS THAT ARE EASY TO GET WRONG
#   * `/system package update install`   — NOT `upgrade`.
#   * `installed-version`                — NOT `current-version`.
#
# FORMATTING: script bodies MUST be a single line. RouterOS .rsc files do not
# support backslash line continuation inside a value — it fails with "expected
# end of command". Use \r\n inside the source string for readability on-device.
# =============================================================================

/system routerboard settings
set auto-upgrade=yes

/system scheduler
remove [ find name="schedule_UPGRADE" ]
add name=schedule_UPGRADE interval=1d start-time="03:00:00" on-event="/system script run script_UPGRADE" policy=read
remove [ find name="schedule_UPDATE" ]
add name=schedule_UPDATE  interval=1d start-time="03:05:00" on-event="/system script run script_UPDATE"  policy=read
remove [ find name="schedule_REBOOT" ]
add name=schedule_REBOOT  interval=1d start-time="03:10:00" on-event="/system script run script_REBOOT"  policy=read

/system script

remove [ find name="script_UPGRADE" ]
add name=script_UPGRADE owner=admin dont-require-permissions=yes policy=read,write,reboot,test,sensitive source=":global logEvent \"maint_upgrade_start\"\r\n:global logLevel \"info\"\r\n:global logMessage \"Nightly UPGRADE started\"\r\n:do { /system script run script_LOG_EVENT } on-error={}\r\n:do {\r\n  :if ([/system routerboard get current-firmware] != [/system routerboard get upgrade-firmware]) do={\r\n    :log info (\"New firmware available. Staging \" . [/system routerboard get current-firmware] . \" -> \" . [/system routerboard get upgrade-firmware]);\r\n    /system routerboard upgrade;\r\n    :global logEvent \"maint_firmware_staged\"\r\n    :global logLevel \"info\"\r\n    :global logMessage (\"Firmware staged -> \" . [/system routerboard get upgrade-firmware])\r\n    :do { /system script run script_LOG_EVENT } on-error={}\r\n  } else={\r\n    :log info \"RouterBOARD firmware already current.\";\r\n  }\r\n} on-error={\r\n  :log error \"script_UPGRADE failed\";\r\n  :global logEvent \"maint_upgrade_fail\"\r\n  :global logLevel \"critical\"\r\n  :global logMessage \"UPGRADE script failed\"\r\n  :do { /system script run script_LOG_EVENT } on-error={}\r\n}"

remove [ find name="script_UPDATE" ]
add name=script_UPDATE owner=admin dont-require-permissions=yes policy=ftp,read,write,policy,test,sensitive source=":global logEvent \"maint_update_start\"\r\n:global logLevel \"info\"\r\n:global logMessage \"Nightly UPDATE started\"\r\n:do { /system script run script_LOG_EVENT } on-error={}\r\n:do {\r\n  /system package update check-for-updates;\r\n  :delay 5s;\r\n  :if ([/system package update get status] = \"New version is available\") do={\r\n    :log info (\"Staging RouterOS \" . [/system package update get installed-version] . \" -> \" . [/system package update get latest-version]);\r\n    /system package update install;\r\n    :global logEvent \"maint_software_staged\"\r\n    :global logLevel \"info\"\r\n    :global logMessage (\"RouterOS staged -> \" . [/system package update get latest-version])\r\n    :do { /system script run script_LOG_EVENT } on-error={}\r\n  } else={\r\n    :log info \"RouterOS already current.\";\r\n  }\r\n} on-error={\r\n  :log error \"script_UPDATE failed\";\r\n  :global logEvent \"maint_update_fail\"\r\n  :global logLevel \"critical\"\r\n  :global logMessage \"UPDATE script failed\"\r\n  :do { /system script run script_LOG_EVENT } on-error={}\r\n}"

remove [ find name="script_REBOOT" ]
add name=script_REBOOT owner=admin dont-require-permissions=yes policy=reboot,read,write,test source=":global logEvent \"maint_reboot_start\"\r\n:global logLevel \"info\"\r\n:global logMessage \"Nightly planned reboot firing\"\r\n:do { /system script run script_LOG_EVENT } on-error={}\r\n:log info \"Rebooting via nightly maintenance schedule.\"\r\n:delay 3s\r\n/system reboot"

:log info "config/20-maintenance: UPGRADE 03:00, UPDATE 03:05, REBOOT 03:10 installed."
