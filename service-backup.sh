#!/bin/bash
set -euo pipefail
umask 077

if [[ $# -ne 2 || ! $1 =~ ^(rabbitmq|redis|couchdb)$ || $2 != *:* ]]; then
    echo 'Usage: service-backup.sh rabbitmq|redis|couchdb backup-user@backup-host:/absolute/directory/' >&2
    exit 2
fi
service=$1
destination=$2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/$service"
mkdir -p backups
exec 9>backups/.backup.lock
flock -n 9 || { echo 'Another backup is running' >&2; exit 1; }

stamp=$(date -u +%Y%m%dT%H%M%SZ)
restart_needed=0
container_file=''
if [[ $service == couchdb ]]; then
    extension=tar.gz
elif [[ $service == rabbitmq ]]; then
    extension=json
    container_file=/tmp/cashkoom-definitions.json
else
    extension=rdb
    container_file=/tmp/cashkoom-backup.rdb
fi
name="${service}-${stamp}.${extension}"
partial="backups/${name}.partial"
cleanup() {
    result=$?
    rm -f -- "$partial"
    if [[ $restart_needed == 1 ]]; then
        if ! docker compose start couchdb; then
            echo 'ALERT: CouchDB could not be restarted after backup failure' >&2
            result=1
        fi
    fi
    if [[ -n $container_file ]]; then
        docker compose exec -T "$service" rm -f "$container_file" >/dev/null 2>&1 || true
    fi
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ $service == couchdb ]]; then
    # Brief downtime gives a consistent copy of all databases and runtime config.
    # Refuse to start a service that was stopped by an operator before this job.
    [[ -n $(docker compose ps -q couchdb) ]] || {
        echo 'CouchDB must be running before its scheduled backup' >&2
        exit 1
    }
    restart_needed=1
    docker compose stop couchdb
    docker compose run --rm --no-deps --user root --entrypoint tar couchdb \
        --exclude=etc/local.d/10-cashkoom.ini -C /opt/couchdb -czf - data etc/local.d > "$partial"
    docker compose start couchdb
    restart_needed=0
    docker compose up -d --wait --wait-timeout 120 couchdb
    tar -tzf "$partial" > /dev/null
elif [[ $service == rabbitmq ]]; then
    # This backs up definitions, NOT queued messages.
    docker compose exec -T rabbitmq rabbitmqctl export_definitions "$container_file"
else
    docker compose exec -T redis sh -ec \
        'export REDISCLI_AUTH="$REDIS_PASSWORD"; redis-cli --rdb /tmp/cashkoom-backup.rdb; redis-check-rdb /tmp/cashkoom-backup.rdb'
fi
if [[ -n $container_file ]]; then
    docker compose cp "${service}:${container_file}" "$partial"
fi
chmod 600 "$partial"
[[ -s $partial ]] || { echo 'Empty backup' >&2; exit 1; }
if [[ $service == rabbitmq ]]; then
    python3 - "$partial" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    data = json.load(stream)
for key in ('users', 'vhosts', 'queues', 'exchanges', 'bindings'):
    if not isinstance(data.get(key), list):
        raise SystemExit(f'Invalid RabbitMQ definitions: missing {key}')
PY
fi
mv -- "$partial" "backups/$name"
(cd backups && sha256sum "$name" > "$name.sha256")
rsync -a --chmod=F600 \
    -e 'ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=15' \
    backups/*."$extension" backups/*."$extension".sha256 "$destination"
touch backups/last-success
find backups -maxdepth 1 -type f \( -name "*.${extension}" -o -name '*.sha256' \) -mtime +14 -delete
echo "Backup and off-server copy completed: $service/$name"
