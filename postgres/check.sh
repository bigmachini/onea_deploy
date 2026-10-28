#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

failed=0
alert() { echo "ALERT: $*" >&2; failed=1; }

if ! docker compose exec -T --user postgres postgres \
    psql -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc 'SELECT 1' >/dev/null; then
    alert 'PostgreSQL query failed'
fi

# Before replica setup this returns no rows. Once its slot exists, monitor it.
replication_alert=$(docker compose exec -T --user postgres postgres \
    psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc \
    "SELECT 'Reporting replication slot inactive, WAL endangered, or retention over 8GB'
     FROM pg_replication_slots
     WHERE slot_name = 'reporting'
       AND (NOT active OR wal_status IN ('unreserved', 'lost')
            OR pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) > 8589934592)")
[[ -z $replication_alert ]] || alert "$replication_alert"

# Check both the backup filesystem and the filesystem holding Docker volumes.
docker_root=$(docker info --format '{{.DockerRootDir}}')
for path in "$PWD" "$docker_root"; do
    [[ -n "$path" && -d "$path" ]] || { alert 'Docker storage path unavailable'; continue; }
    used=$(df -P "$path" | awk 'NR == 2 {gsub(/%/, "", $5); print $5}')
    [[ $used =~ ^[0-9]+$ ]] || { alert "Cannot read disk usage: $path"; continue; }
    (( used < 85 )) || alert "Disk usage is ${used}%: $path"
done

if [[ ! -f backups/last-success ]]; then
    alert 'No successful off-server backup recorded'
elif [[ -n $(find backups/last-success -mmin +1560 -print) ]]; then
    alert 'Last successful off-server backup is older than 26 hours'
fi
exit "$failed"
