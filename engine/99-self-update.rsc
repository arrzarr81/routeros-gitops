# =============================================================================
# routeros-gitops :: engine :: 99-self-update.rsc
# The pull agent. This is the heart of the whole system.
# =============================================================================
#
# WHAT IT DOES
#   Installs script_SELF_UPDATE plus an hourly scheduler. Once an hour the
#   router makes an OUTBOUND HTTPS call to api.github.com, asks for the latest
#   Release of your repo, and — if the tag is newer than what it last applied —
#   downloads the rendered .rsc assets and imports them itself.
#
# WHY OUTBOUND
#   CGNAT, an ISP box you don't control, a customer site with no port-forward:
#   inbound SSH from GitHub Actions is impossible in all of those. Outbound
#   HTTPS traverses every NAT there is. So we invert the direction: CI never
#   touches the router, the router dials CI.
#
# THE APPLY LOOP
#   1. GET /repos/<repo>/releases/latest  -> tag_name + assets[]
#   2. tag == contents of flash/deployed-version  -> no-op, exit quietly.
#   3. New tag -> fetch deploy-manifest.json, then:
#      PHASE 1  fetch EVERY asset to disk, import NOTHING, then verify each
#               file exists with size > 0. Any failure aborts with ZERO config
#               changes — no flag, no marker, no partial import. Next hour
#               retries. (This exists because of a real outage: the hourly dial
#               landed while the release workflow was still uploading assets,
#               so a cleanup module imported and the module that rebuilds
#               config 404'd. Fetch-all-then-import makes that impossible.)
#      PHASE 2  arm the watchdog (flash/deploy-in-progress + pre-deploy
#               snapshot), then import each asset IN MANIFEST ORDER.
#   4. Inline WAN check. Default route gone after applying -> restore the newest
#      pre-deploy backup and reboot. The boot watchdog (engine/02-watchdog.rsc)
#      is the second safety net on that reboot path.
#   5. Success -> write tag to flash/deployed-version, clear the flag, save a
#      confirmed-good backup (flash/ when present, newest 2 kept), ship an event.
#
# BACKUPS GO TO flash/ ON DEVICES THAT HAVE IT — the root there is RAM, wiped
#   on reboot. Rollback picks the newest pre-deploy-* by embedded date-time.
#
# THE SELF-IMPORT PROBLEM
#   This script cannot import the file that defines it — /import would remove
#   script_SELF_UPDATE while script_SELF_UPDATE is the running job. So the
#   manifest entry for this file is marked "self": true; we fetch it, skip it
#   during the import loop, and re-import it afterwards from a one-shot
#   scheduler running in its own context.
#
# PLACEHOLDERS (injected by scripts/render.sh — see secrets.map)
#   PLACEHOLDER_GITHUB_REPO   owner/repo, e.g. acme/net-config
#   PLACEHOLDER_GITHUB_PAT    fine-grained PAT: this repo only, contents:read
#
# REQUIRES (imported earlier in the manifest)
#   script_LOG_EVENT             engine/00-observability.rsc
#   script_PRE_DEPLOY_SNAPSHOT   engine/01-pre-deploy-snapshot.rsc
#
# EVENTS
#   selfupdate_noop / selfupdate_start / selfupdate_fetch_incomplete /
#   selfupdate_applied / selfupdate_applied_warn / selfupdate_fail
#
# -----------------------------------------------------------------------------
# TWO RULES YOU MUST NOT BREAK WHEN EDITING THIS FILE
#
# 1. INSIDE source="..." EVERY RUNTIME $var MUST BE WRITTEN \$var AND EVERY
#    QUOTE \".  RouterOS interpolates $ inside source= at PARSE time. An
#    unescaped $foo is substituted with an empty string before the script is
#    ever stored, silently gutting your logic.
#
# 2. DO NOT REMOVE `password` FROM THE policy= SETS BELOW.  RouterOS can only
#    grant a child script the policies its parent context already holds. This
#    script imports modules that declare `password` (needed for
#    /system backup save|load and /export). Without `password` here, RouterOS
#    marks those children INVALID and blanks their source — the boot watchdog
#    dies silently. It must be present on script_SELF_UPDATE AND on both
#    schedulers that run or re-import it.
# =============================================================================

/system script
remove [ find name="script_SELF_UPDATE" ]
add name=script_SELF_UPDATE owner=admin dont-require-permissions=no policy=ftp,reboot,read,write,policy,test,password,sensitive source=":local repo \"PLACEHOLDER_GITHUB_REPO\"\
    \n:local ghPat \"PLACEHOLDER_GITHUB_PAT\"\
    \n:local ua \"routeros-gitops\"\
    \n:local relUrl (\"https://api.github.com/repos/\" . \$repo . \"/releases/latest\")\
    \n:local metaHdr (\"Authorization:token \" . \$ghPat . \",Accept:application/vnd.github+json,User-Agent:\" . \$ua)\
    \n:local octetHdr (\"Authorization:token \" . \$ghPat . \",Accept:application/octet-stream,User-Agent:\" . \$ua)\
    \n:local fetchOk false\
    \n:local tag \"\"\
    \n:local assets \"\"\
    \n:do {\
    \n  :local metaRes [/tool fetch url=\$relUrl http-header-field=\$metaHdr output=user as-value]\
    \n  :if ((\$metaRes->\"status\") = \"finished\") do={\
    \n    :local meta [:deserialize from=json value=(\$metaRes->\"data\")]\
    \n    :set tag (\$meta->\"tag_name\")\
    \n    :set assets (\$meta->\"assets\")\
    \n    :set fetchOk true\
    \n  }\
    \n} on-error={ :log warning \"SELF_UPDATE: release metadata fetch failed (network?), retry next hour\" }\
    \n:if ((\$fetchOk) && ([:len \$tag] > 0)) do={\
    \n  :local cur \"\"\
    \n  :do { :set cur [/file get [find name=\"flash/deployed-version\"] contents] } on-error={}\
    \n  :if (\$cur = \$tag) do={\
    \n    :log info (\"SELF_UPDATE: already at \" . \$tag)\
    \n    :global logEvent \"selfupdate_noop\"\
    \n    :global logLevel \"info\"\
    \n    :global logMessage (\"Self-update: already at release \" . \$tag)\
    \n    :do { /system script run script_LOG_EVENT } on-error={}\
    \n  } else={\
    \n    :log info (\"SELF_UPDATE: new release \" . \$tag . \" (current \" . \$cur . \") applying\")\
    \n    :global logEvent \"selfupdate_start\"\
    \n    :global logLevel \"info\"\
    \n    :global logMessage (\"Self-update: applying release \" . \$tag)\
    \n    :do { /system script run script_LOG_EVENT } on-error={}\
    \n    :local manifestUrl \"\"\
    \n    :foreach a in=\$assets do={ :if ((\$a->\"name\") = \"deploy-manifest.json\") do={ :set manifestUrl (\$a->\"url\") } }\
    \n    :local applyOk true\
    \n    :if ([:len \$manifestUrl] = 0) do={ :log error \"SELF_UPDATE: manifest asset missing from release\"; :set applyOk false }\
    \n    :local manifest \"\"\
    \n    :if (\$applyOk) do={\
    \n      :local manRes [/tool fetch url=\$manifestUrl http-header-field=\$octetHdr output=user as-value]\
    \n      :if ((\$manRes->\"status\") = \"finished\") do={ :set manifest [:deserialize from=json value=(\$manRes->\"data\")] } else={ :log error \"SELF_UPDATE: manifest fetch failed\"; :set applyOk false }\
    \n    }\
    \n    :local hadErr false\
    \n    :local selfDst \"\"\
    \n    \
    \n    # ---------- PHASE 1: fetch everything, import nothing ----------\
    \n    :if (\$applyOk) do={\
    \n      :local allFetched true\
    \n      :foreach e in=\$manifest do={\
    \n        :local eAsset (\$e->\"asset\")\
    \n        :local eDst (\$e->\"dst\")\
    \n        :local eUrl \"\"\
    \n        :foreach a in=\$assets do={ :if ((\$a->\"name\") = \$eAsset) do={ :set eUrl (\$a->\"url\") } }\
    \n        :if ([:len \$eUrl] = 0) do={\
    \n          :log error (\"SELF_UPDATE: asset missing \" . \$eAsset)\
    \n          :set allFetched false\
    \n        } else={\
    \n          /file remove [find name=\$eDst]\
    \n          :do { /tool fetch url=\$eUrl http-header-field=\$octetHdr dst-path=\$eDst } on-error={ :log error (\"SELF_UPDATE: fetch failed \" . \$eAsset); :set allFetched false }\
    \n        }\
    \n      }\
    \n      :delay 2s\
    \n      :foreach e in=\$manifest do={\
    \n        :local vDst (\$e->\"dst\")\
    \n        :local vOk false\
    \n        :do { :if ([/file get [find name=\$vDst] size] > 0) do={ :set vOk true } } on-error={}\
    \n        :if (\$vOk = false) do={ :log error (\"SELF_UPDATE: fetched file missing/empty \" . \$vDst); /file remove [find name=\$vDst]; :set allFetched false }\
    \n      }\
    \n      :if (\$allFetched = false) do={\
    \n        :set applyOk false\
    \n        :log error (\"SELF_UPDATE: fetch incomplete for \" . \$tag . \", nothing imported, retry next hour\")\
    \n        :global logEvent \"selfupdate_fetch_incomplete\"\
    \n        :global logLevel \"warning\"\
    \n        :global logMessage (\"Self-update \" . \$tag . \" fetch incomplete (release assets not ready?), aborted before any import\")\
    \n        :do { /system script run script_LOG_EVENT } on-error={}\
    \n      }\
    \n    }\
    \n    \
    \n    # ---------- PHASE 2: arm watchdog, import in manifest order ----------\
    \n    :if (\$applyOk) do={\
    \n      /file remove [find name=\"flash/deploy-in-progress\"]\
    \n      /file add name=flash/deploy-in-progress type=file\
    \n      :do { /system script run script_PRE_DEPLOY_SNAPSHOT } on-error={ :log warning \"SELF_UPDATE: pre-deploy snapshot failed\" }\
    \n      :foreach e in=\$manifest do={\
    \n        :local eAction (\$e->\"action\")\
    \n        :local eDst (\$e->\"dst\")\
    \n        :if ((\$e->\"self\") = true) do={\
    \n          :set selfDst \$eDst\
    \n          :log info \"SELF_UPDATE: self asset fetched; import deferred to one-shot scheduler (a running job cannot re-import itself)\"\
    \n        } else={\
    \n          :if (\$eAction = \"import\") do={\
    \n            :do { /import verbose=yes file-name=\$eDst; :log info (\"SELF_UPDATE: imported \" . \$eDst) } on-error={ :log error (\"SELF_UPDATE: import failed \" . \$eDst); :set hadErr true }\
    \n          }\
    \n        }\
    \n      }\
    \n    }\
    \n    \
    \n    # ---------- Verify WAN, then commit or roll back ----------\
    \n    :local wan [/ip route print count-only where active=yes dst-address=0.0.0.0/0]\
    \n    :if ((\$applyOk) && (\$wan = 0)) do={\
    \n      :log error \"SELF_UPDATE: WAN DOWN after apply, rolling back\"\
    \n      :global logEvent \"selfupdate_fail\"\
    \n      :global logLevel \"critical\"\
    \n      :global logMessage (\"Self-update \" . \$tag . \" broke WAN, rolling back\")\
    \n      :do { /system script run script_LOG_EVENT } on-error={}\
    \n      :local bks [/file find where name~\"pre-deploy-\"]\
    \n      :local n [:len \$bks]\
    \n      :if (\$n > 0) do={\
    \n        :local f [/file get (\$bks->(\$n - 1)) name]\
    \n        # newest by embedded date-time; on-error keeps the find-order pick\
    \n        :do { :foreach b in=\$bks do={ :local bn [/file get \$b name]; :if ([:pick \$bn [:find \$bn \"pre-deploy-\"] [:len \$bn]] > [:pick \$f [:find \$f \"pre-deploy-\"] [:len \$f]]) do={ :set f \$bn } } } on-error={}\
    \n        :local bname [:pick \$f 0 ([:len \$f] - 7)]\
    \n        /file remove [find name=\"flash/rollback-marker\"]\
    \n        /file add name=flash/rollback-marker type=file contents=(\"backup=\" . \$bname . \" reason=selfupdate\")\
    \n        /system backup load name=\$bname\
    \n      }\
    \n    } else={\
    \n      :if (\$applyOk) do={\
    \n        /file remove [find name=\"flash/deployed-version\"]\
    \n        /file add name=flash/deployed-version type=file contents=\$tag\
    \n        /file remove [find name=\"flash/deploy-in-progress\"]\
    \n        :local cgRaw [/system clock get date]\
    \n        :local cgSafe \"\"\
    \n        :local cgI 0\
    \n        :while (\$cgI < [:len \$cgRaw]) do={ :local ch [:pick \$cgRaw \$cgI (\$cgI + 1)]; :if (\$ch = \"/\") do={ :set ch \"-\" }; :set cgSafe (\$cgSafe . \$ch); :set cgI (\$cgI + 1) }\
    \n        # flash/ when present: the root is RAM there and is wiped on reboot\
    \n        :local bkDir \"\"\
    \n        :if ([:len [/file find where name=\"flash\"]] > 0) do={ :set bkDir \"flash/\" }\
    \n        :do { /system backup save name=(\$bkDir . \"confirmed-good-\" . \$cgSafe) dont-encrypt=yes } on-error={}\
    \n        :delay 3s\
    \n        # keep the 2 newest confirmed-good (~67 KB each, ~2 MB free flash on small units)\
    \n        :local goods [/file find where name~\"confirmed-good-\"]\
    \n        :do {\
    \n          :while ([:len \$goods] > 2) do={\
    \n            :local oldest (\$goods->0)\
    \n            :local oldKey [/file get \$oldest name]\
    \n            :set oldKey [:pick \$oldKey [:find \$oldKey \"confirmed-good-\"] [:len \$oldKey]]\
    \n            :foreach g in=\$goods do={ :local gn [/file get \$g name]; :set gn [:pick \$gn [:find \$gn \"confirmed-good-\"] [:len \$gn]]; :if (\$gn < \$oldKey) do={ :set oldest \$g; :set oldKey \$gn } }\
    \n            /file remove \$oldest\
    \n            :set goods [/file find where name~\"confirmed-good-\"]\
    \n          }\
    \n        } on-error={ :log warning \"SELF_UPDATE: confirmed-good retention failed\" }\
    \n        :if (\$hadErr) do={\
    \n          :log warning (\"SELF_UPDATE: \" . \$tag . \" applied WITH errors\")\
    \n          :global logEvent \"selfupdate_applied_warn\"\
    \n          :global logLevel \"warning\"\
    \n          :global logMessage (\"Self-update \" . \$tag . \" applied with errors\")\
    \n        } else={\
    \n          :log info (\"SELF_UPDATE: \" . \$tag . \" applied cleanly\")\
    \n          :global logEvent \"selfupdate_applied\"\
    \n          :global logLevel \"info\"\
    \n          :global logMessage (\"Self-update \" . \$tag . \" applied\")\
    \n        }\
    \n        :do { /system script run script_LOG_EVENT } on-error={}\
    \n        :if ([:len \$selfDst] > 0) do={\
    \n          /system scheduler remove [find name=\"schedule_SU_REIMPORT\"]\
    \n          /system scheduler add name=schedule_SU_REIMPORT interval=30s policy=ftp,reboot,read,write,policy,test,password,sensitive on-event=(\"/import file-name=\" . \$selfDst . \"; /system scheduler remove [find name=schedule_SU_REIMPORT]\")\
    \n          :log info \"SELF_UPDATE: one-shot schedule_SU_REIMPORT armed; script_SELF_UPDATE re-imported in scheduler context (~30s)\"\
    \n        }\
    \n      } else={\
    \n        :log error \"SELF_UPDATE: aborted before any import, system untouched, retry next hour\"\
    \n      }\
    \n    }\
    \n  }\
    \n}"

# --- Hourly pull scheduler ---------------------------------------------------
# interval=1h with NO start-time.
#
# Do NOT add start-time=startup here. A startup-anchored scheduler reports
# next-run=startup and does not begin its hourly countdown until the router
# reboots — so the pull agent sits dormant between reboots. Worse, self-update
# re-adds this scheduler on every apply, re-arming the dormancy each time.
# Plain interval=1h is active immediately and counts from creation.
/system scheduler
remove [ find name="schedule_SELF_UPDATE" ]
add name=schedule_SELF_UPDATE interval=1h on-event="/system script run script_SELF_UPDATE" policy=ftp,reboot,read,write,policy,test,password,sensitive comment="Hourly GitHub pull-deploy agent"

:log info "SELF_UPDATE installed: script_SELF_UPDATE + schedule_SELF_UPDATE (hourly GitHub pull)."
