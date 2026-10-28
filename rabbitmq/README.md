# Cashkoom RabbitMQ

Single-node broker with persistent storage, stable node identity, memory/disk
alarms, health checks and rotating logs. No automatic failover. Read the
[shared operations guide](../README.md) for networking, backups and alerts.

## Start

```bash
cd /opt/cashkoom/rabbitmq
cp .env.example .env
chmod 600 .env
# Edit .env: VPN IP and initial administrator credentials.
docker compose config --quiet
docker compose up -d --wait
docker compose ps
```

Defaults: 4 CPUs / 4GB container memory, a 2GB broker memory alarm and 2GB minimum
free disk. Alarms block publishing rather than clean up messages. Adjust limits
and alarms together for the host/workload. Prefer fast local SSD storage. Monitor
queue growth and leave disk headroom. Keep the hostname/nodename unchanged on an
existing volume: it identifies stored state. The private Erlang cookie persists
in the volume. Only AMQP is published to the VPN; clustering ports are not published.

## Management and application users

From your computer:

```bash
ssh -N -L 15672:127.0.0.1:15672 your-admin-user@service-server
```

Open [RabbitMQ management](http://localhost:15672), using the initial administrator
login from `.env`. Under **Admin → Users**, create separate application users
without management/administrator tags. Grant permissions on the `cashkoom` vhost,
scoped to their queue/exchange names. Only use `.*` for configure/write/read if
that application legitimately controls the entire vhost. For independent apps,
create separate vhosts and restrict each user's permissions to its own vhost.
Do not give applications the administrator login.

Applications connect to the server's VPN IP, port **5672**, with their user/password
and vhost `cashkoom`. Use client-library connection parameters, or URL-encode
credentials when constructing AMQP URLs. Bootstrap environment credentials only
seed an empty broker: manage subsequent users/passwords in the UI and keep `.env`
consistent for disaster recovery.

Reliable delivery also requires application behavior:

- Durable queues/exchanges and persistent messages.
- Publisher confirms, handling of unroutable publishes, reconnect and retry.
- Manual consumer acknowledgements after successful processing.
- Idempotent processing, bounded retries and a dead-letter queue.

Compose does not implement these semantics. Default classic queues are not
replicated; a single quorum member would not provide host redundancy either.
For critical jobs, retain a replayable source/outbox in PostgreSQL. Watch ready/
unacknowledged message counts, consumer counts and publish/consume rates in the UI.

## Definitions backup and restore

The shared script exports users/hashes, vhosts, permissions, queues, exchanges,
bindings and policies online. **It does not export queued messages.** Definitions
are sensitive. Retrieve the export/checksum from the backup server and restore
to an isolated, empty broker using the same image version:

```bash
cd /opt/cashkoom/rabbitmq
(cd backups && sha256sum -c rabbitmq-TIMESTAMP.json.sha256)
docker compose cp backups/rabbitmq-TIMESTAMP.json rabbitmq:/tmp/restore-definitions.json
docker compose exec -T rabbitmq rabbitmqctl import_definitions /tmp/restore-definitions.json
docker compose exec -T rabbitmq rm -f /tmp/restore-definitions.json
```

Imported users include their saved hashes. Verify permissions and a test
publish/consume before connecting production clients. Importing is not a clean
rollback of an already populated broker.

## Full message backup (maintenance window)

Pause publishers and consumers, stop the node, and archive the whole volume:

```bash
cd /opt/cashkoom/rabbitmq
install -d -m 700 backups
docker compose stop rabbitmq
if (umask 077; docker compose run --rm --no-deps --entrypoint tar rabbitmq -C /var/lib/rabbitmq -czf - . > backups/rabbitmq-full.tar.gz.partial); then
    docker compose start rabbitmq
    tar -tzf backups/rabbitmq-full.tar.gz.partial > /dev/null && mv backups/rabbitmq-full.tar.gz.partial backups/rabbitmq-full.tar.gz
else
    docker compose start rabbitmq
    echo 'Backup failed; do not accept the partial archive' >&2
fi
```

Copy the archive, configuration and exact image version off-server before
resuming clients. Keep uniquely named checkpoints when retaining multiple copies.
Only persisted messages are recoverable. In-flight processing must be reconciled
by applications.

Restore on a fresh isolated host using the same image version and **the same
hostname/nodename**. Use an empty volume:

```bash
docker compose create rabbitmq
docker compose run --rm --no-deps --entrypoint tar rabbitmq -C /var/lib/rabbitmq -xzf - < backups/rabbitmq-full.tar.gz
docker compose up -d --wait
```

The archive contains definitions, messages and cookie; do not separately import
definitions. Never extract over a populated or running broker. Test queues,
permissions and delivery. Restoring old messages can cause duplicates, so
consumers must be idempotent.

Sources: [RabbitMQ backup](https://www.rabbitmq.com/docs/backup),
[definitions](https://www.rabbitmq.com/docs/definitions),
[reliability](https://www.rabbitmq.com/docs/reliability).
