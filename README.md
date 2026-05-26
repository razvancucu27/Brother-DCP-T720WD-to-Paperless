# Brother DCP-T720DW → Paperless-ngx

One-script installer that connects a **Brother DCP-T720DW** scanner to a **Paperless-ngx** instance running in a Proxmox LXC, so pressing the Scan button on the printer automatically drops a TIFF into Paperless for OCR and indexing.

---

## How it works

1. The daemon listens on **UDP port 54925** for scan button events from the printer
2. When triggered, it calls `scanimage` (brscan5 backend) to scan the document
3. The resulting TIFF is saved directly to the Paperless **consume directory**
4. Paperless picks it up, runs OCR, and indexes it automatically

```
[Brother DCP-T720DW]
      |  UDP :54925
      ▼
[brother-scan-to-paperless daemon]
      |  scanimage (brscan5)
      ▼
[/opt/paperless_data/consume/]
      |
      ▼
[Paperless-ngx OCR + index]
```

---

## Requirements

- Debian 12 or 13 (tested on Proxmox LXC with community-scripts install)
- Paperless-ngx installed and running
- Brother DCP-T720DW on the same network/VLAN as the LXC
- Root access inside the LXC

---

## Quick install

```bash
wget -O install.sh https://raw.githubusercontent.com/razvancucu27/Brother-DCP-T720WD-to-Paperless/main/install.sh && chmod +x install.sh && nano install.sh && bash install.sh
```

### CONFIG block (edit before running)

| Variable | Description | Example |
|---|---|---|
| `BROTHER_MODEL` | Your Brother model name | `DCP-T720DW` |
| `PRINTER_IP` | Printer's static IP | `192.168.100.149` |
| `HOST_IP` | IP of the LXC running Paperless | `192.168.100.140` |
| `CONSUME_DIR` | Paperless consume directory | `/opt/paperless_data/consume` |
| `DISPLAY_NAME` | Name shown on printer LCD | `Paperless` |
| `RESOLUTION` | Scan resolution in DPI | `300` |
| `SCAN_SOURCE` | Scan source (see below) | `FlatBed` |

---

## Switching between FlatBed and ADF

Use the included `scan-mode.sh` script to switch scan modes without manually editing config files.

```bash
# Show current mode
bash scan-mode.sh status

# Switch to FlatBed (single page, 35s debounce)
bash scan-mode.sh flatbed

# Switch to ADF (multi-page, 3s debounce)
bash scan-mode.sh adf
```

### FlatBed mode
- Scans one page at a time from the glass
- After scanning, the printer asks if you want to scan another page — say **No**
- A 35s debounce prevents the "No" button from triggering a duplicate scan

### ADF mode
- Place all pages in the top tray
- All pages are scanned automatically in a single file
- No page prompts — the ADF handles everything

### Scan source options (manual)

If you prefer to edit the config directly:

| Value | Description |
|---|---|
| `FlatBed` | Flatbed glass |
| `Automatic Document Feeder(left aligned)` | ADF top tray |
| `Automatic Document Feeder(center aligned)` | ADF center aligned |

To check what your scanner supports:
```bash
scanimage --device-name="brother5:net1;dev0" -A 2>&1 | grep -i source
```

---

## Useful commands

```bash
# View live logs
tail -f /var/log/brother-scan-to-paperless.log

# Restart daemon
systemctl restart brother-scan-to-paperless

# Check daemon status
systemctl status brother-scan-to-paperless

# Edit config
nano /etc/brother-scan-to-paperless/config.json

# Test scanner manually
scanimage --device-name="brother5:net1;dev0" --resolution=300 --format=tiff > /tmp/test.tiff

# Switch scan mode
bash scan-mode.sh [flatbed|adf|status]
```

---

## Patches applied

The installer applies 4 patches to the upstream [vanessa/brother-scan-to-paperless](https://github.com/vanessa/brother-scan-to-paperless) daemon to fix compatibility with the Brother DCP-T720DW and Debian trixie:

| Patch | Reason |
|---|---|
| brscan4 → brscan5 | DCP-T720DW requires brscan5 driver |
| Remove `--output-file` flag | Not supported by sane-backends 1.2.1 on Debian trixie; use stdout redirect instead |
| Add 3s delay before scan | brscan5 crashes with `std::logic_error` if `scanimage` is called immediately after the UDP event |
| Add `--source` flag | Prevents "document jam" error when scanning from flatbed |

---

## Troubleshooting

**"No PC found" on printer display**
- Check that UDP port 54925 is reachable from the printer
- Ensure printer and LXC are on the same VLAN
- Verify with: `ss -ulnp | grep 54925`

**Scan fails with `std::logic_error`**
- This is the brscan5 timing bug — the 3s delay patch should fix it
- If it persists, increase `time.sleep(3)` in the daemon

**Document jam error on flatbed**
- Set `"source": "FlatBed"` in `/etc/brother-scan-to-paperless/config.json`
- Or run: `bash scan-mode.sh flatbed`

**Duplicate documents in Paperless**
- Enable duplicate detection in Paperless: `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true`
- Or switch to FlatBed mode which has a 35s debounce: `bash scan-mode.sh flatbed`

**Daemon not starting**
```bash
journalctl -u brother-scan-to-paperless -n 50
```

---

## Credits

- Upstream daemon: [vanessa/brother-scan-to-paperless](https://github.com/vanessa/brother-scan-to-paperless)
- brscan5 driver: [Brother Industries](https://support.brother.com)
