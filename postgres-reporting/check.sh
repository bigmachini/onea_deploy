#!/bin/bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
state=$(docker compose exec -T --user postgres reporting \
    psql -X -U postgres -d postgres -v ON_ERROR_STOP=1 -Atqc \
    "SELECT pg_is_in_recovery() AND EXISTS (SELECT 1 FROM pg_stat_wal_receiver WHERE status = 'streaming')")
[[ $state == t ]] || { echo 'ALERT: reporting replica is not in streaming recovery' >&2; exit 1; }
