# Failure tests

Procedures for breaking things on purpose and checking that the monitoring reacts the right way.

Run these on lab VMs, not production. Every test has a cleanup step. None of them touch SSH (port 22), so you can't lock yourself out.

Before each test:

```bash
# start from a clean restart counter, otherwise earlier tests eat the budget
sudo rm -f /var/lib/server-health/restarts_*

# follow the log in a second terminal
sudo tail -f /var/log/server-health/health.log
```

Tip: `--no-alert` keeps test runs out of Slack. Leave it off once to check that alerts arrive.

---

## 1. nginx stopped

Host: web server (`nginx` in `SELF_HEAL_SERVICES`)

**Simulate**

```bash
sudo systemctl stop nginx
systemctl is-active nginx        # inactive
```

**Run the check** (or wait up to 5 minutes for the timer)

```bash
sudo /opt/server-health/scripts/health-check.sh --only services --no-alert
```

**Expected detection**

```
... | nginx | CRITICAL | nginx is inactive | -
```

**Automatic action**

`systemctl restart nginx`, a 3 second wait, then `systemctl is-active nginx` and `curl http://localhost/`.

```
restarting nginx (attempt 1/3)
... | nginx | RECOVERED | service restarted (attempt 1/3) | systemctl restart nginx
```

**Verify**

```bash
systemctl is-active nginx                               # active
curl -sI http://localhost/ | head -1                    # HTTP/1.1 200 OK
cat /var/lib/server-health/restarts_nginx               # one timestamp
grep RECOVERED /var/log/server-health/health.log | tail -1
```

With alerts enabled, you get two messages: `[CRITICAL] web01 - nginx` and `[RECOVERED] web01 - nginx`.

**Cleanup:** nothing, nginx is already running again.

---

## 2. nginx can't start (retry limit)

This tests that a broken service isn't restarted forever.

**Simulate**

```bash
echo 'this is broken;' | sudo tee /etc/nginx/conf.d/zz-broken.conf
sudo systemctl stop nginx
sudo nginx -t        # confirms the config is invalid
```

**Run the check 4 times**

```bash
for i in 1 2 3 4; do
  sudo /opt/server-health/scripts/health-check.sh --only services --no-alert | grep '| nginx |'
done
```

**Expected**

- runs 1-3: `CRITICAL | restart failed (attempt N/3): nginx is failed; journal: ... [emerg] unknown directive "this" ...`
- run 4: `CRITICAL | restart limit reached (3/3 in 3600s), manual action needed | none`, and no restart is attempted

The journal line in the message points straight at the broken file.

**Verify**

```bash
wc -l < /var/lib/server-health/restarts_nginx      # 3, and it stays 3 on later runs
```

**Cleanup**

```bash
sudo rm /etc/nginx/conf.d/zz-broken.conf
sudo nginx -t && sudo systemctl start nginx
sudo rm /var/lib/server-health/restarts_nginx
```

---

## 3. High disk usage

Filling `/` on purpose is a bad idea, even in a lab: journald, apt and the check itself need space. This test fills a small loop-mounted filesystem instead, which `df` treats like any other disk.

**Simulate**

```bash
sudo truncate -s 200M /root/disktest.img
sudo mkfs.ext4 -q /root/disktest.img
sudo mkdir -p /mnt/disktest
sudo mount -o loop /root/disktest.img /mnt/disktest
sudo fallocate -l 150M /mnt/disktest/fill.bin
df -h /mnt/disktest          # ~96%
```

Point a copy of the config at it, so the real config isn't touched:

```bash
sudo sed 's#^DISK_MOUNTS=.*#DISK_MOUNTS="/ /mnt/disktest"#' \
  /etc/server-health/health.conf | sudo tee /root/test-disk.conf >/dev/null
sudo /opt/server-health/scripts/health-check.sh -c /root/test-disk.conf --only system --no-alert
```

**Expected detection**

```
... | disk:/ | OK | / is 31% full | -
... | disk:/mnt/disktest | CRITICAL | /mnt/disktest is 96% full | -
```

**Automatic action:** none. The script never deletes files, because it can't know what's safe to delete. A human decides (old logs, docker images, apt cache, ...).

**Verify recovery**

```bash
sudo rm /mnt/disktest/fill.bin
sudo /opt/server-health/scripts/health-check.sh -c /root/test-disk.conf --only system --no-alert | grep disktest
# ... | disk:/mnt/disktest | OK | /mnt/disktest is 1% full | -
```

**Cleanup**

```bash
sudo umount /mnt/disktest
sudo rm /root/disktest.img /root/test-disk.conf
```

When it happens for real, these usually find the culprit:

```bash
sudo du -xh / --max-depth=2 2>/dev/null | sort -rh | head -15
sudo journalctl --disk-usage
sudo lsof +L1          # deleted files still held open by a process
```

---

## 4. DNS failure

### 4a. Safe version (config override)

Uses `192.0.2.53`, a TEST-NET address that never answers.

```bash
sudo sed 's#^DNS_SERVER=.*#DNS_SERVER="192.0.2.53"#' \
  /etc/server-health/health.conf | sudo tee /root/test-dns.conf >/dev/null
sudo /opt/server-health/scripts/health-check.sh -c /root/test-dns.conf --only network --no-alert
sudo rm /root/test-dns.conf
```

**Expected**

```
... | dns | CRITICAL | cannot resolve ubuntu.com via 192.0.2.53 | -
```

### 4b. Realistic version (break the resolver)

This breaks DNS for the whole VM, like a bad netplan change would. Find the interface name with `ip -br addr` first.

```bash
sudo resolvectl dns ens33 192.0.2.53
sudo resolvectl flush-caches
dig +short ubuntu.com        # times out
```

**Expected detection**

```
... | internet | WARNING | ping works but https://www.google.com failed (proxy/firewall/DNS?) | -
... | dns | CRITICAL | cannot resolve ubuntu.com via system resolver | -
```

The internet warning is useful here: ping to 1.1.1.1 works by IP, so routing is fine and the problem is name resolution. `net-troubleshoot.sh` shows the same thing: the DNS test fails and the ping works.

**Automatic action:** none. DNS settings come from netplan/DHCP, and changing them automatically could make things worse.

**Cleanup / verify**

```bash
sudo resolvectl revert ens33
resolvectl status ens33 | grep 'DNS Servers'
dig +short ubuntu.com
sudo /opt/server-health/scripts/health-check.sh --only network --no-alert | grep dns
```

---

## 5. Closed HTTP port

A firewall rule that rejects port 80. nginx keeps running and listening, but nobody can connect. This shows the difference between "listening" (`ss`) and "reachable" (`curl`).

**Simulate**

```bash
sudo iptables -I INPUT -p tcp --dport 80 -j REJECT
curl -m 3 http://localhost/     # Connection refused
ss -ltn 'sport = :80'           # still LISTEN
```

Traffic to `localhost` also goes through the INPUT chain, so the local check sees it.

**Expected detection**

```
... | port:80 | OK | tcp/80 is listening | -
... | http | CRITICAL | http://localhost/ connection failed | -
... | nginx | CRITICAL | nginx active but http://localhost/ returned 000 | -
```

**Automatic action:** because the nginx health test includes `curl`, the script restarts nginx. The restart can't fix a firewall rule, so verification fails, and after 3 attempts it stops with `restart limit reached`. This is the case the retry limit exists for.

**Cleanup / verify**

```bash
sudo iptables -D INPUT -p tcp --dport 80 -j REJECT
sudo iptables -L INPUT -n --line-numbers | grep 'dpt:80'    # nothing
curl -sI http://localhost/ | head -1
sudo rm -f /var/lib/server-health/restarts_nginx
```

Alternative without iptables: change `listen 80` to `listen 8080` in `/etc/nginx/sites-enabled/default` and `systemctl reload nginx`. Then `port:80` is CRITICAL too, because nothing listens there anymore.

---

## 6. Docker stopped

Host: app server (`docker` in `SELF_HEAL_SERVICES`, see `group_vars/appservers.yml`)

**Simulate**

Docker is socket-activated. If you only stop `docker.service`, the next `docker` command starts it again through `docker.socket`, and the test proves nothing. Stop both:

```bash
sudo docker run -d --name web --restart unless-stopped -p 8080:80 nginx   # something to bring back
sudo systemctl stop docker.socket docker.service
systemctl is-active docker docker.socket     # inactive inactive
```

**Run the check**

```bash
sudo /opt/server-health/scripts/health-check.sh --only services --no-alert
```

**Expected detection**

```
... | docker | CRITICAL | docker is inactive | -
```

**Automatic action**

`systemctl restart docker` (this starts `docker.socket` too, because `docker.service` requires it), then `systemctl is-active docker` and `docker info`.

```
restarting docker (attempt 1/3)
... | docker | RECOVERED | service restarted (attempt 1/3) | systemctl restart docker
```

**Verify**

```bash
systemctl is-active docker docker.socket    # active active
sudo docker info --format '{{.ServerVersion}}'
sudo docker ps                              # "web" is back because of its restart policy
```

**Cleanup**

```bash
sudo docker rm -f web
sudo rm -f /var/lib/server-health/restarts_docker
```

---

## Checking the timer end to end

After any test, confirm that the scheduled path works too, not only manual runs:

```bash
systemctl list-timers server-health.timer
sudo systemctl start server-health.service      # same as a timer run
systemctl status server-health.service --no-pager
journalctl -u server-health.service -n 30 --no-pager
```

`status=2` in `systemctl status` means the run found something critical. That's expected, and the unit still counts as successful because of `SuccessExitStatus=1 2`.
