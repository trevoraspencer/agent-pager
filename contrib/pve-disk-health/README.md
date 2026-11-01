# pve-disk-health

A small read-only check for a Proxmox VE node. A systemd timer runs it every hour. It looks at PERC/MegaRAID volumes
and drives, SMART data and LVM thin pools. When a problem is new or worse, it sends one Proxmox notification. It
never sends again for the same unchanged problem.

It is one Perl file with no dependencies beyond Perl's core modules and the PVE modules that are already on the node.
Nothing about your machines is built in: it finds controllers, drives and pools when it runs.

## What it checks

| Source | Tool | Problem when |
|---|---|---|
| RAID volumes | `perccli64 /call/vall show all J` (optional) | state is not `Optl`, or `Consist` is `No` |
| RAID drives | `perccli64 /call/eall/sall show all J` | state is not `Onln`, `UGood`, `GHS`, `DHS` or `JBOD`; media or other errors; predictive failures; "S.M.A.R.T alert flagged by drive" |
| Foreign configs | `perccli64 /call/fall show J` | a foreign drive group is listed |
| SMART | `smartctl --scan-open -j`, then `smartctl -j -H -A` per device | health failed; SCSI grown defects or uncorrected errors; ATA reallocated, pending or offline-uncorrectable sectors; NVMe critical warning, wear or media errors |
| Thin pools | `lvs --reportformat json` | data at 90% or more; metadata at 80% or more |
| The tools | all of the above | a tool is missing, times out, or gives no usable answer. A MegaRAID controller with no `perccli64` counts too. |

A perccli status of `Success` is never read as healthy. Health comes only from the state and counter fields.
Serial numbers, WWNs and models are never stored, printed or sent.

## When it notifies

It saves what it found in `/var/lib/pve-disk-health/state.json` (mode 0600) and compares each run with the last one.
It sends `error` when:

- a problem appears that was not there last time (the first run sends one notice for everything already wrong);
- a state gets worse, for example a volume goes from `Dgrd` to `Offln`;
- a flag turns on (predictive failure, SMART alert, SMART failed, NVMe warning, metadata high);
- an error counter rises by `counter_step` (10) or more since the last notice for that item, or rises from 0;
- a thin pool passes 90%, then 92%, 94% and so on.

A predictive-failure count that keeps rising does not page again: the flag pages once, when it turns on.
When a problem goes away, it sends one `info` notice and forgets it.

The notification has `type=disk-health` and `hostname=<node name>`, severity `error` or `info`. It carries no details.
Run `pve-disk-health --show` on the node to see them. PVE has no generic template, so mail targets get PVE's "test"
template text with the target name `pve-disk-health`.

To route it, add `disk-health` to a matcher's `type` field rule, together with a severity rule for `error`, for
example:

```
matcher: disk-alerts
    mode all
    match-field exact:type=disk-health
    match-severity error
    target <your-target>
```

## Commands

```
pve-disk-health                  check, notify on what is new or worse, save the state
pve-disk-health --show           print findings and what would be sent; send and save nothing
pve-disk-health --dry-run        same compare, print only; send and save nothing
pve-disk-health --test           send one error with hostname "<node> disk-health test"; state untouched
pve-disk-health --baseline-quiet on the first run only, save the baseline without notifying
```

## Install (as root, on each node)

Download the three files from a fixed commit, check them against checksums you got from a source you trust, then
install:

```sh
d=$(mktemp -d) && cd "$d"
for f in pve-disk-health pve-disk-health.service pve-disk-health.timer; do
  curl -fsSLO "https://raw.githubusercontent.com/trevoraspencer/agent-pager/<commit>/contrib/pve-disk-health/$f"
done
sha256sum -c <<'SUMS'
<sha256>  pve-disk-health
<sha256>  pve-disk-health.service
<sha256>  pve-disk-health.timer
SUMS
install -m 0755 pve-disk-health /usr/local/sbin/
install -m 0644 pve-disk-health.service pve-disk-health.timer /etc/systemd/system/
pve-disk-health --show
pve-disk-health --test
systemctl daemon-reload && systemctl enable --now pve-disk-health.timer
cd / && rm -rf "$d"
```

Optional settings go in `/etc/pve-disk-health.conf`. See `pve-disk-health.conf.example`. Keep that file on the node;
it is where anything specific to your machines belongs (for example an `ignore` list).

## Remove

```sh
systemctl disable --now pve-disk-health.timer
rm -f /etc/systemd/system/pve-disk-health.service /etc/systemd/system/pve-disk-health.timer \
  /usr/local/sbin/pve-disk-health /etc/pve-disk-health.conf
rm -rf /var/lib/pve-disk-health
systemctl daemon-reload
```

## Tests

The tests use made-up JSON fixtures and fake tools, so they need no hardware and no PVE:

```sh
prove contrib/pve-disk-health/t/
```
