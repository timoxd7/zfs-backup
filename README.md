# My ZFS Backup Strategy

Simple script i wrote to be executed at night, to backup my nas. Maybe it helps you too :D

## Initial

First create a new snapshot (initial) on pool

```zsh
zfs snapshot zfs-pool@initial
```

Next send the initial Snapshot to the backup drive (on new filesystem, a "filesystem" is kind of a subvolume in zfs)

```zsh
zfs send -c zfs-pool@initial | zfs receive backup-zfs-drive/zfs-pool
```

>NOTE: The -c says that the compressed blocks from zfs-pool will _not_ be decompressed, thus if both use the same compression makes the transfer faster

## Next

After that, we can create new snapshot (only example, we will use a script for this) with this

```zsh
zfs snapshot zfs-pool@nextsync
```

And then copy them over with

```zsh
zfs send -c -i zfs-pool@initial zfs-pool@nextsync | zfs receive backup-zfs-drive/zfs-pool
```

## Script

See [this](./auto-backup.sh) for automatic build of snapshots and sending of them.
