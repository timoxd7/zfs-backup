#!/bin/bash
# Build the test image and run the test suite against ../auto-backup.sh.
set -euo pipefail
cd "$(dirname "$0")"
docker build -q -t zfs-backup-test . >/dev/null
docker run --rm -v "$PWD/../auto-backup.sh:/app/auto-backup.sh:ro" zfs-backup-test
