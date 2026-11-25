# =============================================================================
# routeros-gitops :: modules/telemetry/telemetry.rsc — OPTIONAL.
# WiFi / CAPsMAN / LTE telemetry for dashboards, shipped to the engine log sink.
#
# Not in the default manifest. Enable per site by adding to the site's
# deploy-manifest.json (after the engine 00-10 entries, before the "self" one):
#   { "action": "import", "path": "gitops/modules/telemetry/telemetry.rsc",
#     "asset": "module__telemetry.rsc", "dst": "module__telemetry.rsc" }
# See docs/08-telemetry.md for the field list and dashboard notes.
#
# INSTALLS
#   script_TELEMETRY      read-only collector, one run per minute
#   schedule_TELEMETRY    every 1m at :50 (only if the log sink is configured)
#
# READ-ONLY. It runs print / get / monitor commands only and never changes
# wireless, CAPsMAN, LTE or interface config.
#
# WHAT IT SENDS (JSON POST to PLACEHOLDER_LOG_INGEST_URL, same sink and token
# as engine/00-observability.rsc script_HEARTBEAT)
#   every minute      message=telemetry    one object: wifi_backend, caps_online,
#                     total/home/guest_clients, lte_* (signal, band, cell, kbps)
#   minute%5  = 1     message=wifi_client  one ARRAY, one object per client
#   minute%15 = 2     message=cap_version  one ARRAY, one object per CAP
#   Arrays keep it to one request per run; Better Stack stores each element as
#   its own row. A sink that rejects JSON arrays needs a per-object loop here.
#   Field names follow a common WiFi/CAP + LTE dashboard layout, so chart SQL
#   ports between routers by changing only {{source}}.
#
# DETECTION AT RUN TIME (no interface names in this file)
#   wifi_backend  capsman   /caps-man manager enabled (legacy wireless package)
#                 wifi      /interface wifi has interfaces (new wifi package)
#                 wireless  local /interface wireless only, no controller
#                 none      nothing found -> no WiFi fields at all
#   Backend commands go through [:parse] so the script still runs on a device
#   whose package lacks that menu (a missing menu would otherwise make the
#   whole script fail to parse).
#   LTE: first running interface of type lte. None -> lte_present=0, no lte_*.
#
# MISSING VALUES ARE OMITTED, NEVER 0. A failed monitor or an absent key leaves
# the JSON key out, so a chart shows a gap instead of a fake "0 dBm".
# lte_present = 1 only when the modem returned rssi/rsrp.
#
# UNITS: rsrq from `monitor once as-value` is in 0.1 dB (-135 = -13.5 dB, the
# value `print` shows), sent as a decimal. rx/tx in kbps. Signals in dBm/dB.
#
# PLACEHOLDERS (see secrets.map)
#   PLACEHOLDER_LOG_INGEST_URL / _TOKEN   engine log sink (required for this
#       module to do anything; unset -> no scheduler, manual run :errors).
#   PLACEHOLDER_TELEMETRY_GUEST_SSID_RE   optional RouterOS regex; clients whose
#       SSID matches count as guest_clients, the rest home_clients. Unset ->
#       all home. Must not contain " \ or $.
#   PLACEHOLDER_TELEMETRY_WAN2_IFACE      optional backup uplink on a plain
#       ethernet interface (e.g. an external LTE box). Set -> wan2_* fields:
#       interface rx/tx kbps, wan2_route_up (an enabled default route resolves
#       via that interface), ping RTT/loss to its gateway, and ping RTT/loss to
#       an internet target ONLY while that uplink carries the active default
#       route (a ping cannot be forced through a standby uplink without a
#       dedicated route, so none is sent then). Unset -> no wan2_* fields.
#   PLACEHOLDER_TELEMETRY_WAN2_GW         optional gateway to ping; unset -> the
#       gateway of the default route that resolves via WAN2_IFACE.
#   PLACEHOLDER_TELEMETRY_WAN2_TARGET     internet ping target (default 1.1.1.1).
#
# REQUIRES: RouterOS 7. Policy read,test (fetch + monitor + ping). Footprint:
# one script of ~9 KB, no files.
# NOTE ON source="..." : every runtime $var is written \$var and every quote \".
# =============================================================================

:log info "modules/telemetry: starting..."

/system scheduler
remove [find name="schedule_TELEMETRY"]

/system script
remove [find name="script_TELEMETRY"]

/system script
add name=script_TELEMETRY \
    policy=read,test \
    owner=admin \
    dont-require-permissions=no \
    source=":local sinkUrl \"PLACEHOLDER_LOG_INGEST_URL\"\
    \n:local sinkToken \"PLACEHOLDER_LOG_INGEST_TOKEN\"\
    \n:if (\$sinkUrl ~ \"^PLACEHOLDER_\") do={ :error \"log sink not configured\" }\
    \n:local guestRe \"PLACEHOLDER_TELEMETRY_GUEST_SSID_RE\"\
    \n:if (\$guestRe ~ \"^PLACEHOLDER_\") do={ :set guestRe \"\" }\
    \n:local q do={ :local r; :do { :set r [[:parse (\":return [\" . \$c . \"]\")]] } on-error={}; :return \$r }\
    \n:local addN do={ :if ([:typeof \$v] = \"num\") do={ :return (\$p . \",\\\"\" . \$k . \"\\\":\" . \$v) }; :return \$p }\
    \n:local addS do={\
    \n  :local s [:tostr \$v]; :local o \"\"\
    \n  :if ([:len \$s] > 0) do={ :for i from=0 to=([:len \$s] - 1) do={ :local ch [:pick \$s \$i]; :if (\$ch != \"\\\"\" && \$ch != \"\\\\\") do={ :set o (\$o . \$ch) } } }\
    \n  :if ([:len \$o] > 0) do={ :return (\$p . \",\\\"\" . \$k . \"\\\":\\\"\" . \$o . \"\\\"\") }; :return \$p\
    \n}\
    \n:local post do={ :do { /tool fetch url=\$u http-method=post http-header-field=(\"Authorization:Bearer \" . \$t . \",Content-Type:application/json\") http-data=\$d output=none } on-error={ :log warning \"TELEMETRY: shipping failed\" } }\
    \n:local host [/system identity get name]\
    \n:local min [:tonum [:pick [/system clock get time] 3 5]]\
    \n:local be \"none\"\
    \n:if ([\$q c=\"/caps-man manager get enabled\"] = true) do={ :set be \"capsman\" }\
    \n:if (\$be = \"none\" && [\$q c=\"/interface wifi print count-only\"] > 0) do={ :set be \"wifi\" }\
    \n:if (\$be = \"none\" && [\$q c=\"/interface wireless print count-only\"] > 0) do={ :set be \"wireless\" }\
    \n:local caps; :local regs\
    \n:if (\$be = \"capsman\") do={ :set caps [\$q c=\"/caps-man remote-cap print count-only where state=Run\"]; :set regs [\$q c=\"/caps-man registration-table print as-value proplist=mac-address,ssid,interface,rx-signal\"] }\
    \n:if (\$be = \"wifi\") do={ :set caps [\$q c=\"/interface wifi capsman remote-cap print count-only\"]; :set regs [\$q c=\"/interface wifi registration-table print as-value\"] }\
    \n:if (\$be = \"wireless\") do={ :set regs [\$q c=\"/interface wireless registration-table print as-value\"] }\
    \n:local cl \"\"; :local home 0; :local guest 0\
    \n:if ([:typeof \$regs] = \"array\") do={\
    \n  :foreach r in=\$regs do={\
    \n    :local radio [:tostr (\$r->\"interface\")]\
    \n    :local ssid [:tostr (\$r->\"ssid\")]\
    \n    :if (\$be = \"wifi\" && [:len \$ssid] = 0) do={ :do { :set ssid [[:parse \":return [/interface wifi get [find name=\\\$n] configuration.ssid]\"] n=\$radio] } on-error={} }\
    \n    :if ([:len \$guestRe] > 0 && \$ssid ~ \$guestRe) do={ :set guest (\$guest + 1) } else={ :set home (\$home + 1) }\
    \n    :if ((\$min % 5) = 1) do={\
    \n      :local sg (\$r->\"rx-signal\")\
    \n      :if ([:typeof \$sg] = \"nothing\") do={ :set sg (\$r->\"signal\") }\
    \n      :if ([:typeof \$sg] = \"nothing\") do={ :set sg (\$r->\"signal-strength\") }\
    \n      :if ([:typeof \$sg] = \"str\") do={ :local e [:find \$sg \"dBm\"]; :if ([:typeof \$e] = \"num\") do={ :set sg [:pick \$sg 0 \$e] }; :set sg [:tonum \$sg] }\
    \n      :local mac [:tostr (\$r->\"mac-address\")]\
    \n      :local o (\"{\\\"level\\\":\\\"info\\\",\\\"message\\\":\\\"wifi_client\\\",\\\"hostname\\\":\\\"\" . \$host . \"\\\"\")\
    \n      :set o [\$addS p=\$o k=\"client_mac\" v=\$mac]\
    \n      :local l [/ip dhcp-server lease find where mac-address=\$mac]\
    \n      :if ([:len \$l] > 0) do={ :set o [\$addS p=\$o k=\"client_host\" v=[/ip dhcp-server lease get (\$l->0) host-name]]; :set o [\$addS p=\$o k=\"client_ip\" v=[/ip dhcp-server lease get (\$l->0) address]] }\
    \n      :set o [\$addS p=\$o k=\"client_ssid\" v=\$ssid]\
    \n      :set o [\$addS p=\$o k=\"client_radio\" v=\$radio]\
    \n      :set o [\$addN p=\$o k=\"client_signal\" v=\$sg]\
    \n      :if ([:len \$cl] > 0) do={ :set cl (\$cl . \",\") }\
    \n      :set cl (\$cl . \$o . \"}\")\
    \n    }\
    \n  }\
    \n}\
    \n:local p (\"{\\\"level\\\":\\\"info\\\",\\\"message\\\":\\\"telemetry\\\",\\\"hostname\\\":\\\"\" . \$host . \"\\\",\\\"wifi_backend\\\":\\\"\" . \$be . \"\\\"\")\
    \n:set p [\$addN p=\$p k=\"caps_online\" v=\$caps]\
    \n:if ([:typeof \$regs] = \"array\") do={ :set p (\$p . \",\\\"total_clients\\\":\" . [:len \$regs] . \",\\\"home_clients\\\":\" . \$home . \",\\\"guest_clients\\\":\" . \$guest) }\
    \n:local lif \"\"\
    \n:foreach i in=[/interface find where type=lte running] do={ :if ([:len \$lif] = 0) do={ :set lif [/interface get \$i name] } }\
    \n:local lp 0\
    \n:if ([:len \$lif] > 0) do={\
    \n  :set p [\$addS p=\$p k=\"lte_iface\" v=\$lif]\
    \n  :local m; :do { :set m [/interface lte monitor \$lif once as-value] } on-error={}\
    \n  :if ([:typeof (\$m->\"rsrp\")] = \"num\" || [:typeof (\$m->\"rssi\")] = \"num\") do={ :set lp 1 }\
    \n  :set p [\$addN p=\$p k=\"lte_rssi\" v=(\$m->\"rssi\")]\
    \n  :set p [\$addN p=\$p k=\"lte_rsrp\" v=(\$m->\"rsrp\")]\
    \n  :set p [\$addN p=\$p k=\"lte_sinr\" v=(\$m->\"sinr\")]\
    \n  :set p [\$addN p=\$p k=\"lte_cqi\" v=(\$m->\"cqi\")]\
    \n  :local rq (\$m->\"rsrq\")\
    \n  :if ([:typeof \$rq] = \"num\") do={ :local sn \"\"; :if (\$rq < 0) do={ :set sn \"-\"; :set rq (0 - \$rq) }; :set p (\$p . \",\\\"lte_rsrq\\\":\" . \$sn . (\$rq / 10) . \".\" . (\$rq % 10)) }\
    \n  :local b [:tostr (\$m->\"primary-band\")]\
    \n  :local e [:find \$b \"@\"]; :if ([:typeof \$e] = \"num\") do={ :set b [:pick \$b 0 \$e] }\
    \n  :set e [:find \$b \" \"]; :if ([:typeof \$e] = \"num\") do={ :set b [:pick \$b 0 \$e] }\
    \n  :set p [\$addS p=\$p k=\"lte_band\" v=\$b]\
    \n  :set p [\$addS p=\$p k=\"lte_cell\" v=(\$m->\"current-cellid\")]\
    \n  :set p [\$addS p=\$p k=\"lte_operator\" v=(\$m->\"current-operator\")]\
    \n  :set p [\$addS p=\$p k=\"lte_status\" v=(\$m->\"registration-status\")]\
    \n  :set p [\$addS p=\$p k=\"lte_data_class\" v=(\$m->\"data-class\")]\
    \n  :do { :local t [/interface monitor-traffic \$lif once as-value]; :set p [\$addN p=\$p k=\"lte_rx_kbps\" v=((\$t->\"rx-bits-per-second\") / 1000)]; :set p [\$addN p=\$p k=\"lte_tx_kbps\" v=((\$t->\"tx-bits-per-second\") / 1000)] } on-error={}\
    \n}\
    \n:local w2If \"PLACEHOLDER_TELEMETRY_WAN2_IFACE\"\
    \n:if (\$w2If ~ \"^PLACEHOLDER_\") do={ :set w2If \"\" }\
    \n:if ([:len \$w2If] > 0) do={\
    \n  :local w2Gw \"PLACEHOLDER_TELEMETRY_WAN2_GW\"; :if (\$w2Gw ~ \"^PLACEHOLDER_\") do={ :set w2Gw \"\" }\
    \n  :local w2Tg \"PLACEHOLDER_TELEMETRY_WAN2_TARGET\"; :if (\$w2Tg ~ \"^PLACEHOLDER_\") do={ :set w2Tg \"\" }\
    \n  :local addP do={\
    \n    :local a; :do { :set a [/ping \$h count=5 interval=200ms as-value] } on-error={}\
    \n    :if ([:typeof \$a] != \"array\" || [:len \$a] = 0) do={ :return \$p }\
    \n    :local n 0; :local s 0; :local c [:len \$a]\
    \n    :foreach x in=\$a do={ :if ([:typeof (\$x->\"time\")] = \"time\" && [:typeof (\$x->\"status\")] = \"nothing\") do={ :set n (\$n + 1); :set s (\$s + ([:tonsec (\$x->\"time\")] / 1000)) } }\
    \n    :local o (\$p . \",\\\"\" . \$k . \"_loss_pct\\\":\" . (((\$c - \$n) * 100) / \$c))\
    \n    :if (\$n > 0) do={ :local u (\$s / \$n); :set o (\$o . \",\\\"\" . \$k . \"_rtt_ms\\\":\" . (\$u / 1000) . \".\" . ((\$u % 1000) / 100)) }\
    \n    :return \$o\
    \n  }\
    \n  :do { :local t [/interface monitor-traffic \$w2If once as-value]; :set p [\$addN p=\$p k=\"wan2_rx_kbps\" v=((\$t->\"rx-bits-per-second\") / 1000)]; :set p [\$addN p=\$p k=\"wan2_tx_kbps\" v=((\$t->\"tx-bits-per-second\") / 1000)] } on-error={}\
    \n  :local w2Up 0; :local bestIf \"\"; :local bestD 256\
    \n  :foreach r in=[/ip route find where dst-address=0.0.0.0/0 disabled=no] do={\
    \n    :local ig [:tostr [/ip route get \$r immediate-gw]]; :local pc [:find \$ig \"%\"]; :local gi \"\"\
    \n    :if ([:typeof \$pc] = \"num\") do={ :set gi [:pick \$ig (\$pc + 1) [:len \$ig]] }\
    \n    :if (\$gi = \$w2If) do={ :set w2Up 1; :if ([:len \$w2Gw] = 0) do={ :set w2Gw [:pick \$ig 0 \$pc] } }\
    \n    :if ([/ip route get \$r active] = true && [/ip route get \$r distance] < \$bestD) do={ :set bestD [/ip route get \$r distance]; :set bestIf \$gi }\
    \n  }\
    \n  :set p (\$p . \",\\\"wan2_route_up\\\":\" . \$w2Up)\
    \n  :if ([:len \$w2Gw] > 0) do={ :set p [\$addP p=\$p k=\"wan2_gw\" h=\$w2Gw] }\
    \n  :if (\$bestIf = \$w2If && [:len \$w2Tg] > 0) do={ :set p [\$addP p=\$p k=\"wan2_inet\" h=\$w2Tg] }\
    \n}\
    \n:set p (\$p . \",\\\"lte_present\\\":\" . \$lp . \"}\")\
    \n\$post u=\$sinkUrl t=\$sinkToken d=\$p\
    \n:if ([:len \$cl] > 0) do={ \$post u=\$sinkUrl t=\$sinkToken d=(\"[\" . \$cl . \"]\") }\
    \n:if ((\$min % 15) = 2 && \$be != \"none\" && \$be != \"wireless\") do={\
    \n  :local cr\
    \n  :if (\$be = \"capsman\") do={ :set cr [\$q c=\"/caps-man remote-cap print as-value proplist=name,identity,version,board,base-mac where state=Run\"] }\
    \n  :if (\$be = \"wifi\") do={ :set cr [\$q c=\"/interface wifi capsman remote-cap print as-value\"] }\
    \n  :local ca \"\"\
    \n  :if ([:typeof \$cr] = \"array\") do={\
    \n    :foreach c in=\$cr do={\
    \n      :local nm [:tostr (\$c->\"identity\")]; :if ([:len \$nm] = 0) do={ :set nm [:tostr (\$c->\"name\")] }\
    \n      :local o (\"{\\\"level\\\":\\\"info\\\",\\\"message\\\":\\\"cap_version\\\",\\\"hostname\\\":\\\"\" . \$host . \"\\\"\")\
    \n      :set o [\$addS p=\$o k=\"cap_name\" v=\$nm]\
    \n      :set o [\$addS p=\$o k=\"cap_version\" v=(\$c->\"version\")]\
    \n      :set o [\$addS p=\$o k=\"cap_board\" v=(\$c->\"board\")]\
    \n      :set o [\$addS p=\$o k=\"cap_mac\" v=(\$c->\"base-mac\")]\
    \n      :if ([:len \$ca] > 0) do={ :set ca (\$ca . \",\") }\
    \n      :set ca (\$ca . \$o . \"}\")\
    \n    }\
    \n  }\
    \n  :if ([:len \$ca] > 0) do={ \$post u=\$sinkUrl t=\$sinkToken d=(\"[\" . \$ca . \"]\") }\
    \n}"

# Fixed start-time, not startup (see engine/00-observability.rsc). :50 keeps it
# away from schedule_HEARTBEAT (:20) and schedule_DEADMAN (:40). Installed only
# when the sink is rendered — an unconfigured run ends in :error, and an error
# every minute floods the disklog.
:if (!("PLACEHOLDER_LOG_INGEST_URL" ~ "^PLACEHOLDER_")) do={ /system scheduler add name=schedule_TELEMETRY interval=1m start-time=00:00:50 on-event="/system script run script_TELEMETRY" policy=read,test }

:log info "modules/telemetry: complete."
