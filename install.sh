#!/bin/bash
# dt-mac-agent installer (macOS, run as root).
#
#   curl -fsSL https://raw.githubusercontent.com/theharithsa/dt-mac-agent/main/install.sh | sudo bash
#
# Optional environment variables:
#   DT_ENV_URL      Dynatrace environment URL (prompted if missing on first install)
#   DT_TOKEN        Dynatrace token (prompted if missing on first install)
#   DTMA_VERSION    release to install (default: latest)
#   DTMA_SKIP_TEST  set to 1 to skip the connection test
set -euo pipefail
export LC_ALL=C

REPO="theharithsa/dt-mac-agent"
PREFIX="/usr/local/dt-mac-agent"
CONF_DIR="/etc/dt-mac-agent"
CONF="$CONF_DIR/config"
STATE_DIR="/var/lib/dt-mac-agent"
LOG_DIR="/var/log/dt-mac-agent"
PLIST_DIR="/Library/LaunchDaemons"
LABELS="com.theharithsa.dt-mac-agent com.theharithsa.dt-mac-agent.watchdog"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "dt-mac-agent supports macOS only"
[ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo bash"

TMP="$(mktemp -d /tmp/dt-mac-agent-install.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. Locate sources: local checkout, otherwise a verified GitHub release ---
SRC=""
script="${BASH_SOURCE[0]:-}"
if [ -n "$script" ] && [ -f "$script" ]; then
  d="$(cd "$(dirname "$script")" && pwd)"
  if [ -f "$d/bin/dt-mac-agent" ] && [ -f "$d/lib/common.sh" ]; then SRC="$d"; fi
fi

if [ -z "$SRC" ]; then
  VERSION="${DTMA_VERSION:-}"
  if [ -z "$VERSION" ]; then
    VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null |
      sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)" || true
    [ -n "$VERSION" ] || die "could not determine the latest release; set DTMA_VERSION"
  fi
  VERSION="${VERSION#v}"
  case "$VERSION" in ''|*[!0-9A-Za-z.-]*) die "invalid version: $VERSION" ;; esac
  base="https://github.com/$REPO/releases/download/v$VERSION"
  tarball="dt-mac-agent-$VERSION.tar.gz"
  say "Downloading dt-mac-agent $VERSION"
  curl -fsSL -o "$TMP/$tarball" "$base/$tarball" || die "download failed: $base/$tarball"
  curl -fsSL -o "$TMP/$tarball.sha256" "$base/$tarball.sha256" || die "checksum download failed"
  expected="$(awk '{print $1}' "$TMP/$tarball.sha256")"
  actual="$(shasum -a 256 "$TMP/$tarball" | awk '{print $1}')"
  [ -n "$expected" ] && [ "$expected" = "$actual" ] || die "SHA-256 mismatch for $tarball"
  say "Checksum verified"
  tar -xzf "$TMP/$tarball" -C "$TMP"
  SRC="$TMP/dt-mac-agent-$VERSION"
  [ -f "$SRC/bin/dt-mac-agent" ] || die "unexpected archive layout"
fi
VERSION="$(cat "$SRC/VERSION")"

# --- 2. Credentials ---
DT_ENV_URL="${DT_ENV_URL:-}"
DT_TOKEN="${DT_TOKEN:-}"

ask() {
  local prompt="$1" secret="$2" answer=""
  { exec 3</dev/tty; } 2>/dev/null || die "no terminal available; pass DT_ENV_URL and DT_TOKEN as environment variables"
  printf '%s' "$prompt" >/dev/tty
  if [ "$secret" = "1" ]; then
    read -r -s answer <&3 || true
    printf '\n' >/dev/tty
  else
    read -r answer <&3 || true
  fi
  exec 3<&-
  printf '%s' "$answer"
}

if [ ! -f "$CONF" ]; then
  [ -n "$DT_ENV_URL" ] || DT_ENV_URL="$(ask 'Dynatrace environment URL (e.g. https://abc12345.apps.dynatrace.com): ' 0)"
  [ -n "$DT_TOKEN" ] || DT_TOKEN="$(ask 'Dynatrace token (input hidden): ' 1)"
  [ -n "$DT_ENV_URL" ] && [ -n "$DT_TOKEN" ] || die "DT_ENV_URL and DT_TOKEN are required"
fi

# Strict validation: the config file is sourced by root.
if [ -n "$DT_ENV_URL" ]; then
  DT_ENV_URL="${DT_ENV_URL%/}"
  printf '%s' "$DT_ENV_URL" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' ||
    die "invalid DT_ENV_URL (expected https://<host>[/path])"
fi
if [ -n "$DT_TOKEN" ]; then
  printf '%s' "$DT_TOKEN" | grep -Eq '^dt0[a-z][0-9]{2}\.[A-Za-z0-9]+\.[A-Za-z0-9]+$' ||
    die "invalid DT_TOKEN format (expected dt0s16.* platform token or dt0c01.* API token)"
fi

# --- 3. Stop running instance (upgrade) ---
for l in $LABELS; do launchctl bootout "system/$l" 2>/dev/null || true; done

# --- 4. Install files ---
say "Installing dt-mac-agent $VERSION to $PREFIX"
mkdir -p "$PREFIX" "$CONF_DIR" "$STATE_DIR" "$LOG_DIR" /usr/local/bin /etc/newsyslog.d
rm -rf "$PREFIX/bin" "$PREFIX/lib"
cp -R "$SRC/bin" "$SRC/lib" "$PREFIX/"
cp "$SRC/VERSION" "$SRC/uninstall.sh" "$PREFIX/"
chown -R root:wheel "$PREFIX"
chmod 755 "$PREFIX" "$PREFIX/bin" "$PREFIX/lib" "$PREFIX"/bin/* "$PREFIX/uninstall.sh"
chmod 644 "$PREFIX"/lib/* "$PREFIX/VERSION"
ln -sf "$PREFIX/bin/dtmacctl" /usr/local/bin/dtmacctl

chown root:wheel "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"
chmod 700 "$CONF_DIR" "$STATE_DIR"
chmod 755 "$LOG_DIR"
rm -f "$STATE_DIR/stopped"

install -m 644 -o root -g wheel "$SRC/etc/newsyslog.d/dt-mac-agent.conf" /etc/newsyslog.d/dt-mac-agent.conf
for l in $LABELS; do
  install -m 644 -o root -g wheel "$SRC/launchd/$l.plist" "$PLIST_DIR/$l.plist"
done

# --- 5. Config (keeps existing settings, replaces only provided credentials) ---
if [ -n "$DT_ENV_URL" ] || [ -n "$DT_TOKEN" ]; then
  umask 077
  new="$CONF_DIR/config.new"
  if [ -f "$CONF" ]; then base_conf="$CONF"; else base_conf="$SRC/etc/config.example"; fi
  drop="__none__"
  if [ -n "$DT_ENV_URL" ]; then drop="$drop|DT_ENV_URL"; fi
  if [ -n "$DT_TOKEN" ]; then drop="$drop|DT_TOKEN"; fi
  {
    grep -v -E "^($drop)=" "$base_conf" || true
    if [ -n "$DT_ENV_URL" ]; then printf 'DT_ENV_URL="%s"\n' "$DT_ENV_URL"; fi
    if [ -n "$DT_TOKEN" ]; then printf 'DT_TOKEN="%s"\n' "$DT_TOKEN"; fi
  } >"$new"
  mv -f "$new" "$CONF"
  say "Wrote $CONF"
fi
chown root:wheel "$CONF"
chmod 600 "$CONF"

# --- 6. Connection test ---
if [ "${DTMA_SKIP_TEST:-0}" != "1" ]; then
  say "Testing connection to Dynatrace"
  "$PREFIX/bin/dtmacctl" send-test ||
    die "connection test failed; agent NOT started. Fix credentials and re-run, e.g. curl ... | sudo DT_TOKEN=<token> bash"
fi

# --- 7. Start agent and watchdog ---
for l in $LABELS; do
  launchctl enable "system/$l"
  ok=0
  for _ in 1 2 3 4 5; do
    if launchctl bootstrap system "$PLIST_DIR/$l.plist" 2>/dev/null; then ok=1; break; fi
    sleep 1
  done
  [ "$ok" -eq 1 ] || die "failed to load launchd job $l"
done

say "dt-mac-agent $VERSION installed and running"
cat <<EOF

  Status : sudo dtmacctl status
  Logs   : sudo dtmacctl logs -f
  Preview: dtmacctl test
  Remove : sudo dtmacctl uninstall

Metrics appear in Dynatrace under '$(sed -n 's/^METRIC_PREFIX="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$CONF" | tail -n 1).*' within ~2 minutes.
EOF
