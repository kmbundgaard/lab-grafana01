#!/bin/bash
# Wildcard *.lab.kabun.io from Let's Encrypt via Cloudflare DNS-01; Grafana switched to HTTPS. Run as root.
# Needs /etc/letsencrypt/cloudflare.ini (dns_cloudflare_api_token = ..., mode 600) - placed by the owner.
set -euo pipefail
log() { echo "[$(date +%H:%M:%S)] $*"; }
INI=/etc/letsencrypt/cloudflare.ini
[ -s "$INI" ] || { echo "missing $INI"; exit 1; }
chmod 600 "$INI"
CB=(certbot certonly --non-interactive --agree-tos --register-unsafely-without-email --dns-cloudflare
    --dns-cloudflare-credentials "$INI" --dns-cloudflare-propagation-seconds 30 --cert-name lab.kabun.io -d '*.lab.kabun.io')
log "dry run against the Let's Encrypt staging CA"
"${CB[@]}" --dry-run
log "issuing the real certificate"
"${CB[@]}" --keep-until-expiring

cat > /etc/letsencrypt/renewal-hooks/deploy/grafana.sh <<'H'
#!/bin/bash
# Copy the renewed certificate where Grafana (user grafana) can read it, then restart Grafana.
install -d -o root -g grafana -m 750 /etc/grafana/tls
install -o root -g grafana -m 640 /etc/letsencrypt/live/lab.kabun.io/fullchain.pem /etc/grafana/tls/fullchain.pem
install -o root -g grafana -m 640 /etc/letsencrypt/live/lab.kabun.io/privkey.pem   /etc/grafana/tls/privkey.pem
restorecon -R /etc/grafana/tls
systemctl restart grafana-server
H
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/grafana.sh
/etc/letsencrypt/renewal-hooks/deploy/grafana.sh

log "Grafana -> HTTPS on 3000 (grafana.ini [server])"
python3 - <<'PY'
import configparser, io, re
p = '/etc/grafana/grafana.ini'
s = open(p).read()
want = {'protocol': 'https', 'cert_file': '/etc/grafana/tls/fullchain.pem', 'cert_key': '/etc/grafana/tls/privkey.pem',
        'domain': 'grafana01.lab.kabun.io', 'root_url': 'https://grafana01.lab.kabun.io:3000/'}
head, sep, rest = s.partition('\n[server]\n')
nxt = re.search(r'\n\[[^\]]+\]\n', rest); body, tail = (rest[:nxt.start()], rest[nxt.start():]) if nxt else (rest, '')
lines = [l for l in body.split('\n') if not any(re.match(r'^\s*;?\s*%s\s*=' % k, l) for k in want)]
body = '\n'.join(lines).rstrip('\n') + '\n' + ''.join('%s = %s\n' % kv for kv in want.items())
open(p, 'w').write(head + sep + body + tail)
PY
systemctl restart grafana-server; sleep 4
systemctl enable --now certbot-renew.timer
curl -sS -o /dev/null -w 'grafana https %{http_code} (verified against public CA)\n' --resolve grafana01.lab.kabun.io:3000:127.0.0.1 https://grafana01.lab.kabun.io:3000/login
openssl x509 -in /etc/grafana/tls/fullchain.pem -noout -subject -issuer -enddate
systemctl list-timers certbot-renew.timer --no-pager | head -2
log "DONE"
