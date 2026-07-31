# =============================================================================
# routeros-gitops :: config :: 10-network.rsc   [EXAMPLE — EDIT FOR YOUR SITE]
# =============================================================================
#
# A complete, working two-network router: trusted LAN + isolated guest LAN,
# DHCP, DNS, firewall, NAT, and a guest bandwidth cap. It is here so you have
# something real to deploy on day one, and so the ordering lessons below live
# in code rather than in a wiki nobody reads.
#
# ASSUMED HARDWARE  a router with ether1..ether5 (e.g. hEX / hAP family)
#   ether1     WAN, DHCP client
#   ether2-5   LAN, bridged
#
# ADAPT: change interface names, subnets and the identity below. If your WAN is
# PPPoE or LTE, replace section 1 and put that interface in the WAN list instead.
#
# IDEMPOTENT: every section removes before it adds, so re-importing converges
# rather than duplicating. This is mandatory for every module in this system —
# the router re-imports the whole manifest on every release.
#
# ---------------------------------------------------------------------------
# THREE ORDERING RULES THAT WILL BITE YOU. THEY ARE WHY THIS FILE IS NUMBERED.
#
# RULE 1 — INTERFACE LISTS BEFORE FIREWALL RULES.
#   If `drop in-interface-list=!LAN` is added before the LAN list exists,
#   RouterOS silently creates an empty ghost LAN list. Your bridge is never in
#   it, so the drop rule fires for everyone, including you. Create and POPULATE
#   the lists first (section 7), then write rules (section 8).
#
# RULE 2 — CLEAN UP BY STABLE KEY, NOT BY COMMENT.
#   `remove [find comment="LAN Port"]` misses an entry that was created by hand
#   or by a factory default with a different comment. The re-add then fails with
#   "already have such entry" and ABORTS THE ENTIRE IMPORT — leaving the router
#   half-configured. Match on interface/list/name instead. See sections 0/57/66.
#
# RULE 3 — FASTTRACK GOES LAST IN THE FORWARD CHAIN.
#   RouterOS evaluates forward rules in insertion order. A fasttrack rule placed
#   early fast-paths packets straight past every simple queue below it. Real
#   measurement: a guest network capped at 30M tested at 90/30 because the reply
#   direction was fasttracked. See section 8 for the two-rule fix.
# ---------------------------------------------------------------------------

:log info "config/10-network: starting..."

# --- 0: Identity -------------------------------------------------------------
# Shows up in every log line and every heartbeat. Make it unique per site.
/system identity set name=gitops-router

# --- 0b: Cloud DDNS (optional but recommended) -------------------------------
# Gives you a free stable *.sn.mynetname.net hostname tracking the public IP.
# Not needed for deploys (those are pull-based) — needed for YOU to get in.
/ip cloud set ddns-enabled=yes

# --- Idempotent cleanup (RULE 2: stable keys, not comments) ------------------
/ip dhcp-client
remove [find interface="ether1"]

/ip firewall filter
remove [find comment~"^gitops:"]

/ip firewall nat
remove [find comment~"^gitops:"]

/interface list member
remove [find list=WAN interface=ether1]
remove [find list=LAN interface=bridge-lan]
/interface list
remove [find name=LAN]

/interface bridge port
# By interface, not comment. The regex deliberately excludes ether1 (WAN) and
# any dynamic wireless/CAP ports.
remove [find interface~"ether[2-5]"]

/interface bridge
remove [find name="bridge-lan"]
remove [find name="bridge-guest"]

/ip address
remove [find interface="bridge-lan"]
remove [find interface="bridge-guest"]

/ip pool
remove [find name="pool-lan"]
remove [find name="pool-guest"]

/ip dhcp-server
remove [find name="dhcp-lan"]
remove [find name="dhcp-guest"]

/ip dhcp-server network
remove [find address="10.1.1.0/24"]
remove [find address="192.168.89.0/24"]

/queue simple
remove [find name="guest-limit"]

# --- 1: WAN ------------------------------------------------------------------
/ip dhcp-client
add interface=ether1 add-default-route=yes use-peer-dns=yes disabled=no comment="gitops: WAN DHCP client"

# --- 2: Bridges --------------------------------------------------------------
/interface bridge
add name=bridge-lan comment="Trusted LAN"
add name=bridge-guest comment="Guest LAN (isolated)"

# --- 3: LAN ports ------------------------------------------------------------
# ether1 stays OUT of the bridge. A WAN port added as a bridge slave makes the
# DHCP client go INVALID -> NAT never applies -> clients get an IP and no
# internet, which is a confusing failure to debug.
/interface bridge port
add bridge=bridge-lan interface=ether2 comment="gitops: LAN port"
add bridge=bridge-lan interface=ether3 comment="gitops: LAN port"
add bridge=bridge-lan interface=ether4 comment="gitops: LAN port"
add bridge=bridge-lan interface=ether5 comment="gitops: LAN port"

# --- 4: Addresses ------------------------------------------------------------
/ip address
add address=10.1.1.1/24 interface=bridge-lan comment="gitops: LAN gateway"
add address=192.168.89.1/24 interface=bridge-guest comment="gitops: guest gateway"

# --- 5: DHCP -----------------------------------------------------------------
/ip pool
add name=pool-lan ranges=10.1.1.10-10.1.1.254
add name=pool-guest ranges=192.168.89.10-192.168.89.254

/ip dhcp-server network
add address=10.1.1.0/24 gateway=10.1.1.1 dns-server=10.1.1.1 comment="gitops: LAN"
# Guest points at public resolvers, NOT at the router: it must not be able to
# enumerate internal names or reach the router's DNS service at all.
add address=192.168.89.0/24 gateway=192.168.89.1 dns-server=1.1.1.1,8.8.8.8 comment="gitops: guest"

/ip dhcp-server
add name=dhcp-lan interface=bridge-lan address-pool=pool-lan disabled=no
add name=dhcp-guest interface=bridge-guest address-pool=pool-guest disabled=no

# --- 6: DNS ------------------------------------------------------------------
/ip dns set allow-remote-requests=yes servers="1.1.1.1,8.8.8.8"

# --- 7: Interface lists (RULE 1 — BEFORE the firewall) -----------------------
/interface list
:if ([:len [/interface list find name=WAN]] = 0) do={ add name=WAN comment="WAN interfaces" }
:if ([:len [/interface list find name=LAN]] = 0) do={ add name=LAN comment="LAN interfaces" }

/interface list member
add list=WAN interface=ether1 comment="gitops: WAN member"
add list=LAN interface=bridge-lan comment="gitops: LAN member"

# --- 8: Firewall -------------------------------------------------------------
/ip firewall filter

# INPUT chain --------------------------------------------------------------
# Management SSH. Order matters: the guest DROP must precede the ACCEPT, or a
# guest client can reach your management port.
#
# Deliberately NOT scoped to in-interface-list=LAN: deploys are pull-based, but
# YOUR admin access arrives over WAN via the DDNS name, and a LAN-only rule
# would lock you out of the site permanently. Dropping bridge-guest closes the
# real exposure without breaking remote admin. Use key-only auth on that port.
add action=drop  chain=input in-interface=bridge-guest protocol=tcp dst-port=2222 comment="gitops: drop guest -> mgmt SSH"
add action=accept chain=input protocol=tcp dst-port=2222 comment="gitops: allow mgmt SSH"

add action=accept chain=input dst-address=127.0.0.1 comment="gitops: accept loopback"
add action=accept chain=input protocol=icmp comment="gitops: accept ICMP"
add action=accept chain=input connection-state=established,related,untracked comment="gitops: accept established"
add action=drop   chain=input in-interface-list=!LAN comment="gitops: drop input not from LAN"
add action=drop   chain=input in-interface=bridge-guest comment="gitops: drop guest -> router mgmt"

# FORWARD chain ------------------------------------------------------------
# Guest isolation drops FIRST — before any accept, or the accepts would let
# guest traffic reach the trusted LAN.
add action=drop chain=forward in-interface=bridge-guest connection-state=invalid comment="gitops: drop invalid guest"
add action=drop chain=forward in-interface=bridge-guest dst-address=10.1.1.0/24 comment="gitops: drop guest -> LAN subnet"
add action=drop chain=forward in-interface=bridge-guest out-interface=bridge-lan comment="gitops: drop guest -> LAN bridge"

# RULE 3, part 1: pull guest traffic out of the forward chain BEFORE fasttrack,
# in BOTH directions, so the guest-limit queue actually shapes it.
# Two rules, not one: matching only in-interface fixes upload and silently
# misses download, because it is the REPLY direction that gets fasttracked.
add action=accept chain=forward in-interface=bridge-guest  connection-state=established,related comment="gitops: guest established out"
add action=accept chain=forward out-interface=bridge-guest connection-state=established,related comment="gitops: guest established in"

# RULE 3, part 2: fasttrack LAST. Trusted LAN still gets the full benefit.
add action=fasttrack-connection chain=forward connection-state=established,related comment="gitops: fasttrack"

add action=accept chain=forward in-interface=bridge-lan out-interface-list=WAN comment="gitops: LAN -> WAN"

/ip firewall nat
add action=masquerade chain=srcnat src-address=10.1.1.0/24     out-interface-list=WAN comment="gitops: NAT LAN"
add action=masquerade chain=srcnat src-address=192.168.89.0/24 out-interface-list=WAN comment="gitops: NAT guest"

# --- 9: Guest bandwidth cap --------------------------------------------------
# Only effective because the guest accepts above keep this traffic off fasttrack.
/queue simple
add name="guest-limit" target=192.168.89.0/24 max-limit=30M/30M comment="gitops: guest cap"

:log info "config/10-network: complete. ether1=WAN, ether2-5=bridge-lan 10.1.1.0/24, bridge-guest 192.168.89.0/24."
