# Cashkoom CouchDB

Single-node CouchDB 3.5 with persistent data and runtime settings, authentication,
resource limits, readiness checks and rotating logs. It has no replica or
automatic failover. See the [shared operations guide](../README.md) for Linux,
networking, off-server storage and alert delivery requirements.

## Start

Copy this directory to `/opt/cashkoom/couchdb`, keeping the shared backup/check
scripts in `/opt/cashkoom`:

```bash
cd /opt/cashkoom/couchdb
cp .env.example .env
chmod 600 .env
# Edit .env: actual VPN IP and initial administrator credentials.
docker compose config --quiet
docker compose up -d --wait
docker compose ps
```

Defaults are 2 CPUs / 2GB container memory. Size these for document sizes, working
set and indexing/compaction load; leave capacity for other colocated services.
Single-node setup creates CouchDB's system databases automatically. CouchDB runs
as the official image's unprivileged UID/GID 5984. Data and runtime configuration
use separate named volumes; the managed INI file is mounted read-only. Do not
change the service hostname on an existing deployment without a recovery plan.

Application traffic binds only to the server's VPN IP on **5984**. It must travel
over the encrypted private network/VPN. Restrict this port to approved application
servers in the provider/network firewall. Do not expose it publicly. Without an
encrypted network, add TLS with client certificate verification first.

## Fauxton and application accounts

CouchDB includes Fauxton on the same HTTP port as its API. Unlike RabbitMQ's
management listener, Fauxton cannot be isolated with a separate port mapping.
All port-5984 clients must therefore be trusted network clients, and CouchDB
authentication/database authorization still applies.

For local administration, open a tunnel from your computer:

```bash
ssh -N -L 15984:10.50.0.10:5984 your-admin-user@service-server
```

Replace `10.50.0.10` with the configured server VPN IP. Open
[Fauxton](http://localhost:15984/_utils/) and sign in with the administrator
credentials from `.env`. The HTTP interface requires authentication; CORS is not
enabled by default. Do not enable permissive cross-origin access just to resolve
a browser error.

Create databases through Fauxton. Give each application a normal CouchDB user,
not the server administrator. In Fauxton's `_users` database, create a document
using the standard form (replace the name/password yourself):

```json
{
  "_id": "org.couchdb.user:cashkoom_app",
  "name": "cashkoom_app",
  "type": "user",
  "roles": [],
  "password": "the-password-you-assign"
}
```

CouchDB hashes the password. For each application database, explicitly set its
Security members to that username or an application role. Keep database admin
rights restricted; grant them only if an application needs to manage design
documents/indexes. Do not leave member restrictions empty expecting database
names to provide isolation. Verify the application account can access its own
database and is denied access to an unrelated one.

Applications connect to `http://VPN_IP:5984` with their assigned credentials over
the VPN. Use client-library authentication rather than embedding credentials in
logged URLs. The administrator environment values seed an absent administrator;
editing `.env` does not change a password already saved in the configuration
volume. Rotate it through Fauxton/API and keep `.env` synchronized.

## Backup, monitoring and maintenance

```bash
cd /opt/cashkoom
./service-backup.sh couchdb backup@backup-host:/srv/backups/cashkoom/couchdb/
./service-check.sh couchdb
```

**The CouchDB backup briefly stops the service.** Schedule it in an agreed
maintenance window and configure applications to retry unavailable connections.
Downtime lasts for the archive copy and restart; measure it with real data.
The script stops CouchDB, archives all databases and writable configuration,
restarts it, verifies readiness/archive readability, then copies the backup
off-server. Normal failures/signals trigger a restart attempt; power loss or
SIGKILL still requires operator recovery. It refuses to start a service that was
already stopped before the backup. Readiness timeout requires investigation.

This avoids partial cross-database checkpoints with a simple file backup. If
downtime becomes unacceptable, use storage snapshots or an independently backed-up
CouchDB replication target instead. Replication alone also copies deletions and
does not replace retained backups. Daily archives allow up to 24 hours of lost
changes after disaster recovery.

The archive contains database files, indexes, `_users`, database security metadata
and runtime INI settings. It excludes the read-only `10-cashkoom.ini`: keep the
deployment directory and `.env` securely backed up separately. Configuration and
user records contain sensitive credentials/hashes. There is no backup of data
stored outside these mounted volumes.

The shared check script reports readiness failure, disk usage at 85%, and stale
off-server backups. Use the shared mail-enabled cron setup and external host
monitoring. Fauxton shows database sizes and active tasks; monitor HTTP errors,
request latency and compaction/indexing load as usage grows. Leave disk space
for compaction to create replacement files. Do not schedule large compactions
at the same time as backups or heavy reports.

## Restore drill / disaster recovery

Use an isolated new host/project with **empty data and config volumes**, the same
CouchDB version initially, and the deployment files/credentials matching the
checkpoint. Prevent clients and restored `_replicator` jobs reaching production
or external endpoints until validation is complete.

Retrieve a timestamped archive/checksum from the backup server into `backups/`:

```bash
cd /opt/cashkoom/couchdb
(cd backups && sha256sum -c couchdb-TIMESTAMP.tar.gz.sha256)
docker compose create couchdb
docker compose run --rm --no-deps --user root --entrypoint tar couchdb -C /opt/couchdb -xzf - < backups/couchdb-TIMESTAMP.tar.gz
docker compose up -d --wait
```

Extraction restores numerical ownership matching UID/GID 5984. Do not restore
over a running/populated instance. Verify system/application databases, known
documents and attachments, user permissions, design documents and query results.
Test a write/read/restart and measure recovery time before go-live and monthly.
Restored runtime settings/passwords override their earlier state; keep the
administrator credentials consistent with the archive for readiness checks.

For updates, follow the shared maintenance procedure with a fresh backup. The
`3.5` image tag follows patch releases in that line; review CouchDB release/security
notes and test updates before pulling them into production. Keep old backups and
image IDs until validation passes. Deleting either named volume loses data or
runtime settings; never use `docker compose down -v` as a restart command.

Sources: [official image](https://hub.docker.com/_/couchdb),
[single-node setup](https://docs.couchdb.org/en/stable/setup/single-node.html),
[backup guidance](https://docs.couchdb.org/en/stable/maintenance/backups.html),
[database security](https://docs.couchdb.org/en/stable/api/database/security.html).
