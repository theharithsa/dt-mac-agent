# shellcheck shell=bash
# Metric collectors. Each prints tab-separated records consumed by format.awk:
#   TYPE<TAB>metric<TAB>value[<TAB>dimKey<TAB>dimValue]...

rec() { local IFS="$TAB"; printf '%s\n' "$*"; }

collect_cpu() {
  # Two samples 1s apart; the first top sample is an average since boot.
  top -l 2 -n 0 -s 1 2>/dev/null | awk '
    BEGIN { OFS = "\t" }
    /^Processes:/ { procs = $2; for (i = 3; i <= NF; i++) if ($i ~ /^threads/) thr = $(i - 1) }
    /^CPU usage:/ { u = $3; s = $5; id = $7; gsub(/%/, "", u); gsub(/%/, "", s); gsub(/%/, "", id) }
    END {
      if (u != "") {
        print "G", "cpu.user", u
        print "G", "cpu.system", s
        print "G", "cpu.idle", id
        printf "G\tcpu.usage\t%.2f\n", u + s
      }
      if (procs != "") print "G", "system.processes", procs
      if (thr != "") print "G", "system.threads", thr
    }'
}

collect_sysctl() {
  sysctl vm.loadavg hw.ncpu hw.physicalcpu kern.num_files kern.maxfiles kern.boottime \
    kern.memorystatus_vm_pressure_level kern.memorystatus_level vm.swapusage 2>/dev/null |
    awk -v now="$(date +%s)" '
    function bytes(x,   u, n) {
      u = substr(x, length(x)); n = x + 0
      if (u == "K") n *= 1024; else if (u == "M") n *= 1048576; else if (u == "G") n *= 1073741824
      return sprintf("%.0f", n)
    }
    BEGIN { OFS = "\t" }
    $1 == "vm.loadavg:" { print "G", "cpu.load1", $3; print "G", "cpu.load5", $4; print "G", "cpu.load15", $5 }
    $1 == "hw.ncpu:" { print "G", "cpu.cores.logical", $2 }
    $1 == "hw.physicalcpu:" { print "G", "cpu.cores.physical", $2 }
    $1 == "kern.num_files:" { print "G", "system.open_files", $2 }
    $1 == "kern.maxfiles:" { print "G", "system.open_files.max", $2 }
    $1 == "kern.boottime:" { b = $5; sub(/,/, "", b); print "G", "system.uptime", now - b }
    $1 == "kern.memorystatus_vm_pressure_level:" { print "G", "memory.pressure.level", $2 }
    $1 == "kern.memorystatus_level:" { print "G", "memory.available.percent", $2 }
    $1 == "vm.swapusage:" {
      t = bytes($4); u = bytes($7)
      print "G", "memory.swap.total", t
      print "G", "memory.swap.used", u
      if (t > 0) printf "G\tmemory.swap.usage\t%.2f\n", u / t * 100
    }'
}

collect_memory() {
  vm_stat 2>/dev/null | awk -v total="$(sysctl -n hw.memsize 2>/dev/null)" '
    BEGIN { OFS = "\t"; pg = 4096 }
    /page size of/ { for (i = 1; i <= NF; i++) if ($i == "of") pg = $(i + 1) }
    /:/ { k = $0; sub(/:.*/, "", k); gsub(/"/, "", k); v = $NF; sub(/\.$/, "", v); val[k] = v }
    END {
      wired = val["Pages wired down"] * pg
      comp = val["Pages occupied by compressor"] * pg
      app = (val["Anonymous pages"] - val["Pages purgeable"]) * pg; if (app < 0) app = 0
      cached = (val["File-backed pages"] + val["Pages purgeable"]) * pg
      free = (val["Pages free"] + val["Pages speculative"]) * pg
      used = app + wired + comp
      printf "G\tmemory.total\t%.0f\n", total
      printf "G\tmemory.used\t%.0f\n", used
      printf "G\tmemory.app\t%.0f\n", app
      printf "G\tmemory.wired\t%.0f\n", wired
      printf "G\tmemory.compressed\t%.0f\n", comp
      printf "G\tmemory.cached\t%.0f\n", cached
      printf "G\tmemory.free\t%.0f\n", free
      if (total > 0) printf "G\tmemory.usage\t%.2f\n", used / total * 100
      print "C", "memory.pageins", val["Pageins"]
      print "C", "memory.pageouts", val["Pageouts"]
      print "C", "memory.swapins", val["Swapins"]
      print "C", "memory.swapouts", val["Swapouts"]
      print "C", "memory.compressions", val["Compressions"]
      print "C", "memory.decompressions", val["Decompressions"]
    }'
}

collect_disk() {
  # Only the user-relevant APFS volumes plus external volumes.
  df -k -i -l 2>/dev/null | awk '
    BEGIN { OFS = "\t" }
    NR > 1 {
      mount = $9; for (i = 10; i <= NF; i++) mount = mount " " $i
      if (mount != "/" && mount != "/System/Volumes/Data" && mount !~ /^\/Volumes\//) next
      if (mount == "/Volumes/Recovery") next
      cap = $5; sub(/%/, "", cap)
      d = "mount" OFS mount OFS "device" OFS $1
      printf "G\tdisk.total\t%.0f\t%s\n", $2 * 1024, d
      printf "G\tdisk.used\t%.0f\t%s\n", $3 * 1024, d
      printf "G\tdisk.free\t%.0f\t%s\n", $4 * 1024, d
      print "G", "disk.usage", cap, d
      print "G", "disk.inodes.used", $6, d
      print "G", "disk.inodes.free", $7, d
    }'
}

collect_diskio() {
  ioreg -c IOBlockStorageDriver -r -l -w0 2>/dev/null | awk '
    function get(s, name,   i, t) {
      i = index(s, "\"" name "\"=")
      if (!i) return ""
      t = substr(s, i + length(name) + 3)
      sub(/[,}].*/, "", t)
      return t
    }
    function emit(dev, s,   rb, wb) {
      rb = get(s, "Bytes (Read)"); wb = get(s, "Bytes (Write)")
      if (rb + wb == 0) return
      print "C\tdisk.io.read.bytes\t" rb "\tdisk\t" dev
      print "C\tdisk.io.write.bytes\t" wb "\tdisk\t" dev
      print "C\tdisk.io.read.ops\t" get(s, "Operations (Read)") "\tdisk\t" dev
      print "C\tdisk.io.write.ops\t" get(s, "Operations (Write)") "\tdisk\t" dev
      print "C\tdisk.io.read.time_ns\t" get(s, "Total Time (Read)") "\tdisk\t" dev
      print "C\tdisk.io.write.time_ns\t" get(s, "Total Time (Write)") "\tdisk\t" dev
      print "C\tdisk.io.errors\t" get(s, "Errors (Read)") + get(s, "Errors (Write)") "\tdisk\t" dev
    }
    /\+-o IOBlockStorageDriver/ { pend = 1; stats = ""; next }
    pend && stats == "" && /"Statistics" = / { stats = $0; next }
    pend && stats != "" && /"BSD Name" = / {
      n = $0; sub(/.*"BSD Name" = "/, "", n); sub(/".*/, "", n)
      emit(n, stats); pend = 0
    }'
}

collect_network() {
  netstat -ibn 2>/dev/null | awk '
    BEGIN { OFS = "\t" }
    $3 ~ /^<Link#/ {
      name = $1; sub(/\*$/, "", name)
      if (NF == 11) { ip = $5; ie = $6; ib = $7; op = $8; oe = $9; ob = $10 }
      else if (NF == 10) { ip = $4; ie = $5; ib = $6; op = $7; oe = $8; ob = $9 }
      else next
      if (ib + ob == 0 || seen[name]++) next
      d = "interface" OFS name
      print "C", "net.bytes.in", ib, d
      print "C", "net.bytes.out", ob, d
      print "C", "net.packets.in", ip, d
      print "C", "net.packets.out", op, d
      print "C", "net.errors.in", ie, d
      print "C", "net.errors.out", oe, d
    }'
  netstat -an -p tcp 2>/dev/null | awk '$NF == "ESTABLISHED" { n++ } END { print "G\tnet.tcp.established\t" n + 0 }'
}

collect_power() {
  local batt
  batt="$(pmset -g batt 2>/dev/null)"
  printf '%s\n' "$batt" | awk '
    BEGIN { OFS = "\t" }
    /drawing from/ { print "G", "power.on_ac", ($0 ~ /AC Power/) ? 1 : 0 }
    /InternalBattery/ {
      split($0, p, ";")
      if (match(p[1], /[0-9]+%/)) print "G", "battery.percent", substr(p[1], RSTART, RLENGTH - 1)
      st = p[2]; gsub(/^ +| +$/, "", st)
      print "G", "battery.charging", (st == "charging") ? 1 : 0
    }'
  if printf '%s' "$batt" | grep -q InternalBattery; then
    ioreg -rn AppleSmartBattery -w0 2>/dev/null | awk '
      BEGIN { OFS = "\t" }
      $1 == "\"CycleCount\"" { cc = $3 }
      $1 == "\"DesignCapacity\"" { dc = $3 }
      $1 == "\"AppleRawMaxCapacity\"" { mc = $3 }
      $1 == "\"Temperature\"" { t = $3 }
      END {
        if (cc != "") print "G", "battery.cycle_count", cc
        if (dc > 0 && mc > 0) printf "G\tbattery.health\t%.2f\n", mc / dc * 100
        if (t != "") printf "G\tbattery.temperature\t%.2f\n", t / 100
      }'
  fi
  pmset -g therm 2>/dev/null | awk '
    BEGIN { OFS = "\t" }
    /CPU_Speed_Limit/ { print "G", "cpu.speed_limit", $NF }
    /CPU_Scheduler_Limit/ { print "G", "cpu.scheduler_limit", $NF }
    /thermal warning level/ { print "G", "system.thermal.warning", ($0 ~ /No thermal warning/) ? 0 : 1 }'
}

collect_system() {
  rec G system.users "$(who 2>/dev/null | wc -l | tr -d ' ')"
}

collect_processes() {
  local total procs="$WORK_DIR/procs.tsv" top="$WORK_DIR/top.tsv" pids
  total="$(sysctl -n hw.memsize 2>/dev/null)"
  # pid, user, cpu%, rss bytes, process name, owning .app bundle, full path
  ps -Aww -o pid=,user=,pcpu=,rss=,comm= 2>/dev/null | awk '
    BEGIN { OFS = "\t" }
    {
      path = $0
      sub(/^ *[0-9]+ +[^ ]+ +[0-9.]+ +[0-9]+ +/, "", path)
      gsub(/\t/, " ", path)
      name = path; sub(/.*\//, "", name)
      app = ""
      if (match(path, /\/[^\/]+\.app\//)) app = substr(path, RSTART + 1, RLENGTH - 6)
      printf "%s\t%s\t%s\t%.0f\t%s\t%s\t%s\n", $1, $2, $3, $4 * 1024, name, app, path
    }' >"$procs"

  awk -F "$TAB" '
    BEGIN { OFS = "\t" }
    $6 != "" {
      a = $6; cpu[a] += $3; mem[a] += $4; n[a]++
      if ($7 ~ /^\/Applications\// || $7 ~ /^\/System\/Applications\// || $7 ~ /^\/Users\/[^\/]+\/Applications\//) type[a] = "user"
      else if (!(a in type)) type[a] = "system"
    }
    END {
      for (a in n) {
        c++; if (type[a] == "user") cu++
        d = "app.name" OFS a OFS "app.type" OFS type[a]
        printf "G\tapp.cpu\t%.1f\t%s\n", cpu[a], d
        printf "G\tapp.memory.rss\t%.0f\t%s\n", mem[a], d
        print "G", "app.processes", n[a], d
      }
      print "G", "apps.running", c + 0
      print "G", "apps.running.user", cu + 0
    }' "$procs"

  {
    sort -t "$TAB" -k3,3nr "$procs" | head -n "$TOP_N" | awk -v by=cpu '{ print by "\t" NR "\t" $0 }'
    sort -t "$TAB" -k4,4nr "$procs" | head -n "$TOP_N" | awk -v by=memory '{ print by "\t" NR "\t" $0 }'
  } >"$top"

  pids="$(cut -f3 "$top" | sort -u | paste -sd, -)"
  [ -n "$pids" ] || return 0
  ps -M -p "$pids" 2>/dev/null | awk '
    NR > 1 { p = ($0 ~ /^[ \t]/) ? $1 : $2; th[p]++ }
    END { for (p in th) print p "\t" th[p] }' >"$WORK_DIR/threads.tsv"

  awk -F "$TAB" -v total="${total:-0}" '
    BEGIN { OFS = "\t" }
    FILENAME == ARGV[1] { th[$1] = $2; next }
    {
      d = "top.by" OFS $1 OFS "rank" OFS $2 OFS "process.name" OFS $7 OFS "pid" OFS $3 OFS "user" OFS $4 OFS "app.name" OFS $8
      print "G", "process.cpu", $5, d
      print "G", "process.memory.rss", $6, d
      if (total > 0) printf "G\tprocess.memory.percent\t%.2f\t%s\n", $6 / total * 100, d
      if ($3 in th) print "G", "process.threads", th[$3], d
    }' "$WORK_DIR/threads.tsv" "$top"
}

collect_agent() {
  rec G agent.heartbeat 1 agent.version "$DTMA_VERSION"
  rec G agent.spool.files "$(spool_count)"
  rec C agent.ingest.failures "$(read_count ingest_failures)"
  rec C agent.watchdog.restarts "$(read_count watchdog_restarts)"
}

collect_all() {
  collect_cpu
  collect_sysctl
  collect_memory
  collect_disk
  collect_diskio
  collect_network
  collect_power
  collect_system
  collect_processes
  collect_agent
}
