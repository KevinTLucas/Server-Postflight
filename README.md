# Server Postflight

Server Postflight is a read-only, post-maintenance verification tool for Windows
servers, websites, and HTTP application endpoints. It is designed for the person
who performs the final check after servers have been patched and restarted.

The operator does not need to know PowerShell or use a command line. Configure the
checks in plain JSON files, double-click **Run Server Postflight.cmd**, enter a
password only if prompted, and review the color-coded results. Every run also
creates a timestamped text log, CSV file, and formatted HTML report.

“Postflight” means the final checklist performed after maintenance, before the
servers and applications are handed back to their users. If you only need to run
the check, follow **Quick start**. The remaining sections teach you how to read the
results, safely change every configuration option, and troubleshoot a failure.

## What Server Postflight answers

After a maintenance window, Server Postflight helps answer these questions:

- Can each server name be resolved on the network?
- Is the server reachable, or is ping simply blocked?
- Are the required TCP ports accepting connections?
- Did the server reboot recently?
- Does its CPU, memory, and disk usage look reasonable?
- Are the expected Windows services running?
- Are the expected application processes running?
- Do the configured websites and application endpoints respond correctly?
- Are responses fast enough and, when requested, do they contain expected text?
- Are HTTPS certificates approaching expiration?

Server Postflight combines those answers into one PASS, WARN, or FAIL result for
each configured server or web check.

## What it does not do

Server Postflight does not patch, restart, repair, or reconfigure anything. It
does not restart stopped services, terminate processes, change certificates, or
modify remote systems. It reports what it finds so a person can decide what to do.

It is a point-in-time verification tool, not a continuously running monitoring
service. Run it whenever a fresh post-maintenance result is needed.

## Before you begin

The computer running Server Postflight needs:

- Windows PowerShell 5.1, which is included with supported Windows versions.
- Network access to the configured servers and websites.
- A corporate network or VPN connection when the targets are internal.
- Permission to query remote Windows information when those checks are enabled.

If the computer is not connected to the required network or VPN, internal checks
will fail even when the servers themselves are healthy.

Keep the entire Server Postflight folder together. The launcher, PowerShell file,
Config folder, and configuration files depend on their relative locations.

## Quick start

If this is a fresh copy from GitHub, first copy
`Config\Examples\ServerChecks.json` to `Config\ServerChecks.json` and copy
`Config\Examples\WebChecks.json` to `Config\WebChecks.json`. Remove the sample
entries and add the real targets. These two live files are deliberately excluded
from Git so internal server names and addresses are not published accidentally.

1. Open the **Config** folder.
2. Open **ServerChecks.json** to review Windows servers.
3. Open **WebChecks.json** to review websites and application endpoints.
4. Normally leave **Settings.json** unchanged unless a timeout or warning
   threshold needs adjustment.
5. Save and close the JSON files.
6. Connect to the required corporate network or VPN.
7. Double-click **Run Server Postflight.cmd**.
8. Enter requested passwords. Password entry is hidden.
9. Wait for the SUMMARY section and the `Finished` message.
10. Press any key to close the window after reviewing the result.
11. Open the newest file in **Reports** for the formatted report.

Do not double-click `ServerPostflight.ps1` directly. The CMD launcher starts it
correctly, preserves the final result, and keeps the window open.

## What happens during a run

Server Postflight follows the same sequence every time:

1. It reads all three live JSON files in Config.
2. It validates every setting and check. A configuration error stops the run
   before a password prompt or network connection occurs.
3. It requests each distinct configured account password once. A password can be
   skipped to try the current Windows account instead.
4. It runs each server and web check and displays results as they complete.
5. It prints a summary showing every target and its overall result.
6. It saves the text log, CSV data, and HTML report using the same timestamp.

The launcher returns a failure result when any target fails. Warnings do not make
the overall run fail, but they should still be reviewed.

## Understanding the on-screen results

Each individual line begins with a status:

| Status | Meaning | What the operator should do |
|---|---|---|
| PASS | The check succeeded. | No action is normally needed. |
| WARN | The target responded, but something deserves attention. | Read the detail and decide whether it is expected. |
| FAIL | The check failed or could not be verified. | Investigate before declaring maintenance complete. |
| INFO | Additional context that does not affect the result. | Use it to understand the target. |
| SKIP | A check was disabled or not configured. | Confirm that skipping it was intentional. |

A server or website receives its worst status. For example, a server with passing
DNS, ping, and uptime checks but a stopped required service receives FAIL.

Ping is the main exception: no ping response produces WARN rather than FAIL because
many healthy servers intentionally block ICMP. A failed required TCP port, remote
query, service, process, or HTTP result produces FAIL.

## Output files and reports

Server Postflight creates two output folders automatically.

### Logs

Each run creates two files with matching timestamps:

```text
Logs\ServerPostflight_2026-09-12_093015_123.log
Logs\ServerPostflight_2026-09-12_093015_123.csv
```

The `.log` file is a permanent plain-text copy of the console output. It is the
best file for troubleshooting because it contains every check and error message.

The `.csv` file contains one row per server or web check. It can be opened in
Excel for sorting, filtering, or combining results from several maintenance runs.

### Reports

Each run also creates a formatted report:

```text
Reports\ServerPostflightReport_2026-09-12_093015_123.html
```

Double-click the HTML file to open it in a browser. The report is self-contained
and does not require internet access. It contains:

- The run date and exact start time.
- The operator and computer that ran the check.
- The total elapsed time.
- An overall PASS, WARN, or FAIL banner.
- Counts of passed, warning, and failed targets.
- A compact summary table.
- A detailed card for every server and web check.
- The status, name, and explanation of every individual check.

The HTML report uses the same results as the console; it does not rerun or reinterpret
the checks. It can be saved with maintenance records or attached to a ticket.

## Configuration folder

Only the three JSON files directly inside Config are used during a normal run:

| File | Purpose | Who normally edits it |
|---|---|---|
| `Config\ServerChecks.json` | Windows servers, ports, system information, services, and processes. | The person maintaining the server list. |
| `Config\WebChecks.json` | Websites and HTTP application endpoints. | The person maintaining application checks. |
| `Config\Settings.json` | Output folders, timeouts, defaults, thresholds, and optional behavior. | Usually the tool owner or administrator. |

The files in `Config\Examples` demonstrate every supported option. They are never
loaded during a normal run, so changing an example does not change live checks.

## JSON basics

JSON is structured text. These rules prevent most editing errors:

- Property names and text values use double quotes: `"Name": "Application VM"`.
- A comma follows an item when another item comes after it.
- Do not put a comma after the final item in an object or list.
- Square brackets contain a list: `[3389, 443]`.
- Curly braces contain one server, web check, or group of settings.
- Windows account names need two backslashes: `"DISTRICT\\user"`.
- Boolean settings are `true` or `false` without quotes.
- Numbers do not use quotes.

Server Postflight reports the name and location of invalid JSON or an invalid
property. Fix the named file and run the launcher again.

### Notes inside JSON

Standard JSON does not support comments. Server Postflight therefore treats
`_comment` and any property beginning with `_comment_` as an operator note:

```json
{
  "_comment": "This text is for people and does not affect the check.",
  "_comment_ports": [
    "3389 is Remote Desktop.",
    "443 is the application HTTPS port."
  ],
  "Name": "Application VM",
  "Host": "APP-SERVER-01",
  "Port": [3389, 443]
}
```

Comment properties can contain one string or a list of strings and may appear at
the top of a configuration file or inside an individual check. Server Postflight
reads but ignores their values. Other unknown properties are rejected so a typo
such as `"ExpectedCodes"` cannot silently disable a real check.

## Configuring Windows server checks

`Config\ServerChecks.json` contains a `ServerChecks` list:

```json
{
  "_comment": "Windows servers checked after maintenance.",
  "ServerChecks": [
    {
      "Name": "Application VM",
      "Host": "APP-SERVER-01",
      "Port": [3389, 443],
      "User": "DISTRICT\\monitoring_user",
      "Info": ["uptime", "os", "memory", "cpu", "disk"],
      "Services": ["W3SVC"],
      "Processes": ["MyApplication.exe"]
    }
  ]
}
```

The outer `ServerChecks` list must remain, even if it is temporarily empty.

### Server-check properties

| Property | Required | Allowed form | Meaning |
|---|---:|---|---|
| `Name` | Yes | Text | Friendly label displayed in the console and reports. It does not have to match the Windows hostname. |
| `Host` | Yes | Text | Hostname, fully qualified domain name, or IP address. `localhost` or `.` checks the computer running Server Postflight. |
| `Port` | No | Number or list of numbers | TCP ports that must accept connections. When omitted, `DefaultTcpPort` from Settings.json is used. |
| `User` | No | Text | Windows account used for remote information, service, and process checks. When omitted, the current Windows account is used. |
| `Info` | No | Text or list | System information to request: `uptime`, `os`, `memory`, `cpu`, `disk`, or `all`. |
| `Services` | No | Text or list | Windows service names or exact display names that must be running. |
| `Processes` | No | Text or list | Executable names that must be running. The `.exe` suffix is optional. |
| `_comment` or `_comment_*` | No | Text or list | Human-readable notes ignored by the program. |

`Port`, `Info`, `Services`, and `Processes` accept either one value or a list:

```json
"Port": 3389
```

```json
"Port": [3389, 443]
```

### Server checks performed

For every configured server, Server Postflight can perform:

1. **DNS:** resolves the configured Host to one or more IP addresses. Failure is
   FAIL because the remaining hostname-based checks cannot be trusted.
2. **Ping (ICMP):** sends the configured number of ping requests. No response is
   WARN because firewalls commonly block ping on healthy systems.
3. **TCP ports:** opens a connection to every configured port. Each port must
   accept a connection within `TcpTimeoutSeconds` or it receives FAIL.
4. **Remote Windows checks:** when Info, Services, or Processes is configured,
   Server Postflight creates a read-only CIM session using WinRM, with DCOM as a
   compatibility fallback for transport problems.

DNS, ping, and TCP checks do not require a username or password. Credentials are
used only when remote Windows information is requested.

### Information choices

| Info value | Result |
|---|---|
| `uptime` | Time since the last boot and the exact last-boot timestamp. When `ExpectedRebootWithinHours` is enabled, an older boot receives WARN. |
| `os` | Windows edition and build number. This is informational and does not affect status. |
| `memory` | Free memory amount and percentage. Low free memory receives WARN. Missing or invalid data receives FAIL. |
| `cpu` | Average processor load. High load receives WARN. Missing data receives FAIL. |
| `disk` | Free space for every fixed disk. Low space receives WARN or FAIL according to Settings.json. |
| `all` | Shortcut for uptime, OS, memory, CPU, and disk. |

### Services and processes

For services, use the Windows service **Name** or its exact **DisplayName**, not
the service executable filename. A missing or stopped configured service receives
FAIL. The output also shows its state and startup mode.

For processes, enter the executable name, such as `MyApplication.exe` or
`MyApplication`. A missing configured process receives FAIL. When found, the
output shows how many instances are running, several process IDs, and their total
working memory.

## Configuring web checks

`Config\WebChecks.json` contains a `WebChecks` list:

```json
{
  "_comment": "Application endpoints checked after maintenance.",
  "WebChecks": [
    {
      "Name": "Application health page",
      "Url": "https://apps.district.org/health",
      "ExpectedCode": 200,
      "MaxResponseMilliseconds": 2500,
      "MustContain": "healthy"
    }
  ]
}
```

The outer `WebChecks` list must remain, even if it is temporarily empty. At least
one entry must exist between ServerChecks.json and WebChecks.json.

### Web-check properties

| Property | Required | Allowed form | Meaning |
|---|---:|---|---|
| `Name` | Yes | Text | Friendly label displayed in the console and reports. |
| `Url` | Yes | Complete HTTP or HTTPS URL | Address requested with HTTP GET. A username or password may not be embedded in the URL. |
| `ExpectedCode` | No | Number or list of numbers | Acceptable HTTP response code or codes. Defaults to 200. |
| `MaxResponseMilliseconds` | No | Zero or positive whole number | Per-check response-time warning limit. When omitted, the setting default is used. Zero disables the response-time warning for this check. |
| `MustContain` | No | Text | Case-insensitive text that must appear in a successful 2xx response body. |
| `_comment` or `_comment_*` | No | Text or list | Human-readable notes ignored by the program. |

Example with more than one acceptable response:

```json
"ExpectedCode": [200, 204]
```

Normal successful web checks follow redirects. When a 3xx response such as 302
is explicitly expected, Server Postflight inspects that redirect without following
it. `MustContain` may only be used when every expected code is in the 200–299 range.

For HTTPS URLs, Server Postflight separately reports certificate expiration. The
normal web request still performs Windows certificate trust validation unless
`SkipCertificateValidation` has deliberately been enabled.

Response bodies are not written to logs or reports. Server Postflight records only
their size and whether the configured `MustContain` text was found.

## Configuring settings

All properties in `Config\Settings.json` are required. The supplied defaults are
appropriate for ordinary use; make one change at a time and rerun the tool.

| Setting | Supplied value | Meaning |
|---|---:|---|
| `LogFolder` | `Logs` | Text-log and CSV destination. A relative path starts beside ServerPostflight.ps1. |
| `ReportFolder` | `Reports` | HTML-report destination. A relative path starts beside ServerPostflight.ps1. |
| `HttpTimeoutSeconds` | `15` | Maximum time allowed for one web request. |
| `TcpTimeoutSeconds` | `3` | Maximum time allowed for a TCP connection or TLS handshake. |
| `RemoteTimeoutSeconds` | `20` | Maximum time allowed for each remote CIM/WMI operation. |
| `PingCount` | `2` | Number of ping requests sent to each server. |
| `DefaultTcpPort` | `3389` | Port checked when a server entry does not provide Port. |
| `DefaultMaxResponseMilliseconds` | `3000` | Default web-response warning limit. Zero disables this warning globally unless a web check overrides it. |
| `ExpectedRebootWithinHours` | `0` | Warns when requested uptime is older than this many hours. Zero disables reboot enforcement. For a Sunday maintenance window, a value such as 24 or 36 is typical. |
| `CertificateWarningDays` | `30` | Warns when an HTTPS certificate expires within this many days. |
| `CpuWarningPercent` | `90` | Warns when CPU load is at or above this percentage. |
| `MemoryWarningPercent` | `10` | Warns when free memory is below this percentage. |
| `DiskWarningPercent` | `15` | Warns when free disk space is below this percentage. |
| `DiskFailurePercent` | `5` | Fails when free disk space is below this percentage. It cannot exceed DiskWarningPercent. |
| `SkipCertificateValidation` | `false` | When true, permits untrusted or self-signed HTTPS certificates. Keep false unless the endpoint and reason are known. Expiration is still reported separately. |
| `SkipRemoteChecks` | `false` | When true, skips Windows information, services, and processes while retaining DNS, ping, TCP, and web checks. |
| `UseCredentialDialog` | `false` | When true, uses a graphical credential prompt. When false, uses hidden password entry in the console. Neither choice saves the password. |

Boolean values must be written without quotation marks:

```json
"SkipRemoteChecks": false
```

## Credentials and safe use

Server Postflight is intentionally read-only.

- Remote Windows queries request information through Microsoft CIM/WMI.
- Web checks use HTTP GET and never submit configuration changes.
- TCP checks only establish and close a connection.
- No service, process, server, or website is changed.
- The complete configuration is validated before any target is contacted.

Usernames may be stored in ServerChecks.json, but passwords are never stored in a
configuration file, log, CSV, HTML report, or application-created credential file.
A password is held only in a PowerShell credential object in memory for the current
run and disappears when the process exits.

When several servers use the same User value, the password is requested once and
reused only in memory during that run. If a remote system rejects an explicit
credential, Server Postflight does not retry it through another protocol or against
later targets, reducing the risk of repeated failures and account lockout.

If User is omitted, Windows attempts the remote query using the account running
Server Postflight. Pressing Enter at an empty console password prompt also skips
the explicit credential and tries the current Windows account.

Logs and reports can contain hostnames, IP addresses, URL paths, usernames, machine
health information, and error messages. Treat them as internal operational records.
URL query strings and response bodies are deliberately excluded.

Keep `SkipCertificateValidation` set to false whenever possible. Setting it to true
affects only the current Server Postflight process and is restored when the run
finishes, but it removes an important HTTPS identity check during that run.

## Common configuration tasks

### Add a server

Copy one complete object inside the `ServerChecks` list, paste it after the previous
object, place a comma between the two objects, then change Name and Host. Add only
the optional Port, User, Info, Services, and Processes properties you need.

### Add a website or API endpoint

Copy one complete object inside the `WebChecks` list, paste it after the previous
object, add the separating comma, then change Name and Url. Start with an
ExpectedCode of 200 unless the application owner specifies another response.

### Remove a check

Delete its entire object from the opening `{` through the matching `}`. Then ensure
the objects before and after it are separated by exactly one comma.

### Temporarily run only connectivity checks

Set `SkipRemoteChecks` to true in Settings.json. This leaves DNS, ping, TCP, and all
web checks enabled but skips remote Windows information, services, and processes.
Set it back to false after troubleshooting.

### Require evidence of a recent reboot

Set `ExpectedRebootWithinHours` to a nonzero value such as 24 or 36 and make sure
the server's Info includes `uptime` or `all`. A server with an older boot time then
receives WARN.

## Troubleshooting

### Configuration error

Read the filename and property named in the red message. Common causes are a missing
comma, an extra final comma, mismatched brackets, a misspelled property, or a Windows
username containing one backslash instead of two. Compare the entry with the matching
file in `Config\Examples`.

### DNS failure

Confirm the Host spelling and connect to the required network or VPN. Try the fully
qualified domain name if a short hostname cannot be resolved.

### Ping warning

The server may be healthy while its firewall blocks ICMP. Use the TCP, remote, and
application results to decide. Ping alone does not fail a target.

### TCP port failure

Confirm the port number, server firewall, network path, and whether the application
that owns the port has started. A listening port confirms connectivity, not that the
entire application is healthy, so combine it with a service, process, or web check.

### Access denied or remote checks unavailable

Confirm the User spelling, password, and account permissions. The account needs
remote CIM/WMI access to `root\cimv2`. Also verify WinRM or WMI/DCOM access through
the server firewall. DNS, ping, and TCP may still pass without these permissions.

### Service not found

Use the service's Windows Name or exact DisplayName, not its `.exe` filename. An
administrator can identify it in `services.msc` or with `Get-Service`.

### Process not found

Use the executable name shown in Task Manager, with or without `.exe`. Verify that
the application normally keeps that process running and that its name has not
changed after an upgrade.

### HTTP status failure

Confirm ExpectedCode with the application owner. Authentication gateways may return
401, 403, or a redirect even while the site is reachable. Configure the expected
result that genuinely proves the application is ready.

### Certificate warning or trust failure

An expiration warning means renewal should be planned. A trust failure usually
means the computer lacks the issuing organization certificate or the site is
presenting the wrong certificate. Fix trust rather than enabling
SkipCertificateValidation whenever possible.

### The window closes immediately

Run **Run Server Postflight.cmd**, not ServerPostflight.ps1. If the launcher itself
was moved away from the other files, restore the complete folder structure.

## Files included with the application

| File or folder | Purpose |
|---|---|
| `Run Server Postflight.cmd` | Operator launcher; this is the file users double-click. |
| `ServerPostflight.ps1` | Read-only implementation used by the launcher. Operators do not edit it. |
| `Config\Settings.json` | Live global settings. |
| `Config\ServerChecks.json` | Local-only Windows server checks; excluded from Git. |
| `Config\WebChecks.json` | Local-only website and HTTP endpoint checks; excluded from Git. |
| `Config\Examples` | Complete reference configurations that are not run. |
| `Logs` | Created automatically for text logs and CSV data. |
| `Reports` | Created automatically for timestamped HTML reports. |
| `Test-ServerPostflight.ps1` | Offline developer smoke test. Operators do not run it. |

## Developer verification

After changing the implementation or configuration schema, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ServerPostflight.ps1
```

The smoke test validates PowerShell syntax, all live and example JSON files,
configuration comments, strict property checking, authentication-error handling,
TCP behavior, an actual loopback HTTP redirect, status priority, HTML generation,
and launcher wiring. It uses the local computer only and never contacts targets
from Config.
