#!/bin/bash
set -euo pipefail

# Use Bash/coreutils already in the official image, without relying on curl.
# Compose applies the overall timeout. Send credentials without putting them
# in process arguments and require CouchDB's readiness endpoint to return 200.
authorization=$(printf '%s:%s' "$COUCHDB_USER" "$COUCHDB_PASSWORD" | base64 | tr -d '\n')
exec 3<>/dev/tcp/127.0.0.1/5984
printf 'GET /_up HTTP/1.1\r\nHost: localhost\r\nAuthorization: Basic %s\r\nConnection: close\r\n\r\n' \
    "$authorization" >&3
IFS= read -r status <&3
[[ $status == HTTP/1.[01]' 200 '* ]]
