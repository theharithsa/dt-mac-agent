# shellcheck shell=bash
# Shared helpers for dt-mac-agent. Must stay compatible with macOS /bin/bash 3.2.

export LC_ALL=C
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DTMA_LABEL="com.theharithsa.dt-mac-agent"
DTMA_WD_LABEL="com.theharithsa.dt-mac-agent.watchdog"
DTMA_PLIST_DIR="/Library/LaunchDaemons"
DTMA_CONFIG="${DTMA_CONFIG:-/etc/dt-mac-agent/config}"
DTMA_STATE_DIR="${DTMA_STATE_DIR:-/var/lib/dt-mac-agent}"
DTMA_LOG_DIR="${DTMA_LOG_DIR:-/Library/Logs/dt-mac-agent}"
DTMA_VERSION="$(cat "$DTMA_HOME/VERSION" 2>/dev/null || echo unknown)"
TAB="$(printf '\t')"
LOG_FILE="${LOG_FILE:-}"
INGEST_LOG="${INGEST_LOG:-}"
LAST_STATUS="none"
SENT_OK=0
SENT_INVALID=0

# log LEVEL MESSAGE [FILE]; falls back to stderr when no log file is configured.
log() {
  local file="${3:-$LOG_FILE}" line
  line="$(date '+%Y-%m-%d %H:%M:%S %z') [$1] $2"
  if [ -n "$file" ] && [ -d "$(dirname "$file")" ]; then
    # Logs never contain the token, so they are world-readable for easy troubleshooting.
    if [ ! -e "$file" ]; then : >"$file"; chmod 644 "$file"; fi
    printf '%s\n' "$line" >>"$file"
  else
    printf '%s\n' "$line" >&2
  fi
}

load_config() {
  METRIC_PREFIX="macos"
  TOP_N=10
  INTERVAL=60
  SPOOL_MAX_AGE_MIN=55
  SPOOL_MAX_FILES=120
  LOG_PAYLOADS=0
  DT_ENV_URL=""
  DT_TOKEN=""
  DT_INGEST_URL=""
  if [ -r "$DTMA_CONFIG" ]; then
    # shellcheck source=/dev/null
    . "$DTMA_CONFIG"
  fi
  DT_ENV_URL="${DT_ENV_URL%/}"
  case "$METRIC_PREFIX" in ''|[!a-z]*|*[!a-z0-9._-]*) log WARN "invalid METRIC_PREFIX, using 'macos'"; METRIC_PREFIX="macos" ;; esac
  case "$TOP_N" in ''|*[!0-9]*) TOP_N=10 ;; esac
  case "$INTERVAL" in ''|*[!0-9]*) INTERVAL=60 ;; esac
  case "$SPOOL_MAX_AGE_MIN" in ''|*[!0-9]*) SPOOL_MAX_AGE_MIN=55 ;; esac
  case "$SPOOL_MAX_FILES" in ''|*[!0-9]*) SPOOL_MAX_FILES=120 ;; esac
  [ "$INTERVAL" -ge 10 ] || INTERVAL=10
  # Dynatrace rejects data points older than 1 hour.
  [ "$SPOOL_MAX_AGE_MIN" -le 55 ] || SPOOL_MAX_AGE_MIN=55
}

# Platform tokens (dt0s16.*) use the platform gateway; classic API tokens (dt0c01.*) the live API.
resolve_ingest() {
  if [ -z "$DT_TOKEN" ]; then log ERROR "DT_TOKEN is not set in $DTMA_CONFIG"; return 1; fi
  if [ -z "$DT_ENV_URL" ] && [ -z "$DT_INGEST_URL" ]; then log ERROR "DT_ENV_URL is not set in $DTMA_CONFIG"; return 1; fi
  case "$DT_TOKEN" in
    dt0c01.*)
      AUTH_HEADER="Authorization: Api-Token $DT_TOKEN"
      INGEST_URL="${DT_INGEST_URL:-$(printf '%s' "$DT_ENV_URL" | sed 's#\.apps\.dynatrace\.com#.live.dynatrace.com#')/api/v2/metrics/ingest}"
      ;;
    *)
      AUTH_HEADER="Authorization: Bearer $DT_TOKEN"
      INGEST_URL="${DT_INGEST_URL:-$DT_ENV_URL/platform/classic/environment-api/v2/metrics/ingest}"
      ;;
  esac
}

init_dirs() {
  SPOOL_DIR="$DTMA_STATE_DIR/spool"
  WORK_DIR="$DTMA_STATE_DIR/work"
  mkdir -p "$SPOOL_DIR" "$WORK_DIR"
}

host_info() {
  HOST_NAME="$(scutil --get LocalHostName 2>/dev/null || hostname -s)"
  OS_VERSION="$(sw_vers -productVersion 2>/dev/null)"
  HW_MODEL="$(sysctl -n hw.model 2>/dev/null)"
  ARCH="$(uname -m)"
}

read_count() { cat "$DTMA_STATE_DIR/$1.count" 2>/dev/null || echo 0; }

bump_count() {
  local n
  n="$(read_count "$1")"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  echo $((n + 1)) >"$DTMA_STATE_DIR/$1.count"
}

# Returns 0 when the batch is accepted (or permanently rejected), 1 when it should be retried.
send_file() {
  local file="$1" resp="$WORK_DIR/resp.txt" err="$WORK_DIR/curl.err" code ok inv
  # Header is passed via stdin config so the token never appears in the process list.
  : >"$resp"
  code="$(printf 'header = "%s"\n' "$AUTH_HEADER" | curl -sS -K - -o "$resp" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -H 'Content-Type: text/plain; charset=utf-8' \
    --data-binary "@$file" "$INGEST_URL" 2>"$err")" || true
  ok="$(sed -n 's/.*"linesOk": *\([0-9]*\).*/\1/p' "$resp" | head -n 1)"
  inv="$(sed -n 's/.*"linesInvalid": *\([0-9]*\).*/\1/p' "$resp" | head -n 1)"
  SENT_OK=$((SENT_OK + ${ok:-0}))
  SENT_INVALID=$((SENT_INVALID + ${inv:-0}))
  case "$code" in
    200|202)
      LAST_STATUS="ok $code"
      return 0
      ;;
    400)
      LAST_STATUS="partial 400"
      log WARN "ingest rejected some lines (HTTP 400): $(head -c 500 "$resp" 2>/dev/null | tr '\n' ' ')"
      return 0
      ;;
    *)
      LAST_STATUS="error ${code:-000}"
      log ERROR "ingest failed (HTTP ${code:-000}): $(head -c 300 "$resp" 2>/dev/null | tr '\n' ' ')$(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
      return 1
      ;;
  esac
}

spool_count() {
  local n=0 f
  for f in "$SPOOL_DIR"/*.txt; do [ -e "$f" ] && n=$((n + 1)); done
  echo "$n"
}

prune_spool() {
  local now f ts n
  now="$(date +%s)"
  for f in "$SPOOL_DIR"/*.txt; do
    [ -e "$f" ] || continue
    ts="${f##*/}"
    ts="${ts%%-*}"
    case "$ts" in ''|*[!0-9]*) rm -f "$f"; continue ;; esac
    if [ $((now - ts)) -gt $((SPOOL_MAX_AGE_MIN * 60)) ]; then
      rm -f "$f"
      log WARN "dropped expired spool file ${f##*/}"
    fi
  done
  n="$(spool_count)"
  for f in "$SPOOL_DIR"/*.txt; do
    [ "$n" -gt "$SPOOL_MAX_FILES" ] || break
    [ -e "$f" ] && rm -f "$f" && n=$((n - 1))
  done
}

spool_file() {
  cp "$1" "$SPOOL_DIR/$(date +%s)-$$-$RANDOM.txt"
  prune_spool
}

# Sends buffered batches oldest-first; stops at the first failure to preserve order.
flush_spool() {
  local f n
  prune_spool
  for f in "$SPOOL_DIR"/*.txt; do
    [ -e "$f" ] || continue
    n="$(wc -l <"$f" | tr -d ' ')"
    send_file "$f" || return 1
    rm -f "$f"
    log INFO "re-sent buffered batch ${f##*/} ($n lines): $LAST_STATUS" "$INGEST_LOG"
  done
  return 0
}

send_payload() {
  local payload="$1" chunk online=1
  flush_spool || online=0
  rm -f "$WORK_DIR"/chunk.*
  split -l 500 "$payload" "$WORK_DIR/chunk."
  for chunk in "$WORK_DIR"/chunk.*; do
    [ -e "$chunk" ] || continue
    if [ "$online" -eq 1 ] && send_file "$chunk"; then
      :
    else
      online=0
      spool_file "$chunk"
      bump_count ingest_failures
    fi
    rm -f "$chunk"
  done
}

job_loaded() { launchctl print "system/$1" >/dev/null 2>&1; }

job_field() {
  launchctl print "system/$1" 2>/dev/null | awk -v k="$2" -F ' = ' '$1 == "\t" k { print $2; exit }'
}
