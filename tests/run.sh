#!/usr/bin/env bash
# Test suite for install.sh. No network, no root, nothing touched outside a
# temporary directory: it builds fake Antigravity archives and installs them
# with --user into a throwaway $HOME.
#
#   bash tests/run.sh
#
# `cond && pass || fail` is safe here: pass never fails.
# shellcheck disable=SC2015,SC2181
# shellcheck source-path=SCRIPTDIR/..
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$ROOT/install.sh"
FIXTURES="$ROOT/tests/fixtures"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/agi-tests.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  \e[32mok\e[0m   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; [[ -n ${2:-} ]] && printf '       %s\n' "$2"; }
check() { # check "name" expected actual
  if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2], got [$3]"; fi
}
section() { printf '\n\e[1m%s\e[0m\n' "$1"; }

# Run a function from install.sh in a clean subshell.
fn() {
  (
    # Respect a caller's AGI_TEST=0 (the file:// rejection test needs it).
    export AGI_SOURCED=1 AGI_TEST="${AGI_TEST:-1}" NO_COLOR=1
    # shellcheck source=install.sh
    source "$SCRIPT"
    "$@"
  )
}

# ---------------------------------------------------------------------------
section "URL extraction"

page="$FIXTURES/download.html"
check "desktop x64 from HTML" \
  "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.35.2-4585983447007232/linux-x64/Antigravity.tar.gz" \
  "$(fn extract_archive_url desktop linux-x64 <"$page")"
check "desktop arm from HTML" \
  "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.35.2-4585983447007232/linux-arm/Antigravity.tar.gz" \
  "$(fn extract_archive_url desktop linux-arm <"$page")"
check "IDE x64 from HTML (not confused with the desktop app)" \
  "https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/2.8.0-6733682917113856/linux-x64/Antigravity%20IDE.tar.gz" \
  "$(fn extract_archive_url ide linux-x64 <"$page")"
check "JSON-escaped bundle" \
  "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.40.0-1/linux-x64/Antigravity.tar.gz" \
  "$(fn extract_archive_url desktop linux-x64 <"$FIXTURES/bundle.js")"
check "picks the newest when several are listed" \
  "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.10.0-9/linux-x64/Antigravity.tar.gz" \
  "$(printf '%s\n' \
      '"https://storage.googleapis.com/antigravity-public/antigravity-hub/2.9.1-5/linux-x64/Antigravity.tar.gz"' \
      '"https://storage.googleapis.com/antigravity-public/antigravity-hub/2.10.0-9/linux-x64/Antigravity.tar.gz"' \
    | fn extract_archive_url desktop linux-x64)"
check "nothing found prints nothing" "" "$(echo '<html></html>' | fn extract_archive_url desktop linux-x64)"

section "Versions"
check "hub URL" "2.35.2" "$(fn version_from_url https://storage.googleapis.com/x/antigravity-hub/2.35.2-4585983447007232/linux-x64/Antigravity.tar.gz)"
check "IDE URL" "2.8.0" "$(fn version_from_url https://edgedl.me.gvt1.com/x/stable/2.8.0-6733682917113856/linux-x64/Antigravity%20IDE.tar.gz)"
check "no version" "unknown" "$(fn version_from_url https://storage.googleapis.com/x/latest/linux-x64/Antigravity.tar.gz)"

section "URL safety"
expect_reject() {
  if AGI_TEST=0 fn validate_archive_url "$1" "$2" 2>/dev/null; then fail "rejects $3"; else pass "rejects $3"; fi
}
expect_accept() {
  if AGI_TEST=0 fn validate_archive_url "$1" "$2" 2>/dev/null; then pass "accepts $3"; else fail "accepts $3"; fi
}
expect_accept "https://storage.googleapis.com/antigravity-public/antigravity-hub/2.35.2-1/linux-x64/Antigravity.tar.gz" desktop "Google storage"
expect_accept "https://edgedl.me.gvt1.com/edgedl/x/2.8.0-1/linux-x64/Antigravity%20IDE.tar.gz" ide "Google edge CDN"
expect_reject "http://storage.googleapis.com/a/linux-x64/Antigravity.tar.gz" desktop "plain HTTP"
expect_reject "https://evil.example.com/linux-x64/Antigravity.tar.gz" desktop "a foreign host"
expect_reject "https://storage.googleapis.com.evil.com/linux-x64/Antigravity.tar.gz" desktop "a look-alike host"
expect_reject "https://storage.googleapis.com/a/linux-x64/other.tar.gz" desktop "a wrong file name"
expect_reject "file:///tmp/linux-x64/Antigravity.tar.gz" desktop "file:// outside tests"

section "Archive checks"
mkdir -p "$TMP/arch/good/App/sub" "$TMP/arch/two/A" "$TMP/arch/two/B"
touch "$TMP/arch/good/App/sub/f" "$TMP/arch/two/A/f" "$TMP/arch/two/B/f"
tar -czf "$TMP/good.tar.gz" -C "$TMP/arch/good" App
tar -czf "$TMP/two.tar.gz" -C "$TMP/arch/two" A B
python3 -I - "$TMP/evil.tar.gz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    for name in ("App/ok", "App/../../escape"):
        info = tarfile.TarInfo(name); info.size = 2
        t.addfile(info, io.BytesIO(b"hi"))
PY
echo "not a tarball" >"$TMP/corrupt.tar.gz"
check "top-level directory" "App" "$(fn inspect_archive "$TMP/good.tar.gz")"
if fn inspect_archive "$TMP/two.tar.gz" >/dev/null 2>&1; then fail "rejects two top-level dirs"; else pass "rejects two top-level dirs"; fi
if fn inspect_archive "$TMP/evil.tar.gz" >/dev/null 2>&1; then fail "rejects ../ paths"; else pass "rejects ../ paths"; fi
if fn inspect_archive "$TMP/corrupt.tar.gz" >/dev/null 2>&1; then fail "rejects a corrupt archive"; else pass "rejects a corrupt archive"; fi

section "Icons"
python3 -I "$ROOT/tests/make-fakes.py" png "$TMP/256.png" 256
check "PNG size" "256" "$(fn png_size "$TMP/256.png")"
check "1024px PNG goes to 512" "512" "$(python3 -I "$ROOT/tests/make-fakes.py" png "$TMP/1024.png" 1024 && fn png_size "$TMP/1024.png")"
check "odd PNG size falls back to 512" "512" "$(python3 -I "$ROOT/tests/make-fakes.py" png "$TMP/300.png" 300 && fn png_size "$TMP/300.png")"

section "Arguments"
run() { (cd "$TMP" && NO_COLOR=1 bash "$SCRIPT" "$@"); }
if run --help | grep -q "auto-update on|off"; then pass "--help"; else fail "--help"; fi
check "--version" "antigravity-installer 1.0.0" "$(run --version)"
if run frobnicate 2>/dev/null; then fail "rejects unknown arguments"; else pass "rejects unknown arguments"; fi
if run install desktop update 2>/dev/null; then fail "rejects two commands"; else pass "rejects two commands"; fi

# ---------------------------------------------------------------------------
section "End to end (--user, fake archives)"

FAKE_HOME="$TMP/home"
SRV="$TMP/srv"
mkdir -p "$FAKE_HOME"
python3 -I "$ROOT/tests/make-fakes.py" archives "$SRV" "$TMP/build"

desk_url() { printf 'file://%s/%s/linux-x64/Antigravity.tar.gz' "$SRV" "$1"; }
ide_url() { printf 'file://%s/%s/linux-x64/Antigravity%%20IDE.tar.gz' "$SRV" "$1"; }

agi() {
  env -i PATH="$FAKE_HOME/.local/bin:/usr/bin:/bin" HOME="$FAKE_HOME" USER="${USER:-tester}" \
    XDG_DATA_HOME="$FAKE_HOME/.local/share" XDG_CONFIG_HOME="$FAKE_HOME/.config" \
    XDG_STATE_HOME="$FAKE_HOME/.local/state" XDG_RUNTIME_DIR="$TMP" TMPDIR="$TMP" \
    AGI_TEST=1 AGI_SKIP_SANDBOX=1 NO_COLOR=1 \
    AGI_DOWNLOAD_PAGE="file://$FIXTURES/empty.html" AGI_RELEASES_API="file://$FIXTURES/empty.html" \
    AGI_DESKTOP_URL="${DESK:-}" AGI_IDE_URL="${IDE:-}" \
    bash "$SCRIPT" "$@" </dev/null
}

L="$FAKE_HOME/.local"
DESK=$(desk_url 1.0.0-11) IDE=$(ide_url 2.0.0-22)
export DESK IDE
out=$(agi install all --user 2>&1)
status=$?
check "install all exits 0" "0" "$status"
[[ $status -eq 0 ]] || printf '%s\n' "$out"

[[ -x $L/opt/antigravity/antigravity ]] && pass "desktop app unpacked" || fail "desktop app unpacked"
[[ -x $L/opt/antigravity-ide/antigravity-ide ]] && pass "IDE unpacked" || fail "IDE unpacked"
check "desktop command" "$L/opt/antigravity/antigravity" "$(readlink "$L/bin/antigravity")"
check "IDE command uses the CLI wrapper" "$L/opt/antigravity-ide/bin/antigravity-ide" "$(readlink "$L/bin/antigravity-ide")"
check "fake app runs" "fake antigravity 1.0.0" "$("$L/bin/antigravity")"
[[ -x $L/bin/antigravity-installer ]] && pass "manager command installed" || fail "manager command installed"
D="$L/share/applications/antigravity.desktop"
grep -q '^MimeType=x-scheme-handler/antigravity;$' "$D" && pass "desktop entry handles antigravity://" || fail "desktop entry handles antigravity://"
grep -q "^Exec=\"$L/opt/antigravity/antigravity\" %U$" "$D" && pass "desktop entry Exec" || fail "desktop entry Exec" "$(grep ^Exec "$D")"
grep -q '^MimeType=x-scheme-handler/antigravity-ide;$' "$L/share/applications/antigravity-ide-url-handler.desktop" \
  && pass "IDE URL handler" || fail "IDE URL handler"
if command -v desktop-file-validate >/dev/null; then
  for f in "$L"/share/applications/antigravity*.desktop; do
    desktop-file-validate "$f" >/dev/null 2>&1 && pass "valid $(basename "$f")" || fail "valid $(basename "$f")" "$(desktop-file-validate "$f" 2>&1)"
  done
fi
[[ -f $L/share/icons/hicolor/256x256/apps/antigravity.png ]] && pass "desktop icon from app.asar" || fail "desktop icon from app.asar"
[[ -f $L/share/icons/hicolor/512x512/apps/antigravity-ide.png ]] && pass "IDE icon (1024px goes to 512x512)" || fail "IDE icon (1024px goes to 512x512)"
check "manifest version" "1.0.0" "$(sed -n 's/^version=//p' "$L/state/antigravity-installer/desktop.manifest")"
if command -v xdg-mime >/dev/null; then
  grep -q 'x-scheme-handler/antigravity=antigravity.desktop' "$FAKE_HOME/.config/mimeapps.list" 2>/dev/null \
    && pass "antigravity:// registered for the user" \
    || fail "antigravity:// registered for the user" "$(cat "$FAKE_HOME/.config/mimeapps.list" 2>&1; grep -i 'sign-in\|register' <<<"$out")"
fi
compgen -G "$TMP/antigravity-installer.*" >/dev/null && fail "temporary files cleaned up" || pass "temporary files cleaned up"

out=$(agi install desktop --user 2>&1)
grep -q "already installed and up to date" <<<"$out" && pass "second install is a no-op" || fail "second install is a no-op" "$out"

out=$(agi status 2>&1)
grep -q "Antigravity *1.0.0" <<<"$out" && pass "status lists the desktop app" || fail "status lists the desktop app" "$out"

touch "$L/opt/antigravity/user-file"
DESK=$(desk_url 1.1.0-12)
out=$(agi update 2>&1)
check "update exits 0" "0" "$?"
grep -q "Updating Antigravity 1.0.0 → 1.1.0" <<<"$out" && pass "update detects the new version" || fail "update detects the new version" "$out"
check "updated app runs" "fake antigravity 1.1.0" "$("$L/bin/antigravity")"
[[ ! -e $L/opt/antigravity/user-file ]] && pass "old files replaced, not merged" || fail "old files replaced, not merged"
[[ ! -e $L/opt/.antigravity.old && ! -e $L/opt/.antigravity.new ]] && pass "no leftovers after swap" || fail "no leftovers after swap"

DESK=$(desk_url 9.9.9-99) # does not exist
out=$(agi update desktop 2>&1)
[[ $? -ne 0 ]] && pass "failed download exits non-zero" || fail "failed download exits non-zero"
check "failed update keeps the working app" "fake antigravity 1.1.0" "$("$L/bin/antigravity")"

mkdir -p "$FAKE_HOME/.config/Antigravity"
out=$(agi uninstall 2>&1)
check "uninstall exits 0" "0" "$?"
left=$(cd "$L" && find . -path ./state -prune -o -name '*antigravity*' -print 2>/dev/null)
check "uninstall removes everything" "" "$left"
[[ ! -e $L/state/antigravity-installer ]] && pass "state removed" || fail "state removed"
[[ -d $FAKE_HOME/.config/Antigravity ]] && pass "user settings kept without --purge" || fail "user settings kept without --purge"

DESK=$(desk_url 1.1.0-12)
agi install --user >/dev/null 2>&1
agi uninstall --purge --yes >/dev/null 2>&1
[[ ! -d $FAKE_HOME/.config/Antigravity ]] && pass "--purge deletes user settings" || fail "--purge deletes user settings"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
