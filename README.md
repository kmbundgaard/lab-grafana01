# grafana01 - lab monitoring for the Veeam appliances

Grafana, Prometheus and Loki for the kabun lab. The VM collects:
- **metrics** from the Veeam appliances' built-in Node Exporter,
- **syslog**, including the audit and login events, from VBR and the appliances.

It's for the lab only. It isn't part of the AutoDeploy toolkit, and none of it runs on deploy01.

| | |
|---|---|
| Grafana | **https://grafana01.lab.kabun.io:3000** - always use the full name; the certificate doesn't cover the IP or the short name |
| Login | `admin`. The password is in `~/veeam-lab/secrets/grafana01-admin.enc` (see [Access](#access)) |
| VM | `grafana01.lab.kabun.io` = **192.168.2.13**, Rocky Linux 9.8, 2 vCPU, 4 GB RAM, 80 GB thin, UEFI + Secure Boot, folder `LAB2.0`, datastore `SSD-2` |
| SSH | `ssh labadmin@192.168.2.13`: key only (Mac `id_rsa`, `kabun@vone`), passwordless sudo. No root login, no password login |
| Built | 2026-10-16, from vone |

---

## How the data flows

```
 Veeam appliances (vbr02 192.168.2.117, vhr01 192.168.2.116, ...)
   |                                         |
   | built-in Node Exporter                  | syslog, TLS 6514 (audit + OS + VBR events)
   | https://<appliance>/metrics             |
   v                                         v
 Prometheus  (127.0.0.1:9090)          rsyslog  (514 udp/tcp, 6514 TLS)
   |   + node_exporter :9100 (grafana01)       |  RFC 5424, octet-counted TCP
   |                                         v
   |                                     Alloy  (127.0.0.1:1514) -> Loki (127.0.0.1:3100)
   v                                         |
 Grafana  (https :3000)  <-------------------+
```

| Component | Version (2026-10-16) | Source | Listens on |
|---|---|---|---|
| Grafana OSS | 13.2.4 | rpm.grafana.com | `0.0.0.0:3000` (HTTPS) |
| Prometheus | 3.15.0 | GitHub release, SHA-256 checked, `/usr/local/bin` | `127.0.0.1:9090` |
| node_exporter | 1.12.1 | GitHub release, SHA-256 checked | `0.0.0.0:9100` |
| Loki | 3.7.8 | rpm.grafana.com | `127.0.0.1:3100` (local only) |
| Alloy | 1.20.1 | rpm.grafana.com | `127.0.0.1:1514` (local only) |
| rsyslog (+ gnutls) | 8.2510 | Rocky BaseOS/AppStream | `514/udp`, `514/tcp`, `6514/tcp` (TLS) |
| certbot + dns-cloudflare | 3.1.0 | EPEL | — |

Open firewall ports: `ssh`, `syslog` (514), `syslog-tls` (6514), `514/tcp`, `3000/tcp`, `9100/tcp`. SELinux is **enforcing**.

---

## Access

Show the Grafana admin password on the Mac:

```bash
pwsh -File ~/Documents/GitHub/veeam-via-proxy-autodeploy/Protect-DeploymentSecrets.ps1 -Show -Reveal \
  -KeyFile ~/veeam-lab/secrets/lab.key -In ~/veeam-lab/secrets/grafana01-admin.enc
```

To change it, on grafana01:

```bash
sudo grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password '<new>'
```

The short `grafana-cli admin reset-admin-password` doesn't work on Rocky: it can't find the paths.

---

## Veeam side (VBR web console)

| What | Where | Setting |
|---|---|---|
| Metrics | Configuration > Observability > **Node Exporter** | Enabled, HTTPS 443 |
| Appliance syslog (OS, services, **audit and logins**) | Configuration > Observability > **Syslog** | Server `grafana01.lab.kabun.io`, **TLS**, port **6514**, severity **Informational (6) and higher** |
| VBR events (jobs and the like) | Options > Event Forwarding > **Syslog servers** | Optional. Plain TCP/UDP 514 or TLS 6514 |
| Trust | Host Management Console (`https://<appliance>:10443`) > Certificates > Trusted Certificates | ISRG Root X1 (Let's Encrypt root) is installed on vbr02 |

Notes from Veeam's documentation (VBR 13.1):
- **Audit and login events are sent only over TLS.** Their app name is `audisp-syslog`.
- VBR pushes the appliance syslog settings to every appliance about **every 5 minutes**, so changes don't take effect immediately.
- Node Exporter and appliance syslog need a VUL or NFR license.
- **Don't install anything on the appliances** (no node_exporter, no agents). Veeam KB4772 says extra packages make the appliance unsupported. Use the built-in exporter.

---

## Certificates (Let's Encrypt, DNS-01 via Cloudflare)

| Certificate | Used by | Why |
|---|---|---|
| `*.lab.kabun.io` (certbot name `lab.kabun.io`) | Grafana HTTPS | A wildcard keeps the individual host names out of the public Certificate Transparency logs |
| `grafana01.lab.kabun.io` (certbot name `grafana01.lab.kabun.io`) | rsyslog TLS 6514 | **The appliances' syslog sender rejects wildcard certificates** (see Troubleshooting) |

- Both were issued on 2026-10-16 and expire on 2027-01-14. `certbot-renew.timer` renews them about 30 days before expiry.
- The renewal hooks are in `/etc/letsencrypt/renewal-hooks/deploy/`:
  - `grafana.sh` copies the wildcard certificate to `/etc/grafana/tls/` and restarts Grafana.
  - `rsyslog.sh` copies the named certificate to `/etc/pki/rsyslog/` and restarts rsyslog.
- The Cloudflare API token is in `/etc/letsencrypt/cloudflare.ini` (root only, mode 600).

> **Renewal will fail** with the token used on 2026-10-16: it expired the same day and was limited to IP 87.104.246.204.
> Before mid-December 2026, create a long-lived token in Cloudflare (My Profile > API Tokens > "Edit zone DNS",
> zone `kabun.io` only, client IP 87.104.246.204), store it, then test:
>
> ```bash
> ssh -t labadmin@192.168.2.13 'read -rsp "Cloudflare token: " T; echo; printf "dns_cloudflare_api_token = %s\n" "$T" | sudo tee /etc/letsencrypt/cloudflare.ini >/dev/null; sudo chmod 600 /etc/letsencrypt/cloudflare.ini; unset T; echo saved'
> ssh labadmin@192.168.2.13 'sudo certbot renew --dry-run'
> ```
>
> Don't press arrow keys at the hidden prompt: on 2026-10-16 an escape sequence ended up in the file and Cloudflare answered with a bare HTTP 400.

---

## Dashboard

**Dashboards > Lab > "Veeam lab - appliances"** is provisioned from `/var/lib/grafana/dashboards/veeam-lab.json` (source: `veeam-lab.json` in this folder). Pick an appliance in the selector at the top; it lists every host Prometheus scrapes in the `veeam-appliances` job.

| Row | Panels |
|---|---|
| Top | Node Exporter up/down, Veeam services failed, Veeam services active, uptime, root filesystem used |
| Charts | CPU busy, memory used, network sent/received, disk read/write |
| Details | Filesystem usage per mount, table of Veeam components with versions |
| Syslog | Events per severity over time, the event list |

**Dashboards > Lab > "Veeam lab - proxies"** (`veeam-proxies.json`) shows the proxy fleet side by side. Its
**Proxy** selector offers All or any set of proxies, i.e. the Prometheus targets with `role: proxy`.

| Row | Panels |
|---|---|
| Top | Proxies down, transport service not running (`veeamtransport.service` = the data mover), Veeam services failed, proxies monitored, busiest CPU |
| Fleet table | One row per proxy: Node Exporter up/down, transport service, CPU / memory / root filesystem gauges, network in+out, uptime |
| Charts | One line per proxy: CPU busy, memory used, network throughput, disk throughput (HotAdd reads show up as disk) |
| Syslog | Events per proxy over time, the proxies' log lines |

The top-row counters are red only when something is wrong. During a backup job, watch network and disk throughput.

Changes saved in the browser are kept, unless you deploy the JSON file again.

### Useful log searches (Explore > Loki > Code)

```logql
{job="syslog"}                                                       # everything
{host="vbr02", app="audisp-syslog"} |= "USER_LOGIN"                  # appliance logins
{host="vbr02"} |~ "(?i)res=failed|failed password"                   # failed attempts
{host="vbr02", app="VeeamManager"}                                   # VBR's own events
sum by (host, app) (count_over_time({job="syslog"}[1h]))             # who sends how much
```

Labels: `host` (sending appliance), `app` (application name), `severity`, `job="syslog"`.

---

## Common tasks

**Add an appliance to the metrics.** In the lab, vbr02 (`role: vsa`), prx-01..04 (`role: proxy`) and vhr01 (`role: hardened-repo`) are already in. For a new one: enable Node Exporter for it in VBR, then on grafana01 add a target to the `veeam-appliances` job in `/etc/prometheus/prometheus.yml`:

```yaml
      - targets: ['192.168.2.190:443']
        labels: { host: prx-01, role: proxy }      # role: proxy -> appears in the proxies dashboard
```

Then run `sudo systemctl reload prometheus`. It appears in the dashboard's appliance selector. Appliance syslog needs nothing extra: VBR pushes the setting to all appliances.

**Add another Linux machine:** install node_exporter on it, add `<ip>:9100` to the `node` job, then reload Prometheus.

**Retention:** Prometheus keeps 30 days (`--storage.tsdb.retention.time=30d` in `/etc/systemd/system/prometheus.service`). Loki uses the package defaults (`/etc/loki/config.yml`). The disk was 10% used on 2026-10-16.

**Check that everything runs:**

```bash
ssh labadmin@192.168.2.13 'for s in grafana-server prometheus node_exporter loki alloy rsyslog; do printf "%-15s %s\n" $s $(systemctl is-active $s); done'
```

---

## Troubleshooting (all seen while building it)

| Symptom | Cause / fix |
|---|---|
| Browser doesn't trust the certificate | You opened it by IP or short name. Use `https://grafana01.lab.kabun.io:3000`. |
| Node Exporter target `down`, HTTP 404 | Node Exporter isn't enabled on that appliance yet (VBR > Configuration > Observability). |
| Appliance connects to 6514, completes the TLS handshake, then closes without sending, about every 30 s. rsyslog logs `TLS connection was non-properly terminated` | The appliance's rsyslog client **checks the server name after the handshake and doesn't accept a wildcard certificate**. It hangs up silently instead of sending a TLS alert. 6514 must use the **named** certificate. |
| rsyslog: `cannot connect to 127.0.0.1:1514: Permission denied` | SELinux. Port 1514 must be labelled for syslog: `sudo semanage port -a -t syslogd_port_t -p tcp 1514` (done). |
| Alloy: `invalid or unsupported framing. first byte: '\n'` | Alloy's own syslog listener can't handle the appliance's TLS framing. That's why rsyslog receives and Alloy only listens locally. |
| Plain TCP/UDP gives no logins | Expected: audit and login events go only over TLS. |
| "Failed to fetch" in a panel | Grafana was restarting (after a certificate renewal, for example). Reload the page. |
| Setting changed in VBR but nothing happens | It's pushed to the appliances only about every 5 minutes. |

---

## Rebuilding from scratch

Everything is in this repository (local working copy also in `~/veeam-lab/grafana01`). Build from **vone**, not from the Mac: large uploads drop the L2TP VPN.

1. Run `./make-oemdrv.sh` to build `grafana01-oemdrv.iso` from `ks.cfg`. Then copy the folder to vone (`C:\AutoDeploy-Build\grafana01\`) together with `iso\Rocky-9.8-x86_64-minimal.iso`.
2. Delete the old VM, then run `vone-grafana01.ps1` on vone. It reads the vCenter user and password on stdin.
   - It uploads the **unchanged** Rocky ISO plus `grafana01-oemdrv.iso`, a tiny CD labelled `OEMDRV` holding `ks.cfg`; the Rocky installer picks it up by itself.
   - It creates the VM, waits for the install to power it off, removes both CDs, boots it and waits for SSH.
3. Over SSH, in this order, each as `sudo bash <script>`:
   1. `setup-grafana01.sh`: the stack. Pass the Grafana admin password on stdin.
   2. Put the Cloudflare token on the VM (command above), then `cert-grafana01.sh`: wildcard certificate and Grafana HTTPS.
   3. `syslog-rsyslog.sh`: rsyslog in front of Alloy, including the SELinux port label for 1514.
   4. `cert-syslog.sh`: the named certificate for 6514.
4. Copy `veeam-lab.json` and `veeam-proxies.json` to `/var/lib/grafana/dashboards/` and `dash-provider.yaml` to `/etc/grafana/provisioning/dashboards/lab.yaml`, then restart Grafana.

| File | Purpose |
|---|---|
| `ks.cfg`, `make-oemdrv.sh` | Unattended Rocky install: static IP, `labadmin` with keys, SSH key-only, SELinux and firewall on. `make-oemdrv.sh` builds `grafana01-oemdrv.iso` from `ks.cfg` (not stored in git) |
| `vone-grafana01.ps1` | Run on vone: upload, create the VM, wait for the install |
| `setup-grafana01.sh` | Grafana, Prometheus, node_exporter, Loki, Alloy, data sources, firewall |
| `cert-grafana01.sh` | Wildcard certificate, Grafana HTTPS, renewal hook |
| `syslog-rsyslog.sh` | rsyslog receiver (514/6514) → Alloy; firewall |
| `cert-syslog.sh` | Named certificate for the TLS syslog receiver, renewal hook |
| `veeam-lab.json`, `veeam-proxies.json`, `dash-provider.yaml` | The two dashboards and their provisioning |

The scripts are safe to run again. The ones in this folder are the final working versions.
