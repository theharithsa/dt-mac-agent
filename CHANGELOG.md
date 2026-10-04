# Changelog

All notable changes to this project are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

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

[0.0.2]: https://github.com/theharithsa/dt-mac-agent/releases/tag/v0.0.2
[0.0.1]: https://github.com/theharithsa/dt-mac-agent/releases/tag/v0.0.1
