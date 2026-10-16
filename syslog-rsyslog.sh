#!/bin/bash
# rsyslog in front of Alloy: receives 514/udp+tcp and 6514/tls (any framing, RFC 3164 or 5424) and forwards
# everything as RFC 5424, octet-counted TCP, to Alloy on 127.0.0.1:1514. Run as root. Idempotent.
set -euo pipefail
dnf -y -q install rsyslog rsyslog-gnutls >/dev/null
H=/etc/letsencrypt/renewal-hooks/deploy/grafana.sh
grep -q '/etc/pki/rsyslog' "$H" || cat >> "$H" <<'X'
# rsyslog (syslog TLS receiver on 6514) uses the same certificate
install -d -m 700 /etc/pki/rsyslog
install -m 600 /etc/letsencrypt/live/lab.kabun.io/fullchain.pem /etc/pki/rsyslog/fullchain.pem
install -m 600 /etc/letsencrypt/live/lab.kabun.io/privkey.pem   /etc/pki/rsyslog/privkey.pem
restorecon -R /etc/pki/rsyslog
systemctl restart rsyslog
X
# Alloy: back to a single plain listener, local only (rsyslog is the network-facing receiver now)
cat > /etc/alloy/config.alloy <<'A'
loki.write "local" {
  endpoint { url = "http://127.0.0.1:3100/loki/api/v1/push" }
}
loki.source.syslog "lab" {
  listener {
    address  = "127.0.0.1:1514"
    protocol = "tcp"
    labels   = { job = "syslog" }
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
cat > /etc/rsyslog.d/10-lab-receiver.conf <<'R'
# Lab syslog receiver (grafana01). TLS uses the Let's Encrypt *.lab.kabun.io certificate.
global(DefaultNetstreamDriverCAFile="/etc/pki/tls/certs/ca-bundle.crt"
       DefaultNetstreamDriverCertFile="/etc/pki/rsyslog/fullchain.pem"
       DefaultNetstreamDriverKeyFile="/etc/pki/rsyslog/privkey.pem")
module(load="imudp")
module(load="imtcp" StreamDriver.Name="gtls" StreamDriver.Mode="1" StreamDriver.AuthMode="anon")
ruleset(name="toAlloy") {
  action(type="omfwd" target="127.0.0.1" port="1514" protocol="tcp" TCP_Framing="octet-counted"
         template="RSYSLOG_SyslogProtocol23Format" queue.type="LinkedList" queue.size="50000" action.resumeRetryCount="-1")
}
input(type="imudp" port="514" ruleset="toAlloy")
input(type="imtcp" port="6514" ruleset="toAlloy")
R
# plain TCP 514 needs its own listener without TLS (imtcp module default is TLS above)
cat > /etc/rsyslog.d/11-lab-plain-tcp.conf <<'R'
module(load="imptcp")
input(type="imptcp" port="514" ruleset="toAlloy")
R
# SELinux: rsyslog may only connect to ports labelled syslogd_port_t
semanage port -a -t syslogd_port_t -p tcp 1514 2>/dev/null || semanage port -m -t syslogd_port_t -p tcp 1514
bash "$H" >/dev/null 2>&1 || true          # copy certs for Grafana, Alloy, rsyslog + restarts
firewall-cmd -q --permanent --remove-forward-port=port=514:proto=udp:toport=1514 || true
firewall-cmd -q --permanent --remove-forward-port=port=514:proto=tcp:toport=1514 || true
firewall-cmd -q --permanent --remove-port=1514/tcp --remove-port=1514/udp || true
firewall-cmd -q --permanent --add-service=syslog --add-service=syslog-tls; firewall-cmd -q --permanent --add-port=514/tcp
firewall-cmd -q --reload
rsyslogd -N1 2>&1 | tail -1
systemctl restart alloy rsyslog; sleep 3
for s in rsyslog alloy; do printf '%-8s %s\n' $s "$(systemctl is-active $s)"; done
ss -ltnup | grep -E ':(514|6514|1514) ' | awk '{print $1, $5}' | sort -u
firewall-cmd --list-services; firewall-cmd --list-ports
