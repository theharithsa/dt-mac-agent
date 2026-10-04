#!/bin/bash
# Removes dt-mac-agent from this Mac.
#   sudo dtmacctl uninstall [--keep-config]
#   curl -fsSL https://raw.githubusercontent.com/theharithsa/dt-mac-agent/main/uninstall.sh | sudo bash
set -u

KEEP_CONFIG=0
[ "${1:-}" = "--keep-config" ] && KEEP_CONFIG=1
[ "$(id -u)" -eq 0 ] || { echo "error: run as root (sudo)" >&2; exit 1; }

# Prevent the agent and watchdog from reviving each other during removal.
mkdir -p /var/lib/dt-mac-agent && touch /var/lib/dt-mac-agent/stopped

for l in com.theharithsa.dt-mac-agent.watchdog com.theharithsa.dt-mac-agent; do
  launchctl bootout "system/$l" 2>/dev/null || true
  launchctl enable "system/$l" 2>/dev/null || true
  rm -f "/Library/LaunchDaemons/$l.plist"
done

[ -L /usr/local/bin/dtmacctl ] && rm -f /usr/local/bin/dtmacctl
rm -f /etc/newsyslog.d/dt-mac-agent.conf
rm -rf /usr/local/dt-mac-agent /var/lib/dt-mac-agent /var/log/dt-mac-agent
if [ "$KEEP_CONFIG" -eq 1 ]; then
  echo "kept /etc/dt-mac-agent/config"
else
  rm -rf /etc/dt-mac-agent
fi
echo "dt-mac-agent removed"
