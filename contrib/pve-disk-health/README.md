# pve-disk-health

A small read-only check for a Proxmox VE node. A systemd timer runs it every hour. It looks at PERC/MegaRAID volumes
and drives, SMART data and LVM thin pools. When a problem is new, worse, or hardware that was there is gone, it sends
one Proxmox notification. It never sends again for the same unchanged problem.

It is one Perl file with no dependencies beyond Perl's core modules and the PVE modules that are already on the node.
Nothing about your machines is built in: it finds controllers, drives and pools when it runs.

## What it checks

| Source | Tool | Problem when |
|---|---|---|
| RAID volumes | `perccli64 /call/vall show all J` (optional) | state is not `Optl`, or `Consist` is `No` |
| RAID drives | `perccli64 /call/eall/sall show all J` | state is not `Onln`, `UGood`, `GHS`, `DHS` or `JBOD`; media or other errors; predictive failures; "S.M.A.R.T alert flagged by drive" |
| Foreign configs | `perccli64 /call/fall show J` | a foreign drive group is listed |
| SMART | `smartctl --scan-open -j`, then `smartctl -j -H -A` per device | health failed (or exit bit 3); SCSI grown defects or uncorrected errors; ATA reallocated, pending or offline-uncorrectable sectors; NVMe critical warning, wear or media errors |
| Thin pools | `lvs --reportformat json` | data at 90% or more; metadata at 80% or more |
| Inventory | all of the above | a controller, volume, drive, SMART device or thin pool seen before is no longer there |
| The tools | all of the above | see "When a check cannot run" |

A perccli status of `Success` is never read as healthy. Health comes only from the state and counter fields.
Serial numbers, WWNs and models are never stored, printed or sent.

## When it notifies

It saves what it found, and an inventory of what it saw, in `/var/lib/pve-disk-health/state.json` (mode 0600). Each
run compares with the last one and sends `error` when:

- a problem appears that was not there last time (the first run sends one notice for everything already wrong);
- a state gets worse, for example a volume goes from `Dgrd` to `Offln`;
- a flag turns on (predictive failure, SMART alert, SMART failed, NVMe warning, metadata high);
- an error counter rises by `counter_step` (10) or more since the last notice for that item, or rises from 0;
- a thin pool passes 90%, then 92%, 94% and so on;
- an inventory item is gone (`gone:<item>`). A drive that disappears is an error, never a fix.

A predictive-failure count that keeps rising does not page again: the flag pages once, when it turns on.
When a problem goes away, it sends one `info` notice and forgets it.

After removing hardware on purpose, run `pve-disk-health --accept-inventory` to forget it.
This removes only findings and inventory for confirmed removals. It does not acknowledge new faults or
advance any other notification baseline. A missing device retains its previous failure until it recovers
or you accept its removal.

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

## When a check cannot run

Each of these is its own finding, so one failure cannot hide another. Each one pages once, and clears with `info`
when it works again:

- a tool is missing (including a MegaRAID controller with no `perccli64`), times out, exits with an error, or gives
  output of the wrong shape (`check:perccli:*`, `check:smartctl:<device>`, `check:lvs`);
- a SMART device cannot be opened, its query fails (exit bits 0 to 2), or it reports no health data. A RAID volume
  that smartctl cannot open because it sits behind MegaRAID is skipped; its member drives are checked as `megaraid,N`;
- the foreign-config query gives anything other than a list or an explicit "no foreign configuration";
- the run reaches its deadline (`deadline`, 200 s by default, below the service's 300 s `TimeoutStartSec`). It
  stops collecting and still notifies (`check:deadline`);
- the state file is corrupt or unreadable (`check:state`). It is kept as `state.json.bad` and a new baseline starts;
- the state file cannot be written (`check:state-write`). It sends one error and keeps its state in
  `/run/pve-disk-health/state.json` until the normal file can be written again, so it does not page every hour.

While a source cannot be read completely, its earlier findings are kept and nothing of it is reported as cleared or
gone. If a notification cannot be sent, the state is not saved, so the next run tries again.

## Commands

```
pve-disk-health                    check, notify on what is new, worse or gone, save the state
pve-disk-health --show             print findings and what would be sent; send and save nothing
pve-disk-health --dry-run          same compare, print only; send and save nothing
pve-disk-health --test             send one error with hostname "<node> disk-health test"; state untouched
pve-disk-health --accept-inventory forget hardware that was removed on purpose; send nothing
pve-disk-health --baseline-quiet   on the first run only, save the baseline without notifying
```

## Install or upgrade (as root, on each node)

1. Find the commit to install: the SHA of the merge commit on `main` that contains the version you want (on GitHub,
   the commit list for `main`). Use the full 40-character SHA, never a branch name, so the files cannot change under
   you.
2. Check that the checksums below are the ones for that commit: they belong to version 0.2.0. If the commit has
   other files, take the checksums from a source you trust and put them in the paste.
3. Paste the block. It runs in a subshell with `set -euo pipefail`, so any failed download or checksum stops it before
   anything is installed or run. An upgrade keeps the previous version in `/usr/local/lib/pve-disk-health/previous`.

```sh
(
set -euo pipefail
c=PASTE-THE-40-CHARACTER-MERGE-COMMIT-SHA-HERE
case "$c" in *[!0-9a-f]*) echo "c must be a 40-character commit SHA" >&2; exit 1 ;; esac
[ "${#c}" -eq 40 ] || { echo "c must be a 40-character commit SHA" >&2; exit 1; }
d=$(mktemp -d); trap 'rm -rf "$d"' EXIT; cd "$d"
for f in pve-disk-health pve-disk-health.service pve-disk-health.timer; do
  curl -fsS --proto '=https' -o "$f" \
    "https://raw.githubusercontent.com/trevoraspencer/agent-pager/$c/contrib/pve-disk-health/$f"
done
sha256sum --strict -c - <<'SUMS'
cacc4db7b9a0a858d90c3b1cd83617d6146681abda1cd5ee3fcd7919a71d4b8c  pve-disk-health
f367c0cb985c1c2c4ad50eaa5d4b4a8ef80c7b206cae4a0ab17628b7ab6f3486  pve-disk-health.service
2ac8ffc02f35b6f44cca69f98bd83976947c888b37a421aa5f08530af6c976ba  pve-disk-health.timer
SUMS
p=/usr/local/lib/pve-disk-health/previous
if [ -e /usr/local/sbin/pve-disk-health ]; then
  install -d -m 0700 "$p"
  cp -p /usr/local/sbin/pve-disk-health /etc/systemd/system/pve-disk-health.service \
    /etc/systemd/system/pve-disk-health.timer "$p"/
fi
install -m 0755 pve-disk-health /usr/local/sbin/pve-disk-health
install -m 0644 pve-disk-health.service pve-disk-health.timer /etc/systemd/system/
systemctl daemon-reload
/usr/local/sbin/pve-disk-health --show
/usr/local/sbin/pve-disk-health --test
systemctl enable --now pve-disk-health.timer
echo "installed pve-disk-health from $c"
)
```

Optional settings go in `/etc/pve-disk-health.conf`. See `pve-disk-health.conf.example`. Keep that file on the node;
it is where anything specific to your machines belongs (for example an `ignore` list).

## Roll back to the previous version

```sh
(
set -euo pipefail
p=/usr/local/lib/pve-disk-health/previous
install -m 0755 "$p/pve-disk-health" /usr/local/sbin/pve-disk-health
install -m 0644 "$p/pve-disk-health.service" "$p/pve-disk-health.timer" /etc/systemd/system/
systemctl daemon-reload
/usr/local/sbin/pve-disk-health --version
)
```

The state file stays. Version 0.1.0 reads the version 2 state (it ignores the inventory). After going back to 0.1.0
and forward again, the first run rebuilds the inventory, so nothing is reported gone on that run.

## Remove

```sh
systemctl disable --now pve-disk-health.timer
rm -f /etc/systemd/system/pve-disk-health.service /etc/systemd/system/pve-disk-health.timer \
  /usr/local/sbin/pve-disk-health /etc/pve-disk-health.conf
rm -rf /var/lib/pve-disk-health /run/pve-disk-health /usr/local/lib/pve-disk-health
systemctl daemon-reload
```

## Tests

The tests use made-up JSON fixtures and fake tools, so they need no hardware and no PVE:

```sh
prove contrib/pve-disk-health/t/
```
