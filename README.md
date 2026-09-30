# linux-health-automation

![ci](https://github.com/yaserkaka/Linux-Server-Health-check/actions/workflows/ci.yml/badge.svg)

Health checks and basic self-healing for a small fleet of Ubuntu servers, deployed with Ansible and scheduled with a systemd timer.

I built this in my homelab (Ubuntu Server 24.04 VMs on VMware Workstation) to practice the kind of monitoring you end up writing when there's no budget for a full monitoring stack yet. It's deliberately small: Bash, Python, and systemd. No agents, no database, no Kubernetes.

## Problem

The servers were checked by hand. Nobody had a list of what to look at, and failures were usually noticed when a user complained that the site was down or that a disk had filled up overnight.

What I wanted:

- every server checks itself every 5 minutes, using the same list of checks
- a stopped nginx gets restarted automatically, but a service that keeps crashing doesn't get restarted forever
- one log format that's easy to `grep`
- alerts to Slack, Discord or email, with the webhook URLs kept out of git
- the whole thing deployable to new servers with one Ansible command

## Architecture

```
                 control node (laptop / jump host)
                 ansible-playbook site.yml
                          |
          ssh  -----------+-----------+-----------
                          |           |          |
                        web01       web02      app01
   ---------------------------------------------------------------
   on every server:

   server-health.timer  (every 5 min)
         |
         v
   server-health.service  (oneshot, runs as root)
         |
         v
   /opt/server-health/scripts/health-check.sh
         |   reads /etc/server-health/health.conf
         |
         +-- system checks    cpu, memory, disk, inodes, load
         +-- network checks   ip, route, gateway, internet, dns, ports, http
         +-- service checks   nginx, ssh, docker, failed units
         |        |
         |        +-- self_heal.sh  restart -> verify -> RECOVERED / CRITICAL
         |                          (max N attempts per window)
         |
         +--> /var/log/server-health/health.log      (every result)
         +--> python/alert.py  (CRITICAL / RECOVERED only)
                  |  reads secrets from /etc/server-health/alert.env
                  +--> Slack / Discord / email
```

## Tech stack

| Part | Used for |
|---|---|
| Ubuntu Server 24.04 (22.04 also works) | target OS |
| Bash | all checks and the self-healing logic |
| Python 3 (standard library only) | alert delivery, cooldown/de-duplication |
| systemd | service + timer instead of cron |
| logrotate | log rotation |
| Ansible | deployment to all servers |
| GitHub Actions | ShellCheck, flake8, pytest, Ansible syntax check |

The Python side has no pip dependencies on purpose: the servers only need the `python3` that ships with Ubuntu.

## Repository layout

```
linux-health-automation/
├── ansible/
│   ├── ansible.cfg
│   ├── site.yml                   deploy monitoring
│   ├── lab-setup.yml              install nginx/docker in the lab
│   ├── inventory/
│   │   ├── hosts.ini
│   │   └── group_vars/            per-group thresholds and services
│   └── roles/server_health/
├── config/
│   ├── health.conf                all thresholds and settings
│   ├── alert.env.example
│   └── logrotate/server-health
├── docs/
│   └── failure-tests.md
├── python/
│   ├── alert.py                   CLI called by the bash script
│   └── alerting/                  channels, cooldown, alert model
├── scripts/
│   ├── health-check.sh            entry point
│   ├── net-troubleshoot.sh        manual network overview
│   └── lib/                       checks + self-healing
├── systemd/
│   ├── server-health.service
│   └── server-health.timer
├── tests/python/                  unit tests
└── .github/workflows/ci.yml
```

## Installation

### With Ansible (normal way)

Requirements on the control node: Ansible 2.15+ and SSH access to the servers with a sudo user.

```bash
git clone https://github.com/yaserkaka/Linux-Server-Health-check.git
cd Linux-Server-Health-check/ansible

# check connectivity first
ansible monitored -m ping

# lab only: install nginx on webservers, docker on appservers
ansible-playbook lab-setup.yml

ansible-playbook site.yml
```

### Manually on a single server

Useful for testing, or on a box that isn't in the inventory.

```bash
sudo apt install -y curl iproute2 iputils-ping bind9-dnsutils python3 logrotate

sudo mkdir -p /opt/server-health /etc/server-health
sudo cp -r scripts python /opt/server-health/
sudo cp config/health.conf /etc/server-health/
sudo install -m 600 config/alert.env.example /etc/server-health/alert.env
sudo cp systemd/server-health.* /etc/systemd/system/
sudo cp config/logrotate/server-health /etc/logrotate.d/

sudo systemctl daemon-reload
sudo systemctl enable --now server-health.timer
```

Run it once by hand to see the output:

```bash
sudo /opt/server-health/scripts/health-check.sh
```

## Configuration

Everything lives in one file, `/etc/server-health/health.conf` ([config/health.conf](config/health.conf)). The scripts don't hardcode any threshold, host or port.

| Setting | Default | Meaning |
|---|---|---|
| `CPU_WARN` / `CPU_CRIT` | 75 / 85 | CPU usage %, 1 second sample |
| `MEM_WARN` / `MEM_CRIT` | 80 / 90 | memory used %, based on `available` |
| `DISK_WARN` / `DISK_CRIT` | 70 / 80 | filesystem usage % |
| `INODE_CRIT` | 90 | inode usage % |
| `LOAD_WARN_PER_CORE` / `LOAD_CRIT_PER_CORE` | 1.0 / 2.0 | 5 min load divided by CPU count |
| `DISK_MOUNTS` | `/` | mount points to check |
| `TCP_PORTS` | `22 80` | ports that must be listening |
| `HTTP_URL` | `http://localhost/` | app URL, empty to skip |
| `SERVICES` | `nginx ssh docker` | services to check |
| `SELF_HEAL_SERVICES` | `nginx` | services allowed to be restarted |
| `MAX_RESTART_ATTEMPTS` | 3 | restart budget ... |
| `RESTART_WINDOW_SEC` | 3600 | ... per this many seconds |
| `ALERT_ON` | `CRITICAL RECOVERED` | statuses that send a notification |
| `ALERT_CHANNELS` | `slack` | `slack`, `discord`, `email`, or `none` |
| `ALERT_COOLDOWN_SEC` | 1800 | don't repeat the same alert inside this time |

On Ansible-managed servers the file is generated from the inventory, so the values are changed in `group_vars/` and not on the server. For example, app servers don't run nginx, so [appservers.yml](ansible/inventory/group_vars/appservers.yml) checks docker instead and allows docker to be restarted.

The script refuses to load a config file that is group- or world-writable, because it's sourced as root.

### Secrets

Webhook URLs and SMTP passwords are only read from environment variables:

```
SLACK_WEBHOOK_URL  DISCORD_WEBHOOK_URL
SMTP_HOST  SMTP_PORT  SMTP_USER  SMTP_PASSWORD  ALERT_EMAIL_FROM  ALERT_EMAIL_TO
```

systemd loads them from `/etc/server-health/alert.env` (mode 600, root only). Ansible writes that file from vaulted variables:

```bash
cd ansible/inventory/group_vars/all
cp vault.yml.example vault.yml
ansible-vault encrypt vault.yml
cd ../../..
ansible-playbook site.yml --ask-vault-pass
```

The task that writes `alert.env` has `no_log: true`, so the values don't appear in Ansible output.

## Ansible deployment

The `server_health` role:

1. checks the host is Ubuntu
2. installs the packages the checks need (`bind9-dnsutils`, `iputils-ping`, `iproute2`, `curl`, `python3`, ...)
3. creates `/opt/server-health`, `/etc/server-health`, `/var/log/server-health` (root:adm 750) and `/var/lib/server-health` (700)
4. copies the scripts and the Python package
5. templates `health.conf` and `alert.env`
6. installs the service and timer, reloads systemd only if they changed
7. installs the logrotate config
8. enables and starts the timer

It's idempotent. The second run should report `changed=0`:

```
$ ansible-playbook site.yml
...
PLAY RECAP *******************************************************
web01   : ok=11   changed=0    unreachable=0    failed=0    skipped=0
```

When scripts or config change, a handler starts one health check right away, so there's no need to wait for the next timer tick to see if the new config works.

Useful variations:

```bash
ansible-playbook site.yml --limit web01          # one server
ansible-playbook site.yml --check --diff         # dry run, show changes
ansible monitored -a "systemctl list-timers server-health.timer" -b
ansible monitored -a "tail -n 5 /var/log/server-health/health.log" -b
```

## Monitoring checks

| Check | How | Result |
|---|---|---|
| cpu | two samples of `/proc/stat` 1s apart | WARNING / CRITICAL over threshold |
| memory | `free -b`, uses the `available` column | WARNING / CRITICAL |
| disk | `df -P` for each mount in `DISK_MOUNTS` | WARNING / CRITICAL |
| inodes | `df -Pi` | CRITICAL over `INODE_CRIT` |
| load | `uptime`, 5 min average divided by `nproc` | WARNING / CRITICAL |
| ip_address | `ip -4 addr show scope global` | CRITICAL if none |
| default_route | `ip route show default` | CRITICAL if none |
| gateway | `ping`, then `ip neigh` if ping fails | WARNING if ARP works but ICMP is blocked, CRITICAL if neither |
| internet | `ping` + `curl` | OK if either works, CRITICAL if both fail |
| dns | `dig` (falls back to `nslookup`) | CRITICAL if the test name doesn't resolve |
| port:N | `ss -ltn` | CRITICAL if nothing listens |
| http | `curl` to `HTTP_URL` | CRITICAL on connection error or HTTP >= 400 |
| nginx | `systemctl is-active` + `curl` | self-healed |
| ssh | `ssh.service` or `ssh.socket` active | CRITICAL |
| docker | `systemctl is-active` + `docker info` | CRITICAL, self-healed on app servers |
| failed_units | `systemctl --failed`, cause from `journalctl` | CRITICAL per failed unit |

A few details that caused false alarms while testing and are handled now:

- **ssh on Ubuntu 24.04** is socket-activated, so `ssh.service` is `inactive` until someone connects. The check accepts `ssh.socket` too.
- **Memory** "used" in `free` includes page cache, so a healthy server always looks full. The check uses `available`.
- **Gateways that drop ping** (Azure does this, so do some firewalls). If the gateway has an ARP entry, it's a warning and not a critical.
- **Locale**: some locales print `0,52` instead of `0.52` in `uptime`, so the script runs with `LC_ALL=C`.

## Self-healing logic

Only services listed in `SELF_HEAL_SERVICES` are touched.

```
service unhealthy?  (not active, or active but curl/docker info fails)
   |
   log CRITICAL
   |
   restarts in the last RESTART_WINDOW_SEC >= MAX_RESTART_ATTEMPTS ?
   |-- yes --> log CRITICAL "restart limit reached, manual action needed", stop
   |
   record attempt, systemctl restart <svc>, wait RESTART_WAIT_SEC
   |
   systemctl is-active <svc>  and  curl localhost   (nginx)
                                   docker info      (docker)
   |-- ok   --> log RECOVERED
   |-- fail --> log CRITICAL with the most useful journal line
```

Restart attempts are stored as timestamps in `/var/lib/server-health/restarts_<service>`. Successful restarts count too. If nginx needs three restarts in an hour, it's flapping, and a human should look at it instead of a script restarting it every 5 minutes.

A restart only helps if the service died on its own. It can't fix a broken config file or a firewall rule. The retry limit is there for those cases, and the CRITICAL message includes the journal line with the actual error:

```
restart failed (attempt 1/3): nginx is failed; journal: [emerg] unknown directive "broken" in /etc/nginx/conf.d/zz.conf:1
```

To reset the counter after fixing something by hand:

```bash
sudo rm /var/lib/server-health/restarts_nginx
```

Other safety details:

- `flock` stops two runs overlapping if a network check hangs
- `--no-heal` runs detection only
- the script disables self-healing when it's not run as root
- exit codes 1 (warning) and 2 (critical) are listed in `SuccessExitStatus`, so the unit itself doesn't end up in `systemctl --failed`

### Alerts

`health-check.sh` calls `python/alert.py` for every result whose status is in `ALERT_ON`. The alert script:

- sends to each channel in `ALERT_CHANNELS`
- remembers what it sent in `/var/lib/server-health/alerts.json` and suppresses the same host/check/status for `ALERT_COOLDOWN_SEC`
- clears the CRITICAL cooldown when a RECOVERED is sent, so a new outage alerts again right away
- writes its own output to `/var/log/server-health/alerts.log`

Adding a channel (Teams, Telegram, ...) means one new class in `python/alerting/channels/` with a `send()` method, plus one line in the registry in `channels/__init__.py`.

Test a channel by hand:

```bash
sudo bash -c 'set -a; . /etc/server-health/alert.env; set +a;
  python3 /opt/server-health/python/alert.py --host web01 --check test \
  --status CRITICAL --message "test alert, please ignore" --channels slack'
```

## Network troubleshooting

`scripts/net-troubleshoot.sh` is for humans: SSH in and get the whole picture on one screen. It changes nothing.

```bash
sudo /opt/server-health/scripts/net-troubleshoot.sh            # tests ubuntu.com
sudo /opt/server-health/scripts/net-troubleshoot.sh intranet.local
```

It prints, in this order:

1. `ip -br addr` and full `ip addr`
2. `ip route` and the default gateway
3. `/etc/resolv.conf` (plus upstream servers from `resolvectl` on systemd-resolved)
4. DNS test with answer, query time and the server that answered
5. gateway ping, and the ARP entry if ping fails
6. internet test (ping 1.1.1.1 + HTTPS)
7. listening ports with process names (`ss -tulpn`)
8. local HTTP test

The order matters. If there's no IP address, nothing below will work, so start at the top and the first `[FAIL]` is usually the real problem.

## Testing

### CI

`.github/workflows/ci.yml` runs on every push and pull request:

```
checkout -> shellcheck -> flake8 -> pytest -> ansible-playbook --syntax-check
```

Any step failing fails the pipeline.

### Locally

```bash
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements-dev.txt
make check
```

### Failure scenarios

[docs/failure-tests.md](docs/failure-tests.md) has step-by-step procedures, each with how to simulate the failure, what should be detected, what happens automatically, and how to verify and clean up. It covers:

- nginx stopped
- nginx that can't start (tests the retry limit)
- high disk usage
- DNS failure
- closed HTTP port
- Docker stopped

## Screenshots

<!-- add screenshots to docs/screenshots/ -->

| | |
|---|---|
| Timer status (`systemctl list-timers`) | `docs/screenshots/timer.png` |
| nginx stopped and recovered in `health.log` | `docs/screenshots/nginx-recovered.png` |
| Slack alert | `docs/screenshots/slack-alert.png` |
| Ansible second run, `changed=0` | `docs/screenshots/ansible-idempotent.png` |
| `net-troubleshoot.sh` output | `docs/screenshots/net-troubleshoot.png` |
| GitHub Actions run | `docs/screenshots/ci.png` |

## Example logs

`/var/log/server-health/health.log`, format `timestamp | host | check | status | message | recovery_action`:

```
2026-09-30 20:56:19 | web01 | cpu | OK | cpu usage 4% (warn 75%, crit 85%) | -
2026-09-30 20:56:19 | web01 | memory | OK | memory used 8%, 7343 MiB available | -
2026-09-30 20:56:19 | web01 | disk:/ | OK | / is 31% full | -
2026-09-30 20:56:19 | web01 | load | OK | 5m load 0.32 on 2 cores (0.16 per core) | -
2026-09-30 20:56:20 | web01 | gateway | OK | gateway 192.168.56.1 answers ping | -
2026-09-30 20:56:25 | web01 | dns | OK | ubuntu.com -> 185.125.190.20 via system resolver | -
2026-09-30 20:56:25 | web01 | port:80 | OK | tcp/80 is listening | -
2026-09-30 20:57:01 | web01 | nginx | CRITICAL | nginx is inactive | -
2026-09-30 20:57:04 | web01 | nginx | RECOVERED | service restarted (attempt 1/3) | systemctl restart nginx
```

Restart limit reached, from the retry test:

```
2026-09-30 20:58:09 | web01 | nginx | CRITICAL | restart failed (attempt 2/3): nginx is failed; journal: [emerg] unknown directive "this" in /etc/nginx/conf.d/zz-broken.conf:1 | systemctl restart nginx
2026-09-30 20:58:12 | web01 | nginx | CRITICAL | restart failed (attempt 3/3): nginx is failed; journal: [emerg] unknown directive "this" in /etc/nginx/conf.d/zz-broken.conf:1 | systemctl restart nginx
2026-09-30 20:58:17 | web01 | nginx | CRITICAL | restart limit reached (3/3 in 3600s), manual action needed | none
```

Handy one-liners:

```bash
grep -E '\| (CRITICAL|RECOVERED) \|' /var/log/server-health/health.log      # incidents only
awk -F' \\| ' '$4=="CRITICAL" {print $3}' /var/log/server-health/health.log | sort | uniq -c | sort -rn
journalctl -u server-health.service --since "1 hour ago"
```

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `server-health.timer` not in `list-timers` | not enabled: `systemctl enable --now server-health.timer` |
| `ERROR: ... group/world writable` | `chmod 644 /etc/server-health/health.conf` |
| every run says `another health check is still running` | a run is stuck, check `systemctl status server-health.service` |
| alerts not arriving | look in `/var/log/server-health/alerts.log`, usually a missing env var or wrong webhook |
| `docker is inactive` right after stopping it, then active again | `docker.socket` restarted it, stop both units (see failure tests) |
| DNS CRITICAL but `ping 1.1.1.1` works | resolver problem, run `net-troubleshoot.sh` and `resolvectl status` |

## Future improvements

- expose results as Prometheus metrics through the node_exporter textfile collector
- per-check enable/disable flags instead of the `--only` groups
- ship `health.log` to a central place (rsyslog forwarding or Loki)
- Molecule tests for the Ansible role, including an idempotency check in CI
- TLS certificate expiry check
- support RHEL/Rocky (dnf, `sshd` unit name, firewalld)
- maintenance mode flag file that pauses self-healing during planned work

## License

MIT
