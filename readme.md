# Timesync

A small Windows command line tool that keeps the system clock synchronized with internet time servers. It installs itself as a background service that starts on boot, similar to NetTime.

Written in [Odin](https://odin-lang.org) as a single file with no dependencies beyond the Windows API.

## Features

- Synchronizes the clock using SNTP (NTP version 4 over UDP port 123)
- Runs as a Windows service that starts automatically on boot
- Syncs on start and then every hour; retries every minute if no server responds (e.g. network not up yet)
- Queries each server several times and uses the sample with the lowest round trip for better accuracy
- Falls back through multiple servers: `pool.ntp.org`, `time.cloudflare.com`, `time.google.com`, `time.windows.com`
- Shows clock offset, time zone and service state
- Restarts automatically if the service crashes

## Building

Requires the [Odin compiler](https://odin-lang.org/docs/install/).

```
odin build .
```

## Usage

```
timesync <command> [server]
```

| Command | Description |
| --- | --- |
| `help` | Print available commands |
| `install` | Install and start the background service |
| `uninstall` | Stop and remove the background service |
| `status` | Show clock offset, time zone and service state |
| `sync [server]` | Synchronize the clock now, optionally with a specific server |

`install`, `uninstall` and `sync` require an elevated (administrator) prompt. On Windows 11 with Sudo enabled you can also use `sudo timesync sync`.

### Installing the service

Place `timesync.exe` where you want it to live (for example `C:\Program Files\timesync\`), then from an administrator prompt run:

```
timesync install
```

The service runs the executable from the location it was installed from, so don't move or delete it afterwards. To move it, run `timesync uninstall`, move the file and install again.

### Checking status

```
> timesync status
Local time:    2026-10-22 11:19:27.854 (Thursday)
UTC time:      2026-10-22 08:19:27.854
Time zone:     FLE Standard Time (UTC+03:00)
               FLE Daylight Time, daylight saving time in effect
Clock offset:  +0.0441 s vs pool.ntp.org (round trip 1.0 ms)
               clock is in sync
Service:       running
Windows Time:  stopped
Last log:      2026-10-22 11:19:02.120  clock already in sync (offset +0.0004 s, pool.ntp.org, round trip 1.2 ms)
```

`status` does not require administrator rights.

## Logging

Every sync is logged to `C:\ProgramData\timesync\timesync.log`. Entries from manual `timesync sync` runs are marked with `[manual]`. The log is cleared once it grows past 1 MB.

## Windows Time service

Windows has its own time service (`w32time`) that also adjusts the clock. Running both works, but they may make competing adjustments. `timesync status` shows whether it is running. To disable it, from an administrator prompt:

```
sc stop w32time
sc config w32time start= disabled
```

## Configuration

Settings are constants at the top of `main.odin`. Change them and rebuild:

| Constant | Default | Description |
| --- | --- | --- |
| `SYNC_INTERVAL_MS` | 1 hour | Time between syncs |
| `RETRY_INTERVAL_MS` | 1 minute | Time between retries when no server responds |
| `NTP_TIMEOUT_MS` | 2 seconds | How long to wait for a server reply |
| `NTP_SAMPLES` | 4 | Queries per server |
| `DEFAULT_SERVERS` | see above | Servers to try, in order |

## License

MIT, see [license.txt](license.txt).
