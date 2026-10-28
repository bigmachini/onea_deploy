#!/bin/bash
set -euo pipefail
umask 077
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if [[ $# -gt 1 || ( $# -eq 1 && $1 != *:* ) ]]; then
    echo 'Usage: backup.sh [backup-user@backup-host:/absolute/backup/directory/]' >&2
    exit 2
fi

mkdir -p backups
exec 9>backups/.backup.lock
flock -n 9 || { echo 'Another backup is running' >&2; exit 1; }
stamp=$(date -u +%Y%m%dT%H%M%SZ)
partial="backups/${stamp}.partial"
archive="backups/${stamp}"
mkdir -- "$partial"
trap 'rm -rf -- "$partial"' EXIT

docker compose exec -T --user postgres postgres \
    pg_dumpall -U postgres --globals-only > "$partial/globals.sql"

# Discover all non-template databases, including future Odoo databases.
# Use database OIDs as filenames; keep the name mapping alongside the dumps.
docker compose exec -T --user postgres postgres \
    psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc \
    "SELECT oid, datname FROM pg_database WHERE NOT datistemplate ORDER BY oid" \
    > "$partial/databases.tsv"

while IFS='|' read -r oid db; do
    [[ $oid =~ ^[0-9]+$ && $db =~ ^[a-zA-Z0-9_][a-zA-Z0-9_-]*$ ]] || {
        echo 'Use simple database names: letters, numbers, underscores and hyphens' >&2
        exit 1
    }
    docker compose exec -T --user postgres postgres \
        pg_dump -U postgres --dbname="$db" --format=custom --create > "$partial/${oid}.dump"
    docker compose exec -T postgres pg_restore --list < "$partial/${oid}.dump" > /dev/null
done < "$partial/databases.tsv"
[[ -s "$partial/databases.tsv" ]] || { echo 'Empty database list' >&2; exit 1; }
mv -- "$partial" "$archive"

# Optional off-server copy. SSH must already have a verified host key and unattended key
# authentication. A failed copy fails the job and leaves last-success unchanged.
if [[ $# -eq 1 ]]; then
    rsync -a --chmod=D700,F600 -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15' \
        backups/[0-9]*[0-9]Z "$1"
else
    echo 'WARNING: no off-server destination given; backup exists only on this server' >&2
fi
touch backups/last-success
find backups -mindepth 1 -maxdepth 1 -type d -name '????????T??????Z' -mtime +14 -exec rm -rf -- {} +
echo "Backup completed: $archive"
