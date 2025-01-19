#!/bin/bash

SOURCE_POOL="zfs-pool"
BACKUP_POOL="backup-zfs-disk/zfs-pool"

DRY_RUN=false
FORCE_FULL=false

usage() {
    echo "Usage: $0 [-h] [-n] [-f]"
    echo "Options:"
    echo "  -h  Print help and exit"
    echo "  -n  Dry-run mode (only print commands)"
    echo "  -f  Force full backup (ignores missing previous snapshot)"
    exit 0
}

while getopts "hnf" opt; do
  case "${opt}" in
    h) usage ;;
    n) DRY_RUN=true ;;
    f) FORCE_FULL=true ;;
    *) usage ;;
  esac
done

COMMAND_PREFIX=""
if $DRY_RUN; then
    COMMAND_PREFIX="echo"
fi

# 1. Create a dated snapshot on the main pool
SNAP_DATE=$(date +%Y-%m-%d---%H-%M-%S)
$COMMAND_PREFIX zfs snapshot "${SOURCE_POOL}@${SNAP_DATE}"

# 2. Find the *previous* snapshot name (the second-latest one by creation time)
PREVIOUS=$(
    zfs list -t snapshot -o name -S creation -H \
    | grep "^${SOURCE_POOL}@" \
    | sed -n '2p' \
    | awk -F@ '{print $2}'
)

# 3. If we have a previous snapshot, do an incremental send.
if [[ -n "$PREVIOUS" && "$PREVIOUS" != "$SNAP_DATE" ]]; then
    echo "Incremental: $PREVIOUS -> $SNAP_DATE"

    $COMMAND_PREFIX zfs send -i "${SOURCE_POOL}@${PREVIOUS}" "${SOURCE_POOL}@${SNAP_DATE}" | zfs receive -F "${BACKUP_POOL}"
else
    # Otherwise, do a full send
    echo "No previous snapshot found. Doing full send."

    if ! $FORCE_FULL; then
        echo "EXIT! No previous snapshot found. Use -f to force a full backup."
        exit 1
    fi

    $COMMAND_PREFIX zfs send "${SOURCE_POOL}@${SNAP_DATE}" | zfs receive -F "${BACKUP_POOL}"
fi
