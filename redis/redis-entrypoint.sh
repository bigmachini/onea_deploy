#!/bin/bash
set -euo pipefail

: "${REDIS_PASSWORD:?Set REDIS_PASSWORD}"
[[ $REDIS_PASSWORD != *$'\n'* && $REDIS_PASSWORD != *$'\r'* ]] || {
    echo 'Redis password must be a single line' >&2
    exit 1
}

# Keep the password out of redis-server command-line arguments. Match Redis's
# double-quoted configuration syntax, including literal backslashes and quotes.
escaped=${REDIS_PASSWORD//\\/\\\\}
escaped=${escaped//\"/\\\"}
umask 077
printf 'requirepass "%s"\n' "$escaped" > /tmp/redis-auth.conf
chown redis:redis /tmp/redis-auth.conf
exec /usr/local/bin/docker-entrypoint.sh redis-server \
    /usr/local/etc/redis/redis.conf \
    --include /tmp/redis-auth.conf --maxmemory "${REDIS_MAXMEMORY:-1gb}" "$@"
