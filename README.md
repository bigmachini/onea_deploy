# Cashkoom infrastructure

Independent Compose projects:

| Directory | Purpose | Private application port |
| --- | --- | --- |
| [postgres](postgres/README.md) | PostgreSQL primary and pgAdmin | 5432 |
| [postgres-reporting](postgres-reporting/README.md) | PostgreSQL reporting replica | 5433 |
| [rabbitmq](rabbitmq/README.md) | Message broker and local management UI | 5672 |
| [redis](redis/README.md) | Persistent Redis | 6379 |

These are single-node services, except for PostgreSQL's reporting copy. Persistent
storage and operational checks do not provide automatic failover. Colocated
services compete for hardware and share its failure risk. RabbitMQ's production
guidance recommends isolating it from other data services for predictable
performance; colocation is a deliberate capacity tradeoff. Size the host before
enabling everything together.

Copy this directory's contents to `/opt/cashkoom`, retaining `service-backup.sh`
and `service-check.sh` beside the service directories. PostgreSQL keeps its own
backup/check scripts.

## Requirements

Linux, Docker Engine/Compose v2+, bash, Python 3, rsync, SSH, and util-linux
(flock). Run host operations as root. Set each service's VPN IP in its `.env`.
Traffic must use an **encrypted private network/VPN**; otherwise add service TLS
and client certificate verification first. Do not expose application ports to the
public Internet. Restrict them to application hosts at the provider/network
firewall. Docker publishing can bypass ordinary UFW rules: do not rely on UFW alone.
Management UIs bind to localhost and use SSH tunnels.

Copy each `.env.example` to `.env`, fill the administrator login/private IP and
set mode 600. Single-quote passwords containing `$` so Compose treats it literally.
Never commit real credentials. Docker administrators can inspect environments.
Application accounts are managed explicitly; no account-generation tool is added.

## Daily off-server backups and checks

Create separate mode-700 directories on another backup server. Configure root's
unattended SSH key and verify its host key. Use encrypted backup storage and
restricted access. Replace these example destinations:

```bash
cd /opt/cashkoom
chmod +x service-backup.sh service-check.sh
./service-backup.sh rabbitmq backup@backup-host:/srv/backups/cashkoom/rabbitmq/
./service-backup.sh redis backup@backup-host:/srv/backups/cashkoom/redis/
./service-check.sh rabbitmq
./service-check.sh redis
```

The script validates each backup and sends it with SHA-256 sidecars over SSH.
The success marker changes only after the off-server copy succeeds. Local backups
are kept about 14 days. Remote backups are never deleted: configure remote
retention (for example 30 days) and monitor that server's disk.

**RabbitMQ daily exports contain definitions, not queued messages.** See its guide
for stopped-node message backups. Redis's daily RDB snapshot permits up to 24 hours
of lost changes after a host/disk disaster. Local AOF reduces Redis's crash-loss
window, but remains on that same disk. Back up configuration/credentials securely
and separately. SHA-256 checks do not replace restore drills.

Install/test host email delivery. Add to root's crontab, replacing email and paths:

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=ops@example.com
15 2 * * * /opt/cashkoom/service-backup.sh rabbitmq backup@backup-host:/srv/backups/cashkoom/rabbitmq/ > /var/log/cashkoom-rabbitmq-backup.log 2>&1 || cat /var/log/cashkoom-rabbitmq-backup.log
30 2 * * * /opt/cashkoom/service-backup.sh redis backup@backup-host:/srv/backups/cashkoom/redis/ > /var/log/cashkoom-redis-backup.log 2>&1 || cat /var/log/cashkoom-redis-backup.log
*/5 * * * * /opt/cashkoom/service-check.sh rabbitmq
*/5 * * * * /opt/cashkoom/service-check.sh redis
```

Use UTC on the host. Backup logs are overwritten each run. Checks alert on
unhealthy containers, disk usage at 85%, or backups older than 26 hours. Redis also
alerts on persistence errors or 85% maxmemory usage. RabbitMQ health includes
memory/disk alarms. Health failure does not restart a container: Docker restarts
exited processes. Test an external host/HTTPS uptime alert too; a dead host cannot
run its own checks. Monitor application queue depth/latency in addition to health.

Before go-live and monthly, restore off-server backups on an isolated host. Check
unauthenticated access fails, then test publishing/consumption and Redis write/read
persistence across restarts. Test application permissions and alert delivery.

## Updates

RabbitMQ `4.4-management` and Redis `8.2-bookworm` track patches within their selected
release lines. Redis 8.2 is an extended release. RabbitMQ 4.4 currently has community
support through July 2027: plan a tested release upgrade before support ends.
Review upstream lifecycle/security notices regularly.

Test new images in staging, take backups, record the image ID, and update one
service in a maintenance window:

```bash
cd /opt/cashkoom/rabbitmq  # or /opt/cashkoom/redis
docker inspect "$(docker compose ps -q)" --format '{{.Image}}'
docker compose pull
docker compose up -d --wait
docker compose logs --tail=100
```

Validate applications and keep old images/backups until checks pass. RabbitMQ
metadata upgrades may prevent image downgrades: follow supported upgrade paths
and feature-flag guidance. Keep Linux/Docker patched. Ordinary `docker compose down`
preserves volumes; **`docker compose down -v` deletes them**. Moving a Compose
project also requires moving/restoring its data and configuration.

Sources: [RabbitMQ production guidance](https://www.rabbitmq.com/docs/production-checklist),
[RabbitMQ lifecycle](https://www.rabbitmq.com/release-information),
[Redis lifecycle](https://redis.io/docs/latest/operate/oss_and_stack/install/version-mgmt/).
