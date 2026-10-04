# Converts collector records into Dynatrace metric ingestion protocol lines.
# Input (tab-separated): TYPE metric value [dimKey dimValue]...
#   TYPE G = gauge, C = monotonic counter (emitted as "<metric>.count" delta vs. previous run).
# Vars: prefix, ts (epoch ms), host, osver, model, arch, statefile, newstate.

function q(s) {
  gsub(/\\/, "/", s)
  gsub(/"/, "'", s)
  if (length(s) > 250) s = substr(s, 1, 250)
  return "\"" s "\""
}

BEGIN {
  FS = "\t"
  common = ",host.name=" q(host) ",os.version=" q(osver) ",hw.model=" q(model) ",arch=" q(arch)
  if (statefile != "") {
    while ((getline line < statefile) > 0) {
      split(line, p, "\t")
      prev[p[1]] = p[2]
    }
    close(statefile)
  }
  # Skip deltas after long gaps (sleep, downtime) so they don't show as spikes.
  fresh = ("__ts" in prev) && (ts - prev["__ts"] <= 300000)
}

NF >= 3 && $3 ~ /^-?[0-9]+(\.[0-9]+)?$/ {
  key = prefix "." $2
  dims = ""
  for (i = 4; i < NF; i += 2)
    if ($(i + 1) != "") dims = dims "," $i "=" q($(i + 1))
  if ($1 == "G") {
    print key dims common " gauge," $3 " " ts
  } else if ($1 == "C") {
    id = key dims
    cur[id] = $3
    if (fresh && (id in prev) && $3 + 0 >= prev[id] + 0)
      printf "%s.count%s%s count,delta=%.0f %s\n", key, dims, common, $3 - prev[id], ts
  }
}

END {
  if (newstate != "") {
    printf "__ts\t%s\n", ts > newstate
    for (id in cur) printf "%s\t%s\n", id, cur[id] > newstate
    close(newstate)
  }
}
