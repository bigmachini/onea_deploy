# Dedicated PostgreSQL 16 server

One PostgreSQL instance hosts multiple databases for remote Odoo and HES servers.
pgAdmin manages users and databases. Explicit network access, daily off-server
backups and cron checks keep this small. No connection pooler or monitoring stack.

## Network requirement

This setup requires an **encrypted private network/VPN** between the database,
Odoo and HES servers. A private IP by itself does not encrypt traffic. If your
network does not provide encryption, configure PostgreSQL TLS and certificate
verification before deployment instead of using these rules unchanged.

Example addresses (replace all three):

| Server | VPN address | Database role | Initial database |
| --- | --- | --- | --- |
| PostgreSQL | 10.50.0.10 | local administration only | postgres |
| Odoo | 10.50.0.20 | odoo | cashkoom |
| HES | 10.50.0.30 | hes | hes |

PostgreSQL binds only to the database server's VPN address. `pg_hba.conf` permits
only the listed database/role/source-address combinations. There is no remote
superuser access. Use your provider firewall to allow TCP 5432 only from the
application servers on that network as well. Docker-published ports can bypass
ordinary UFW rules; do not rely on UFW alone.

## First installation

Requires Linux, Docker Engine with Compose v2+, bash, rsync, SSH and util-linux
(flock). Run as root on the database server. Copy this directory to
`/opt/cashkoom/postgres`:

```bash
cd /opt/cashkoom/postgres
cp .env.example .env
chmod 600 .env
# Edit .env: database VPN address and the two initial administrator logins.
# Edit pg_hba.conf: actual Odoo and HES server VPN addresses.
install -d -m 700 backups
chmod +x backup.sh check.sh
docker network create cashkoom-replication
docker compose config --quiet
docker compose up -d --wait
docker compose ps
```

Only PostgreSQL's initial administrator and pgAdmin's login are configured in
`.env`. Application users, passwords and databases are created manually in pgAdmin.
No startup script creates them. Keep `.env` out of Git and store a secure copy
off-server. Docker administrators can inspect container environment variables.

For an existing deployment, changing `.env` does not reset existing PostgreSQL
or pgAdmin passwords. Use their current credentials and rotate through pgAdmin
when needed. Existing application users/databases remain intact.

## pgAdmin: create users and databases

pgAdmin is bound to localhost. From your own computer, open an SSH tunnel:

```bash
ssh -N -L 5050:127.0.0.1:5050 your-admin-user@database-server
```

Open [pgAdmin](http://localhost:5050) and log in using `PGADMIN_EMAIL` and
`PGADMIN_PASSWORD`. Register a server with:

| Field | Value |
| --- | --- |
| Name | Cashkoom PostgreSQL |
| Host | postgres |
| Port | 5432 |
| Maintenance database | postgres |
| Username | postgres |
| Password | Your PostgreSQL administrator password |

The `postgres` hostname connects over the internal Compose network. pgAdmin can
use the database administrator there; remote application servers cannot. Keep
pgAdmin access restricted to administrators. Its saved settings persist in a
separate volume; the daily database backup does not include pgAdmin preferences.
These can be recreated from this guide.

For each application in pgAdmin:

1. Under **Login/Group Roles → Create**, create its role (for example `odoo` or
   `hes`) and set its password in the Definition tab.
2. In Privileges, enable **Can login**. Leave superuser, create roles, create
   databases, replication and bypass row security disabled.
3. Under **Databases → Create**, create the database and assign that role as
   owner (for example `cashkoom` owned by `odoo`, and `hes` owned by `hes`).
4. In the maintenance database's Query Tool, restrict connections:

```sql
REVOKE CONNECT, TEMPORARY ON DATABASE cashkoom FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE cashkoom TO odoo;
REVOKE CONNECT, TEMPORARY ON DATABASE hes FROM PUBLIC;
GRANT CONNECT, TEMPORARY ON DATABASE hes TO hes;
```

In **cashkoom**'s Query Tool, install Odoo's extensions under its owner:

```sql
SET ROLE odoo;
CREATE EXTENSION IF NOT EXISTS unaccent;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
RESET ROLE;
```

Use simple database names: letters, numbers, underscores and hyphens. Repeat for
additional databases. Give independent applications their own roles. Initialize
Odoo/HES schemas through their applications or restore existing data before
switching production traffic. This Compose file starts no application services.

For a new Odoo database, add its name to the access rule, for example:

```text
host cashkoom,odoo_company2 odoo 10.50.0.20/32 scram-sha-256
```

After editing `pg_hba.conf`, run these in pgAdmin's Query Tool:

```sql
SELECT pg_reload_conf();
SELECT line_number, error FROM pg_hba_file_rules WHERE error IS NOT NULL;
```

The second query should return no rows. New databases are automatically backed up.

### Application connections

Example Odoo configuration (use the password you assigned in pgAdmin):

```ini
db_host = 10.50.0.10
db_port = 5432
db_user = odoo
db_password = <password assigned in pgAdmin>
db_name = cashkoom
dbfilter = ^cashkoom$
list_db = False
```

Give HES the same host/port, its own database, user and password. Protect
application configuration files. Never use `postgres` for application connections.
Use the VPN address; if using the TLS alternative, verify the server certificate.

## Backups and monitoring

Daily backups allow **up to 24 hours of data loss**. Restore time depends on data
size. For payment records or high-volume meter readings requiring a smaller loss
window, add continuous WAL backups / point-in-time recovery or use a managed
service. A single database instance also shares resources and downtime across
Odoo and HES; monitor workload before adding tuning or splitting servers.

Configure a restricted account on a separate backup server, create a mode-700
backup directory, set up root's unattended SSH key, and verify the SSH host key.
Replace the destination below:

```bash
./backup.sh backup@backup-host:/srv/backups/cashkoom/
./check.sh
```

Each timestamped backup set contains:

- `globals.sql`: roles, password hashes and global privileges.
- `databases.tsv`: database OID/name mapping, separated by `|`.
- One custom-format `.dump` per non-template database, including `postgres`.

Ownership and privileges are preserved. Each database dump is consistent on its
own; this is not a shared snapshot across applications. Do not change databases
or roles while a backup is running. Completed sets are copied via SSH and kept
about 14 days locally. Remote files are never deleted by this script: configure
remote retention (for example 30 days) and disk monitoring on the backup server.
Protect backups as sensitive data, use encrypted disks, and keep backup deletion
credentials separate where possible.

Install and test host email delivery, then add this to root's crontab. Replace
the address and destination; times use the host timezone (use UTC):

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=ops@example.com
0 2 * * * /opt/cashkoom/postgres/backup.sh backup@backup-host:/srv/backups/cashkoom/ > /var/log/cashkoom-db-backup.log 2>&1 || cat /var/log/cashkoom-db-backup.log
*/5 * * * * /opt/cashkoom/postgres/check.sh
```

Checks report failed database queries, disk usage at 85%, or off-server backup
success older than 26 hours. Failed copies do not mark backups successful.
The backup log is overwritten daily; PostgreSQL logs rotate automatically.
Docker restarts exited containers; health-check failure alone does not restart
PostgreSQL. Add an external uptime check for the database server/VPN and application
HTTPS endpoints: local cron cannot alert when its entire host is down. Never
expose PostgreSQL publicly to make monitoring work. Test alert delivery.

```bash
docker compose ps
docker compose logs --tail=100 postgres
docker stats --no-stream
./check.sh
```

Back up Odoo's filestore, MinIO bucket, configuration and addon versions separately.
For a matching recovery checkpoint, pause all relevant writers, back up databases
and attachment storage, then resume. HES configuration and external object storage
also need their own backups. Never copy live PostgreSQL data files as a backup.

## Recovery and monthly restore drills

Before go-live, restore an off-server backup onto a separate test PostgreSQL 16
instance. Keep test applications isolated: disable Odoo cron/queue workers and
block outbound token, SMS, ERP and HES calls. Record recovery time.

On the isolated recovery server, start an empty instance with the Compose file
as normal; no application databases or roles are precreated.
Recover `.env` and configuration separately. Copy a complete backup set into
`backups/RESTORE_SET`, then restore roles before databases:

```bash
# The image already creates postgres; skip its duplicate CREATE, retain its ALTER.
sed '/^CREATE ROLE postgres;$/d' backups/RESTORE_SET/globals.sql | docker compose exec -T --user postgres postgres psql -X -U postgres -d postgres -v ON_ERROR_STOP=1
cat backups/RESTORE_SET/databases.tsv
# Select the OID matching the database you want, e.g. 16384 for cashkoom.
docker compose exec -T --user postgres postgres pg_restore -U postgres -d postgres --create --exit-on-error < backups/RESTORE_SET/16384.dump
docker compose exec -T --user postgres postgres vacuumdb -U postgres --analyze cashkoom
```

Repeat pg_restore for each application database, using its dump file. Restore
matching attachments and application versions, verify recent payments, meter
reading timestamps, counts and application login. Restore globals only once on a
fresh cluster; do not apply them blindly to an existing shared server. The saved
postgres password hash is restored too; keep `POSTGRES_PASSWORD` in `.env` in sync. Global
backup restoration requires any custom tablespace directories to exist first.

The `postgres` maintenance database already exists on a fresh cluster. If it holds
custom data you need, restore its dump **without `--create`**, with `-d postgres`.
Do not run that on a live shared cluster. For disaster recovery, use the same
procedure, restore HBA rules/VPN access, and start applications only after checks.

For restoring one database on an existing server: stop every writer to that
database, preserve its current state, verify its owner roles exist, then explicitly
drop that database before using `pg_restore --create`. Other databases can remain
running. Never restore blindly over a populated database or remove the volume.

## Updates

Test on staging, use a maintenance window covering **all applications**, and take
a fresh off-server backup. Record the current image before changing it:

```bash
docker inspect "$(docker compose ps -q postgres)" --format '{{.Image}}'
./backup.sh backup@backup-host:/srv/backups/cashkoom/
# Stop Odoo, HES and any other database writers on their own servers.
docker compose pull postgres
docker compose up -d --wait postgres
docker compose exec -T --user postgres postgres psql -U postgres -d postgres -c 'SELECT version();'
./check.sh
# Resume applications and verify login, payments and new meter readings.
```

The `16-bookworm` tag receives PostgreSQL 16 minor updates when explicitly pulled.
Review release notes, update regularly, and keep the previous image until checks
pass. Avoid automatic database image updates. Never change the major version tag
against this volume; major upgrades require tested dump/restore or pg_upgrade.
Update pgAdmin deliberately with a tested version tag as well. Keep Linux, Docker
and VPN software patched too. Default durability settings stay
enabled; memory/connection tuning should follow actual server size and workload.

`docker compose down` preserves data. **`docker compose down -v` deletes it.**

References: [official image](https://hub.docker.com/_/postgres),
[PostgreSQL access rules](https://www.postgresql.org/docs/16/auth-pg-hba-conf.html),
[global backups](https://www.postgresql.org/docs/16/app-pg-dumpall.html),
[database dumps](https://www.postgresql.org/docs/16/app-pgdump.html).

[pgAdmin container documentation](https://www.pgadmin.org/docs/pgadmin4/latest/container_deployment.html).

## Reporting replica

The separate [reporting project](../postgres-reporting/README.md) provides a
read-only physical replica with manual promotion only. The shared external Docker
network is created once above; if it already exists, do not recreate it. Each
project has its own database volume and lifecycle. The primary caps replication
slot WAL retention at 10GB (evaluated at checkpoints, not a hard disk quota).
Leave enough disk headroom and monitor retained WAL; an offline replica exceeding
that budget must be rebuilt. See the reporting guide for roles, initialization,
monitoring and moving the replica to another server.

## Existing deployments under the previous name

The project names now use Cashkoom. Compose derives volume names from project
names, so applying a renamed project to an existing deployment selects new,
empty volumes. If the earlier deployment is already running, preserve its existing
project/volume names until you have backed up and planned the migration. Renaming
these files does not rename existing databases, volumes, networks, crontabs or
server directories. Update those deliberately, along with application connections
and the replica connection/password file. Do not delete existing volumes.
