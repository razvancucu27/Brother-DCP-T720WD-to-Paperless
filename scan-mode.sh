#!/bin/bash
# ============================================================
# Brother Scan Mode Switcher
# Switches between FlatBed and ADF scanning modes
# Usage: bash scan-mode.sh [flatbed|adf|status]
# ============================================================

CONFIG="/etc/brother-scan-to-paperless/config.json"
DAEMON="/opt/brother-scan-to-paperless/brother_scan_daemon.py"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

FLATBED_SOURCE="FlatBed"
ADF_SOURCE="Automatic Document Feeder(left aligned)"
DEBOUNCE_FLATBED=35
DEBOUNCE_ADF=3

current_source() {
    python3 -c "import json; d=json.load(open('$CONFIG')); print(d['source'])"
}

current_debounce() {
    grep "last_scan_time > " "$DAEMON" | grep -oP '\d+' | head -1
}

set_source() {
    local source="$1"
    python3 - << PYEOF
import json
with open('$CONFIG', 'r') as f:
    config = json.load(f)
config['source'] = '$source'
with open('$CONFIG', 'w') as f:
    json.dump(config, f, indent=2)
print("Source updated to: $source")
PYEOF
}

set_debounce() {
    local seconds="$1"
    local current=$(current_debounce)
    sed -i "s/if now - last_scan_time > ${current}:/if now - last_scan_time > ${seconds}:/" "$DAEMON"
    echo "Debounce updated to: ${seconds}s"
}

show_status() {
    local source=$(current_source)
    local debounce=$(current_debounce)
    echo -e "${CYAN}============================================${NC}"
    echo -e " Current scan mode"
    echo -e "${CYAN}============================================${NC}"
    echo -e " Source:   ${GREEN}${source}${NC}"
    echo -e " Debounce: ${GREEN}${debounce}s${NC}"
    echo -e "${CYAN}============================================${NC}"
}

switch_to_flatbed() {
    echo -e "${YELLOW}Switching to FlatBed mode...${NC}"
    set_source "$FLATBED_SOURCE"
    set_debounce "$DEBOUNCE_FLATBED"
    systemctl restart brother-scan-to-paperless
    echo -e "${GREEN}Done! FlatBed mode active.${NC}"
    echo -e " - Scans one page at a time"
    echo -e " - Say 'No' to next page prompt after each scan"
    echo -e " - Debounce: ${DEBOUNCE_FLATBED}s (prevents duplicate from 'No' button)"
    show_status
}

switch_to_adf() {
    echo -e "${YELLOW}Switching to ADF mode...${NC}"
    set_source "$ADF_SOURCE"
    set_debounce "$DEBOUNCE_ADF"
    systemctl restart brother-scan-to-paperless
    echo -e "${GREEN}Done! ADF mode active.${NC}"
    echo -e " - Place all pages in the ADF tray"
    echo -e " - All pages scanned automatically in one file"
    echo -e " - Debounce: ${DEBOUNCE_ADF}s"
    show_status
}

# ---- Main ----
case "${1,,}" in
    flatbed|fb)
        switch_to_flatbed
        ;;
    adf)
        switch_to_adf
        ;;
    status|"")
        show_status
        ;;
    *)
        echo -e "${RED}Usage:${NC} bash scan-mode.sh [flatbed|adf|status]"
        echo ""
        echo "  flatbed   Switch to FlatBed mode (single page, debounce 35s)"
        echo "  adf       Switch to ADF mode (multi-page, debounce 3s)"
        echo "  status    Show current mode"
        exit 1
        ;;
esac
