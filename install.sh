#!/bin/bash
# ============================================================
# Brother DCP-T720DW → Paperless-ngx installer
# Scan-to-Paperless daemon installer
#
# Tested on:
#   - Debian 12/13 LXC (Proxmox VE)
#   - Paperless-ngx installed via community-scripts
#   - Brother DCP-T720DW (brscan5 driver)
#
# Usage:
#   wget -O install.sh https://raw.githubusercontent.com/razvancucu27/Brother-DCP-T720WD-to-Paperless/main/install.sh
#   chmod +x install.sh
#   nano install.sh        # edit the CONFIG block below
#   bash install.sh
# ============================================================

set -e

# ============================================================
# CONFIG — edit these values before running
# ============================================================
BROTHER_MODEL="DCP-T720DW"
PRINTER_IP="192.168.100.149"        # Brother printer IP
HOST_IP="192.168.100.140"           # IP of this LXC / machine
CONSUME_DIR="/opt/paperless_data/consume"
DISPLAY_NAME="Paperless"            # Name shown on printer LCD
RESOLUTION=300                      # DPI (300 recommended for OCR)
SCAN_SOURCE="FlatBed"               # FlatBed | Automatic Document Feeder(left aligned)
BRSCAN_DEB_URL="https://download.brother.com/welcome/dlf104033/brscan5-1.5.1-0.amd64.deb"
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}==>${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }

# ---- Preflight checks ----------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo -e "${RED}[ERROR]${NC} This script must be run as root." && exit 1
fi

if [[ ! -d "$CONSUME_DIR" ]]; then
  echo -e "${RED}[ERROR]${NC} Consume directory not found: $CONSUME_DIR"
  echo "  Set CONSUME_DIR to your Paperless consume path and re-run."
  exit 1
fi

# ---- Step 1: Dependencies ------------------------------------
info "[1/6] Installing dependencies..."
apt-get update -qq
apt-get install -y sane-utils snmp wget git python3 img2pdf
success "Dependencies installed"

# ---- Step 2: brscan5 driver ----------------------------------
info "[2/6] Installing brscan5 driver..."
TMP_DEB=$(mktemp /tmp/brscan5-XXXXXX.deb)
wget -q "$BRSCAN_DEB_URL" -O "$TMP_DEB"
dpkg -i --force-all "$TMP_DEB"
rm -f "$TMP_DEB"
success "brscan5 driver installed"

# ---- Step 3: SANE configuration ------------------------------
info "[3/6] Configuring SANE..."
mkdir -p /etc/sane.d
echo "brother5" > /etc/sane.d/dll.conf
success "SANE configured"

# ---- Step 4: Register scanner --------------------------------
info "[4/6] Registering scanner with brsaneconfig5..."
brsaneconfig5 -a name=BROTHER model="$BROTHER_MODEL" ip="$PRINTER_IP" || \
  warn "Scanner may already be registered — continuing"
echo "  Registered scanners:"
brsaneconfig5 -q | grep BROTHER || warn "No scanner found — check PRINTER_IP and BROTHER_MODEL"

# ---- Step 5: Install daemon ----------------------------------
info "[5/6] Installing brother-scan-to-paperless daemon..."

REPO_DIR=$(mktemp -d)
git clone --quiet https://github.com/vanessa/brother-scan-to-paperless.git "$REPO_DIR"

mkdir -p /opt/brother-scan-to-paperless
cp "$REPO_DIR/src/brother_scan_daemon.py" /opt/brother-scan-to-paperless/
chmod +x /opt/brother-scan-to-paperless/brother_scan_daemon.py
ln -sf /opt/brother-scan-to-paperless/brother_scan_daemon.py /usr/local/bin/brother-scan-to-paperless
rm -rf "$REPO_DIR"

# Patch 1: use brscan5 instead of brscan4
sed -i 's/brsaneconfig4/brsaneconfig5/g' /opt/brother-scan-to-paperless/brother_scan_daemon.py
sed -i 's/brother4:net1;dev0/brother5:net1;dev0/g' /opt/brother-scan-to-paperless/brother_scan_daemon.py
success "Patched: brscan4 → brscan5"

# Patch 2: replace --output-file with stdout redirect + clean env
# (--output-file is unsupported by sane-backends 1.2.1 on Debian trixie)
# Patch 3: add 3s delay before scan (brscan5 timing bug)
# Patch 4: add --source flag
# Patch 5: ADF batch mode for multi-page scanning
python3 - << 'PYEOF'
with open('/opt/brother-scan-to-paperless/brother_scan_daemon.py', 'r') as f:
    txt = f.read()

old = '''def do_scan(config: dict) -> bool:
    """Run scanimage and save to the consume folder."""
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    ext = config["format"]
    outfile = os.path.join(config["consume_dir"], f"scan_{timestamp}.{ext}")
    log_file = config.get("log_file")
    log(f"Starting scan -> {outfile}", log_file)
    try:
        cmd = [
            "scanimage",
            f"--device-name={config['scanner_device']}",
            f"--resolution={config['resolution']}",
            f"--format={config['format']}",
            f"--output-file={outfile}",
        ]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=config["scan_timeout"],
        )'''

new = '''def do_scan(config: dict) -> bool:
    """Run scanimage and save to the consume folder."""
    import time
    import glob
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    ext = config["format"]
    source = config.get("source", "FlatBed")
    is_adf = "feeder" in source.lower() or "adf" in source.lower()
    outfile = os.path.join(config["consume_dir"], f"scan_{timestamp}.{ext}")
    log_file = config.get("log_file")
    log(f"Starting scan -> {outfile} (source: {source})", log_file)
    time.sleep(3)
    try:
        if is_adf:
            # ADF batch mode - scan all pages
            batch_dir = f"/tmp/scan_{timestamp}"
            os.makedirs(batch_dir, exist_ok=True)
            batch_pattern = f"{batch_dir}/page%04d.tiff"
            cmd = [
                "scanimage",
                f"--device-name={config['scanner_device']}",
                f"--resolution={config['resolution']}",
                "--format=tiff",
                f"--source={source}",
                "--batch=" + batch_pattern,
                "--batch-start=1",
            ]
            result = subprocess.run(
                cmd,
                stderr=subprocess.PIPE,
                timeout=config["scan_timeout"],
                env={"HOME": "/root", "PATH": "/usr/bin:/bin"},
            )
            stderr_text = result.stderr.decode("utf-8", errors="replace")
            pages = sorted(glob.glob(f"{batch_dir}/page*.tiff"))
            if not pages:
                log(f"Scan failed: no pages produced. stderr={stderr_text.strip()}", log_file)
                return False
            if len(pages) == 1:
                import shutil
                shutil.move(pages[0], outfile)
            else:
                pdf_out = outfile.replace(".tiff", ".pdf")
                merge = subprocess.run(
                    ["img2pdf"] + pages + ["-o", pdf_out],
                    stderr=subprocess.PIPE,
                    env={"HOME": "/root", "PATH": "/usr/bin:/bin"},
                )
                if merge.returncode == 0:
                    outfile = pdf_out
                    for p in pages: os.remove(p)
                else:
                    import shutil
                    shutil.move(pages[0], outfile)
                    log(f"img2pdf merge failed, using first page only", log_file)
            import shutil
            shutil.rmtree(batch_dir, ignore_errors=True)
            size = os.path.getsize(outfile)
            log(f"Scan complete: {outfile} ({size:,} bytes, {len(pages)} page(s))", log_file)
            return True
        else:
            # FlatBed single page mode
            cmd = [
                "scanimage",
                f"--device-name={config['scanner_device']}",
                f"--resolution={config['resolution']}",
                f"--format={config['format']}",
                f"--source={source}",
            ]
            with open(outfile, "wb") as out_f:
                result = subprocess.run(
                    cmd,
                    stdout=out_f,
                    stderr=subprocess.PIPE,
                    timeout=config["scan_timeout"],
                    env={"HOME": "/root", "PATH": "/usr/bin:/bin"},
                )
            stderr_text = result.stderr.decode("utf-8", errors="replace")
            result = type("R", (), {"returncode": result.returncode, "stderr": stderr_text})()'''

if old in txt:
    txt = txt.replace(old, new)
    with open('/opt/brother-scan-to-paperless/brother_scan_daemon.py', 'w') as f:
        f.write(txt)
    print("  [OK] Patched: stdout redirect, 3s delay, --source flag, ADF batch mode")
else:
    print("  [WARN] Could not apply main patch (upstream may have changed)")

with open('/opt/brother-scan-to-paperless/brother_scan_daemon.py', 'r') as f:
    txt = f.read()
PYEOF

# Patch 6: debounce to prevent duplicate scans on flatbed
python3 - << 'PYEOF'
with open('/opt/brother-scan-to-paperless/brother_scan_daemon.py', 'r') as f:
    txt = f.read()

old = '            if "BUTTON=SCAN" in msg:\n                do_scan(config)'
new = ('            if "BUTTON=SCAN" in msg:\n'
       '                now = time.time()\n'
       '                if now - last_scan_time > 35:\n'
       '                    last_scan_time = now\n'
       '                    do_scan(config)\n'
       '                else:\n'
       '                    log("Duplicate scan event ignored (debounce)", log_file)')

if old in txt:
    txt = txt.replace(old, new)
    with open('/opt/brother-scan-to-paperless/brother_scan_daemon.py', 'w') as f:
        f.write(txt)
    print("  [OK] Patched: debounce added")
else:
    print("  [WARN] Could not apply debounce patch")
PYEOF

# Initialize last_scan_time variable
sed -i 's/    last_register = time.time()/    last_register = time.time()\n    last_scan_time = 0/' \
    /opt/brother-scan-to-paperless/brother_scan_daemon.py

success "All patches applied"

# ---- Step 6: Config + systemd service -----------------------
info "[6/6] Writing config and systemd service..."

mkdir -p /etc/brother-scan-to-paperless
cat > /etc/brother-scan-to-paperless/config.json << EOF
{
  "printer_ip": "$PRINTER_IP",
  "host_ip": "$HOST_IP",
  "listen_port": 54925,
  "consume_dir": "$CONSUME_DIR",
  "scanner_device": "brother5:net1;dev0",
  "resolution": $RESOLUTION,
  "source": "$SCAN_SOURCE",
  "size": "A4",
  "format": "tiff",
  "register_interval": 300,
  "scan_timeout": 120,
  "display_name": "$DISPLAY_NAME",
  "log_file": "/var/log/brother-scan-to-paperless.log"
}
EOF

cat > /etc/systemd/system/brother-scan-to-paperless.service << 'SVCEOF'
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
SVCEOF

# Install scan-mode.sh switcher
wget -q -O /usr/local/bin/scan-mode.sh \
  https://raw.githubusercontent.com/razvancucu27/Brother-DCP-T720WD-to-Paperless/main/scan-mode.sh
chmod +x /usr/local/bin/scan-mode.sh

systemctl daemon-reload
systemctl enable --now brother-scan-to-paperless

# ---- Done ---------------------------------------------------
echo ""
echo "============================================"
echo -e " ${GREEN}Installation complete!${NC}"
echo "============================================"
echo " Scanner:  $BROTHER_MODEL @ $PRINTER_IP"
echo " Consume:  $CONSUME_DIR"
echo " Source:   $SCAN_SOURCE"
echo ""
echo " Daemon status:"
systemctl status brother-scan-to-paperless --no-pager -l
echo ""
echo " Useful commands:"
echo "   tail -f /var/log/brother-scan-to-paperless.log"
echo "   systemctl restart brother-scan-to-paperless"
echo "   scan-mode.sh [flatbed|adf|status]"
echo "============================================"
echo ""
echo " Scan modes:"
echo "   scan-mode.sh flatbed   Single page from glass (35s debounce)"
echo "   scan-mode.sh adf       Multi-page from ADF tray (3s debounce)"
echo "   scan-mode.sh status    Show current mode"
echo "============================================"
