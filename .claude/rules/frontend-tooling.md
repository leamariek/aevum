---
id: frontend-tooling
title: Frontend Tooling (Chrome DevTools MCP, Playwright)
created: 2026-05-15T00:00:00Z
updated: 2026-05-17T00:00:00Z
status: active
owner: founder
---

# Frontend Tooling

Frontend work must not be "blind". Claude needs a live view of the
rendered UI, the DOM, the console, and network traffic; source alone
hides layout breakpoint issues, hydration mismatches, per-frame
allocation problems in animated canvases, and the real API payload
flow.

This rule applies to any project consuming Aevum that ships a web UI.
Backend-only or CLI-only projects can ignore this file entirely.

## Default: Playwright

The default visual tool is Playwright. It runs scripted (test-driven)
flows and produces screenshots plus console snapshots. Heavier than
DevTools MCP for ad-hoc inspection, but it requires no Windows-side
Chrome session.

## Optional: Chrome DevTools MCP

For ad-hoc inspection (live DOM, console, network), the official
`chrome-devtools-mcp` is available. Wiring is left to the operator:
add to `.claude/settings.json` under `mcpServers.chrome-devtools` only if
you actively want it. Start with Playwright; opt into DevTools MCP only
when you need deep DOM or network introspection.

## Tool details (when opted in)

- **Name**: `chrome-devtools-mcp` (official Anthropic MCP).
- **Capabilities**: live DOM, console logs, network inspector,
  screenshots, click/fill simulation.
- **Requirement**: Node 22+. WSL2 attaches to the Windows-host Chrome via
  `--browserUrl` (DevTools Protocol over HTTP).

Canonical config (only if opted in):

```json
{
  "disabled": false,
  "command": "npx",
  "args": ["-y", "chrome-devtools-mcp@latest", "--browserUrl", "http://<wsl-gateway-ip>:9222"]
}
```

`.mcp.json` must NOT duplicate this entry. Two configs for the same
server name race each other and cause "Failed to reconnect" on startup.

## WSL2 networking (if using DevTools MCP)

NAT-mode WSL (the default) does not share loopback with Windows.
`127.0.0.1` from inside WSL reaches WSL itself, not the Windows host, so
Chrome bound to Windows loopback is unreachable. Two implications:

1. **Chrome on Windows must bind to a non-loopback address.** Launch with
   `--remote-debugging-address=0.0.0.0` and `--remote-allow-origins=*`
   (Chrome 111+ blocks non-loopback CDP origins by default).
2. **`browserUrl` uses the WSL-to-Windows gateway IP**, not `127.0.0.1`.
   Find it with `ip route show | grep default | awk '{print $3}'`. The
   gateway IP can change across Windows reboots; update `settings.json`
   if reconnect fails.

Mirrored-networking WSL (opt-in via `.wslconfig` `networkingMode=mirrored`)
maps Windows loopback into WSL; in that mode `http://127.0.0.1:9222`
works and the `--remote-debugging-address` override is not needed.

## Windows Chrome launch (PowerShell)

```powershell
& "C:\Program Files\Google\Chrome\Application\chrome.exe" `
  --remote-debugging-port=9222 `
  --remote-debugging-address=0.0.0.0 `
  --remote-allow-origins=* `
  --user-data-dir="$env:LOCALAPPDATA\chrome-mcp-profile"
```

Keep that Chrome window open while Claude Code runs. The dedicated
`--user-data-dir` avoids hijacking the user's normal profile.

## Verify from WSL

```bash
curl -s http://<wsl-gateway-ip>:9222/json/version
```

Expect JSON with `Browser`, `webSocketDebuggerUrl`, etc. Empty response
or `Connection reset by peer` means Chrome is bound to loopback only;
re-launch with `--remote-debugging-address=0.0.0.0`.

## Fallbacks

- **Playwright MCP**: test-driven user flows; the default for Aevum's
  frontend smoke pattern.
- **Claude Code Desktop built-in preview**: headless screenshots only.
