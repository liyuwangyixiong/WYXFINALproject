#!/bin/sh
# Install the already-copied release on a PYNQ-Z2 Linux SD card.
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run as root.' >&2; exit 1; }
pynq_py=/usr/local/share/pynq-venv/bin/python3
[ -x "$pynq_py" ] || { echo 'PYNQ Python environment missing.' >&2; exit 1; }
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
[ "$root" = /boot/wyxfinalproject_latest ] || { echo 'Expected /boot/wyxfinalproject_latest.' >&2; exit 1; }
[ -f "$root/data/sd_copy_manifest.json" ] || { echo 'Missing SD copy manifest.' >&2; exit 1; }
"$pynq_py" -B - "$root" <<'PY'
import hashlib
import json
import platform
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve()
model_path = Path('/proc/device-tree/model')
model = model_path.read_bytes().replace(b'\0', b'').decode('ascii', 'ignore') if model_path.exists() else ''
compatible_path = Path('/proc/device-tree/compatible')
compatible = compatible_path.read_bytes().replace(b'\0', b' ').decode('ascii', 'ignore') if compatible_path.exists() else ''
identity = (model + ' ' + compatible).lower()
if not platform.machine().startswith('arm') or not any(token in identity for token in ('zynq-7000', 'pynq-z2', 'pynq z2')):
    raise SystemExit('Expected the PYNQ-Z2 Zynq-7000 Linux image')
manifest = json.loads((root / 'data/sd_copy_manifest.json').read_text(encoding='utf-8'))
for name, expected in manifest['files'].items():
    path = (root / name).resolve()
    if root not in path.parents or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('SD file differs: ' + name)
from pynq import Bitstream, Clocks
print('SD_PACKAGE_VERIFIED files=' + str(len(manifest['files'])), flush=True)
PY
target=/opt/wyx-current
install -d -m 755 "$target/board" "$target/data"
install -m 644 "$root/board/wyxfinalproject.bit" "$target/board/wyxfinalproject.bit"
install -m 644 "$root/board/load_on_pynq.py" "$target/board/load_on_pynq.py"
install -m 644 "$root/data/source_inventory.json" "$target/data/source_inventory.json"
"$pynq_py" -B - "$target" <<'PY'
import hashlib
import json
import sys
from pathlib import Path
root = Path(sys.argv[1])
expected = json.loads((root / 'data/source_inventory.json').read_text(encoding='utf-8'))['new_bit_sha256']
actual = hashlib.sha256((root / 'board/wyxfinalproject.bit').read_bytes()).hexdigest()
if actual != expected:
    raise SystemExit('Installed bitstream SHA-256 mismatch')
print('INSTALLED_BIT_VERIFIED ' + actual, flush=True)
PY
unit=/etc/systemd/system/wyx-board-loader.service
backup=/etc/systemd/system/wyx-board-loader.service.backup-20261102
if [ -f "$unit" ] && [ ! -e "$backup" ]; then cp -p "$unit" "$backup"; fi
cat > "$unit.new" <<'UNIT'
[Unit]
Description=Load current WYXFINALproject FPGA firmware from SD
After=local-fs.target bootpy.service boot_leds.service rc-local.service
Before=wyx-arm-monitor.service

[Service]
Type=oneshot
User=root
WorkingDirectory=/opt/wyx-current/board
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONIOENCODING=utf-8
Environment=XILINX_XRT=/usr
Environment=BOARD=Pynq-Z2
Environment=VIRTUAL_ENV=/usr/local/share/pynq-venv
Environment=PATH=/usr/local/share/pynq-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/share/pynq-venv/bin/python3 -B /opt/wyx-current/board/load_on_pynq.py
RemainAfterExit=yes
TimeoutStartSec=45

[Install]
WantedBy=multi-user.target
UNIT
mv "$unit.new" "$unit"
systemctl daemon-reload
systemctl enable wyx-board-loader.service
systemctl restart wyx-board-loader.service
systemctl is-active --quiet wyx-board-loader.service
sh "$root/src/arm_monitor/install_on_pynq.sh" --enable
install -d -m 755 /etc/systemd/system/wyx-arm-monitor.service.d
cat > /etc/systemd/system/wyx-arm-monitor.service.d/board.conf <<'UNIT'
[Unit]
Requires=wyx-board-loader.service
After=wyx-board-loader.service
UNIT
systemctl daemon-reload
systemctl restart wyx-arm-monitor.service
systemctl is-active --quiet wyx-arm-monitor.service
sync
echo 'SD_LATEST_PL_AND_ARM_INSTALLED'
echo 'ARM_MONITOR_INPUT_EXTERNAL; PL_TO_ARM_PRODUCER_NOT_IN_THIS_RELEASE'
