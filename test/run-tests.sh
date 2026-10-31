#!/bin/bash
# Runs inside the container. Exercises auto-backup.sh against the fake zfs.
set -u
SCRIPT=/app/auto-backup.sh
SRC=zfs-pool
BAK=backup-zfs-disk/zfs-pool
PAT='^[0-9]{4}-[0-9]{2}-[0-9]{2}---[0-9]{2}-[0-9]{2}-[0-9]{2}$'
export ZFS_STATE=/state
PASS=0 FAIL=0 OUT="" RC=0

file()   { echo "/state/ds/${1//\//%}"; }
reset()  { rm -rf /state /run/zfs_backup.lock; mkdir -p /state/ds /state/pool /state/hold
           touch /state/pool/zfs-pool "$(file $SRC)"; }
disk()   { touch /state/pool/backup-zfs-disk; }
snaps()  { sort -k1,1n "$(file "$1")" 2>/dev/null | awk '{ print $3 }'; }
guids()  { sort -k1,1n "$(file "$1")" 2>/dev/null | awk '{ print $2 }'; }
nauto()  { snaps "$1" | grep -cE "$PAT"; }
nall()   { snaps "$1" | grep -c .; }
has()    { snaps "$1" | grep -qx "$2"; }
same()   { [[ "$(guids $SRC)" == "$(guids $BAK)" ]]; }
run()    { OUT=$(PATH=/test/bin:$PATH bash "$SCRIPT" "$@" 2>&1); RC=$?; }
says()   { grep -qF -- "$1" <<< "$OUT"; }
check()  { local d=$1; shift
           if "$@"; then PASS=$((PASS + 1)); echo "  ok    $d"
           else FAIL=$((FAIL + 1)); echo "  FAIL  $d"; sed 's/^/        | /' <<< "$OUT"; fi; }
section(){ echo; echo "## $*"; }
# seed N: N script snapshots on source and the identical ones (same GUIDs) on the backup
seed() { local i name s=0
         for ((i = 0; i < $1; i++)); do
             name=$(printf '2025-%02d-%02d---00-00-00' $((i / 28 + 1)) $((i % 28 + 1)))
             s=$((s + 1)); echo "$s 1000$i $name" >> "$(file $SRC)"; echo "$s 1000$i $name" >> "$(file $BAK)"
         done; echo "$s" > /state/seq; }

echo "bash $BASH_VERSION, $(uname -m), $(. /etc/os-release; echo "$PRETTY_NAME")"

section "Options"
run -h;  check "-h exits 0 and prints usage"     [ $RC -eq 0 ]
check  "  usage text shown"                       says "Usage:"
run -x;  check "unknown option exits 1"          [ $RC -ne 0 ]

section "Preconditions"
reset
OUT=$(setpriv --reuid=65534 --regid=65534 --clear-groups bash "$SCRIPT" 2>&1); RC=$?
check "non-root is refused"                       [ $RC -eq 1 ]
check "  with a clear message"                    says "must be run as root"
reset; run
check "missing backup pool -> exit 1"             [ $RC -eq 1 ]
check "  message names the backup pool"           says "backup pool backup-zfs-disk not found"
check "  no snapshot was created"                 [ "$(nall $SRC)" -eq 0 ]
reset; disk; run
check "no common snapshot, no -f -> exit 1"       [ $RC -eq 1 ]
check "  message suggests -f"                     says "Use -f"
check "  no snapshot was created"                 [ "$(nall $SRC)" -eq 0 ]
reset; disk; seed 1
(flock /run/zfs_backup.lock sleep 3) & sleep 0.5; run; wait
check "second concurrent run is refused"          [ $RC -eq 1 ]
check "  'already in progress'"                   says "already in progress"

section "Full + incremental sends"
reset; disk; run -f
check "-f: full send succeeds"                    [ $RC -eq 0 ]
check "  one snapshot on each side, same GUID"    eval '[ "$(nall $BAK)" -eq 1 ] && same'
check "  full send is compressed (-c)"            grep -q '^-c zfs-pool@' /state/send_args
run
check "next run is incremental"                   eval '[ $RC -eq 0 ] && says "Incremental:"'
check "  both sides have 2 identical snapshots"   eval '[ "$(nall $BAK)" -eq 2 ] && same'
check "  incremental send is compressed (-c -I)"  grep -q '^-c -I zfs-pool@' /state/send_args

section "Recovery after a failed send"
touch /state/fail_receive; run
check "failed receive -> exit 1"                  [ $RC -eq 1 ]
check "  says nothing was pruned"                 says "Nothing was pruned"
check "  source has 3, backup still 2"            eval '[ "$(nall $SRC)" -eq 3 ] && [ "$(nall $BAK)" -eq 2 ]'
run
check "  still failing: source keeps snapshots"   eval '[ $RC -eq 1 ] && [ "$(nall $SRC)" -eq 4 ]'
rm /state/fail_receive; run
check "next good run catches up (-I)"             [ $RC -eq 0 ]
check "  backup has all 5 snapshots, same GUIDs"  eval '[ "$(nall $BAK)" -eq 5 ] && same'

section "Base is matched by GUID, not by name"
reset; disk
echo "1 111 2025-01-01---00-00-00" > "$(file $SRC)"
echo "1 222 2025-01-01---00-00-00" > "$(file $BAK)"; echo 1 > /state/seq
run
check "same name, different GUID -> no common base" eval '[ $RC -eq 1 ] && says "no snapshot in common"'

section "Manual snapshots"
reset; disk; seed 2
ZFS_STATE=/state zfs snapshot $SRC@manual
run
check "manual snapshot in between is sent too"    eval '[ $RC -eq 0 ] && has $BAK manual'

section "Pruning"
reset; disk
echo "1 999 initial" > "$(file $SRC)"; echo "1 999 initial" > "$(file $BAK)"
for ((i = 0; i < 70; i++)); do
    name=$(printf '2025-%02d-%02d---00-00-00' $((i / 28 + 1)) $((i % 28 + 1)))
    echo "$((i + 2)) 1000$i $name" >> "$(file $SRC)"; echo "$((i + 2)) 1000$i $name" >> "$(file $BAK)"
done; echo 71 > /state/seq
NEWEST_OLD=$(snaps $SRC | tail -1)
run
NEW=$(snaps $SRC | tail -1)
check "run with 70 old snapshots succeeds"        [ $RC -eq 0 ]
check "  source keeps exactly 30 script snapshots" [ "$(nauto $SRC)" -eq 30 ]
check "  backup keeps exactly 60 script snapshots" [ "$(nauto $BAK)" -eq 60 ]
check "  the oldest ones were removed"            eval '! has $SRC 2025-01-01---00-00-00 && ! has $BAK 2025-01-01---00-00-00'
check "  newest (common base) kept on both"       eval 'has $SRC "$NEW" && has $BAK "$NEW"'
check "  previous newest still there"             has $SRC "$NEWEST_OLD"
check "  manual 'initial' untouched on both"      eval 'has $SRC initial && has $BAK initial'
run
check "  following run still incremental"         eval '[ $RC -eq 0 ] && says "Incremental:" && [ "$(nauto $SRC)" -eq 30 ]'

section "Pruning failure is reported"
reset; disk; seed 35
touch /state/hold/2025-01-01---00-00-00
run
check "held snapshot -> exit 1"                   [ $RC -eq 1 ]
check "  message says the backup itself worked"   says "backup succeeded, but pruning old snapshots failed"
check "  new snapshot did reach the backup"       [ "$(nall $BAK)" -eq 36 ]

section "Dry run changes nothing"
reset; disk; seed 40
cp -r /state/ds /tmp/before; run -n
check "dry run exits 0"                           [ $RC -eq 0 ]
check "  prints [dry-run] lines"                  says "[dry-run] zfs snapshot"
check "  shows what pruning would destroy"        says "would destroy zfs-pool@"
check "  no dataset state changed"                diff -r /tmp/before /state/ds

echo; echo "== $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
