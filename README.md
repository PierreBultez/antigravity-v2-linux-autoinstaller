# Antigravity v2 Linux auto-installer

Install **Google Antigravity 2.0** (and optionally **Antigravity IDE** and the **Antigravity CLI**) on Linux with one command, then keep it up to date.

Google only ships Antigravity 2.x for Linux as `.tar.gz` archives: no `.deb`, no APT repository, no launcher, no updates. This script fills that gap. It downloads the official archives from [antigravity.google/download](https://antigravity.google/download) and sets everything up so the app behaves like any other installed app.

```bash
curl -fsSL https://raw.githubusercontent.com/PierreBultez/antigravity-v2-linux-autoinstaller/main/install.sh | bash
```

> Unofficial project, not affiliated with or endorsed by Google. Antigravity is a Google product under Google's terms. This repository contains no Google code or assets: the script only downloads Google's own archives.

## What it does

- Finds the latest official release on Google's download page, for x86_64 or arm64.
- Accepts downloads only over HTTPS from Google hosts (`storage.googleapis.com`, `*.gvt1.com`, `dl.google.com`), and rejects archives with unsafe paths.
- Installs into `/opt` (for all users) or `~/.local` (just you, no sudo).
- Swaps in a new version only after it is fully downloaded and unpacked, so a failed update never breaks the working app.
- Adds the app-menu launcher, the icon and the `antigravity` / `antigravity-ide` commands.
- **Registers the `antigravity://` sign-in link**, so a Google sign-in done in the browser comes back to the app.
- **Sets up the Chromium sandbox**: on Ubuntu 23.10+ (which restricts user namespaces) it installs an AppArmor profile, like VS Code and Chrome do, instead of making the app run without a sandbox.
- Updates on request, or daily through a systemd timer. Updates are skipped while the app is open.
- Uninstalls cleanly, and keeps your settings unless you ask for `--purge`.
- Runs compatibility checks and offers to clean up files that would conflict with it.
- Doesn't need `apt`: it works on Debian, Ubuntu, Mint, Pop!_OS, Fedora, Arch, openSUSE…

## Usage

```bash
# Antigravity 2.0 desktop app, for all users (asks for sudo once)
curl -fsSL https://raw.githubusercontent.com/PierreBultez/antigravity-v2-linux-autoinstaller/main/install.sh | bash

# Desktop app + IDE
curl -fsSL https://raw.githubusercontent.com/PierreBultez/antigravity-v2-linux-autoinstaller/main/install.sh | bash -s -- install all

# Only for you, in ~/.local, without sudo
curl -fsSL https://raw.githubusercontent.com/PierreBultez/antigravity-v2-linux-autoinstaller/main/install.sh | bash -s -- --user
```

The first install also adds an `antigravity-installer` command:

| Command | What it does |
| --- | --- |
| `antigravity-installer update` | Update everything that is installed |
| `antigravity-installer status` | Installed versions, and whether an update is out |
| `antigravity-installer auto-update on` | Check for updates every day (`off` to stop) |
| `antigravity-installer install ide` | Add Antigravity IDE |
| `antigravity-installer install cli` | Add the Antigravity CLI (runs Google's own CLI installer) |
| `antigravity-installer check` | Print the latest official download URLs, install nothing |
| `antigravity-installer uninstall` | Remove everything (`uninstall ide` for just one; `--purge` also deletes settings and sign-in) |
| `antigravity-installer fix-sandbox` | Reinstall the AppArmor profile if the app refuses to start |
| `antigravity-installer self-update` | Update the installer itself |

Options: `--system` (default) / `--user`, `-y` (no questions), `-f` (reinstall, or act while the app is open), `-q` (quiet). See `antigravity-installer --help`.

Prefer to read the script before running it? Good idea:

```bash
curl -fsSLO https://raw.githubusercontent.com/PierreBultez/antigravity-v2-linux-autoinstaller/main/install.sh
less install.sh
bash install.sh
```

## Where things go

| | `--system` (default) | `--user` |
| --- | --- | --- |
| App | `/opt/antigravity`, `/opt/antigravity-ide` | `~/.local/opt/…` |
| Commands | `/usr/local/bin` | `~/.local/bin` |
| Launchers, icons | `/usr/share/applications`, `/usr/share/icons` | `~/.local/share/…` |
| Installer state | `/var/lib/antigravity-installer` | `~/.local/state/antigravity-installer` |
| Sandbox profile (Ubuntu 23.10+) | `/etc/apparmor.d/antigravity-installer-*` | same (asks for sudo once) |

Your settings and sign-in live in your home folder (`~/.config/Antigravity`, `~/.antigravity-ide`, …) and are never touched unless you pass `--purge`.

## Troubleshooting

**The app doesn't start, or complains about the sandbox.** Run `antigravity-installer fix-sandbox`. On Ubuntu 23.10+ the app needs the AppArmor profile, and `--user` installs only get it if you accepted the sudo prompt.

**Sign-in in the browser doesn't come back to the app.** Run `xdg-mime query default x-scheme-handler/antigravity`. It should print `antigravity.desktop`. Reinstall with `antigravity-installer install -f` to register it again.

**"could not find the Antigravity archive".** Google changed its download page. Please [open an issue](https://github.com/PierreBultez/antigravity-v2-linux-autoinstaller/issues). The repository also checks the live page every day, so this is usually spotted quickly. Until it's fixed, copy the `.tar.gz` link from the download page and run:

```bash
AGI_DESKTOP_URL='<link>' antigravity-installer install
```

**Compatibility checks.** Before installing, the script looks for files that would conflict with it, such as other Antigravity update helpers in `/usr/local/bin` or the old 1.x APT package. It lists them and asks before removing anything; it never removes an APT package itself.

## Development

```bash
bash tests/run.sh        # offline test suite: fake archives, throwaway $HOME
shellcheck install.sh
```

CI runs ShellCheck and the tests on every push, plus a daily check that Google's live download page still resolves.

## License

[MIT](LICENSE)
