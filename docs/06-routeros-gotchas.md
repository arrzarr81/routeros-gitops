# 06 — RouterOS gotchas

Behaviours confirmed on hardware, each of which cost real downtime. Most are not
in the documentation, and several fail *silently* — which is what makes them
expensive.

---

## Scripting language

### `$` is interpolated inside `source=` at parse time

The single biggest trap in this repo.

When you write `/system script add source="..."`, RouterOS expands **every**
`$var` in that string *before storing the script*. An unescaped `$foo` is
replaced with an empty string, silently gutting your logic. The script is stored,
looks plausible, and does the wrong thing.

```routeros
# WRONG — $count is expanded (to nothing) at parse time
add name=script_X source=":local count 5; :put $count"

# RIGHT — escaped, so the stored script contains a real $count
add name=script_X source=":local count 5; :put \$count"
```

Applies to `/system script set` as well as `add`.

**Corollary: never patch credentials into a script over SSH after importing.**
Substitute placeholders in the `.rsc` file *before* the router ever sees it —
which is exactly what `scripts/render.sh` does. Values become literal strings
before RouterOS parses anything.

### Backslash line continuation does not work in `.rsc` files

```routeros
# FAILS: "expected end of command"
add name=script_X \
    policy=read \
    source=":put 1"
```

...except it does work for `/system script add` in practice, and does *not*
work inside a value. The reliable rule: **script bodies must be one physical
line.** Use `\r\n` inside the source string for on-device readability, as
`engine/10-maintenance.rsc` does. Where you see continuations in this repo
(`engine/*.rsc`), they are inside a `source="..."` string that RouterOS joins —
a different construct, and one that has been tested on hardware.

When in doubt, single-line it.

### Assorted language traps

| Trap | Reality |
|---|---|
| `:find` returning "nothing" | Returns **nil**. Test with `[:typeof $pos] = "nil"`. |
| `{}` empty array in a `do={}` block | Broken. Use `:local e {}; $e`. |
| `/ping` inside a script | Returns 0 regardless of reality on some builds. Use `[/tool ping address=X count=3]` (returns received count) or count active default routes. |
| `/system package update` property | `installed-version`, **not** `current-version`. |
| Installing a package update | `/system package update install`, **not** `upgrade`. |
| `start-date=` in `/system scheduler add` | Rejects the string from `/system clock get date`. Omit it. |
| `/system ssh` in a script | Needs an interactive terminal. Use `/system ssh-exec`. |
| `find action="name"` on a name that does not exist | Does **not** match nothing: the unknown name resolves to item `*0`, so `/system logging find action="disklog"` returns every `memory` rule (defaults included). Check that the referenced item exists first. Seen on RouterOS 7.25.1. |

---

## Schedulers

### `start-time=startup` fires at ADD time too

Not only at boot. Importing a file that adds a startup scheduler runs its
`on-event` **immediately**, during the import.

Consequence: a boot watchdog installed during a live deploy starts its
five-minute ping loop concurrently with the deploy's own fetch/import churn.
That concurrency has crashed RouterOS outright — service malfunction and a
`supout.rif` dump.

The fix, used in `engine/02-watchdog.rsc`, is a fresh-boot guard:

```routeros
:if ([/system resource get uptime] > 10m) do={
  :log info "Not a fresh boot - skipping."
  :error ""
}
```

Guard every startup-triggered script this way.

### `start-time=startup` also makes an interval scheduler dormant

A scheduler with both `start-time=startup` and an interval reports
`next-run: startup` and **does not begin its interval countdown until the router
reboots**. It looks armed. It never fires.

This is why `schedule_SELF_UPDATE` uses plain `interval=1h` with no start-time —
active immediately, counting from creation. Getting this wrong means a pull agent
that quietly does nothing between reboots, and every apply re-arms the dormancy.

### Removing a scheduler kills its running job instantly

A scheduler's `on-event` runs **in the scheduler's context**. `/system scheduler
remove` terminates it mid-execution, wherever it happens to be.

This caused a WiFi outage: a one-shot "force pull" scheduler was deleted at the
one-minute mark to stop it re-firing, which killed `script_SELF_UPDATE` between
two modules. The cleanup module had wiped the wireless config; the module that
rebuilds it never ran. The log simply stops after the last successful import,
with no error.

**Never judge "done" by elapsed time.** Wait for the marker
(`flash/deployed-version` updated, `flash/deploy-in-progress` gone), then remove.
Details in [04 — Operations](04-operations.md#forcing-an-immediate-pull).

### Script policies are a superset relationship

A script can only grant a child the policies it holds itself. If a parent that
imports modules lacks `password`, RouterOS marks those children **invalid and
blanks their source** — no error you'd notice, the script simply ceases to
function.

That is why `script_SELF_UPDATE` and both schedulers that run it declare
`password` even though the agent itself never saves a backup directly. It
imports modules that do.

---

## Firewall and interfaces

### Interface lists must exist and be populated BEFORE firewall rules

If `drop in-interface-list=!LAN` is added before the `LAN` list is created,
RouterOS silently creates an **empty ghost `LAN` list**. Your bridge is never in
it, so the rule drops everything — including you.

Create lists, add members, *then* write rules. `config/10-network.rsc` is
ordered this way deliberately (section 7 before section 8).

### A failed command aborts the entire `/import`

Not just that line. Everything after it in the file never runs, and the router
is left half-configured with no rollback of its own.

The usual trigger is *"already have such entry"* from an `add` whose matching
cleanup didn't fire — because the cleanup matched on a comment and the existing
entry had a different one. Clean up by stable key (interface, name, address),
never by comment alone.

### A WAN port added as a bridge slave breaks NAT

The DHCP client on that interface goes `INVALID`, so NAT never applies. Clients
get an address and no internet. Keep the WAN interface out of the bridge.

Related: a leftover factory IP on the bridge can create ECMP, so half your
packets bypass NAT — intermittent, direction-dependent connectivity that looks
like anything but a routing problem.

### Fasttrack must be the LAST rule in the forward chain

RouterOS evaluates forward rules in insertion order. A fasttrack rule placed
early fast-paths packets straight past every simple queue below it.

Measured: a guest network capped at `30M/30M` tested at **90/30**. Conntrack
showed `orig-fasttrack-packets=0` but `repl-fasttrack-packets=151` — only the
**download** (reply) direction was being fast-pathed, so the queue shaped upload
and never saw download.

The fix needs **two** accept rules, not one, because matching only
`in-interface` fixes upload and silently misses download:

```routeros
add action=accept chain=forward in-interface=bridge-guest  connection-state=established,related
add action=accept chain=forward out-interface=bridge-guest connection-state=established,related
add action=fasttrack-connection chain=forward connection-state=established,related
```

### Don't scope management access to LAN-only on a remote router

Tempting, and it will lock you out of the site permanently. With pull-deploy you
don't need inbound access for *deploys* — but you do need it for the emergencies
a release can't fix. Drop the guest bridge specifically rather than allowing only
LAN, and use key-only auth.

---

## Wireless

Two systems exist and they are not interchangeable:

| System | Syntax | Devices |
|---|---|---|
| Old | `/interface wireless`, `/caps-man` | hEX PoE, older hAP, RouterOS 7 + `wireless` package |
| New | `/interface wifi`, `/interface wifi capsman` | Chateau, Audience, ax-generation hardware |

A controller on one protocol **cannot** manage access points on the other. Check
`/system package print` before writing a line of wireless config.

### Probe unfamiliar property values before shipping them

`control-channel-width=80mhz` does not exist. It is a syntax error, and per the
rule above it **aborts the entire import** — so the channel is never created,
configurations are never made, radios never provision, and WiFi goes dark. This
shipped in a release and caused an outage. WAN stayed up throughout, so nothing
rolled back.

One command would have prevented it:

```routeros
/caps-man channel add name=__probe <the-property-you-are-guessing>
```

Do this on the live box for any property value you are not certain of. It costs
ten seconds.

(For the record, on `/caps-man` width comes from `extension-channel`:
`Ce`/`eC` for 40MHz, `Ceee` for 80MHz, with `control-channel-width=20mhz`.
And on `/interface wifi`, `width=80mhz` is invalid for `5ghz-ax` — omit it.)

### Silent fallbacks

Wireless config fails quietly more than anything else in RouterOS. An 80MHz
`extension-channel` placement that doesn't form a legal channel block drops the
radio to **20MHz with no error and no log**. Always verify what the radio
actually negotiated rather than what you configured:

```routeros
/interface wireless monitor wlan1 once      ;# old system
/interface wifi monitor wifi1 once          ;# new system
```

---

## Hardware and performance

### Check the cable before you check the config

When someone reports slow throughput, verify the physical layer **first**. It is
the one part you cannot inspect remotely with confidence, and it is the most
common real cause.

```routeros
/interface ethernet monitor [find] once     ;# rate + duplex on every port
```

Any active port at `100Mbps` is a ~94 Mbps hard cap. Stop and fix that before
touching anything else.

The decisive test for cable-versus-config:

```routeros
/interface ethernet print detail where name="ether1"   ;# advertise=  -> what we OFFER
/interface ethernet monitor ether1 once                ;# advertising: -> what the PHY MANAGES
```

`advertise` listing `1G-baseT-full` while `advertising` tops out at
`100M-baseT-full` means the PHY **cannot train gigabit** — a cable or connector
fault, not configuration. 1000BASE-T needs all four pairs; 100BASE-TX needs two,
so a broken pair links happily at 100M forever.

Usual culprits: plain Cat5, flat/"slim" patch cables, cheap moulded leads,
passive PoE injectors (many are 100M-only), keystones, couplers, hand-crimped
ends with an untwisted pair.

**Re-check the link rate after every failed hypothesis.** A marginal cable
flaps: one deployment read `1Gbps` at 07:00 and `100Mbps` at 10:00, which
invalidated a conclusion drawn in between. A reading from an hour ago is not
evidence now.

### Several causes stack at the same number

A symmetric ~100/100 cap can be a 100M link, a 20MHz channel width, *and*
CAPWAP tunnelling on a slow CPU — simultaneously. Fixing one moves nothing,
which makes it look like you were wrong. Check all of them, and re-check after
each change. Never claim a root cause without a post-fix measurement.

### `local-forwarding=no` caps CAPsMAN WiFi at ~100 Mbps

`/caps-man datapath` defaults to `local-forwarding=no`: every client packet is
wrapped in a CAPWAP tunnel to the controller, decapsulated **in software**,
bridged, NAT'd, re-encapsulated. The switch chip cannot hardware-offload
tunnelled traffic, so it all lands on one CPU core. On MIPS hardware that
ceiling is ~100 Mbps, symmetric — both directions cross the same tunnel.

Fasttrack does not help; the encap/decap happens *below* L3 forwarding.

```routeros
/caps-man datapath set [find name=datapath-home] local-forwarding=yes
```

**Never enable it on an isolated guest datapath.** Guest isolation relies on that
traffic arriving at the router, where the firewall drops it. Local forwarding
puts guest clients on the access point's local bridge — straight into the home
bridge, isolation silently defeated, no error, no log. Keep guest tunnelled and
cap it with a queue. Comment the asymmetry so nobody "fixes" it later.

### Measure CPU with `/tool profile`, not `cpu-load`

A one-shot `cpu-load` reading is polluted by your own SSH session.
`/tool profile duration=8` breaks it down per process.

### Small flash is a reliability problem

A full disk breaks `/system backup save` → breaks the pre-deploy snapshot →
breaks rollback. Keep the prune schedule in `config/30-backup.rsc`, and watch
`free-hdd-space` in the heartbeat.

### Files outside `flash/` live in RAM on flash-dir devices

On devices that show a `flash` directory in `/file print` (e.g. RBLtAP-2HnD,
hAP lite and other small-flash boards), the file root is a RAM disk. Only paths
under `flash/` survive a reboot. `/system backup save name=x` writes `x.backup`
to the **root** — confirmed on an RBLtAP-2HnD running RouterOS 7.25.1 — so it is
gone after the next reboot.

That kills rollback: the boot watchdog runs *after* a reboot and finds no
`pre-deploy-*` backup. Detect the case at runtime and prefix the name:

```routeros
:local bkDir ""
:if ([:len [/file find where name="flash"]] > 0) do={ :set bkDir "flash/" }
/system backup save name=($bkDir . "pre-deploy-...") dont-encrypt=yes
/system backup load name=flash/pre-deploy-...   ;# load takes the flash/ path too
```

The engine does this for `pre-deploy-*` and `confirmed-good-*`, and writes
its state files (`flash/deploy-in-progress`, `flash/deployed-version`,
`flash/rollback-marker`) under `flash/` for the same reason. A `target=disk`
logging action needs the prefix too (`disk-file-name=flash/router-log`).

---

## Environment

### DNS-level blocking of API endpoints

Some ISPs (notably mobile carriers) block API hosts at the DNS level. If a
`/tool fetch` to a known-good endpoint fails only on one uplink, try a static
entry:

```routeros
/ip dns static add name=api.example.org address=<resolved-ip>
```

### A wrong clock breaks TLS

Certificate validation fails and every `/tool fetch` errors with a message that
never mentions time. Enable NTP early:

```routeros
/system ntp client set enabled=yes servers=pool.ntp.org
```

### Private repos are invisible to devices without credentials

A downstream access point cannot fetch from your GitHub raw URLs — the repo is
private and the device has no token. Relay through the router instead: ship the
file with `"action": "upload"` and serve it from the router. See
[03 — Writing modules](03-writing-modules.md#modules-for-downstream-devices).
