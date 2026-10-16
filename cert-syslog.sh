#!/bin/bash
# Named certificate grafana01.lab.kabun.io for the rsyslog TLS receiver (appliance rsyslog clients reject the
# wildcard in their name check). Grafana keeps the *.lab.kabun.io wildcard. Run as root.
set -euo pipefail
INI=/etc/letsencrypt/cloudflare.ini
CB=(certbot certonly --non-interactive --agree-tos --register-unsafely-without-email --dns-cloudflare
    --dns-cloudflare-credentials "$INI" --dns-cloudflare-propagation-seconds 30 --cert-name grafana01.lab.kabun.io -d grafana01.lab.kabun.io)
"${CB[@]}" --dry-run | grep -E "dry run was successful|Error" || true
"${CB[@]}" --keep-until-expiring | grep -E "Successfully|expires|Certificate not yet due" || true
# rsyslog block out of the wildcard hook; own hook for the named cert
python3 - <<'PY'
p='/etc/letsencrypt/renewal-hooks/deploy/grafana.sh'; s=open(p).read()
i=s.find('# rsyslog (syslog TLS receiver on 6514)')
if i>=0: open(p,'w').write(s[:i])
PY
cat > /etc/letsencrypt/renewal-hooks/deploy/rsyslog.sh <<'H'
#!/bin/bash
# rsyslog TLS receiver (6514) uses the NAMED certificate grafana01.lab.kabun.io
L=/etc/letsencrypt/live/grafana01.lab.kabun.io
[ -f "$L/fullchain.pem" ] || exit 0
install -d -m 700 /etc/pki/rsyslog
install -m 600 "$L/fullchain.pem" /etc/pki/rsyslog/fullchain.pem
install -m 600 "$L/privkey.pem"   /etc/pki/rsyslog/privkey.pem
restorecon -R /etc/pki/rsyslog
systemctl restart rsyslog
H
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/rsyslog.sh
bash /etc/letsencrypt/renewal-hooks/deploy/rsyslog.sh
sleep 2; systemctl is-active rsyslog
echo | openssl s_client -connect 127.0.0.1:6514 -servername grafana01.lab.kabun.io 2>/dev/null | openssl x509 -noout -subject -ext subjectAltName -enddate | tr '\n' ' '; echo
