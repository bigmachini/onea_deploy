# Reporting replica — PostgreSQL 16

This is a separate Compose project from [the primary](../postgres/README.md).
Initially both run on the same Linux server. It uses its own data volume and port
5433; the primary stays on port 5432. There is no automatic failover. Reports can
lag behind production. Server failure takes both instances down.

## 1. Prepare the primary in pgAdmin

Deploy the updated primary Compose file first. It joins the external Docker
network `cashkoom-replication`, sets `wal_level=replica`, and limits slot WAL
retention to 10GB. Create the network once if it does not already exist:

```bash
docker network create cashkoom-replication
cd /opt/cashkoom/postgres
docker compose up -d --wait
```

Apply changes to a running primary in a maintenance window. On pgAdmin's primary
connection, create **Login/Group Roles → replicator**:

- Set a password and enable **Can login** and **Can initiate streaming replication**.
- Keep superuser, create roles, create databases and bypass row security disabled.

In the primary Query Tool, create the slot once:

```sql
SELECT * FROM pg_create_physical_replication_slot('reporting');
```

Create another login role, **reporting**, through pgAdmin. Enable login only and
set its password. In each database that reporting needs, use the Query Tool as
an administrator (replace `cashkoom` / `odoo` for other databases / owners):

```sql
GRANT CONNECT ON DATABASE cashkoom TO reporting;
GRANT USAGE ON SCHEMA public TO reporting;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO reporting;
ALTER DEFAULT PRIVILEGES FOR ROLE odoo IN SCHEMA public
    GRANT SELECT ON TABLES TO reporting;
ALTER ROLE reporting SET statement_timeout = '5min';
ALTER ROLE reporting SET idle_in_transaction_session_timeout = '1min';
```

Repeat the schema/table/default grants in `hes`, using `hes` as its owner, and in
future Odoo databases as needed. Default grants apply to future objects created
by the named owner, not every role. These examples expose all public-schema
tables; grant selected tables instead if reporting should see less data. Do not
grant reporting membership of application roles or any write privileges.

Roles and grants are created on the primary and replicate automatically. The
primary HBA does not allow the `reporting` login; the replica HBA does. The
replication login can copy the entire cluster, so restrict its credentials.

## 2. Start the replica

Copy this directory to `/opt/cashkoom/postgres-reporting`:

```bash
cd /opt/cashkoom/postgres-reporting
cp .env.example .env
touch .pgpass
chmod 600 .env .pgpass
chmod +x check.sh
```

Edit `.env` with this server's VPN IP. `PRIMARY_HOST=cashkoom-primary` resolves
through the shared Docker network. Choose reporting CPU/memory limits appropriate
to the host; defaults are 2 CPUs and 2GB RAM. These limits cannot eliminate shared
disk contention. Keep memory headroom for production and both containers.

Edit `.pgpass` with the replication password you created in pgAdmin:

```text
cashkoom-primary:5432:replication:replicator:YOUR_REPLICATION_PASSWORD
```

Escape any `:` or backslash within the password with a backslash, as required by
PostgreSQL's password-file format. This file is Git-ignored. The entrypoint copies
it into a postgres-owned mode-600 runtime file; it never creates a user/password.
Rotating the password means updating the primary role and this file, then
restarting the reporting container to refresh its runtime copy.

Edit `pg_hba.conf` with your BI/reporting server's actual VPN IP. Then:

```bash
docker compose config --quiet
docker compose up -d
docker compose logs -f reporting
```

First startup runs `pg_basebackup` to clone **all primary databases** into the
empty reporting volume and records streaming recovery settings. It can take a
while and use primary disk/network bandwidth; initialize outside peak hours.
Later starts reuse the data. A partial/non-empty initialization is not silently
erased, and a volume without `standby.signal` is rejected instead of starting as
an independent primary. Use only standard in-volume storage; custom external
tablespaces require separate mapping and are outside this setup.

If initialization fails, stop the reporting project and inspect the error. Fix
access/credentials first. To rebuild a disposable replica, remove **only its own**
reporting volume while the reporting container is removed, then start again. A
lost slot must also be dropped/recreated on the primary after confirming no
replica uses it. Never delete the primary project's volume.

## 3. Connect and verify

In pgAdmin, register another server using host `cashkoom-reporting`, port `5432`,
and maintenance database `cashkoom`. Use the `reporting` login for reports.
Use the existing postgres administrator only for administrative checks. pgAdmin
joins the shared network through the primary Compose project.

Remote BI tools use this server's VPN IP and port **5433**, with the reporting
credentials. Permit this port only from approved reporting hosts. The encrypted
private network/VPN requirement is the same as for the primary. Odoo and HES
continue using the primary's port 5432.

As an administrator on the replica:

```sql
SELECT pg_is_in_recovery(); -- must be true
SHOW transaction_read_only; -- must be on
SELECT status, sender_host, slot_name FROM pg_stat_wal_receiver;
```

On the primary:

```sql
SELECT application_name, client_addr, state, sync_state,
       pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS pending_bytes,
       replay_lag
FROM pg_stat_replication;
SELECT slot_name, active, wal_status,
       pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) AS retained_bytes
FROM pg_replication_slots;
```

Expect application `reporting`, state `streaming`, and sync state `async`. Confirm
new primary data appears in a report. Idle periods can make time-based lag values
null or misleading; check connection status and pending WAL bytes as well.

The primary check script now alerts on an inactive reporting slot, endangered WAL,
or more than 8GB retained. The 10GB retention setting is enforced at checkpoints
and can be exceeded temporarily; it is not a hard disk quota. An offline replica
that loses required WAL must be rebuilt. The primary continues accepting writes
while this asynchronous reporting replica is offline.

Add a replica check to root's existing mail-enabled crontab:

```cron
*/5 * * * * /opt/cashkoom/postgres-reporting/check.sh
```

Long-running reports may be cancelled to let replay proceed. This setup keeps
PostgreSQL's default conflict delay and leaves `hot_standby_feedback` off to avoid
holding back cleanup on production. The reporting role has a five-minute query
timeout. Review these tradeoffs if reports need longer execution.

## 4. Updates and moving to another server

Update PostgreSQL 16 images deliberately, keeping both on matching minor builds
where possible. Update and validate the replica first, then the primary in its
maintenance window. Each project's `docker compose pull` / `up -d` is independent.
Backups remain on the primary. Replication also copies deletions; it is not backup.

When moving to a new server:

1. Stop the old replica. Do not run two replicas against the same slot.
2. Connect the new host to the encrypted private network/VPN.
3. Add a primary HBA entry allowing `replication`, role `replicator`, from the
   new replica host's VPN address (`/32`), before the reject rules; reload HBA.
   Allow its traffic in the provider/network firewall too.
4. Copy this directory, create its local `cashkoom-replication` Docker network,
   and set `PRIMARY_HOST` to the primary's reachable VPN IP or DNS name. Set
   `DB_BIND_IP` to the new reporting host's VPN IP and update `.pgpass`'s hostname.
5. Start with an empty replica volume to clone afresh. Reuse the slot if it is
   inactive and valid; otherwise drop/recreate it before the clone.
6. Register the replica in pgAdmin using its new VPN IP and port 5433. For remote
   administrative access, allow `postgres` explicitly from pgAdmin's observed
   source VPN IP in the replica HBA; the existing `samenet` rule is local-only.
7. Verify streaming and reporting, redirect BI tools, then retire the old copy.

Changing `PRIMARY_HOST` on an existing initialized volume does not rewrite the
connection stored by pg_basebackup. The fresh-clone procedure avoids that issue.
On a separate host, add host/disk monitoring and external uptime checks there too.

## Failure behavior

If the primary stops, the replica remains read-only, serves already-replayed
data, and reconnects when the primary returns. There is **no automatic promotion**.
Manual promotion is a separate recovery operation: fence the old primary first,
assess possible transaction loss, promote, and reconfigure application routing,
access rules, service startup guard/health check and resource limits. The replica
service intentionally refuses to restart a promoted volume as a normal replica.
The former primary must be rewound/rebuilt before rejoining. Do not use promotion
as a reporting workaround. Both containers on one server share its failure risk.

References: [pg_basebackup](https://www.postgresql.org/docs/16/app-pgbasebackup.html),
[streaming replication and slots](https://www.postgresql.org/docs/16/warm-standby.html),
[hot standby](https://www.postgresql.org/docs/16/hot-standby.html).
