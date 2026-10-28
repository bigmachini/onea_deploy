# Cashkoom Redis

Persistent single-node Redis with password authentication, memory limits, health
checks and rotating logs. No replica or automatic failover. Read the
[shared operations guide](../README.md) before deployment.

## Host and startup

Redis persistence forks its process. Enable host memory overcommit and disable
Transparent Huge Pages (THP), following Redis's Linux guidance:

```bash
echo 'vm.overcommit_memory = 1' > /etc/sysctl.d/99-cashkoom-redis.conf
sysctl --system
if test -e /sys/kernel/mm/transparent_hugepage/enabled; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
```

Persist THP's setting through your distribution's boot/tuned configuration and
verify after reboot. These settings affect the whole host; account for other
services. Do not put host kernel tuning in a container.

```bash
cd /opt/cashkoom/redis
cp .env.example .env
chmod 600 .env
# Edit .env: VPN IP and Redis password.
docker compose config --quiet
docker compose up -d --wait
docker compose ps
```

Defaults: 2 CPUs, 3GB container memory, 1GB Redis maxmemory. Extra memory allows for
persistence forks, clients and buffers. These are starting budgets, not capacity
guarantees. Leave host headroom, avoid swapping/OOM, and test expected write load.

Applications use the VPN IP, port **6379**, username `default`, and the configured
password. The startup helper renders a private runtime authentication file instead
of putting the password in redis-server arguments. Clients are trusted and have
administrative powers; use Redis ACLs before sharing with less-trusted clients.
Redis has no bundled account-management UI.

Use a separate instance for incompatible workloads/trust boundaries. Logical
database numbers do not isolate memory, security or eviction. Do not mix a
disposable evicting cache with durable jobs/sessions on this instance.

## Persistence and memory

AOF uses `appendfsync everysec`, with periodic RDB snapshots as well. A sudden
crash/power loss can lose roughly the latest second of writes. Disk loss and
accidental deletion still require off-server backups. Financial records belong
in PostgreSQL as the source of truth.

`noeviction` rejects memory-growing writes when full instead of silently deleting
jobs/session keys. Applications must handle these errors and reconnect after
outages. Use appropriate TTLs. For a purely rebuildable cache, deliberately choose
an eviction policy such as `allkeys-lru` in redis.conf; do not do that for durable
jobs/sessions.

Redis stops writes when RDB persistence fails. Shared checks also detect AOF/RDB
errors and warn at 85% maxmemory usage; PING alone is insufficient:

```bash
docker compose exec -T redis sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli INFO persistence'
docker compose exec -T redis sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli INFO memory'
```

Rotate credentials by editing `.env` and recreating the container in a maintenance
window, updating clients together. Data persists in its volume.

## Backup and restore

The shared backup script obtains a fresh RDB with `redis-cli --rdb`, validates it
with `redis-check-rdb`, and copies it off-server. It covers all logical databases
and works online, but can add fork/disk load. Schedule outside peak hours. Back up
credentials/configuration separately.

Restore only onto a fresh isolated instance and empty volume, using the same
Redis version initially. Retrieve the RDB and checksum into `backups/`. Prevent
production clients connecting during a drill:

```bash
cd /opt/cashkoom/redis
(cd backups && sha256sum -c redis-TIMESTAMP.rdb.sha256)
docker compose create redis
docker compose cp backups/redis-TIMESTAMP.rdb redis:/data/dump.rdb
docker compose run --rm --no-deps --entrypoint chown redis redis:redis /data/dump.rdb
```

Start temporarily with AOF disabled so Redis loads the restored RDB. Create
`restore.yaml`:

```yaml
services:
  redis:
    command: ['--appendonly', 'no']
```

```bash
docker compose -f compose.yaml -f restore.yaml up -d --wait
docker compose exec -T redis sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli -e CONFIG SET appendonly yes'
docker compose exec -T redis sh -ec 'REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli INFO persistence'
```

Wait for `aof_rewrite_in_progress` and `aof_rewrite_scheduled` to become 0, with
`aof_last_bgrewrite_status` equal to `ok`. Verify known keys and logical database
key counts. Then restart normally to load the newly generated AOF:

```bash
docker compose up -d --wait
rm restore.yaml
```

Check keys again and test write/read/restart before releasing to applications.
Simply copying an RDB over an existing AOF-enabled deployment can load the wrong
data: do not skip the controlled restore procedure.

Sources: [persistence](https://redis.io/docs/latest/operate/oss_and_stack/management/persistence/),
[CLI backups](https://redis.io/docs/latest/develop/tools/cli/),
[Linux host guidance](https://redis.io/docs/latest/operate/oss_and_stack/management/admin/).
