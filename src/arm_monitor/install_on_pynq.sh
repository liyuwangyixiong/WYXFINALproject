#!/bin/sh
set -eu
[ "$(id -u)" -eq 0 ] || { echo 'Run with sudo on PYNQ Linux.' >&2; exit 1; }
case "${1-}" in ''|--enable) ;; *) echo 'Usage: sudo sh install_on_pynq.sh [--enable]' >&2; exit 1;; esac
src=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
py_bin=$(command -v python3)
case "$py_bin" in *[!a-zA-Z0-9/_.-]*) echo 'Python executable path must not contain spaces or special characters.' >&2; exit 1;; esac
"$py_bin" -c 'import sys,sqlite3; assert sys.version_info >= (3,6), "Python 3.6+ required"'
command -v systemctl >/dev/null
getent passwd wyx-monitor >/dev/null || useradd --system --user-group --home /nonexistent --shell /usr/sbin/nologin wyx-monitor
install -d -m 755 /opt/wyx-arm-monitor
install -d -m 750 -o wyx-monitor -g wyx-monitor /var/lib/wyx-arm-monitor
for name in engine.py storage.py monitor.py simulator.py settings.json interface.json; do
    install -m 644 "$src/$name" "/opt/wyx-arm-monitor/$name"
done
if [ ! -e /var/lib/wyx-arm-monitor/input.jsonl ]; then
    install -m 640 -o wyx-monitor -g wyx-monitor /dev/null /var/lib/wyx-arm-monitor/input.jsonl
fi
if [ ! -e /etc/default/wyx-arm-monitor ]; then
    cat > /etc/default/wyx-arm-monitor <<'ENV'
WYX_MODE=external
WYX_INPUT=/var/lib/wyx-arm-monitor/input.jsonl
ENV
    chmod 644 /etc/default/wyx-arm-monitor
fi
cat > /etc/systemd/system/wyx-arm-monitor.service <<UNIT
[Unit]
Description=WYX ARM evidence monitor (no web service)
After=local-fs.target

[Service]
Type=simple
User=wyx-monitor
Group=wyx-monitor
WorkingDirectory=/opt/wyx-arm-monitor
Environment=PYTHONDONTWRITEBYTECODE=1
Environment=PYTHONUNBUFFERED=1
EnvironmentFile=/etc/default/wyx-arm-monitor
ExecStart=$py_bin /opt/wyx-arm-monitor/monitor.py --data-dir /var/lib/wyx-arm-monitor
Restart=on-failure
RestartSec=5
KillSignal=SIGTERM
TimeoutStopSec=10
NoNewPrivileges=true
PrivateTmp=true
UMask=0027

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
if [ "${1-}" = '--enable' ]; then
    systemctl enable wyx-arm-monitor
    systemctl restart wyx-arm-monitor
fi
printf '%s\n' 'Installed. External input only by default; no simulated fallback.' \
    'Append complete JSONL records as the service user, or grant your producer access.' \
    'Start: sudo systemctl start wyx-arm-monitor' \
    'Status: sudo systemctl status wyx-arm-monitor' \
    'Output: sudo journalctl -u wyx-arm-monitor -f' \
    'Stop: sudo systemctl stop wyx-arm-monitor'
