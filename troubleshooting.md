# Troubleshooting dt-mac-agent

Start with the [quick health check](#quick-health-check). Most problems show up in `sudo dtmacctl status` or in one
of the log files under `/Library/Logs/dt-mac-agent/`.

- [Quick health check](#quick-health-check)
- [Token and permissions](#token-and-permissions)
- [Updating or rotating the token](#updating-or-rotating-the-token)
- [Environment URL and connectivity](#environment-url-and-connectivity)
- [No data in Dynatrace](#no-data-in-dynatrace)
- [Dimensions missing in the metric definition or split picker](#dimensions-missing-in-the-metric-definition-or-split-picker)
- [Agent not running or restarting](#agent-not-running-or-restarting)
- [Buffered batches (spool) growing](#buffered-batches-spool-growing)
- [Log shipping to Dynatrace](#log-shipping-to-dynatrace)
- [Auto-update](#auto-update)
- [Installer problems](#installer-problems)
- [Gaps and odd values](#gaps-and-odd-values)
- [Clean reinstall](#clean-reinstall)
- [Collecting diagnostics](#collecting-diagnostics)

---

## Quick health check

```bash
sudo dtmacctl status            # agent/watchdog state, heartbeat, last send, spool, log shipping, auto-update
dtmacctl logs ingest            # one line per batch: lines, HTTP result, accepted/invalid
dtmacctl logs agent             # errors and warnings
sudo dtmacctl send-test         # send one test metric with the configured URL + token
dtmacctl test                   # collect once and print the lines (nothing is sent)
dtmacctl payload                # the last batch exactly as sent
```

A healthy agent shows `state=running`, a heartbeat under 60s old, `last send ... ok 202`, `spool: 0` and lines
like this in `ingest.log`:

```text
[INFO] batch 497 lines (113255 B): ok 202, accepted=497 invalid=0, collect=2s send=0s, spool=0 | ...
```

---

## Token and permissions

| Error (in `agent.log`, `ingest.log` or the installer) | Cause | Fix |
|---|---|---|
| `HTTP 401` | Token wrong, expired or revoked | [Update the token](#updating-or-rotating-the-token) |
| `HTTP 403 ... missing required permission: openpipeline:metrics:ingest` | Platform token without metric ingest permission | Add the permission, or use an API token with `metrics.ingest` |
| `HTTP 403` on metrics with an API token | Token lacks `metrics.ingest` | Add the scope |
| `metadata: Settings API not usable (HTTP 403)` | Token lacks `settings.write` (API) / `settings:objects:write` (platform) | Add the scope. Metrics still flow, but dimensions are not listed in metric definitions |
| `log shipping failed (HTTP 403)` | Token lacks `logs.ingest` | Add the scope, or set `SEND_LOGS=0` |

Required scopes for a **platform token** (`dt0s16.`, recommended; one token covers everything):

| Scope | Required? |
|---|---|
| `openpipeline:metrics:ingest` | Required |
| `settings:objects:write` | Recommended (metric definitions with dimensions) |
| `openpipeline:logs:ingest` | Only with `SEND_LOGS=1` |
| `document:documents:read`, `document:documents:write` | Only for the dashboard upload |

**`HTTP 403 ... User is missing required permission` although the token has the scope:** a platform token can only
use permissions its owner also has. Make sure the token owner's IAM policies allow the permission (for example
`ALLOW openpipeline:metrics:ingest;`), then wait a few minutes for the change to take effect. A token with the right
scopes and an owner with the right policies works without being recreated.

Required scopes for a classic API token (`dt0c01.`):

| Scope | Required? |
|---|---|
| `metrics.ingest` | Required |
| `settings.write` | Recommended (metric definitions with dimensions) |
| `logs.ingest` | Only with `SEND_LOGS=1` |

---

## Updating or rotating the token

`sudo dtmacctl update` and automatic updates **never** ask for or change the token; they keep `/etc/dt-mac-agent/config`.
You do not need to uninstall or reinstall.

**Adding a scope to the existing token** (same token string): edit the token in Dynatrace (*Access tokens*). Nothing
changes on the Mac. Make the agent re-send its metric definitions straight away:

```bash
sudo rm -f /var/lib/dt-mac-agent/metadata.sent
sudo dtmacctl restart
dtmacctl logs ingest | grep metadata     # expect: ... via Settings API (HTTP 200)
```

The definitions are also re-sent automatically after every upgrade and once a day.

**Using a new token**: re-run the installer with `DT_TOKEN`. It upgrades in place, keeps all other settings,
tests the new token and only then restarts the agent. To keep the token out of your shell history, read it
into a variable with hidden input first:

```bash
# zsh (macOS default)
read -rs "T?Token: "; echo
# bash
read -rsp "Token: " T; echo

curl -fsSL --connect-timeout 8 --retry 3 https://raw.githubusercontent.com/theharithsa/dt-mac-agent/main/install.sh | sudo DT_TOKEN="$T" bash; unset T
```

**Editing the config by hand**:

```bash
sudo nano /etc/dt-mac-agent/config        # change DT_TOKEN="..."
sudo dtmacctl send-test                   # verify
sudo dtmacctl restart
```

If a token was ever pasted on a command line, remove it from your shell history (`~/.zsh_history`) or rotate it.

---

## Environment URL and connectivity

- Use `DT_ENV_URL="https://<env-id>.live.dynatrace.com"`. The agent also accepts `.apps.` and picks the right host:
  API tokens (`dt0c01.`) use `.live.dynatrace.com/api/v2/...`, and platform tokens (`dt0s16.`) use
  `.apps.dynatrace.com/platform/classic/environment-api/v2/...`.
- `sudo dtmacctl status` shows the endpoint in use.
- Basic reachability (DNS + TLS) from the Mac:

  ```bash
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' https://<env-id>.live.dynatrace.com/api/v2/metrics/ingest
  ```

  Any HTTP code (typically `401` or `405`) means the network path works. `000` or a curl error means DNS, firewall,
  VPN or proxy problems.
- **Proxy**: the daemon runs under launchd and does not inherit your shell's proxy variables. If outbound traffic must
  go through a proxy, add `https_proxy` to the `EnvironmentVariables` dict of
  `/Library/LaunchDaemons/com.theharithsa.dt-mac-agent.plist`, then `sudo dtmacctl restart`.
  An upgrade rewrites this file, so re-apply the change after each upgrade.
- **Managed / ActiveGate**: set `DT_INGEST_URL`, `DT_LOGS_URL` and `DT_SETTINGS_URL` in the config to full endpoint URLs.

---

## No data in Dynatrace

1. `dtmacctl logs ingest`: are batches `ok 202` with `accepted > 0`? If not, see [Token and permissions](#token-and-permissions).
2. Query the raw data, using a short timeframe:

   ```sql
   metrics from: now()-15m | filter startsWith(metric.key, "macos.")
   ```

3. Metric keys and dimensions changed in **0.1.0** (e.g. `process.name` → `process.executable.name`). Dashboards built
   on older versions need updating, and timeframes spanning the upgrade show both the old and the new series.
4. The metric prefix is `macos.` unless `METRIC_PREFIX` was changed (`sudo dtmacctl config`).
5. New metrics can take 1–2 minutes to appear. Counter metrics (`*.count`) appear from the second minute, because the
   first sample has no previous value to compute a delta from.

---

## Dimensions missing in the metric definition or split picker

The data always carries the dimensions (check with the DQL above). The **metric definition** (and the Notebook split
picker, which reads from it) lists dimensions only when they were declared through the Settings API.

1. `dtmacctl logs ingest | grep metadata`
   - `... via Settings API (HTTP 200)`: declared. Pickers can take a few minutes to refresh.
   - `Settings API not usable (HTTP 403)`: add `settings.write` to the token, then
     [force a re-send](#updating-or-rotating-the-token).
2. Typing the dimension name directly works regardless:

   ```sql
   timeseries cpu = avg(macos.process.cpu), by: { host.name, process.executable.name, app.name }
   ```

Dimension display names are defined in [lib/dimensions.tsv](lib/dimensions.tsv), and metric names, units and
descriptions in [lib/metrics.tsv](lib/metrics.tsv).

---

## Agent not running or restarting

```bash
sudo dtmacctl status
dtmacctl logs agent
dtmacctl logs watchdog
cat /Library/Logs/dt-mac-agent/agent.stderr.log      # crashes / bash errors
sudo launchctl print system/com.theharithsa.dt-mac-agent | head -40
```

| Symptom | Cause / fix |
|---|---|
| `NOTE: agent was stopped with 'dtmacctl stop'` | Intentional stop that survives reboots. Run `sudo dtmacctl start` |
| `agent: not loaded` | Run `sudo dtmacctl start`. The watchdog also re-loads the agent within a minute |
| `watchdog: not loaded` | The agent re-loads the watchdog within a minute, or run `sudo dtmacctl start` |
| `watchdog: state=not running` | Normal. The watchdog runs for a moment every 60s |
| `restarts` keeps increasing | See `watchdog.log` for the reason (`heartbeat is Ns old` = hung collection). Check `agent.stderr.log` |
| Heartbeat old after the Mac woke from sleep | Normal. The watchdog may restart the agent once after wake |

---

## Buffered batches (spool) growing

`spool: N buffered batches` means sends are failing and batches are waiting to be retried
(`/var/lib/dt-mac-agent/spool/`).

- Typical causes: no network, VPN/firewall, token revoked, or a missing permission. See `dtmacctl logs agent`.
- Batches older than `SPOOL_MAX_AGE_MIN` (55 min) are dropped, because Dynatrace rejects data older than 1 hour.
  At most `SPOOL_MAX_FILES` (120) batches are kept.
- Once the cause is fixed, the spool drains automatically on the next cycles (`re-sent buffered batch` in `ingest.log`).

---

## Log shipping to Dynatrace

Enabled with `SEND_LOGS=1` (shown in `sudo dtmacctl status` as `log ship`).

| Status | Meaning / fix |
|---|---|
| `last result ok` | Working |
| `last result 403` | Token lacks `logs.ingest` |
| `last result 000` | Network problem |
| `pending` | Nothing sent yet. Wait a minute |

Find the logs in Dynatrace:

```sql
fetch logs | filter service.name == "dt-mac-agent" | sort timestamp desc
```

Unsent lines are retried every minute. To turn log shipping off, set `SEND_LOGS=0` in the config and run
`sudo dtmacctl restart`.

---

## Auto-update

```bash
sudo dtmacctl update --check     # compare installed vs. latest GitHub release
sudo dtmacctl update             # install now
dtmacctl logs watchdog | grep update
dtmacctl logs install
```

| Symptom | Cause / fix |
|---|---|
| Never updates | `AUTO_UPDATE=0` in the config, or the installed version is older than 0.1.0 (re-run the install command once) |
| `could not reach GitHub` | No access to `api.github.com` / `github.com`. Retried after 24h |
| `SHA-256 mismatch` | The download was corrupted or tampered with. Nothing was installed; retried after 24h |
| Update failed | See `install.log`. The previous files stay in place if the download or checksum fails |

The check runs at most once every 24h (`/var/lib/dt-mac-agent/update.checked`). Delete that file to force a check
on the next watchdog run.

---

## Installer problems

| Symptom | Cause / fix |
|---|---|
| Looks stuck after entering the sudo password | It is waiting at a prompt. The token prompt hides input; paste the token and press Enter |
| Stuck at `Downloading dt-mac-agent ...` for minutes (versions before 0.1.5) | Your network cannot reach one of GitHub's download servers (CDN nodes `185.199.108-111.133`), and curl waited about 45s on it each time. 0.1.5+ uses an 8s connect timeout with retries, so it moves to a working node within seconds. Press Ctrl+C and re-run the install command |
| `no terminal available` / prompts skipped | Running without a TTY (MDM, scripts). Pass `DT_ENV_URL`, `DT_TOKEN` and optionally `DTMA_PREFIX`, `DTMA_SEND_LOGS`, `DTMA_AUTO_UPDATE` as environment variables |
| `connection test failed; agent NOT started` | URL or token wrong, or a missing scope. The line above it shows the HTTP error |
| `Dynatrace rejected its first batch` | Same as above, for the running agent. See `dtmacctl logs agent` |
| `install location ... is not allowed` / `parent directory ... must be owned by root` | The program runs as root, so it must live in a root-owned path. Use `/usr/local/dt-mac-agent` or `/opt/dt-mac-agent` |
| `... already exists and is not empty` | Choose a dedicated, empty directory |
| Want to see what happened | `dtmacctl logs install` (also contains automatic updates) |
| `Dashboard upload failed (HTTP 401/403)` | The dashboard needs a **platform token** (`dt0s16.`) with `document:documents:write`; classic API tokens cannot upload dashboards. Retry with `sudo dtmacctl dashboard` |
| `Dashboard upload failed (HTTP 409)` | Someone edited the dashboard at the same moment. Run `sudo dtmacctl dashboard` again |
| Dashboard edits disappeared | Re-uploading (installer or `dtmacctl dashboard`) overwrites the dashboard. Duplicate it in Dynatrace before customizing |

To debug the installer step by step:

```bash
curl -fsSL -o /tmp/dtma-install.sh https://raw.githubusercontent.com/theharithsa/dt-mac-agent/main/install.sh
sudo bash -x /tmp/dtma-install.sh
```

`bash -x` prints commands including the token if you pass one via `DT_TOKEN`. Don't share that output.

---

## Gaps and odd values

| Observation | Explanation |
|---|---|
| Gaps while the Mac was asleep | Nothing is collected during sleep. Counter deltas are skipped after gaps > 5 min to avoid spikes |
| `process.cpu` / `app.cpu` above 100 | Values are % of **one** core. A 10-core Mac can reach 1000 |
| A process appears and disappears | Only the top `TOP_N` process groups by CPU and memory are reported each minute |
| Many apps with `app.type=system` | macOS background apps (Finder, Dock, Control Center, …) are `.app` bundles too. Filter `app.type == "user"` |
| `cpu.speed_limit` missing | Only available on Intel Macs. Apple Silicon reports `system.thermal.warning` |
| Battery metrics missing | Desktop Macs have no battery |

---

## Clean reinstall

```bash
sudo dtmacctl uninstall              # removes everything, including config and logs
# or keep the config (URL, token, options):
sudo dtmacctl uninstall --keep-config

curl -fsSL --connect-timeout 8 --retry 3 https://raw.githubusercontent.com/theharithsa/dt-mac-agent/main/install.sh | sudo bash
```

---

## Collecting diagnostics

When opening an issue, attach the output of the following. The token is masked, and the logs never contain it.

```bash
sudo dtmacctl status
sudo dtmacctl config
dtmacctl logs | tail -n 200
sw_vers; uname -m
```
