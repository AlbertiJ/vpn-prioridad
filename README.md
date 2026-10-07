# vpn-prioridad

**English** · [Español](README.es.md)

All-in-one **Windows** tool (a single `.bat`, nothing to install) that makes your VPN win on **outbound traffic** and **name resolution**, **monitors** the connection, and keeps a **log and a report** you can hand to your administrator.

> It started as a real problem: connected to a VPN, internal websites kept failing because Windows still sent traffic through the home connection and asked the wrong DNS servers first. I diagnosed it, solved it with the help of AI, and turned the fix into a reusable tool.

*The tool's menus and messages are in Spanish; this README explains every screen.*

## The problem

Windows merges the DNS servers of **all** active interfaces and picks the route by the **metric** of each one. When your home adapter has the lowest metric:

1. Traffic meant for the VPN leaves through your internet provider.
2. Internal names are asked to your provider's DNS, which doesn't know them (`nslookup` times out or fails).

## How it works

```
 you connect to the VPN
          │
          ▼
  detect the VPN adapter ── (from the OpenVPN log, or pick it yourself)
          │
          ▼
  1. remove the VPN's DNS from every other adapter  (back to DHCP, verified)
  2. put your DNS on the VPN adapter only
  3. VPN metric → 1   |   other adapters → 70       (IPv4 and IPv6)
  4. check for IPv6 DNS leaks (optional: turn IPv6 off for the session)
  5. flush DNS cache + ARP table
          │
          ▼
  VERIFY: does the traffic exit through the VPN?  does the internal name resolve?
          │
          ├── OK   → done
          └── FAIL → tells you what to check, and the monitor keeps watching
```

Everything is reversible: option **4** restores DNS, metrics, IPv6 and caches, and checks that no VPN DNS is left on other adapters.

## Screenshots

> The screenshots are **illustrative renderings with fictitious data** (documentation IP ranges `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24` and `example.local`). They follow the tool's real output format.

**Main menu**

![Main menu](docs/img/menu.png)

**Option 1 – the problem:** the home adapter (`Ethernet`, effective metric 25) beats the VPN (35), so traffic leaves through the provider.

![Network status before forcing](docs/img/problem.png)

**Option F – forced mode:** five steps and a final verification.

![Forced mode](docs/img/forced.png)

**Option 6 – live monitor:** it detects the moment traffic stops using the VPN and offers to force it again.

![Live monitor](docs/img/monitor.png)

**Option 7 – outage history**

![Outage history](docs/img/history.png)

## Quick start

1. Connect to the VPN **first**.
2. Double-click `VPN-Prioridad-TodoEnUno.bat` and accept the administrator prompt.
3. Option **5**: enter **the DNS servers your administrator gave you** (and, optionally, an internal name that only resolves through the VPN, used for the final check). They are saved in `logs\vpn_config.json`.
4. Choose **F**. When you finish using the VPN, choose **4** to restore everything.

Restore without the menu: `VPN-Prioridad-TodoEnUno.bat -Restore`

## Three ways to run it

| Format | How | Notes |
|---|---|---|
| **`.bat` all-in-one** | Double-click `VPN-Prioridad-TodoEnUno.bat` | Asks for administrator rights by itself and bypasses the execution policy. The easiest option. |
| **`.ps1` (PowerShell)** | From an administrator PowerShell: `.\VPN-Prioridad.ps1` | If PowerShell blocks it: `powershell -NoProfile -ExecutionPolicy Bypass -File .\VPN-Prioridad.ps1` (or `Unblock-File .\VPN-Prioridad.ps1` if you downloaded it). |
| **`.exe` (compile it yourself)** | `powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\Build-Exe.ps1` | Produces `dist\VPN-Prioridad.exe`, which asks for administrator rights when opened. Uses [ps2exe](https://github.com/MScholtes/PS2EXE) (installed for your user only). |

**Why there is no ready-made `.exe` in the repo:** an unsigned executable is often blocked by SmartScreen or antivirus, and for a tool that changes your network settings you should be able to read exactly what you run. Compile it from the source.

`VPN-Prioridad.ps1` is the single source of truth. The `.bat` is generated from it with `tools\Build-Bat.ps1`, so edit the `.ps1` and rebuild.

## Menu

| Key | What it does |
|---|---|
| `F` | **Forced mode**: everything above, with verification |
| `1` | Show network status (changes nothing) |
| `2` | Apply the VPN's DNS (offers to lower the metric if another adapter wins) |
| `3` | Set the VPN metric to 1 only |
| `4` | **Restore everything** (DNS, metrics, IPv6, DNS cache, ARP) |
| `5` | Set the DNS servers and the test name |
| `I` | Change the selected VPN interface |
| `6` | Live monitor (every 5 s, configurable time limit) |
| `7` | Outage history |
| `8` | OpenVPN log: connection, reconnection and error events |
| `9` | Delete or archive records |
| `A` | **Report for the administrator** |

## Logs and the report for your administrator

Everything is written to the `logs\` folder next to the `.bat`:

| File | Content | Example |
|---|---|---|
| `vpn_eventos.csv` | Events with date, type and severity (INFO, OK, AVISO, CAIDA, ACCION) | [`examples/vpn_eventos.sample.csv`](examples/vpn_eventos.sample.csv) |
| `vpn_monitor.log` | The same, as readable text | |
| `informe_admin_*.txt` | Report: system, routes, metrics, DNS, OpenVPN status, outage summary and latest OpenVPN events | [`examples/informe_admin.sample.txt`](examples/informe_admin.sample.txt) |
| `vpn_config.json` | Your DNS servers and test name | [`examples/vpn_config.sample.json`](examples/vpn_config.sample.json) |
| `vpn_dns_state.json` | Previous state, so it can be restored | |

## Privacy and safety

- **The code contains no DNS servers, domains or IPs from anyone**: you enter your own.
- `logs\` is in `.gitignore`. Don't publish those files.
- Logs and the report include the computer name, adapter names, DNS servers and routes. Review them before sending.
- The tool changes DNS and metrics on your machine. On a work computer, check with your administrator first.

## Requirements and limits

- Windows 10/11, PowerShell 5.1 (included) and administrator rights to apply changes. Without them you can still use diagnostics and monitoring.
- Automatic adapter detection and the log features target **OpenVPN**. With another VPN, pick the adapter manually (`I`).
- Designed for **full-tunnel** setups (the VPN carries the default route). With split tunneling, the "traffic exits through the VPN" check will report a failure even if everything works.
- Turning IPv6 off briefly resets the adapter (the connection drops for a moment). Option `4` turns it back on.

## If the verification fails

1. The selected interface is not the VPN → option `I` and check its gateway.
2. The tunnel dropped → option `1` and check that OpenVPN is `Running`.
3. The internal DNS changed → option `5`.

## How I built it with AI

1. I described the symptom and pasted the output of the diagnostic commands (`Get-NetRoute`, `Get-DnsClientServerAddress`, `Resolve-DnsName`), without sensitive data.
2. I asked for the likely cause and how to confirm it.
3. I turned each loose command into a menu option, with verification and rollback.
4. I added monitoring and logs so I could explain the problem to the administrator with data.

The result: something that used to waste my time on every connection is now solved with one click.

## Project layout

```
VPN-Prioridad.ps1               the tool (PowerShell)
VPN-Prioridad-TodoEnUno.bat     the same tool wrapped in a double-click launcher (generated)
tools/Build-Bat.ps1             regenerates the .bat from the .ps1
tools/Build-Exe.ps1             compiles the .ps1 to an .exe (ps2exe)
tools/bat-header.txt            the launcher part of the .bat (self-elevation)
docs/img/                       screenshots
examples/                       sample config, event log and administrator report
```

## License

[MIT](LICENSE) © 2026 AlbertiJ. Free to use, modify and share. Provided as is, with no warranty: it changes network settings, so use it at your own risk.
