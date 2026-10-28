#!/bin/bash
set -euo pipefail

[[ $PRIMARY_HOST =~ ^[a-zA-Z0-9_.-]+$ ]] || {
    echo 'PRIMARY_HOST must be an IPv4 address or hostname' >&2
    exit 1
}
[[ -s /config/pgpass ]] || { echo 'Configure .pgpass with the pgAdmin-created replication login' >&2; exit 1; }
install -o postgres -g postgres -m 600 /config/pgpass /tmp/replication.pgpass
install -d -o postgres -g postgres -m 700 "$PGDATA"

if [[ ! -f "$PGDATA/PG_VERSION" ]]; then
    [[ -z $(find "$PGDATA" -mindepth 1 -maxdepth 1 -print -quit) ]] || {
        echo 'Replica data directory is not empty; inspect it before retrying' >&2
        exit 1
    }
    gosu postgres pg_basebackup \
        --dbname="host=$PRIMARY_HOST port=5432 user=replicator application_name=reporting passfile=/tmp/replication.pgpass" \
        --pgdata="$PGDATA" --wal-method=stream --write-recovery-conf \
        --slot=reporting --progress --no-password
fi

# Never initialize a standalone primary or silently start a promoted replica.
[[ -f "$PGDATA/standby.signal" ]] || {
    echo 'standby.signal missing: this service is for a replica only' >&2
    exit 1
}
exec /usr/local/bin/docker-entrypoint.sh postgres "$@"
