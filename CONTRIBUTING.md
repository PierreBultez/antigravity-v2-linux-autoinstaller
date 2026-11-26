# Contributing

Thanks for helping! This project is small on purpose: one Bash script, `install.sh`, plus an offline test suite. Keeping it that way makes it easy to read before running with `curl | bash`.

## Reporting a problem

[Open an issue](https://github.com/PierreBultez/antigravity-v2-linux-autoinstaller/issues/new/choose) and include:

- your distribution and version (`cat /etc/os-release`), and your desktop (GNOME, KDE…);
- the output of `antigravity-installer status`;
- the full output of the command that failed.

If the installer says it **could not find the Antigravity archive**, Google probably changed its download page. Mention it in the title, because it affects everyone.

Test reports are welcome too. If you ran it on a distribution the README marks "Should work", say how it went.

## Changing the code

1. Fork, then create a branch.
2. Make your change in `install.sh`, and add or update a test in `tests/run.sh`.
3. Run the checks:

   ```bash
   bash tests/run.sh
   shellcheck install.sh tests/run.sh
   ```

   The tests need no network, no root and no real Antigravity download: they build fake archives (`tests/make-fakes.py`) and install them with `--user` into a throwaway `$HOME`.
4. Add a line to `CHANGELOG.md` under an "Unreleased" heading.
5. Open a pull request explaining what changed and why. CI must be green.

## Guidelines

- **Bash 4.3+ only**, no other runtime. `python3` is optional and only used for icon extraction.
- **No package manager calls** (`apt`, `dnf`, `pacman`…): the script must work on any distribution. Tell users what to install instead.
- **The script runs as the user**. Only commands that need root go through `priv` (or `as_root`), so downloads and per-user setup never run as root.
- **Prompts read `/dev/tty`**, never stdin: with `curl | bash`, stdin is the script itself. Use `ask`.
- **Download only from Google hosts**, over HTTPS. Don't widen `validate_archive_url` without a good reason.
- **Never leave a broken install**: unpack next to the target, then swap directories.
- **Don't ship Google's assets** (logos, binaries) in the repository. Use what the official archives contain.
- Keep user-facing messages short and actionable.
