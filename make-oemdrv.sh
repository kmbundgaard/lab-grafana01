#!/bin/bash
# Builds grafana01-oemdrv.iso: a tiny CD labelled OEMDRV that holds ks.cfg. The stock Rocky 9 installer loads
# /ks.cfg from a volume with that label by itself, so the Rocky ISO stays unmodified.
# Needs xorriso (macOS: brew install xorriso; Rocky: dnf install xorriso; WSL: apt install xorriso).
set -euo pipefail
cd "$(dirname "$0")"
X=${XORRISO:-xorriso}
d=$(mktemp -d); cp ks.cfg "$d/ks.cfg"
"$X" -as mkisofs -V OEMDRV -J -R -o grafana01-oemdrv.iso "$d"
rm -rf "$d"; echo "built grafana01-oemdrv.iso"
