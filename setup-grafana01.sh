#!/bin/bash
# grafana01 stack: Grafana OSS + Prometheus + node_exporter + Loki + Alloy (syslog -> Loki).
# Idempotent: safe to rerun. Run as root. Reads the Grafana admin password from stdin (one line).
set -euo pipefail
read -r GF_ADMIN_PW
log() { echo "[$(date +%H:%M:%S)] $*"; }
ARCH=linux-amd64

log "base packages"
dnf -y install tar curl jq policycoreutils-python-utils >/dev/null
rpm -q open-vm-tools >/dev/null || { dnf -y install open-vm-tools >/dev/null && systemctl enable --now vmtoolsd; }

log "Grafana package repository (rpm.grafana.com)"
cat > /etc/yum.repos.d/grafana.repo <<'R'
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
sslverify=1
sslcacert=/etc/pki/tls/certs/ca-bundle.crt
R
dnf -y install grafana loki alloy >/dev/null
log "installed: $(rpm -q grafana loki alloy | tr '\n' ' ')"

gh_install() {   # gh_install <repo> <name> : latest release tarball, checksum-verified, binary to /usr/local/bin
  local repo=$1 name=$2 tag ver tgz
  tag=$(curl -fsSL "https://api.github.com/repos/$repo/releases/latest" | jq -r .tag_name); ver=${tag#v}
  if [ -x "/usr/local/bin/$name" ] && "/usr/local/bin/$name" --version 2>&1 | grep -q "version $ver"; then log "$name $ver already installed"; return; fi
  tgz="$name-$ver.$ARCH.tar.gz"
  cd /tmp && curl -fsSLO "https://github.com/$repo/releases/download/$tag/$tgz" && curl -fsSL "https://github.com/$repo/releases/download/$tag/sha256sums.txt" | grep " $tgz\$" | sha256sum -c -
  tar xzf "$tgz" && install -m 755 "$name-$ver.$ARCH/$name" /usr/local/bin/
  [ "$name" = prometheus ] && install -m 755 "$name-$ver.$ARCH/promtool" /usr/local/bin/
  rm -rf "/tmp/$tgz" "/tmp/$name-$ver.$ARCH"; log "$name $ver installed (checksum OK)"
}
gh_install prometheus/prometheus prometheus
gh_install prometheus/node_exporter node_exporter
restorecon -R /usr/local/bin

id prometheus >/dev/null 2>&1 || useradd -r -s /sbin/nologin -d /var/lib/prometheus prometheus
id node_exporter >/dev/null 2>&1 || useradd -r -s /sbin/nologin node_exporter
install -d -o prometheus -g prometheus /var/lib/prometheus /etc/prometheus
[ -f /etc/prometheus/prometheus.yml ] || cat > /etc/prometheus/prometheus.yml <<'P'
global:
  scrape_interval: 30s
scrape_configs:
  - job_name: prometheus
    static_configs: [{ targets: ['localhost:9090'] }]
  - job_name: node
    static_configs:
      - targets: ['localhost:9100']
        labels: { host: grafana01 }
    # add more Linux hosts here, e.g. - targets: ['192.168.2.12:9100'] (deploy01), then: systemctl reload prometheus
  # Veeam appliances (VSA / VIA): the BUILT-IN Node Exporter (VBR web UI > Configuration > Observability >
  # Node Exporter; helpcenter.veeam.com/docs/vbr/userguide/configure_node_exporter.html). HTTPS on 443 with the
  # appliance's self-signed certificate. If basic auth is enabled there, add: basic_auth: { username: ..., password_file: ... }
  - job_name: veeam-appliances
    scheme: https
    metrics_path: /metrics
    tls_config: { insecure_skip_verify: true }
    static_configs:
      - targets: ['192.168.2.117:443']
        labels: { host: vbr02, role: vsa }
P
cat > /etc/systemd/system/prometheus.service <<'U'
[Unit]
Description=Prometheus
After=network-online.target
[Service]
User=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=30d --web.listen-address=127.0.0.1:9090
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
[Install]
WantedBy=multi-user.target
U
cat > /etc/systemd/system/node_exporter.service <<'U'
[Unit]
Description=Prometheus node_exporter
After=network-online.target
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure
[Install]
WantedBy=multi-user.target
U

log "Grafana: admin password, provisioned data sources (Prometheus, Loki)"
install -d /etc/grafana/provisioning/datasources
cat > /etc/grafana/provisioning/datasources/lab.yaml <<'D'
apiVersion: 1
datasources:
  - { name: Prometheus, type: prometheus, uid: prometheus, access: proxy, url: http://127.0.0.1:9090, isDefault: true }
  - { name: Loki, type: loki, uid: loki, access: proxy, url: http://127.0.0.1:3100 }
D
chown -R root:grafana /etc/grafana/provisioning

log "Alloy: syslog listener -> Loki (RFC 5424 per the VBR 13.1 docs; 514 is forwarded to 1514)"
cat > /etc/alloy/config.alloy <<'A'
loki.write "local" {
  endpoint { url = "http://127.0.0.1:3100/loki/api/v1/push" }
}
loki.source.syslog "lab" {
  listener {
    address  = "0.0.0.0:1514"
    protocol = "tcp"
    labels   = { job = "syslog", transport = "tcp" }
  }
  listener {
    address  = "0.0.0.0:1514"
    protocol = "udp"
    labels   = { job = "syslog", transport = "udp" }
  }
  relabel_rules = loki.relabel.syslog.rules
  forward_to    = [loki.write.local.receiver]
}
loki.relabel "syslog" {
  forward_to = []
  rule {
    source_labels = ["__syslog_message_hostname"]
    target_label  = "host"
  }
  rule {
    source_labels = ["__syslog_message_app_name"]
    target_label  = "app"
  }
  rule {
    source_labels = ["__syslog_message_severity"]
    target_label  = "severity"
  }
}
A
touch /etc/alloy/config.alloy.lab

log "firewall: 3000/tcp Grafana, 9100/tcp node_exporter, 514 -> 1514 tcp+udp syslog"
firewall-cmd -q --permanent --add-port=3000/tcp --add-port=9100/tcp --add-port=1514/tcp --add-port=1514/udp
firewall-cmd -q --permanent --add-forward-port=port=514:proto=udp:toport=1514 --add-forward-port=port=514:proto=tcp:toport=1514
firewall-cmd -q --reload

systemctl daemon-reload
systemctl enable --now node_exporter prometheus loki alloy grafana-server
sleep 5
grafana cli --homepath /usr/share/grafana --config /etc/grafana/grafana.ini admin reset-admin-password "$GF_ADMIN_PW" >/dev/null 2>&1 && log "Grafana admin password set" || log "WARN: could not set the Grafana admin password"
unset GF_ADMIN_PW
for s in node_exporter prometheus loki alloy grafana-server; do printf '%-16s %s\n' "$s" "$(systemctl is-active $s)"; done
curl -fsS -o /dev/null -w 'grafana http %{http_code}\n' http://127.0.0.1:3000/login || true
log "DONE"
