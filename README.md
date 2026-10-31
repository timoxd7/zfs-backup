# My ZFS Backup Strategy

Simple script i wrote to be executed at night, to backup my nas (a Raspberry Pi). Maybe it helps you too :D

`auto-backup.sh` snapshots a ZFS dataset, sends it incrementally to a backup
disk and thins out old snapshots on both sides.

## What the script does

1. **Finds the newest snapshot that source and backup have in common.**
   Snapshots are matched by their ZFS GUID, not only by name, so a renamed or
   re-created snapshot with the same name is never mistaken for a valid base.
2. **Creates a new snapshot** on the source, named after the current time,
   e.g. `zfs-pool@2026-10-31---03-00-00`.
3. **Sends everything since the common snapshot** with `zfs send -c -I`. If a
   previous run failed (disk not attached, power loss, ...), the next run
   simply catches up and transfers all missing snapshots. `-c` sends the
   blocks still compressed, which saves a lot of CPU on a Raspberry Pi.
4. **Prunes old snapshots** – only after a successful send:
   - keeps the newest `KEEP_SOURCE` (default 30) on the source,
   - keeps the newest `KEEP_BACKUP` (default 60) on the backup.

   Only snapshots created by the script (matching `SNAP_PATTERN`) are counted
   and deleted. Manual snapshots like `zfs-pool@initial` are never touched.
   The snapshot that was just sent is always kept, so the next incremental
   run always has a common base.

Safety checks: must run as root, refuses to run twice at the same time (lock
file in `/run`), aborts with a clear message if the source dataset or backup
pool is missing, and returns a non-zero exit code if anything fails – including
pruning – so cron/systemd can alert you.

## Requirements

- Linux with OpenZFS (`zfs` command). On a Raspberry Pi use a **64-bit**
  Raspberry Pi OS / Debian / Ubuntu – OpenZFS is not really usable on 32-bit
  ARM.
- bash 4 or newer and `flock` (util-linux). Both are installed by default on
  Raspberry Pi OS.

## Configuration

Edit the variables at the top of `auto-backup.sh`:

| Variable       | Default                    | Meaning                                  |
| -------------- | -------------------------- | ---------------------------------------- |
| `SOURCE_DS`    | `zfs-pool`                 | Dataset to back up                       |
| `BACKUP_DS`    | `backup-zfs-disk/zfs-pool` | Where it is received on the backup pool  |
| `KEEP_SOURCE`  | `30`                       | Script snapshots kept on the source      |
| `KEEP_BACKUP`  | `60`                       | Script snapshots kept on the backup      |
| `LOCK_FILE`    | `/run/zfs_backup.lock`     | Prevents overlapping runs                |
| `SEND_OPTS`    | `(-c)`                     | Extra `zfs send` options (compressed send) |

> NOTE: With `-c` the backup stores the blocks exactly as compressed on the
> source, i.e. with the source's compression algorithm, regardless of the
> `compression` property on the backup dataset. Set `SEND_OPTS=()` to have
> the backup recompress with its own setting instead.

> NOTE: Only `SOURCE_DS` itself is backed up, child datasets are not (no
> `zfs send -R`).

## Initial setup

The backup needs one full copy first. Either let the script do it:

```zsh
sudo ./auto-backup.sh -f
```

or do it by hand. First create a new snapshot (initial) on the pool

```zsh
zfs snapshot zfs-pool@initial
```

Next send the initial snapshot to the backup drive (on a new filesystem, a
"filesystem" is kind of a subvolume in zfs)

```zsh
zfs send -c zfs-pool@initial | zfs receive backup-zfs-disk/zfs-pool
```

> NOTE: The -c says that the compressed blocks from zfs-pool will _not_ be
> decompressed, thus if both use the same compression makes the transfer faster

`-f` only performs a full send if source and backup share **no** snapshot. If
the backup dataset already exists and contains snapshots, `zfs receive` will
refuse – destroy or rename the old backup dataset first.

## Usage

```
Usage: ./auto-backup.sh [-h] [-n] [-f]
  -h  Print help and exit
  -n  Dry-run mode (print what would happen, change nothing)
  -f  Allow a full send if source and backup share no snapshot
```

Always try a dry run first:

```zsh
sudo ./auto-backup.sh -n
```

In dry-run mode the snapshot is not really created, so the prune preview may
list one snapshot fewer than a real run would delete.

### Run it every night

With cron (`sudo crontab -e`):

```
0 3 * * * /path/to/auto-backup.sh >> /var/log/zfs-backup.log 2>&1
```

## Testing

```zsh
./test/run.sh
```

Runs the script in a Docker container (Debian bookworm, the base of Raspberry
Pi OS; native arm64 on Apple Silicon) against a fake `zfs` command
(`test/fake-zfs`) that keeps snapshot state in files. It covers the
preconditions, full and incremental sends, recovery after a failed send,
GUID-based base detection, pruning limits, pruning failures and dry-run.

> NOTE: This tests the script's logic, not real ZFS. Docker Desktop has no
> ZFS kernel module, so a real end-to-end test has to run on Linux with
> OpenZFS (e.g. on the Pi itself with throwaway file-backed pools).

## How it works by hand

For reference, this is what the script automates. Create a new snapshot

```zsh
zfs snapshot zfs-pool@nextsync
```

and copy everything since the last common snapshot over with

```zsh
zfs send -c -I zfs-pool@initial zfs-pool@nextsync | zfs receive -F backup-zfs-disk/zfs-pool
```
