# shellcheck shell=bash
# Shared helpers for dt-mac-agent. Must stay compatible with macOS /bin/bash 3.2.

export LC_ALL=C
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

DTMA_LABEL="com.theharithsa.dt-mac-agent"
DTMA_WD_LABEL="com.theharithsa.dt-mac-agent.watchdog"
DTMA_REPO="theharithsa/dt-mac-agent"
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
  SEND_LOGS=0
  AUTO_UPDATE=1
  DT_ENV_URL=""
  DT_TOKEN=""
  DT_INGEST_URL=""
  DT_LOGS_URL=""
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

# DT_ENV_URL may be given as https://<env>.live.dynatrace.com or https://<env>.apps.dynatrace.com.
# Classic API tokens (dt0c01.*) use the live API; platform tokens (dt0s16.*) the platform gateway on apps.
resolve_ingest() {
  local api_base
  if [ -z "$DT_TOKEN" ]; then log ERROR "DT_TOKEN is not set in $DTMA_CONFIG"; return 1; fi
  if [ -z "$DT_ENV_URL" ] && [ -z "$DT_INGEST_URL" ]; then log ERROR "DT_ENV_URL is not set in $DTMA_CONFIG"; return 1; fi
  case "$DT_TOKEN" in
    dt0c01.*)
      AUTH_HEADER="Authorization: Api-Token $DT_TOKEN"
      api_base="$(printf '%s' "$DT_ENV_URL" | sed 's#\.apps\.dynatrace\.com#.live.dynatrace.com#')/api"
      ;;
    *)
      AUTH_HEADER="Authorization: Bearer $DT_TOKEN"
      api_base="$(printf '%s' "$DT_ENV_URL" | sed 's#\.live\.dynatrace\.com#.apps.dynatrace.com#')/platform/classic/environment-api"
      ;;
  esac
  INGEST_URL="${DT_INGEST_URL:-$api_base/v2/metrics/ingest}"
  LOGS_URL="${DT_LOGS_URL:-$api_base/v2/logs/ingest}"
  SETTINGS_URL="${DT_SETTINGS_URL:-$api_base/v2/settings/objects}"
}

# Builds builtin:metric.metadata settings objects (name, description, unit and dimensions) for every metric.
build_metric_settings() {
  awk -F "$TAB" -v p="$METRIC_PREFIX" -v df="$DTMA_HOME/lib/dimensions.tsv" '
    function j(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return "\"" s "\"" }
    BEGIN {
      while ((getline l < df) > 0) {
        if (l ~ /^#/ || l == "") continue
        split(l, d, "\t"); nd++; dk[nd] = d[1]; dn[nd] = d[2]; dr[nd] = d[3]
      }
      printf "["
    }
    !/^#/ && NF >= 5 {
      dims = ""
      for (i = 1; i <= nd; i++)
        if ($1 ~ dr[i]) dims = dims (dims == "" ? "" : ",") "{\"key\":" j(dk[i]) ",\"displayName\":" j(dn[i]) "}"
      printf "%s{\"schemaId\":\"builtin:metric.metadata\",\"scope\":%s,\"value\":{\"displayName\":%s,\"description\":%s,\"unit\":%s,\"dimensions\":[%s],\"tags\":[\"dt-mac-agent\"]}}", \
        (n++ ? "," : ""), j("metric-" p "." $1), j($4), j($5), j($3), dims
    }
    END { printf "]\n" }' "$DTMA_HOME/lib/metrics.tsv"
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

# http_post FILE URL CONTENT_TYPE: sets HTTP_CODE and HTTP_DETAIL; response body in $WORK_DIR/resp.txt.
http_post() {
  local resp="$WORK_DIR/resp.txt" err="$WORK_DIR/curl.err"
  : >"$resp"
  # Header is passed via stdin config so the token never appears in the process list.
  HTTP_CODE="$(printf 'header = "%s"\n' "$AUTH_HEADER" | curl -sS -K - -o "$resp" -w '%{http_code}' \
    --connect-timeout 10 --max-time 30 \
    -H "Content-Type: $3" \
    --data-binary "@$1" "$2" 2>"$err")" || true
  HTTP_CODE="${HTTP_CODE:-000}"
  HTTP_DETAIL="$(head -c 400 "$resp" 2>/dev/null | tr '\n' ' ')$(head -c 200 "$err" 2>/dev/null | tr '\n' ' ')"
}

# Returns 0 when the batch is accepted (or permanently rejected), 1 when it should be retried.
send_file() {
  local ok inv
  http_post "$1" "$INGEST_URL" 'text/plain; charset=utf-8'
  ok="$(sed -n 's/.*"linesOk": *\([0-9]*\).*/\1/p' "$WORK_DIR/resp.txt" | head -n 1)"
  inv="$(sed -n 's/.*"linesInvalid": *\([0-9]*\).*/\1/p' "$WORK_DIR/resp.txt" | head -n 1)"
  SENT_OK=$((SENT_OK + ${ok:-0}))
  SENT_INVALID=$((SENT_INVALID + ${inv:-0}))
  case "$HTTP_CODE" in
    200|202)
      LAST_STATUS="ok $HTTP_CODE"
      return 0
      ;;
    400)
      LAST_STATUS="partial 400"
      log WARN "ingest rejected some lines (HTTP 400): $HTTP_DETAIL"
      return 0
      ;;
    *)
      LAST_STATUS="error $HTTP_CODE"
      log ERROR "ingest failed (HTTP $HTTP_CODE): $HTTP_DETAIL"
      return 1
      ;;
  esac
}

# Sends display name, description and unit for every metric; repeated daily and after upgrades.
send_metadata() {
  local f="$WORK_DIR/metadata.txt" stamp="$DTMA_STATE_DIR/metadata.sent" now last n
  now="$(date +%s)"
  last="$(cat "$stamp" 2>/dev/null)"
  case "$last" in
    "$DTMA_VERSION $METRIC_PREFIX "*) [ $((now - ${last##* })) -lt 86400 ] && return 0 ;;
  esac

  # Preferred: Settings API, which also declares the dimensions shown in metric definitions.
  build_metric_settings >"$WORK_DIR/metadata.json"
  http_post "$WORK_DIR/metadata.json" "$SETTINGS_URL" 'application/json; charset=utf-8'
  if [ "$HTTP_CODE" = "200" ]; then
    log INFO "metadata: declared name, description, unit and dimensions for all metrics via Settings API (HTTP 200)" "$INGEST_LOG"
    echo "$DTMA_VERSION $METRIC_PREFIX $now" >"$stamp"
    return 0
  fi
  log WARN "metadata: Settings API not usable (HTTP $HTTP_CODE); dimensions will not be listed in metric definitions. Grant the token settings.write (API token) or settings:objects:write (platform token). Falling back to metadata lines." "$INGEST_LOG"

  awk -F "$TAB" -v p="$METRIC_PREFIX" '
    !/^#/ && NF >= 5 {
      gsub(/"/, "", $4); gsub(/"/, "", $5)
      printf "#%s.%s %s dt.meta.displayName=\"%s\",dt.meta.description=\"%s\",dt.meta.unit=\"%s\"\n", p, $1, $2, $4, $5, $3
    }' "$DTMA_HOME/lib/metrics.tsv" >"$f"
  n="$(wc -l <"$f" | tr -d ' ')"
  http_post "$f" "$INGEST_URL" 'text/plain; charset=utf-8'
  case "$HTTP_CODE" in
    200|202)
      log INFO "metadata: sent display name, description and unit for $n metrics (HTTP $HTTP_CODE)" "$INGEST_LOG"
      echo "$DTMA_VERSION $METRIC_PREFIX $now" >"$stamp"
      ;;
    400)
      log WARN "metadata: some of $n metric descriptions were rejected (HTTP 400): $HTTP_DETAIL" "$INGEST_LOG"
      echo "$DTMA_VERSION $METRIC_PREFIX $now" >"$stamp"
      ;;
    *)
      log WARN "metadata: send failed (HTTP $HTTP_CODE), retrying next cycle: $HTTP_DETAIL" "$INGEST_LOG"
      ;;
  esac
}

# Ships new lines of the agent's own log files to the Dynatrace log ingest API (SEND_LOGS=1).
ship_logs() {
  local state="$DTMA_STATE_DIR/logship.tsv" new="$DTMA_STATE_DIR/logship.tsv.new" lines="$WORK_DIR/logs.lines"
  local json="$WORK_DIR/logs.json" name f ino size off n prev
  LOGS_SHIPPED=0
  [ "$SEND_LOGS" = "1" ] || return 0
  touch "$state"
  : >"$new"
  : >"$lines"
  for name in agent ingest watchdog install; do
    f="$DTMA_LOG_DIR/$name.log"
    [ -f "$f" ] || continue
    ino="$(stat -f %i "$f")"
    size="$(stat -f %z "$f")"
    # Offset is tied to the inode so rotated files are read from the start.
    off="$(awk -F "$TAB" -v n="$name" -v i="$ino" '$1 == n && $2 == i { print $3 }' "$state")"
    case "$off" in ''|*[!0-9]*) off=0 ;; esac
    [ "$off" -le "$size" ] || off=0
    if [ "$off" -lt "$size" ]; then
      tail -c +$((off + 1)) "$f" | head -c 262144 >"$WORK_DIR/log.chunk"
      n="$(wc -l <"$WORK_DIR/log.chunk" | tr -d ' ')"
      if [ "$n" -gt 0 ]; then
        head -n "$n" "$WORK_DIR/log.chunk" >"$WORK_DIR/log.full"
        off=$((off + $(wc -c <"$WORK_DIR/log.full")))
        LOGS_SHIPPED=$((LOGS_SHIPPED + n))
        awk -v comp="$name" -v src="$f" -v host="$HOST_NAME" -v osver="$OS_VERSION" -v ver="$DTMA_VERSION" '
          function j(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); gsub(/\r/, "", s); return "\"" s "\"" }
          {
            ts = ""; lvl = "INFO"; msg = $0
            if (match($0, /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9] [-+][0-9][0-9][0-9][0-9] \[[A-Z]+\] /)) {
              ts = substr($0, 1, 10) "T" substr($0, 12, 8) substr($0, 21, 3) ":" substr($0, 24, 2)
              lvl = substr($0, 28, RLENGTH - 29)
              msg = substr($0, RLENGTH + 1)
            }
            if (msg == "") next
            printf "{%s\"content\":%s,\"loglevel\":%s,\"log.source\":%s,\"service.name\":\"dt-mac-agent\",\"dt_mac_agent.component\":%s,\"host.name\":%s,\"os.type\":\"macos\",\"os.version\":%s,\"agent.version\":%s}\n", (ts == "" ? "" : "\"timestamp\":" j(ts) ","), j(msg), j(lvl), j(src), j(comp), j(host), j(osver), j(ver)
          }' "$WORK_DIR/log.full" >>"$lines"
      fi
    fi
    printf '%s\t%s\t%s\n' "$name" "$ino" "$off" >>"$new"
  done
  if [ ! -s "$lines" ]; then
    mv -f "$new" "$state"
    return 0
  fi
  { printf '['; paste -sd, "$lines"; printf ']'; } >"$json"
  http_post "$json" "$LOGS_URL" 'application/json; charset=utf-8'
  prev="$(cat "$DTMA_STATE_DIR/logship.status" 2>/dev/null)"
  case "$HTTP_CODE" in
    200|204)
      mv -f "$new" "$state"
      [ "$prev" = "ok" ] || log INFO "log shipping to Dynatrace is working (HTTP $HTTP_CODE)"
      echo ok >"$DTMA_STATE_DIR/logship.status"
      ;;
    *)
      LOGS_SHIPPED=0
      rm -f "$new"
      # Log only on status change; unsent lines are retried next cycle.
      [ "$prev" = "$HTTP_CODE" ] || log ERROR "log shipping failed (HTTP $HTTP_CODE): $HTTP_DETAIL"
      echo "$HTTP_CODE" >"$DTMA_STATE_DIR/logship.status"
      ;;
  esac
}

DTMA_DASHBOARD_ID="dt-mac-agent-health-center"
DTMA_DASHBOARD_NAME="MacOS Health Center"

# upload_dashboard FILE PLATFORM_TOKEN: creates or updates the dashboard (fixed id) via the Document API.
upload_dashboard() {
  local file="$1" token="$2" base resp="$WORK_DIR/dashboard.out" ver
  base="$(printf '%s' "$DT_ENV_URL" | sed 's#\.live\.dynatrace\.com#.apps.dynatrace.com#')"
  DASHBOARD_URL="$base/ui/apps/dynatrace.dashboards/dashboard/$DTMA_DASHBOARD_ID"
  base="$base/platform/document/v1/documents"
  HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - -o "$resp" -w '%{http_code}' \
    --max-time 30 "$base/$DTMA_DASHBOARD_ID/metadata" 2>/dev/null)" || HTTP_CODE=000
  if [ "$HTTP_CODE" = "200" ]; then
    ver="$(sed -n 's/.*"version":\([0-9]*\).*/\1/p' "$resp" | head -n 1)"
    HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - -o "$resp" -w '%{http_code}' \
      --max-time 60 -X PATCH -F "name=$DTMA_DASHBOARD_NAME" -F "content=@$file;type=application/json" \
      "$base/$DTMA_DASHBOARD_ID?optimistic-locking-version=$ver" 2>/dev/null)" || HTTP_CODE=000
    DASHBOARD_ACTION="updated"
  elif [ "$HTTP_CODE" = "404" ]; then
    HTTP_CODE="$(printf 'header = "Authorization: Bearer %s"\n' "$token" | curl -sS -K - -o "$resp" -w '%{http_code}' \
      --max-time 60 -F "id=$DTMA_DASHBOARD_ID" -F "name=$DTMA_DASHBOARD_NAME" -F 'type=dashboard' -F 'isPrivate=false' \
      -F "content=@$file;type=application/json" "$base" 2>/dev/null)" || HTTP_CODE=000
    DASHBOARD_ACTION="created"
  fi
  HTTP_DETAIL="$(head -c 300 "$resp" 2>/dev/null | tr '\n' ' ')"
  case "$HTTP_CODE" in 200|201) return 0 ;; *) return 1 ;; esac
}

latest_version() {
  curl -fsSL --connect-timeout 8 --retry 4 --retry-delay 1 --retry-all-errors --max-time 60 "https://api.github.com/repos/$DTMA_REPO/releases/latest" 2>/dev/null |
    sed -n 's/.*"tag_name": *"v\{0,1\}\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)".*/\1/p' | head -n 1
}

# version_gt A B: true when semantic version A is newer than B.
version_gt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)" = "$1" ]
}

# run_update VERSION [verbose]: downloads, verifies and installs a release into $DTMA_HOME.
run_update() {
  local v="$1" tmp base tarball expected actual rc
  tmp="$(mktemp -d /tmp/dt-mac-agent-update.XXXXXX)"
  base="https://github.com/$DTMA_REPO/releases/download/v$v"
  tarball="dt-mac-agent-$v.tar.gz"
  if ! curl -fsSL --connect-timeout 8 --retry 4 --retry-delay 1 --retry-all-errors --max-time 120 -o "$tmp/$tarball" "$base/$tarball" ||
    ! curl -fsSL --connect-timeout 8 --retry 4 --retry-delay 1 --retry-all-errors --max-time 60 -o "$tmp/$tarball.sha256" "$base/$tarball.sha256"; then
    log ERROR "update: download of $v failed"
    rm -rf "$tmp"
    return 1
  fi
  expected="$(awk '{print $1}' "$tmp/$tarball.sha256")"
  actual="$(shasum -a 256 "$tmp/$tarball" | awk '{print $1}')"
  if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
    log ERROR "update: SHA-256 mismatch for $tarball; not installing"
    rm -rf "$tmp"
    return 1
  fi
  tar -xzf "$tmp/$tarball" -C "$tmp"
  if [ "${2:-}" = "verbose" ]; then
    DTMA_UPDATE=1 DTMA_SKIP_TEST=1 DTMA_PREFIX="$DTMA_HOME" /bin/bash "$tmp/dt-mac-agent-$v/install.sh" </dev/null
  else
    DTMA_UPDATE=1 DTMA_SKIP_TEST=1 DTMA_PREFIX="$DTMA_HOME" /bin/bash "$tmp/dt-mac-agent-$v/install.sh" </dev/null >/dev/null 2>&1
  fi
  rc=$?
  rm -rf "$tmp"
  return "$rc"
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
