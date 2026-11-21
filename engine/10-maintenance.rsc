# =============================================================================
# routeros-gitops :: engine :: 10-maintenance.rsc
# Unattended RouterOS + RouterBOARD firmware updates. Reboots ONLY when an
# update needs it — never on a timer.
# =============================================================================
#
# INSTALLS
#   script_UPDATE  / schedule_UPDATE    03:00  RouterOS packages: install if newer
#                                              (install reboots the router itself)
#   script_UPGRADE / schedule_UPGRADE   03:20  RouterBOARD firmware: if newer,
#                                              upgrade + reboot to activate it
# REMOVES (legacy, from older configs)
#   script_REBOOT  / schedule_REBOOT           the unconditional nightly reboot
#
# WHY NO NIGHTLY REBOOT
#   A daily reboot drops the internet for 2-4 minutes every night, and anything
#   watching the network (home automation, uptime checks) has to learn to ignore
#   it — which also hides real outages in that window. Now a quiet night has no
#   reboot at all; an update night has one (packages) or two (packages, then the
#   firmware that auto-upgrade staged during that boot).
#
# ORDER: packages first, firmware second. routerboard auto-upgrade=yes flashes
#   the firmware that matches the new packages during the post-install boot;
#   script_UPGRADE at 03:20 then sees current != upgrade firmware and does the
#   one reboot that activates it. On a non-RouterBOARD device (CHR, x86) the
#   firmware step finds nothing and exits.
#
# PLANNED-REBOOT EVENT
#   Before any reboot this ships `maint_reboot_planned` (level warning) with the
#   reason, so monitoring can tell a planned reboot from an outage. It waits a
#   few seconds so the event leaves the router before the reboot does.
#
# STARTUP-SCHEDULER NOTE
#   Both schedulers use a fixed start-time, never start-time=startup (that makes
#   an interval scheduler dormant until the next reboot — see docs/06).
#
# TWO API DETAILS THAT ARE EASY TO GET WRONG
#   * `/system package update install`   — NOT `upgrade`.
#   * `installed-version`                — NOT `current-version`.
#
# FORMATTING: script bodies are single physical lines with \r\n inside the
# source string (see docs/06, "Backslash line continuation").
# =============================================================================

/system routerboard settings
:do { set auto-upgrade=yes } on-error={ :log info "10-maintenance: no routerboard settings (CHR/x86?), skipping auto-upgrade" }

/system scheduler
remove [ find name="schedule_REBOOT" ]
remove [ find name="schedule_UPGRADE" ]
remove [ find name="schedule_UPDATE" ]
/system script
remove [ find name="script_REBOOT" ]
remove [ find name="script_UPGRADE" ]
remove [ find name="script_UPDATE" ]

/system script
add name=script_UPDATE owner=admin dont-require-permissions=yes policy=ftp,reboot,read,write,policy,test,sensitive source=":global logEvent \"maint_update_start\"\r\n:global logLevel \"info\"\r\n:global logMessage \"Nightly UPDATE check started\"\r\n:do { /system script run script_LOG_EVENT } on-error={}\r\n:do {\r\n  /system package update check-for-updates;\r\n  :delay 10s;\r\n  :if ([/system package update get status] = \"New version is available\") do={\r\n    :local rosFrom [/system package update get installed-version]\r\n    :local rosTo [/system package update get latest-version]\r\n    :log warning (\"UPDATE: installing RouterOS \" . \$rosFrom . \" -> \" . \$rosTo . \", router will reboot\")\r\n    :global logEvent \"maint_reboot_planned\"\r\n    :global logLevel \"warning\"\r\n    :global logMessage (\"Planned reboot: RouterOS \" . \$rosFrom . \" -> \" . \$rosTo)\r\n    :do { /system script run script_LOG_EVENT } on-error={}\r\n    :delay 5s\r\n    /system package update install;\r\n  } else={\r\n    :log info \"UPDATE: RouterOS already current, no reboot.\";\r\n  }\r\n} on-error={\r\n  :log error \"script_UPDATE failed\";\r\n  :global logEvent \"maint_update_fail\"\r\n  :global logLevel \"critical\"\r\n  :global logMessage \"UPDATE script failed\"\r\n  :do { /system script run script_LOG_EVENT } on-error={}\r\n}"
add name=script_UPGRADE owner=admin dont-require-permissions=yes policy=reboot,read,write,test,sensitive source=":global logEvent \"maint_upgrade_start\"\r\n:global logLevel \"info\"\r\n:global logMessage \"Nightly firmware check started\"\r\n:do { /system script run script_LOG_EVENT } on-error={}\r\n:do {\r\n  :local cur [/system routerboard get current-firmware]\r\n  :local upg [/system routerboard get upgrade-firmware]\r\n  :if ((\$cur != \$upg) && ([:len \$upg] > 0)) do={\r\n    :log warning (\"UPGRADE: firmware \" . \$cur . \" -> \" . \$upg . \", router will reboot\")\r\n    /system routerboard upgrade;\r\n    :global logEvent \"maint_reboot_planned\"\r\n    :global logLevel \"warning\"\r\n    :global logMessage (\"Planned reboot: firmware \" . \$cur . \" -> \" . \$upg)\r\n    :do { /system script run script_LOG_EVENT } on-error={}\r\n    :delay 5s\r\n    /system reboot;\r\n  } else={\r\n    :log info \"UPGRADE: firmware already current, no reboot.\";\r\n  }\r\n} on-error={\r\n  :log error \"script_UPGRADE failed (no routerboard on CHR/x86 is fine)\";\r\n  :global logEvent \"maint_upgrade_fail\"\r\n  :global logLevel \"warning\"\r\n  :global logMessage \"UPGRADE script failed\"\r\n  :do { /system script run script_LOG_EVENT } on-error={}\r\n}"

/system scheduler
add name=schedule_UPDATE  interval=1d start-time="03:00:00" on-event="/system script run script_UPDATE"  policy=ftp,reboot,read,write,policy,test,sensitive
add name=schedule_UPGRADE interval=1d start-time="03:20:00" on-event="/system script run script_UPGRADE" policy=reboot,read,write,test,sensitive

:log info "engine/10-maintenance: UPDATE 03:00, UPGRADE 03:20, reboot only when an update needs it."
