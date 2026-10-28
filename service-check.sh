#!/bin/bash
set -euo pipefail
if [[ $# -ne 1 || ! $1 =~ ^(rabbitmq|redis|couchdb)$ ]]; then
    echo 'Usage: service-check.sh rabbitmq|redis|couchdb' >&2
    exit 2
fi
service=$1
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/$service"
failed=0
alert() { echo "ALERT [$service]: $*" >&2; failed=1; }

container=$(docker compose ps -q "$service")
if [[ -z $container ]]; then
    alert 'Container is not running'
else
    health=$(docker inspect --format '{{.State.Health.Status}}' "$container")
    [[ $health == healthy ]] || alert "Container health is $health"
fi

if [[ $service == redis && -n $container ]]; then
    if ! docker compose exec -T redis sh -ec \
        'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli --raw INFO all' | awk -F: '
        {gsub(/\r/, "", $2)}
        $1 == "rdb_last_bgsave_status" || $1 == "aof_last_write_status" {
            count++; if ($2 != "ok") {print "ALERT [redis]: " $1 "=" $2; failed=1}
        }
        $1 == "used_memory" {used=$2}
        $1 == "maxmemory" {maximum=$2}
        END {
            if (count != 2) {print "ALERT [redis]: persistence status unavailable"; failed=1}
            if (maximum > 0 && used / maximum >= 0.85) {
                print "ALERT [redis]: memory usage is at least 85% of maxmemory"; failed=1
            }
            exit failed
        }'; then
        failed=1
    fi
fi

docker_root=$(docker info --format '{{.DockerRootDir}}')
for path in "$PWD" "$docker_root"; do
    [[ -n $path && -d $path ]] || { alert 'Docker storage path unavailable'; continue; }
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
