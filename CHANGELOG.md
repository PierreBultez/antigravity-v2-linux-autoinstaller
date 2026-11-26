# Changelog

## 1.0.0 (2026-11-26)

First release.

- Install Antigravity 2.0, Antigravity IDE and the Antigravity CLI from Google's official Linux archives.
- System (`/opt`) and per-user (`~/.local`, no sudo) installs.
- Reads the current static download page, with a fallback to the desktop app's release feed.
- Accepts HTTPS downloads from Google hosts only; checks archives before unpacking.
- Swaps versions atomically: a failed update keeps the working app.
- Registers the `antigravity://` and `antigravity-ide://` sign-in links.
- AppArmor profile for the Chromium sandbox on Ubuntu 23.10+.
- `update`, `status`, `check`, `uninstall [--purge]`, `auto-update on|off` (systemd timer), `fix-sandbox`, `self-update`.
- Compatibility checks for conflicting files and the old 1.x APT package.
- Doesn't use `apt`, so it works on any distribution with bash, curl and tar.
