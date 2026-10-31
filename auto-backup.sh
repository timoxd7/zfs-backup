#!/bin/bash
# auto-backup.sh
#
# 1. Creates a dated snapshot of SOURCE_DS.
# 2. Sends it incrementally to BACKUP_DS, starting from the newest snapshot
#    both sides have in common (so it recovers on its own after failed runs).
# 3. After a successful send, keeps the newest KEEP_BACKUP snapshots on the
#    backup and the newest KEEP_SOURCE on the source; older ones are destroyed.
#    Only snapshots whose name matches SNAP_PATTERN (i.e. created by this
#    script) are counted and pruned. Manual snapshots are left alone.

set -uo pipefail

SOURCE_DS="zfs-pool"
BACKUP_DS="backup-zfs-disk/zfs-pool"
KEEP_SOURCE=30
KEEP_BACKUP=60
SNAP_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}---[0-9]{2}-[0-9]{2}-[0-9]{2}$'
LOCK_FILE="/run/zfs_backup.lock"
# -c sends blocks as they are compressed on disk instead of decompressing and
# recompressing them: much less CPU (matters on a Raspberry Pi) and less data
# through the pipe. The backup keeps the source's compression algorithm.
SEND_OPTS=(-c)

DRY_RUN=false
FORCE_FULL=false
PRUNE_FAILED=false

usage() {
    echo "Usage: $0 [-h] [-n] [-f]"
    echo "Options:"
    echo "  -h  Print help and exit"
    echo "  -n  Dry-run mode (print what would happen, change nothing)"
    echo "  -f  Allow a full send if source and backup share no snapshot"
    exit "${1:-0}"
}

while getopts "hnf" opt; do
    case "$opt" in
        h) usage 0 ;;
        n) DRY_RUN=true ;;
        f) FORCE_FULL=true ;;
        *) usage 1 ;;
    esac
done

die() { echo "ERROR: $*" >&2; exit 1; }

run() {
    if $DRY_RUN; then
        echo "[dry-run] $*"
    else
        echo "+ $*"
        "$@"
    fi
}

# Prints "<guid> <snapshot-name-after-@>" for the dataset's own snapshots, newest first.
list_snaps() {
    zfs list -H -t snapshot -d 1 -o guid,name -S creation "$1" \
        | awk -F'\t' '{ split($2, a, "@"); print $1, a[2] }'
}

# prune <dataset> <keep> <protected-snapshot-name>
prune() {
    local ds=$1 keep=$2 protect=$3
    local -a old=()
    local count=0 guid name

    while read -r guid name; do
        [[ "$name" =~ $SNAP_PATTERN ]] || continue
        count=$((count + 1))
        (( count <= keep )) && continue
        [[ "$name" == "$protect" ]] && continue
        old+=("$name")
    done < <(list_snaps "$ds")

    if (( ${#old[@]} == 0 )); then
        echo "${ds}: nothing to prune (${count} snapshot(s), keeping ${keep})"
        return 0
    fi

    local list
    list=$(IFS=,; echo "${old[*]}")
    echo "${ds}: destroying ${#old[@]} snapshot(s) beyond the newest ${keep}"
    if $DRY_RUN; then
        # zfs's own dry run: lists what would go and how much space is reclaimed.
        zfs destroy -nv "${ds}@${list}"
    else
        zfs destroy -v "${ds}@${list}" || { echo "WARNING: pruning ${ds} failed" >&2; PRUNE_FAILED=true; }
    fi
}

# --- Preconditions -----------------------------------------------------------

[[ $EUID -eq 0 ]] || die "must be run as root"

exec 9>"$LOCK_FILE" || die "cannot open lock file $LOCK_FILE"
flock -n 9 || die "another backup run is already in progress"

zfs list -H -o name "$SOURCE_DS" >/dev/null || die "source dataset $SOURCE_DS not found"
BACKUP_POOL="${BACKUP_DS%%/*}"
zfs list -H -o name "$BACKUP_POOL" >/dev/null 2>&1 \
    || die "backup pool $BACKUP_POOL not found (is the backup disk attached and imported?)"

# --- 1. Find the newest common snapshot (matched by GUID, not just by name) ----

declare -A BACKUP_GUIDS=()
if zfs list -H -o name "$BACKUP_DS" >/dev/null 2>&1; then
    while read -r guid name; do
        BACKUP_GUIDS[$guid]=1
    done < <(list_snaps "$BACKUP_DS")
fi

BASE=""
while read -r guid name; do
    if [[ -n "${BACKUP_GUIDS[$guid]:-}" ]]; then
        BASE="$name"
        break
    fi
done < <(list_snaps "$SOURCE_DS")

if [[ -z "$BASE" ]] && ! $FORCE_FULL; then
    die "source and backup have no snapshot in common. Use -f to force a full send" \
        "(the backup dataset must not contain any snapshots for that)."
fi

# --- 2. Create the new snapshot ------------------------------------------------

SNAP_DATE=$(date +%Y-%m-%d---%H-%M-%S)
NEW_SNAP="${SOURCE_DS}@${SNAP_DATE}"

run zfs snapshot "$NEW_SNAP" || die "could not create $NEW_SNAP"

# --- 3. Send ------------------------------------------------------------------

if [[ -n "$BASE" ]]; then
    echo "Incremental: ${BASE} -> ${SNAP_DATE} (including all snapshots in between)"
    SEND_ARGS=("${SEND_OPTS[@]}" -I "${SOURCE_DS}@${BASE}" "$NEW_SNAP")
else
    echo "Full send: ${SNAP_DATE}"
    SEND_ARGS=("${SEND_OPTS[@]}" "$NEW_SNAP")
fi

if $DRY_RUN; then
    echo "[dry-run] zfs send ${SEND_ARGS[*]} | zfs receive -F ${BACKUP_DS}"
else
    echo "+ zfs send ${SEND_ARGS[*]} | zfs receive -F ${BACKUP_DS}"
    if ! zfs send "${SEND_ARGS[@]}" | zfs receive -F "$BACKUP_DS"; then
        die "send/receive failed. Nothing was pruned. The next run will resume from ${BASE:-a full send}."
    fi
fi

# --- 4. Prune (only reached after a successful send) ----------------------------
# The new snapshot is now the common base and is always protected.
# Note: in dry-run mode the new snapshot doesn't exist yet, so the listing may
# show one snapshot fewer to destroy than a real run would.

prune "$BACKUP_DS" "$KEEP_BACKUP" "$SNAP_DATE"
prune "$SOURCE_DS" "$KEEP_SOURCE" "$SNAP_DATE"

if $PRUNE_FAILED; then
    die "backup succeeded, but pruning old snapshots failed (see above)"
fi

echo "Backup finished."
