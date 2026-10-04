#!/bin/bash
# dt-mac-agent installer (macOS, run as root).
#
#   curl -fsSL https://raw.githubusercontent.com/theharithsa/dt-mac-agent/main/install.sh | sudo bash
#
# Every prompt can be answered up front with an environment variable (needed for unattended installs):
#   DT_ENV_URL         Dynatrace environment URL, e.g. https://abc12345.live.dynatrace.com
#   DT_TOKEN           Dynatrace token (dt0s16.* platform token or dt0c01.* API token)
#   DTMA_PREFIX        install location (default: /usr/local/dt-mac-agent)
#   DTMA_SEND_LOGS     1 = also send the agent's own logs to Dynatrace (default: 0)
#   DTMA_AUTO_UPDATE   1 = install new releases automatically, checked daily (default: 1)
#   DTMA_VERSION       release to install (default: latest)
#   DTMA_SKIP_TEST     1 = skip the connection test
set -euo pipefail
export LC_ALL=C

REPO="theharithsa/dt-mac-agent"
DEFAULT_PREFIX="/usr/local/dt-mac-agent"
CONF_DIR="/etc/dt-mac-agent"
CONF="$CONF_DIR/config"
STATE_DIR="/var/lib/dt-mac-agent"
LOG_DIR="/Library/Logs/dt-mac-agent"
PLIST_DIR="/Library/LaunchDaemons"
AGENT_LABEL="com.theharithsa.dt-mac-agent"
WD_LABEL="com.theharithsa.dt-mac-agent.watchdog"
UPDATE="${DTMA_UPDATE:-0}"

say() { printf '%s [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*"; }
warn() { printf '%s [WARN] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >&2; }
die() { printf '%s [ERROR] %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "dt-mac-agent supports macOS only"
[ "$(id -u)" -eq 0 ] || die "run as root: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sudo bash"

# Mirror all installer output into install.log (readable by admin users).
mkdir -p "$LOG_DIR"
chown root:wheel "$LOG_DIR"
chmod 755 "$LOG_DIR"
touch "$LOG_DIR/install.log"
chown root:admin "$LOG_DIR/install.log"
chmod 640 "$LOG_DIR/install.log"
exec > >(tee -a "$LOG_DIR/install.log") 2>&1
if [ "$UPDATE" = "1" ]; then mode="automatic update"; else mode="install"; fi
say "dt-mac-agent installer started ($mode; user: ${SUDO_USER:-root}, macOS $(sw_vers -productVersion), $(uname -m))"

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
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then die "SHA-256 mismatch for $tarball"; fi
  say "Checksum verified"
  tar -xzf "$TMP/$tarball" -C "$TMP"
  SRC="$TMP/dt-mac-agent-$VERSION"
  [ -f "$SRC/bin/dt-mac-agent" ] || die "unexpected archive layout"
fi
VERSION="$(cat "$SRC/VERSION")"

# --- 2. Gather settings (environment variables first, then interactive prompts) ---
existing_prefix=""
if [ -f "$PLIST_DIR/$AGENT_LABEL.plist" ]; then
  existing_prefix="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$PLIST_DIR/$AGENT_LABEL.plist" 2>/dev/null |
    sed 's#/bin/dt-mac-agent$##')" || true
fi

conf_get() { [ -f "$CONF" ] && sed -n "s/^$1=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$CONF" | tail -n 1; }

INTERACTIVE=0
if [ "$UPDATE" != "1" ] && (exec </dev/tty) 2>/dev/null; then
  exec 3</dev/tty
  INTERACTIVE=1
fi

ask() {
  local prompt="$1" default="$2" secret="${3:-0}" a=""
  printf '%s' "$prompt" >/dev/tty
  if [ "$secret" = "1" ]; then
    read -r -s a <&3 || true
    printf '\n' >/dev/tty
  else
    read -r a <&3 || true
  fi
  ANSWER="${a:-$default}"
}

yes_no() {
  local hint="[y/N]"
  [ "$2" = "1" ] && hint="[Y/n]"
  ask "$1 $hint: " ""
  case "$ANSWER" in
    [Yy]*) ANSWER=1 ;;
    [Nn]*) ANSWER=0 ;;
    *) ANSWER="$2" ;;
  esac
}

# Install location
PREFIX="${DTMA_PREFIX:-}"
if [ -z "$PREFIX" ]; then
  PREFIX="${existing_prefix:-$DEFAULT_PREFIX}"
  if [ "$INTERACTIVE" = "1" ]; then
    ask "Install location [$PREFIX]: " "$PREFIX"
    PREFIX="$ANSWER"
  fi
fi
PREFIX="${PREFIX%/}"

# Dynatrace credentials (only asked on first install; pass DT_TOKEN to rotate)
DT_ENV_URL="${DT_ENV_URL:-}"
DT_TOKEN="${DT_TOKEN:-}"
if [ ! -f "$CONF" ]; then
  if [ "$INTERACTIVE" = "1" ]; then
    [ -n "$DT_ENV_URL" ] || { ask "Dynatrace environment URL (e.g. https://abc12345.live.dynatrace.com): " ""; DT_ENV_URL="$ANSWER"; }
    [ -n "$DT_TOKEN" ] || { ask "Dynatrace token (input hidden): " "" 1; DT_TOKEN="$ANSWER"; }
  fi
  if [ -z "$DT_ENV_URL" ] || [ -z "$DT_TOKEN" ]; then die "DT_ENV_URL and DT_TOKEN are required"; fi
fi

# Optional features: asked on first install, or when upgrading from a version without the setting.
SEND_LOGS="${DTMA_SEND_LOGS:-}"
if [ -z "$SEND_LOGS" ]; then
  SEND_LOGS="$(conf_get SEND_LOGS || true)"
  if [ -z "$SEND_LOGS" ]; then
    SEND_LOGS=0
    if [ "$INTERACTIVE" = "1" ]; then
      yes_no "Also send the agent's own logs (agent, ingest, watchdog, install) to Dynatrace?" 0
      SEND_LOGS="$ANSWER"
    fi
  fi
fi
AUTO_UPDATE="${DTMA_AUTO_UPDATE:-}"
if [ -z "$AUTO_UPDATE" ]; then
  AUTO_UPDATE="$(conf_get AUTO_UPDATE || true)"
  if [ -z "$AUTO_UPDATE" ]; then
    AUTO_UPDATE=1
    if [ "$INTERACTIVE" = "1" ]; then
      yes_no "Install new releases automatically (checked once a day)?" 1
      AUTO_UPDATE="$ANSWER"
    fi
  fi
fi
[ "$INTERACTIVE" = "1" ] && exec 3<&-

# --- 3. Validate (the config is sourced by root and the program runs as root) ---
if [ -n "$DT_ENV_URL" ]; then
  DT_ENV_URL="${DT_ENV_URL%/}"
  printf '%s' "$DT_ENV_URL" | grep -Eq '^https://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$' ||
    die "invalid DT_ENV_URL (expected https://<host>[/path])"
fi
if [ -n "$DT_TOKEN" ]; then
  printf '%s' "$DT_TOKEN" | grep -Eq '^dt0[a-z][0-9]{2}\.[A-Za-z0-9]+\.[A-Za-z0-9]+$' ||
    die "invalid DT_TOKEN format (expected dt0s16.* platform token or dt0c01.* API token)"
fi
case "$SEND_LOGS" in 0|1) ;; *) die "DTMA_SEND_LOGS must be 0 or 1" ;; esac
case "$AUTO_UPDATE" in 0|1) ;; *) die "DTMA_AUTO_UPDATE must be 0 or 1" ;; esac

printf '%s' "$PREFIX" | grep -Eq '^(/[A-Za-z0-9._-]+){2,}$' ||
  die "invalid install location '$PREFIX' (absolute path with at least two levels; letters, digits, '.', '_' and '-' only)"
case "$PREFIX" in
  /System/*|/bin/*|/sbin/*|/usr/bin/*|/usr/sbin/*|/usr/lib/*|/usr/libexec/*|/private/*|/tmp/*|/var/*|/etc/*|/Volumes/*|/Users/*)
    die "install location '$PREFIX' is not allowed; use e.g. /usr/local/dt-mac-agent or /opt/dt-mac-agent" ;;
esac
if [ -e "$PREFIX" ] && [ ! -f "$PREFIX/.dt-mac-agent" ] && [ -n "$(ls -A "$PREFIX" 2>/dev/null)" ] &&
  [ "$PREFIX" != "$existing_prefix" ]; then
  die "$PREFIX already exists and is not empty; choose a dedicated directory"
fi
# Every parent must be root-owned and not group/world-writable, otherwise a user could swap root-run scripts.
d="$(dirname "$PREFIX")"
while [ "$d" != "/" ]; do
  if [ -e "$d" ]; then
    owner="$(stat -f '%u' "$d")"
    perm="$(stat -f '%Lp' "$d")"
    if [ "$owner" != "0" ] || [ $((8#$perm & 022)) -ne 0 ]; then
      die "parent directory $d must be owned by root and not writable by group/others"
    fi
  fi
  d="$(dirname "$d")"
done

say "Settings: location=$PREFIX, send logs=$SEND_LOGS, auto-update=$AUTO_UPDATE"

# --- 4. Stop running instance ---
launchctl bootout "system/$AGENT_LABEL" 2>/dev/null || true
# During an automatic update this script runs as a child of the watchdog, so the watchdog stays loaded.
[ "$UPDATE" = "1" ] || launchctl bootout "system/$WD_LABEL" 2>/dev/null || true

# --- 5. Install files ---
say "Installing dt-mac-agent $VERSION to $PREFIX"
mkdir -p "$PREFIX" "$CONF_DIR" "$STATE_DIR" /usr/local/bin /etc/newsyslog.d
# Remove before copying so running scripts keep reading their old inode.
rm -rf "${PREFIX:?}/bin" "${PREFIX:?}/lib"
cp -R "$SRC/bin" "$SRC/lib" "$PREFIX/"
cp "$SRC/VERSION" "$SRC/uninstall.sh" "$PREFIX/"
touch "$PREFIX/.dt-mac-agent"
chown -R root:wheel "$PREFIX"
chmod 755 "$PREFIX" "$PREFIX/bin" "$PREFIX/lib" "$PREFIX"/bin/* "$PREFIX/uninstall.sh"
chmod 644 "$PREFIX"/lib/* "$PREFIX/VERSION" "$PREFIX/.dt-mac-agent"
ln -sf "$PREFIX/bin/dtmacctl" /usr/local/bin/dtmacctl

chown root:wheel "$CONF_DIR" "$STATE_DIR"
chmod 700 "$CONF_DIR" "$STATE_DIR"
rm -f "$STATE_DIR/stopped"
date +%s >"$STATE_DIR/update.checked"
if [ -d /var/log/dt-mac-agent ]; then
  rm -rf /var/log/dt-mac-agent
  say "Removed legacy log directory /var/log/dt-mac-agent"
fi

install -m 644 -o root -g wheel "$SRC/etc/newsyslog.d/dt-mac-agent.conf" /etc/newsyslog.d/dt-mac-agent.conf
reload_wd=0
for l in "$AGENT_LABEL" "$WD_LABEL"; do
  sed "s#@PREFIX@#$PREFIX#g" "$SRC/launchd/$l.plist.in" >"$TMP/$l.plist"
  if [ "$l" = "$WD_LABEL" ] && [ "$UPDATE" = "1" ] && ! cmp -s "$TMP/$l.plist" "$PLIST_DIR/$l.plist"; then reload_wd=1; fi
  install -m 644 -o root -g wheel "$TMP/$l.plist" "$PLIST_DIR/$l.plist"
done

# --- 6. Config (keeps existing settings, replaces only what was provided) ---
umask 077
: >"$TMP/set"
[ -n "$DT_ENV_URL" ] && printf 'DT_ENV_URL="%s"\n' "$DT_ENV_URL" >>"$TMP/set"
[ -n "$DT_TOKEN" ] && printf 'DT_TOKEN="%s"\n' "$DT_TOKEN" >>"$TMP/set"
printf 'SEND_LOGS=%s\nAUTO_UPDATE=%s\n' "$SEND_LOGS" "$AUTO_UPDATE" >>"$TMP/set"
keys="$(cut -d= -f1 "$TMP/set" | paste -sd'|' -)"
if [ -f "$CONF" ]; then base_conf="$CONF"; else base_conf="$SRC/etc/config.example"; fi
{ grep -v -E "^($keys)=" "$base_conf" || true; cat "$TMP/set"; } >"$CONF_DIR/config.new"
mv -f "$CONF_DIR/config.new" "$CONF"
chown root:wheel "$CONF"
chmod 600 "$CONF"
say "Updated $CONF"

# --- 7. Connection test ---
if [ "${DTMA_SKIP_TEST:-0}" != "1" ]; then
  say "Testing connection to Dynatrace"
  "$PREFIX/bin/dtmacctl" send-test ||
    die "connection test failed; agent NOT started. Fix the token permissions/URL and re-run the installer."
fi

# --- 8. Remove a previous installation from another location ---
if [ -n "$existing_prefix" ] && [ "$existing_prefix" != "$PREFIX" ] &&
  [ -f "$existing_prefix/bin/dt-mac-agent" ] && [ -f "$existing_prefix/VERSION" ]; then
  rm -rf "$existing_prefix"
  say "Removed previous installation at $existing_prefix"
fi

# --- 9. Start ---
bootstrap() {
  local l="$1" i
  launchctl enable "system/$l"
  for i in 1 2 3 4 5; do
    launchctl bootstrap system "$PLIST_DIR/$l.plist" 2>/dev/null && return 0
    sleep "$i"
  done
  return 1
}
rm -f "$STATE_DIR/last_status" "$STATE_DIR/logship.status"
bootstrap "$AGENT_LABEL" || die "failed to load launchd job $AGENT_LABEL"
if [ "$UPDATE" != "1" ]; then
  bootstrap "$WD_LABEL" || die "failed to load launchd job $WD_LABEL"
fi

# --- 10. Verify the running agent really reaches Dynatrace ---
env_url="$(conf_get DT_ENV_URL || true)"
say "Verifying connectivity: waiting for the agent's first metric batch to reach $env_url"
st=""
for _ in $(seq 1 60); do
  st="$(cat "$STATE_DIR/last_status" 2>/dev/null || true)"
  [ -n "$st" ] && break
  sleep 1
done
[ -n "$st" ] || die "the agent did not send its first batch within 60s; check 'dtmacctl logs agent'"
batch_lines="$(echo "$st" | awk '{print $2}')"
batch_status="$(echo "$st" | cut -d' ' -f3-)"
case "$batch_status" in
  ok*) say "Successfully connected to Dynatrace environment $env_url (first batch: $batch_lines metric lines, HTTP ${batch_status#ok })" ;;
  partial*) warn "Connected to Dynatrace environment $env_url, but some metric lines were rejected; see 'dtmacctl logs ingest'" ;;
  *) die "the agent is running but Dynatrace rejected its first batch ($batch_status); see 'dtmacctl logs agent'" ;;
esac

if [ "$SEND_LOGS" = "1" ]; then
  ls_status=""
  for _ in $(seq 1 15); do
    ls_status="$(cat "$STATE_DIR/logship.status" 2>/dev/null || true)"
    [ -n "$ls_status" ] && break
    sleep 1
  done
  case "$ls_status" in
    ok) say "Log shipping to Dynatrace verified" ;;
    "") warn "Log shipping not confirmed yet; check 'sudo dtmacctl status' in a minute" ;;
    *) warn "Log shipping to Dynatrace failed (HTTP $ls_status): the token may lack log ingest permission; see 'dtmacctl logs agent'" ;;
  esac
fi

say "dt-mac-agent $VERSION installed and running from $PREFIX"
if [ "$UPDATE" = "1" ]; then
  if [ "$reload_wd" = "1" ]; then
    say "Watchdog definition changed; reloading it (the agent re-loads it within a minute)"
    launchctl bootout "system/$WD_LABEL" 2>/dev/null || true
  fi
  exit 0
fi

cat <<EOF

  Status  : sudo dtmacctl status
  Logs    : dtmacctl logs -f              ($LOG_DIR, also in Console.app)
  Sends   : dtmacctl logs ingest -f
  Metrics : dtmacctl metrics
  Update  : sudo dtmacctl update          (automatic daily check: $([ "$AUTO_UPDATE" = 1 ] && echo on || echo off))
  Remove  : sudo dtmacctl uninstall

Metrics appear in Dynatrace under '$(conf_get METRIC_PREFIX || echo macos).*' within ~2 minutes.
EOF
