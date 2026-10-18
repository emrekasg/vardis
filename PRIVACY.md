# Privacy

Vardis is free forever and collects nothing. This page says exactly what it reads, what it keeps, and when it talks to the internet.

## What Vardis reads on your Mac

- **System and process statistics:** CPU, memory, energy, disk and network counters for running apps and processes, read through public macOS APIs.
- **Claude Code files:** the folders Claude Code uses, such as `~/.claude`, `~/.claude-*` and `$CLAUDE_CONFIG_DIR`, to show sessions, token usage and cost. In the direct download, Vardis also reads the Claude Code sign-in from your Keychain (item `Claude Code-credentials`) so it can ask for your plan limits.
- **Folders you choose:** for Disk Cleanup, Vardis looks at developer caches and the project folders you configure. In the App Store version it only sees folders you pick.

All of this is read on your Mac and stays there.

## What Vardis stores on your Mac

- **History:** a local database of past readings in `~/Library/Application Support/Vardis`. Older data is thinned out over time.
- **Search index:** a local index of your Claude Code session text, so you can search past sessions. It lives in the same folder.
- **Settings:** your preferences, stored by macOS.

Delete that folder and the history and index are gone. Nothing is copied anywhere else.

## When Vardis goes online

Only for these two things:

1. **Update check (direct download only).** Vardis fetches `https://vardis.app/appcast.xml` to see if a new version exists. The request carries the app version and the standard request details any download has; nothing about you or your Mac's activity. You can turn it off in Settings. The App Store version gets updates from the App Store instead.
2. **Your Claude plan limits.** To show how much of your plan you have used, Vardis sends a request to `api.anthropic.com` with your own Claude Code sign-in token. The token is sent only to `api.anthropic.com`, the same place Claude Code itself sends it. Anthropic's privacy policy covers that request.

## What Vardis never collects

- No account and no sign-up.
- No analytics, usage tracking or telemetry.
- No crash reports.
- No advertising identifiers and no third-party SDKs.
- Your files, process list, history, sessions and tokens never leave your Mac, except the token going to Anthropic as described above.

There is no Vardis server. There is nowhere for your data to go.

## Checking for yourself

The code is open source under the MIT License. You can read it, build it yourself, or watch Vardis's network activity with any firewall tool.

## Questions

Open an issue on [GitHub](https://github.com/emrekasg/vardis/issues).
