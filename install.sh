#!/bin/bash
# ============================================================
# Brother Scan-to-Paperless installer
# Tested on: Debian 12/13 LXC (Proxmox), Paperless-ngx community script install
# Scanner: Brother DCP-T720DW (brscan5)
# ============================================================

set -e

# ---------- CONFIG — edit these before running ----------
BROTHER_MODEL="DCP-T720DW"
PRINTER_IP="192.168.100.149"
HOST_IP="192.168.100.140"           # IP of this LXC
CONSUME_DIR="/opt/paperless_data/consume"
DISPLAY_NAME="Paperless"
RESOLUTION=300
BRSCAN_VERSION="brscan5"
BRSCAN_DEB_URL="https://download.brother.com/welcome/dlf104033/brscan5-1.5.1-0.amd64.deb"
# --------------------------------------------------------

echo "==> [1/6] Installing dependencies..."
apt-get update -qq
apt-get install -y sane-utils snmp wget git python3

echo "==> [2/6] Installing brscan5 driver..."
TMP_DEB=$(mktemp /tmp/brscan5-XXXXXX.deb)
wget -q "$BRSCAN_DEB_URL" -O "$TMP_DEB"
dpkg -i --force-all "$TMP_DEB"
rm -f "$TMP_DEB"

echo "==> [3/6] Configuring SANE..."
mkdir -p /etc/sane.d
echo "brother5" > /etc/sane.d/dll.conf

echo "==> [4/6] Registering scanner..."
brsaneconfig5 -a name=BROTHER model="$BROTHER_MODEL" ip="$PRINTER_IP" || true
echo "Registered scanners:"
brsaneconfig5 -q | grep BROTHER || echo "(none found — check IP and model)"

echo "==> [5/6] Installing brother-scan-to-paperless daemon..."
REPO_DIR=$(mktemp -d)
git clone --quiet https://github.com/vanessa/brother-scan-to-paperless.git "$REPO_DIR"

mkdir -p /opt/brother-scan-to-paperless
cp "$REPO_DIR/src/brother_scan_daemon.py" /opt/brother-scan-to-paperless/
chmod +x /opt/brother-scan-to-paperless/brother_scan_daemon.py
ln -sf /opt/brother-scan-to-paperless/brother_scan_daemon.py /usr/local/bin/brother-scan-to-paperless
rm -rf "$REPO_DIR"

# Patch: use brscan5 instead of brscan4
sed -i 's/brsaneconfig4/brsaneconfig5/g' /opt/brother-scan-to-paperless/brother_scan_daemon.py
sed -i 's/brother4:net1;dev0/brother5:net1;dev0/g' /opt/brother-scan-to-paperless/brother_scan_daemon.py

# Patch: remove --output-file (not supported by this scanimage version), use stdout redirect
python3 - << 'PYEOF'
import os
path = '/opt/brother-scan-to-paperless/brother_scan_daemon.py'
with open(path, 'r') as f:
    txt = f.read()

old = '            f"--output-file={outfile}",\n        ]\n\n        result = subprocess.run(\n            cmd,\n            capture_output=True,\n            text=True,\n            timeout=config["scan_timeout"],\n        )'
new = '        ]\n\n        with open(outfile, "wb") as out_f:\n            result = subprocess.run(\n                cmd,\n                stdout=out_f,\n                stderr=subprocess.PIPE,\n                timeout=config["scan_timeout"],\n                env={"HOME": "/root", "PATH": "/usr/bin:/bin"},\n            )\n        stderr_text = result.stderr.decode("utf-8", errors="replace")\n        result = type("R", (), {"returncode": result.returncode, "stderr": stderr_text})()'

if old in txt:
    txt = txt.replace(old, new)
    print("  Patched: --output-file removed, stdout redirect applied")
else:
    print("  WARNING: Could not apply output-file patch (upstream may have fixed this)")

with open(path, 'w') as f:
    f.write(txt)
PYEOF

# Patch: add 3s delay before scan (brscan5 needs time after UDP event)
python3 - << 'PYEOF'
path = '/opt/brother-scan-to-paperless/brother_scan_daemon.py'
with open(path, 'r') as f:
    txt = f.read()

old = '    log(f"Starting scan -> {outfile}", log_file)\n\n    try:'
new = '    log(f"Starting scan -> {outfile}", log_file)\n\n    import time; time.sleep(3)\n    try:'

if old in txt:
    txt = txt.replace(old, new)
    print("  Patched: 3s delay added before scan")
else:
    print("  WARNING: Could not apply delay patch")

with open(path, 'w') as f:
    f.write(txt)
PYEOF

# Patch: pass --source FlatBed to scanimage
python3 - << 'PYEOF'
path = '/opt/brother-scan-to-paperless/brother_scan_daemon.py'
with open(path, 'r') as f:
    txt = f.read()

old = "            f\"--format={config['format']}\",\n        ]"
new = "            f\"--format={config['format']}\",\n            f\"--source={config['source']}\",\n        ]"

if old in txt:
    txt = txt.replace(old, new)
    print("  Patched: --source flag added")
else:
    print("  WARNING: Could not apply --source patch")

with open(path, 'w') as f:
    f.write(txt)
PYEOF

echo "==> [6/6] Writing config and installing systemd service..."
mkdir -p /etc/brother-scan-to-paperless
cat > /etc/brother-scan-to-paperless/config.json << EOF
{
  "printer_ip": "$PRINTER_IP",
  "host_ip": "$HOST_IP",
  "listen_port": 54925,
  "consume_dir": "$CONSUME_DIR",
  "scanner_device": "brother5:net1;dev0",
  "resolution": $RESOLUTION,
  "source": "FlatBed",
  "size": "A4",
  "format": "tiff",
  "register_interval": 300,
  "scan_timeout": 120,
  "display_name": "$DISPLAY_NAME",
  "log_file": "/var/log/brother-scan-to-paperless.log"
}
EOF

cat > /etc/systemd/system/brother-scan-to-paperless.service << 'EOF'
[Unit]
Description=Brother Scan to Paperless-ngx Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/brother-scan-to-paperless run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now brother-scan-to-paperless

echo ""
echo "============================================"
echo " Installation complete!"
echo "============================================"
echo " Daemon status:"
systemctl status brother-scan-to-paperless --no-pager -l
echo ""
echo " Config: /etc/brother-scan-to-paperless/config.json"
echo " Logs:   /var/log/brother-scan-to-paperless.log"
echo " Test:   tail -f /var/log/brother-scan-to-paperless.log"
echo "============================================"
