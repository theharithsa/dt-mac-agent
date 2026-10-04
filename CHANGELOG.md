# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.1.1] - 2026-10-05

### Added

- Installer verifies end-to-end connectivity after starting the agent: it waits for the first real metric batch,
  reports `Successfully connected to Dynatrace environment <url>`, and only then prints the success summary.
  If log shipping is enabled, the first log upload is verified as well. Fails with a clear error if Dynatrace rejects the batch.

## [0.1.0] - 2026-10-05

### Added

- Metric metadata: every metric is sent with a display name, description and unit (`dt.meta.*`) at start-up,
  after upgrades and daily. The catalog lives in `lib/metrics.tsv`, and `dtmacctl metrics` lists it.
- Auto-update: the watchdog checks GitHub releases once a day and installs newer versions after SHA-256
  verification (`AUTO_UPDATE=1`, default). Manual: `sudo dtmacctl update [--check]`.
- Optional shipping of the agent's own logs to Dynatrace Logs (`SEND_LOGS=1`), with original timestamps,
  log levels and `service.name=dt-mac-agent`.
- Installer prompts for install location, log shipping and auto-update (or `DTMA_PREFIX`, `DTMA_SEND_LOGS`,
  `DTMA_AUTO_UPDATE`). Installing to a custom location is validated for safe, root-owned parent directories.
- New metrics: `process.instances`, `app.threads`, `app.memory.percent`. New dimension: `app.bundle.id`.

### Changed (breaking: metric keys and dimensions)

- Processes are grouped by executable name and owner. The `rank`, `top.by` and `pid` dimensions are removed;
  they split one process into many short, gappy series. The agent reports the union of the top `TOP_N` groups
  by CPU and by memory.
- Dimensions renamed to semantic names: `process.name` → `process.executable.name`, `user` → `process.owner`,
  `mount`/`device` → `disk.mount`/`disk.device`, `disk` → `disk.device`, `interface` → `network.interface`,
  `arch`/`hw.model` → `host.arch`/`host.model`; added `os.type` and `process.executable.path`.
- `agent.collect.seconds` → `agent.collect.duration`; `disk.io.*.time_ns.count` → `disk.io.*.time.count` (unit NanoSecond).
- Installer log lines use the same format as the other logs.

## [0.0.2] - 2026-10-05

### Added

- `ingest.log`: one line per batch sent to Dynatrace with line count, size, HTTP result, accepted/invalid lines,
  collect/send duration, spool size and a per-category breakdown. Re-sent buffered batches are logged too.
- `last-payload.txt`: the most recent batch exactly as sent; `dtmacctl payload` prints it.
- `LOG_PAYLOADS=1` option to append every full batch to `payloads.log`.
- `install.log`: the full installer output with timestamps.
- The watchdog logs the result of every check, not only restarts.
- `dtmacctl logs [agent|ingest|watchdog|install] [-f]`.

### Changed

- Logs moved from `/var/log/dt-mac-agent` to `/Library/Logs/dt-mac-agent`, so they are visible in Console.app.
  Runtime logs are readable without `sudo` (they never contain the token); `install.log` is readable by admin users.
- Log timestamps use local time with the UTC offset.

## [0.0.1] - 2026-10-05

### Added

- Collector daemon (`dt-mac-agent`) that pushes metrics to the Dynatrace metrics ingest API every 60 s:
  CPU, load, memory, swap, memory pressure, disk usage, inodes, disk I/O, network, TCP connections,
  power and battery, thermal state, top 10 processes by CPU and by memory, and per-app aggregation of all running `.app` bundles.
- Watchdog daemon (`dt-mac-watchdog`) that restarts the agent when it is unloaded, stopped or hung (stale heartbeat).
- On-disk spool that retries failed batches for up to 55 minutes.
- Support for platform tokens (`dt0s16.`) and classic API tokens (`dt0c01.`).
- `dtmacctl` CLI: status, start, stop, restart, logs, test, send-test, config, uninstall.
- One-line installer with SHA-256 release verification and a connection test before start-up.
- Log rotation via `newsyslog`.
- CI (shellcheck + macOS dry-run) and tag-based GitHub release workflow.

[0.1.1]: https://github.com/theharithsa/dt-mac-agent/releases/tag/v0.1.1
[0.1.0]: https://github.com/theharithsa/dt-mac-agent/releases/tag/v0.1.0
[0.0.2]: https://github.com/theharithsa/dt-mac-agent/releases/tag/v0.0.2
[0.0.1]: https://github.com/theharithsa/dt-mac-agent/releases/tag/v0.0.1
