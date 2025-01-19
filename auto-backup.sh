#!/bin/bash

SOURCE_POOL="zfs-pool"
BACKUP_POOL="backup-zfs-drive/zfs-pool"

if [[ "$1" == "-h" ]]; then
    echo "Usage: $0 [-h] [-n] [-f]"
    echo "Create a snapshot of a ZFS pool and send it to a backup pool."
    echo "Options (optional, need to be in order):"
    echo "  -h: Print this help message and exit"
    echo "  -n: Dry-run mode. Only print the commands that would be executed"
    echo "  -f: Force a full backup, even if there is a previous snapshot"
    exit 0
fi

COMMAND_PREFIX=""

if [[ "$1" == "-n" ]]; then
    COMMAND_PREFIX="echo"
    shift
fi

# 1. Create a dated snapshot on the main pool
SNAP_DATE=$(date +%Y-%m-%d---%H-%M-%S)
$COMMAND_PREFIX zfs snapshot ${SOURCE_POOL}@${SNAP_DATE}

# 2. Find the *previous* snapshot name (the second-latest one by creation time)
PREVIOUS=$(zfs list -t snapshot -o name -S creation -H | grep "^${SOURCE_POOL}@" | sed -n '2p' | awk -F@ '{print $2}')

# 3. If we have a previous snapshot, do an incremental send.
if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$SNAP_DATE" ]]; then
    echo "Incremental: ${PREVIOUS} -> ${SNAP_DATE}"

    $COMMAND_PREFIX zfs send -i ${SOURCE_POOL}@${PREVIOUS} ${SOURCE_POOL}@${SNAP_DATE} | zfs receive -F ${BACKUP_POOL}
else
    # Otherwise, do a full send
    echo "No previous snapshot found. Doing full send."

    # Check if the -f flag is given, otherwise exit
    if [[ "$1" != "-f" ]]; then
        echo "EXIT! No previous snapshot found. Use -f to force a full backup."
        exit 1
    fi

    $COMMAND_PREFIX zfs send ${SOURCE_POOL}@${SNAP_DATE} | zfs receive -F ${BACKUP_POOL}
fi
