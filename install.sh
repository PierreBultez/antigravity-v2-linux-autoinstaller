#!/usr/bin/env bash
# antigravity-installer: install and keep Google Antigravity up to date on Linux.
#
#   curl -fsSL https://raw.githubusercontent.com/PierreBultez/antigravity-v2-linux-autoinstaller/main/install.sh | bash
#
# Unofficial project, not affiliated with Google. It only downloads the official
# Linux archives listed on https://antigravity.google/download and wires them
# into the desktop (launcher, icon, sign-in links, sandbox, updates).
#
# SPDX-License-Identifier: MIT
# https://github.com/PierreBultez/antigravity-v2-linux-autoinstaller

set -Eeuo pipefail

readonly AGI_VERSION="1.0.0"
readonly AGI_CMD="antigravity-installer"
readonly AGI_REPO="PierreBultez/antigravity-v2-linux-autoinstaller"

AGI_SELF_URL="${AGI_SELF_URL:-https://raw.githubusercontent.com/${AGI_REPO}/main/install.sh}"
AGI_DOWNLOAD_PAGE="${AGI_DOWNLOAD_PAGE:-https://antigravity.google/download}"
AGI_RELEASES_API="${AGI_RELEASES_API:-https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases}"
AGI_CLI_INSTALLER="${AGI_CLI_INSTALLER:-https://antigravity.google/cli/install.sh}"
# Test hooks (see tests/). Never set these for a real install.
AGI_TEST="${AGI_TEST:-0}"
AGI_SKIP_SANDBOX="${AGI_SKIP_SANDBOX:-0}"

# Options (set by parse_args).
OPT_MODE=""          # system | user | "" (auto)
OPT_YES=0
OPT_FORCE=0
OPT_PURGE=0
OPT_QUIET=0

WORKDIR=""
SELF_INSTALLED=0

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m' C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m'
else
  C_RESET="" C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE=""
fi

info() { [[ $OPT_QUIET -eq 1 ]] || printf '%s==>%s %s\n' "$C_BLUE$C_BOLD" "$C_RESET" "$*" >&2; }
ok()   { [[ $OPT_QUIET -eq 1 ]] || printf '%s ✓%s  %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
note() { [[ $OPT_QUIET -eq 1 ]] || printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RESET" >&2; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW$C_BOLD" "$C_RESET" "$*" >&2; }
die()  { printf '%serror:%s %s\n' "$C_RED$C_BOLD" "$C_RESET" "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# Prompts read from the terminal, never from stdin: with `curl ... | bash`,
# stdin is the script itself.
interactive() { [[ $OPT_YES -eq 0 ]] && { : </dev/tty; } 2>/dev/null; }

# ask "Question?" y|n  -> returns 0 for yes. Non-interactive runs get the default.
ask() {
  local question=$1 default=$2 hint reply
  if [[ $OPT_YES -eq 1 ]]; then return 0; fi
  if ! interactive; then [[ $default == y ]]; return; fi
  if [[ $default == y ]]; then hint="[Y/n]"; else hint="[y/N]"; fi
  printf '%s %s ' "$question" "$hint" >/dev/tty
  read -r reply </dev/tty || reply=""
  reply=${reply,,}
  [[ -z $reply ]] && reply=$default
  [[ $reply == y || $reply == yes || $reply == o || $reply == oui ]]
}

cleanup() {
  if [[ -n $WORKDIR && -d $WORKDIR ]]; then rm -rf -- "$WORKDIR"; fi
}
trap cleanup EXIT
trap 'die "interrupted"' INT TERM

# Created once by main(), before any subshell can call workdir().
init_workdir() {
  WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/${AGI_CMD}.XXXXXX")
}
workdir() { printf '%s\n' "$WORKDIR"; }

# ---------------------------------------------------------------------------
# Platform and products
# ---------------------------------------------------------------------------

detect_platform() {
  case "$(uname -m)" in
    x86_64 | amd64) AGI_PLATFORM="linux-x64" ;;
    aarch64 | arm64) AGI_PLATFORM="linux-arm" ;;
    *) die "unsupported CPU architecture '$(uname -m)'. Google publishes Linux builds for x86_64 and arm64 only." ;;
  esac
}

readonly PRODUCTS=(desktop ide)

product_label() {
  case $1 in
    desktop) echo "Antigravity" ;;
    ide) echo "Antigravity IDE" ;;
  esac
}
# File name of the archive in Google's URLs (already URL-encoded).
product_archive() {
  case $1 in
    desktop) echo "Antigravity.tar.gz" ;;
    ide) echo "Antigravity%20IDE.tar.gz" ;;
  esac
}
# Used for the install directory, the desktop file, the icon and the command.
product_id() {
  case $1 in
    desktop) echo "antigravity" ;;
    ide) echo "antigravity-ide" ;;
  esac
}
# Electron binary, relative to the install directory.
product_exe() {
  case $1 in
    desktop) echo "antigravity" ;;
    ide) echo "antigravity-ide" ;;
  esac
}
# What goes on the PATH. The IDE ships a VS Code style CLI wrapper in bin/,
# which detaches from the terminal and supports `antigravity-ide .`.
product_cli() {
  case $1 in
    desktop) echo "antigravity" ;;
    ide) echo "bin/antigravity-ide" ;;
  esac
}
# URL scheme the app uses to come back from a browser sign-in.
product_scheme() {
  case $1 in
    desktop) echo "antigravity" ;;
    ide) echo "antigravity-ide" ;;
  esac
}

is_product() {
  local p
  for p in "${PRODUCTS[@]}"; do [[ $p == "$1" ]] && return 0; done
  return 1
}

# ---------------------------------------------------------------------------
# Install modes and privileges
# ---------------------------------------------------------------------------

# Sets every path for the chosen mode.
set_mode() {
  MODE=$1
  local data="${XDG_DATA_HOME:-$HOME/.local/share}"
  case $MODE in
    system)
      OPT_DIR="/opt"
      BIN_DIR="/usr/local/bin"
      APPS_DIR="/usr/share/applications"
      ICONS_DIR="/usr/share/icons/hicolor"
      STATE_DIR="/var/lib/${AGI_CMD}"
      SYSTEMD_DIR="/etc/systemd/system"
      ;;
    user)
      [[ $EUID -ne 0 ]] || die "--user installs into a normal user's home; run it without sudo."
      OPT_DIR="$HOME/.local/opt"
      BIN_DIR="$HOME/.local/bin"
      APPS_DIR="$data/applications"
      ICONS_DIR="$data/icons/hicolor"
      STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/${AGI_CMD}"
      SYSTEMD_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
      ;;
    *) die "unknown mode: $MODE" ;;
  esac
}

# Runs a command with the rights the current mode needs. The script itself
# never runs as root: only these commands do, so downloads and per-user setup
# stay with the real user.
priv() {
  if [[ $MODE == user || $EUID -eq 0 ]]; then
    "$@"
  else
    sudo -- "$@"
  fi
}

# Always root, whatever the mode (AppArmor profiles live in /etc).
as_root() {
  if [[ $EUID -eq 0 ]]; then "$@"; else sudo -- "$@"; fi
}

ensure_sudo() {
  [[ $MODE == system && $EUID -ne 0 ]] || return 0
  have sudo || die "system install needs root: install sudo, run as root, or use --user."
  if ! sudo -n true 2>/dev/null; then
    info "Administrator rights are needed to install into /opt."
    # shellcheck disable=SC2024 # the prompt must read the terminal, not the piped script
    sudo -v </dev/tty || die "could not get administrator rights (or use --user)."
  fi
}

# The desktop user, for per-user setup (URL handlers, CLI, purge). Empty when
# running as root outside sudo (e.g. the system auto-update timer).
target_user() {
  if [[ $EUID -ne 0 ]]; then
    id -un
  elif [[ -n ${SUDO_USER:-} && ${SUDO_USER} != root ]]; then
    printf '%s\n' "$SUDO_USER"
  fi
}

as_target_user() {
  local user
  user=$(target_user)
  [[ -n $user ]] || return 1
  if [[ $EUID -ne 0 ]]; then
    "$@"
  else
    sudo -u "$user" -H -- "$@"
  fi
}

target_home() {
  if [[ $EUID -ne 0 ]]; then
    printf '%s\n' "$HOME"
    return 0
  fi
  local user
  user=$(target_user)
  [[ -n $user ]] || return 1
  getent passwd "$user" | cut -d: -f6
}

# Mode for update/uninstall/status: what is already installed, system first.
detect_installed_mode() {
  local m p
  for m in system user; do
    [[ $m == user && $EUID -eq 0 ]] && continue
    set_mode "$m"
    for p in "${PRODUCTS[@]}"; do
      [[ -f $STATE_DIR/$p.manifest ]] && { printf '%s\n' "$m"; return 0; }
    done
  done
  return 1
}

# ---------------------------------------------------------------------------
# Downloads and version resolution
# ---------------------------------------------------------------------------

curl_protos() {
  if [[ $AGI_TEST == 1 ]]; then echo "=https,file"; else echo "=https"; fi
}

fetch_text() {
  curl -fsSL --proto "$(curl_protos)" --tlsv1.2 --compressed --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 60 -A "${AGI_CMD}/${AGI_VERSION}" -- "$1"
}

fetch_file() {
  local url=$1 out=$2 progress=(-s)
  if [[ -t 2 && $OPT_QUIET -eq 0 ]]; then progress=(-#); fi
  curl -fL "${progress[@]}" --proto "$(curl_protos)" --tlsv1.2 --retry 3 --retry-delay 2 \
    --connect-timeout 15 -A "${AGI_CMD}/${AGI_VERSION}" -o "$out" -- "$url"
}

# Reads a page on stdin and prints the newest archive URL for a product and
# platform. Copes with HTML entities and JSON-escaped slashes.
extract_archive_url() {
  local product=$1 platform=$2 name
  name=$(product_archive "$product")
  name=${name//./\\.}
  sed -e 's#\\/#/#g' -e 's/&amp;/\&/g' -e 's/\\u002[fF]/\//g' \
    | { grep -oE "https://[^\"'<>[:space:]\\\\]+/${platform}/${name}" || true; } \
    | sort -uV | tail -n 1
}

# Fallback for the desktop app: the release feed its built-in updater uses.
resolve_from_releases_api() {
  local platform=$1 json entry version exec_id
  json=$(fetch_text "$AGI_RELEASES_API" 2>/dev/null) || return 1
  entry=$(grep -oE '"version":"[0-9.]+","execution_id":"[0-9]+"' <<<"$json" | head -n 1) || return 1
  version=$(sed -E 's/.*"version":"([0-9.]+)".*/\1/' <<<"$entry")
  exec_id=$(sed -E 's/.*"execution_id":"([0-9]+)".*/\1/' <<<"$entry")
  [[ -n $version && -n $exec_id ]] || return 1
  printf 'https://storage.googleapis.com/antigravity-public/antigravity-hub/%s-%s/%s/Antigravity.tar.gz\n' \
    "$version" "$exec_id" "$platform"
}

version_from_url() {
  if [[ $1 =~ /([0-9]+\.[0-9]+\.[0-9]+)(-[0-9]+)?/linux- ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    echo "unknown"
  fi
}

# Only accept archives served by Google, whatever the page says.
validate_archive_url() {
  local url=$1 product=$2 host
  if [[ $AGI_TEST == 1 && $url == file://* ]]; then return 0; fi
  [[ $url == https://* ]] || die "refusing non-HTTPS download URL: $url"
  host=${url#https://}
  host=${host%%/*}
  case $host in
    storage.googleapis.com | dl.google.com | edgedl.me.gvt1.com | *.gvt1.com) ;;
    *) die "refusing download from unexpected host '$host' ($url)" ;;
  esac
  [[ $url == */"$(product_archive "$product")" ]] || die "unexpected archive name in $url"
}

PAGE_CACHE=""
PAGE_LOADED=0

# Fetches the download page once. Call it from the main shell (not inside
# $(...)), so later lookups in subshells reuse it.
load_download_page() {
  [[ $PAGE_LOADED -eq 0 ]] || return 0
  PAGE_LOADED=1
  PAGE_CACHE=$(fetch_text "$AGI_DOWNLOAD_PAGE" 2>/dev/null) || PAGE_CACHE=""
}

download_page() {
  [[ $PAGE_LOADED -eq 1 ]] || load_download_page
  printf '%s' "$PAGE_CACHE"
}

# Prints "<version> <url>" for the latest release of a product.
resolve_latest() {
  local product=$1 override url=""
  override="AGI_${product^^}_URL"
  if [[ -n ${!override:-} ]]; then
    url=${!override}
  else
    url=$(download_page | extract_archive_url "$product" "$AGI_PLATFORM")
    if [[ -z $url && $product == desktop ]]; then
      url=$(resolve_from_releases_api "$AGI_PLATFORM") || url=""
    fi
  fi
  if [[ -z $url ]]; then
    die "could not find the $(product_label "$product") archive for $AGI_PLATFORM on $AGI_DOWNLOAD_PAGE.
       Google may have changed the page. Please open an issue: https://github.com/${AGI_REPO}/issues
       Workaround: AGI_${product^^}_URL=<tarball URL from the page> $AGI_CMD install $product"
  fi
  validate_archive_url "$url" "$product"
  printf '%s %s\n' "$(version_from_url "$url")" "$url"
}

# ---------------------------------------------------------------------------
# Archive handling
# ---------------------------------------------------------------------------

# Checks an archive and prints its single top-level directory.
inspect_archive() {
  local archive=$1 list top
  list=$(tar -tzf "$archive" 2>/dev/null) || die "the downloaded archive is corrupt: $archive"
  [[ -n $list ]] || die "the downloaded archive is empty"
  if grep -qE '(^/|(^|/)\.\.(/|$))' <<<"$list"; then
    die "the archive contains unsafe paths; refusing to extract it"
  fi
  top=$(head -n 1 <<<"$list")
  top=${top%%/*}
  [[ -n $top ]] || die "unexpected archive layout"
  if grep -qvxF -- "$top" <<<"$(cut -d/ -f1 <<<"$list" | sort -u)"; then
    die "the archive has more than one top-level directory; refusing to install it"
  fi
  printf '%s\n' "$top"
}

# Reads one file out of an Electron app.asar (python3 only; optional).
asar_extract() {
  local asar=$1 member=$2 out=$3
  have python3 || return 1
  python3 -I - "$asar" "$member" "$out" <<'PY'
import json, struct, sys
asar, member, out = sys.argv[1:4]
with open(asar, "rb") as f:
    f.seek(4)
    header_size = struct.unpack("<I", f.read(4))[0]
    f.seek(12)
    json_size = struct.unpack("<I", f.read(4))[0]
    node = json.loads(f.read(json_size))
    for part in member.split("/"):
        node = node["files"][part]
    f.seek(8 + header_size + int(node["offset"]))
    data = f.read(int(node["size"]))
with open(out, "wb") as o:
    o.write(data)
PY
}

# Width of a square PNG, to put the icon in the right hicolor size folder.
# hicolor has no folder above 512x512, so bigger icons (the IDE ships 1024px)
# go into 512x512: icon loaders scale them down.
png_size() {
  local w h
  w=$(od -An -tu1 -j16 -N4 "$1" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')
  h=$(od -An -tu1 -j20 -N4 "$1" 2>/dev/null | awk '{print $1*16777216+$2*65536+$3*256+$4}')
  case "$w" in
    16 | 22 | 24 | 32 | 48 | 64 | 128 | 256 | 512) [[ $w == "$h" ]] && { echo "$w"; return; } ;;
  esac
  echo 512
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------

sysctl_value() { cat "/proc/sys/kernel/$1" 2>/dev/null || true; }

# Ubuntu 23.10+ blocks unprivileged user namespaces unless an AppArmor profile
# allows them; Electron's sandbox needs them. Same fix as VS Code and Chrome.
needs_apparmor_profile() {
  [[ $AGI_SKIP_SANDBOX == 1 ]] && return 1
  [[ $(sysctl_value apparmor_restrict_unprivileged_userns) == 1 ]] && have apparmor_parser
}

apparmor_profile_path() { echo "/etc/apparmor.d/${AGI_CMD}-$(product_id "$1")"; }

install_apparmor_profile() {
  local product=$1 exe_path=$2 profile tmp
  profile=$(apparmor_profile_path "$product")
  tmp="$(workdir)/apparmor-$product"
  cat >"$tmp" <<EOF
# Generated by ${AGI_CMD}. Lets $(product_label "$product") use user namespaces
# for its Chromium sandbox on systems that restrict them (Ubuntu 23.10+).
abi <abi/4.0>,
include <tunables/global>

profile ${AGI_CMD}-$(product_id "$product") "${exe_path}" flags=(unconfined) {
  userns,

  include if exists <local/${AGI_CMD}-$(product_id "$product")>
}
EOF
  if [[ $MODE == user ]]; then
    info "Your system restricts the sandbox $(product_label "$product") relies on."
    note "Allowing it needs one AppArmor profile in /etc/apparmor.d (administrator rights)."
    if ! have sudo || ! ask "Install it with sudo now?" y; then
      warn "$(product_label "$product") may refuse to start until you run: $AGI_CMD fix-sandbox --user"
      return 0
    fi
    if ! { sudo install -m 0644 -- "$tmp" "$profile" && sudo apparmor_parser -r "$profile"; }; then
      warn "could not load the AppArmor profile; $(product_label "$product") may not start."
      return 0
    fi
  else
    priv install -m 0644 -- "$tmp" "$profile"
    priv apparmor_parser -r "$profile" || warn "could not load $profile; $(product_label "$product") may not start."
  fi
  ok "Sandbox allowed by AppArmor profile $profile"
}

configure_sandbox() {
  local product=$1 dest=$2
  local exe helper="$dest/chrome-sandbox"
  exe="$dest/$(product_exe "$product")"
  if needs_apparmor_profile; then
    install_apparmor_profile "$product" "$exe"
  elif [[ $AGI_SKIP_SANDBOX != 1 && $(sysctl_value unprivileged_userns_clone) == 0 && -f $helper ]]; then
    # No user namespaces at all: fall back to Chromium's setuid helper.
    if [[ $MODE == system ]]; then
      priv chown root:root -- "$helper"
      priv chmod 4755 -- "$helper"
      ok "Configured the setuid sandbox helper"
    else
      warn "user namespaces are disabled; a --user install cannot use the setuid sandbox. Use a system install instead."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Desktop integration
# ---------------------------------------------------------------------------

write_desktop_entries() {
  local product=$1 dest=$2 id exe scheme out
  id=$(product_id "$product")
  exe="$dest/$(product_exe "$product")"
  scheme=$(product_scheme "$product")
  out=$(workdir)
  case $product in
    desktop)
      cat >"$out/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Antigravity
GenericName=AI Agent Platform
Comment=Google Antigravity agent platform
Exec="$exe" %U
Icon=$id
Terminal=false
StartupNotify=true
StartupWMClass=Antigravity
Categories=Development;
Keywords=antigravity;google;agent;ai;gemini;
MimeType=x-scheme-handler/$scheme;
EOF
      printf '%s\n' "$id.desktop"
      ;;
    ide)
      cat >"$out/$id.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Antigravity IDE
GenericName=Text Editor
Comment=Google Antigravity IDE
Exec="$exe" %F
Icon=$id
Terminal=false
StartupNotify=true
StartupWMClass=antigravity-ide
Categories=Development;IDE;TextEditor;
Keywords=antigravity;ide;editor;code;
MimeType=text/plain;inode/directory;application/x-antigravity-ide-workspace;
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec="$exe" --new-window %F
Icon=$id
EOF
      cat >"$out/$id-url-handler.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Antigravity IDE - URL Handler
Comment=Google Antigravity IDE
Exec="$exe" --open-url %U
Icon=$id
Terminal=false
NoDisplay=true
StartupNotify=true
Categories=Utility;
MimeType=x-scheme-handler/$scheme;
EOF
      printf '%s\n' "$id.desktop" "$id-url-handler.desktop"
      ;;
  esac
}

refresh_desktop_caches() {
  if have update-desktop-database; then priv update-desktop-database -q "$APPS_DIR" 2>/dev/null || true; fi
  if have gtk-update-icon-cache && [[ -f $ICONS_DIR/index.theme ]]; then
    priv gtk-update-icon-cache -q -t "$ICONS_DIR" 2>/dev/null || true
  fi
}

register_url_handler() {
  local desktop_file=$1 scheme=$2
  local err
  have xdg-mime || { warn "xdg-mime not found: $scheme:// sign-in links may not reach the app (install xdg-utils)."; return 0; }
  [[ -n $(target_user) ]] || return 0
  # xdg-mime touches mimeapps.list before creating its folder, so on a fresh
  # account the first registration is silently lost. Create it first, and
  # trust the query, not xdg-mime's exit code.
  local home
  home=$(target_home) || return 0
  if [[ $EUID -ne 0 ]]; then
    mkdir -p -- "${XDG_CONFIG_HOME:-$home/.config}"
  else
    as_target_user mkdir -p -- "$home/.config"
  fi
  err=$(as_target_user xdg-mime default "$desktop_file" "x-scheme-handler/$scheme" 2>&1) || true
  if [[ $(as_target_user xdg-mime query default "x-scheme-handler/$scheme" 2>/dev/null) == "$desktop_file" ]]; then
    ok "Sign-in links ($scheme://) open $desktop_file"
  else
    warn "could not register $scheme:// for $desktop_file${err:+: $err}"
    note "Run as your user: xdg-mime default $desktop_file x-scheme-handler/$scheme"
  fi
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

manifest_get() {
  local file=$1 key=$2
  [[ -f $file ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n 1
}

installed_version() { manifest_get "$STATE_DIR/$1.manifest" version || true; }

write_manifest() {
  local product=$1 version=$2 url=$3 dest=$4
  shift 4
  local tmp f
  tmp="$(workdir)/$product.manifest"
  {
    echo "# ${AGI_CMD} ${AGI_VERSION}. Do not edit."
    echo "product=$product"
    echo "version=$version"
    echo "url=$url"
    echo "mode=$MODE"
    echo "dir=$dest"
    echo "installed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for f in "$@"; do echo "file=$f"; done
  } >"$tmp"
  priv mkdir -p -- "$STATE_DIR"
  priv install -m 0644 -- "$tmp" "$STATE_DIR/$product.manifest"
}

# ---------------------------------------------------------------------------
# Install / update / uninstall
# ---------------------------------------------------------------------------

app_running() {
  local exe=$1
  have pgrep && pgrep -f -- "^$exe( |$)" >/dev/null 2>&1
}

path_has() { [[ ":$PATH:" == *":$1:"* ]]; }

install_product() {
  local product=$1 label id latest version url dest archive top staging
  label=$(product_label "$product")
  id=$(product_id "$product")
  dest="$OPT_DIR/$id"

  info "Looking for the latest $label for $AGI_PLATFORM"
  latest=$(resolve_latest "$product")
  version=${latest%% *}
  url=${latest#* }
  note "$url"

  local current
  current=$(installed_version "$product")
  if [[ $OPT_FORCE -eq 0 && -n $current && $current == "$version" && -x $dest/$(product_exe "$product") ]]; then
    ok "$label $version is already installed and up to date"
    return 0
  fi

  if app_running "$dest/$(product_exe "$product")"; then
    warn "$label is running. Replacing its files now would make it crash."
    if [[ $OPT_FORCE -eq 0 ]] && ! { interactive && ask "Close it yourself first, then continue?" n; }; then
      warn "skipped $label: close it and run '$AGI_CMD update' again."
      return 0
    fi
  fi

  if [[ -n $current ]]; then
    info "Updating $label $current → $version"
  else
    info "Installing $label $version"
  fi

  archive="$(workdir)/$id.tar.gz"
  fetch_file "$url" "$archive" || die "download failed: $url"
  top=$(inspect_archive "$archive")

  # Unpack next to the final location, then swap directories, so a failed
  # update never leaves a half-installed app behind.
  priv mkdir -p -- "$OPT_DIR"
  staging="$OPT_DIR/.$id.new"
  priv rm -rf -- "$staging" "$OPT_DIR/.$id.old"
  priv mkdir -p -- "$staging"
  priv tar -xzf "$archive" -C "$staging" --no-same-owner
  [[ -x $staging/$top/$(product_exe "$product") ]] \
    || { priv rm -rf -- "$staging"; die "$(product_exe "$product") not found in the archive (layout changed?)"; }
  priv chmod -R u+rwX,go+rX,go-w -- "$staging/$top"

  if [[ $version == unknown && $product == desktop ]]; then
    local pkg
    pkg="$(workdir)/package.json"
    if asar_extract "$staging/$top/resources/app.asar" package.json "$pkg" 2>/dev/null; then
      version=$(sed -nE 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$pkg" | head -n 1)
      version=${version:-unknown}
    fi
  fi

  if [[ -e $dest ]]; then priv mv -- "$dest" "$OPT_DIR/.$id.old"; fi
  if ! priv mv -- "$staging/$top" "$dest"; then
    [[ -e $OPT_DIR/.$id.old ]] && priv mv -- "$OPT_DIR/.$id.old" "$dest"
    die "could not move the new version into $dest"
  fi
  priv rm -rf -- "$staging" "$OPT_DIR/.$id.old"
  ok "Unpacked into $dest"

  configure_sandbox "$product" "$dest"

  local files=()
  # Command on the PATH.
  priv mkdir -p -- "$BIN_DIR"
  priv ln -sfn -- "$dest/$(product_cli "$product")" "$BIN_DIR/$id"
  files+=("$BIN_DIR/$id")

  # Icon.
  local icon="" size
  case $product in
    desktop)
      icon="$(workdir)/$id.png"
      asar_extract "$dest/resources/app.asar" icon.png "$icon" 2>/dev/null || icon=""
      ;;
    ide)
      icon="$dest/resources/app/resources/linux/code.png"
      [[ -f $icon ]] || icon=""
      ;;
  esac
  if [[ -n $icon ]]; then
    size=$(png_size "$icon")
    priv mkdir -p -- "$ICONS_DIR/${size}x${size}/apps"
    priv install -m 0644 -- "$icon" "$ICONS_DIR/${size}x${size}/apps/$id.png"
    files+=("$ICONS_DIR/${size}x${size}/apps/$id.png")
  else
    warn "could not extract the $label icon (python3 missing?); the launcher will use a generic icon."
  fi

  # Launchers.
  local entry entries=()
  mapfile -t entries < <(write_desktop_entries "$product" "$dest")
  priv mkdir -p -- "$APPS_DIR"
  for entry in "${entries[@]}"; do
    if have desktop-file-validate; then
      desktop-file-validate "$(workdir)/$entry" >/dev/null 2>&1 || warn "$entry did not validate; installing it anyway."
    fi
    priv install -m 0644 -- "$(workdir)/$entry" "$APPS_DIR/$entry"
    files+=("$APPS_DIR/$entry")
  done
  refresh_desktop_caches
  register_url_handler "${entries[-1]}" "$(product_scheme "$product")"

  if needs_apparmor_profile && [[ -f $(apparmor_profile_path "$product") ]]; then
    files+=("$(apparmor_profile_path "$product")")
  fi

  write_manifest "$product" "$version" "$url" "$dest" "${files[@]}"
  ok "$label $version installed. Start it from your app menu or with: $id"
  if [[ $MODE == user ]] && ! path_has "$BIN_DIR"; then
    note "$BIN_DIR is not on your PATH yet; log out and back in, or add it to your shell profile."
  fi
}

uninstall_product() {
  local product=$1 label manifest dest f
  label=$(product_label "$product")
  manifest="$STATE_DIR/$product.manifest"
  [[ -f $manifest ]] || { note "$label is not installed ($MODE)"; return 0; }
  dest=$(manifest_get "$manifest" dir)

  if app_running "$dest/$(product_exe "$product")" && [[ $OPT_FORCE -eq 0 ]]; then
    die "$label is running. Close it first (or use --force)."
  fi

  info "Removing $label"
  while IFS= read -r f; do
    [[ -n $f ]] || continue
    case $f in
      /etc/apparmor.d/*)
        # Lives outside the home dir even for --user installs.
        as_root apparmor_parser -R "$f" 2>/dev/null || true
        as_root rm -f -- "$f" || warn "could not remove $f"
        ;;
      *) priv rm -f -- "$f" ;;
    esac
  done < <(sed -n 's/^file=//p' "$manifest")
  # Only ever delete the directory this tool created.
  if [[ -n $dest && $dest == "$OPT_DIR/$(product_id "$product")" ]]; then
    priv rm -rf -- "$dest"
  fi
  priv rm -f -- "$manifest"
  refresh_desktop_caches
  ok "$label removed"

  if [[ $OPT_PURGE -eq 1 ]]; then purge_user_data "$product"; fi
}

purge_user_data() {
  local product=$1 home dirs d existing=()
  home=$(target_home) || { warn "no desktop user to purge settings for"; return 0; }
  case $product in
    desktop) dirs=("$home/.config/Antigravity" "$home/.cache/Antigravity" "$home/.cache/antigravity-updater") ;;
    ide) dirs=("$home/.config/Antigravity IDE" "$home/.antigravity-ide") ;;
  esac
  for d in "${dirs[@]}"; do [[ -e $d ]] && existing+=("$d"); done
  [[ ${#existing[@]} -gt 0 ]] || return 0
  warn "This deletes your $(product_label "$product") settings, sign-in and local data:"
  printf '      %s\n' "${existing[@]}" >&2
  if ask "Delete them?" n; then
    as_target_user rm -rf -- "${existing[@]}"
    ok "Deleted $(product_label "$product") user data"
  fi
}

install_cli() {
  info "Running Google's official Antigravity CLI installer ($AGI_CLI_INSTALLER)"
  local script
  script="$(workdir)/cli-install.sh"
  fetch_text "$AGI_CLI_INSTALLER" >"$script" || die "could not download $AGI_CLI_INSTALLER"
  chmod 0644 "$script"
  as_target_user bash "$script" || die "the Antigravity CLI installer failed"
}

# Installs this script as `antigravity-installer`, for updates later.
install_self() {
  [[ $SELF_INSTALLED -eq 0 ]] || return 0
  SELF_INSTALLED=1
  local src tmp
  tmp="$(workdir)/self.sh"
  src="${BASH_SOURCE[0]:-}"
  if [[ -n $src && -f $src && -r $src ]]; then
    cp -- "$src" "$tmp"
  elif ! fetch_text "$AGI_SELF_URL" >"$tmp" 2>/dev/null; then
    warn "could not save $AGI_CMD for later updates; rerun the one-line installer to update."
    return 0
  fi
  bash -n "$tmp" || { warn "downloaded $AGI_CMD is invalid; not saving it"; return 0; }
  priv mkdir -p -- "$BIN_DIR"
  priv install -m 0755 -- "$tmp" "$BIN_DIR/$AGI_CMD"
}

# Compatibility checks: files that would conflict with this installer.
compatibility_checks() {
  [[ $MODE == system ]] || return 0
  if have dpkg && dpkg-query -W -f='${Status}' antigravity 2>/dev/null | grep -q "install ok installed"; then
    warn "the old Antigravity 1.x apt package is installed and also provides 'antigravity'."
    note "Remove it to avoid two launchers: sudo apt remove antigravity"
  fi
  local conflicts=() f
  for f in /usr/local/bin/antigravity-linux /usr/local/bin/update-antigravity /usr/local/bin/update-antigravity-ide; do
    [[ -e $f ]] && conflicts+=("$f")
  done
  [[ -e /usr/share/nautilus-python/extensions/open-in-antigravity-ide.py ]] \
    && conflicts+=(/usr/share/nautilus-python/extensions/open-in-antigravity-ide.py)
  if [[ ${#conflicts[@]} -gt 0 ]]; then
    warn "compatibility check: these files conflict with ${AGI_CMD} and could overwrite its updates:"
    printf '      %s\n' "${conflicts[@]}" >&2
    if ask "Remove them?" y; then priv rm -f -- "${conflicts[@]}"; ok "Removed conflicting files"; fi
  fi
}

# ---------------------------------------------------------------------------
# Automatic updates (systemd timer)
# ---------------------------------------------------------------------------

timer_name() { echo "${AGI_CMD}-update"; }

auto_update_enable() {
  have systemctl || die "systemd is required for automatic updates."
  local dir out user_flag=() name exec
  name=$(timer_name)
  out=$(workdir)
  if [[ $MODE == user ]]; then
    user_flag=(--user)
    exec="$BIN_DIR/$AGI_CMD update --user --yes --quiet"
  else
    exec="$BIN_DIR/$AGI_CMD update --system --yes --quiet"
  fi
  [[ -x $BIN_DIR/$AGI_CMD ]] || install_self
  cat >"$out/$name.service" <<EOF
[Unit]
Description=Update Google Antigravity (${AGI_CMD})
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$exec
EOF
  cat >"$out/$name.timer" <<EOF
[Unit]
Description=Check daily for Google Antigravity updates (${AGI_CMD})

[Timer]
OnCalendar=daily
RandomizedDelaySec=2h
Persistent=true

[Install]
WantedBy=timers.target
EOF
  dir=$SYSTEMD_DIR
  priv mkdir -p -- "$dir"
  priv install -m 0644 -- "$out/$name.service" "$dir/$name.service"
  priv install -m 0644 -- "$out/$name.timer" "$dir/$name.timer"
  priv systemctl "${user_flag[@]}" daemon-reload
  priv systemctl "${user_flag[@]}" enable --now "$name.timer" >/dev/null
  ok "Automatic updates enabled (daily). Updates are skipped while the app is open."
}

auto_update_disable() {
  have systemctl || return 0
  local name user_flag=()
  name=$(timer_name)
  [[ $MODE == user ]] && user_flag=(--user)
  [[ -f $SYSTEMD_DIR/$name.timer ]] || { note "Automatic updates are not enabled ($MODE)"; return 0; }
  priv systemctl "${user_flag[@]}" disable --now "$name.timer" >/dev/null 2>&1 || true
  priv rm -f -- "$SYSTEMD_DIR/$name.timer" "$SYSTEMD_DIR/$name.service"
  priv systemctl "${user_flag[@]}" daemon-reload || true
  ok "Automatic updates disabled"
}

auto_update_state() {
  if [[ -f $SYSTEMD_DIR/$(timer_name).timer ]]; then echo "on"; else echo "off"; fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
${C_BOLD}${AGI_CMD}${C_RESET} ${AGI_VERSION}: install Google Antigravity on Linux (unofficial)

${C_BOLD}Usage${C_RESET}
  ${AGI_CMD} [command] [products] [options]

${C_BOLD}Commands${C_RESET}
  install [products]     Install or update (default command; default product: desktop)
  update [products]      Update what is installed (all installed products by default)
  uninstall [products]   Remove products (everything, plus this tool, by default)
  status                 Show installed and latest versions
  check                  Print the latest official download URLs, install nothing
  auto-update on|off     Check for updates every day with a systemd timer
  fix-sandbox            Reinstall the AppArmor profile the sandbox needs
  self-update            Replace ${AGI_CMD} with the latest version from GitHub

${C_BOLD}Products${C_RESET}
  desktop                Antigravity 2.0, the desktop agent app (default)
  ide                    Antigravity IDE
  cli                    Antigravity CLI (runs Google's own installer)
  all                    desktop + ide

${C_BOLD}Options${C_RESET}
  --system               Install for all users into /opt (default, uses sudo)
  --user                 Install for you only into ~/.local, no sudo
  -y, --yes              Answer yes to every question
  -f, --force            Reinstall even if up to date; act even if the app is open
  --purge                With uninstall: also delete settings and sign-in data
  -q, --quiet            Only print warnings and errors
  -h, --help             Show this help
  -V, --version          Show the version

${C_BOLD}Examples${C_RESET}
  curl -fsSL ${AGI_SELF_URL} | bash
  curl -fsSL ${AGI_SELF_URL} | bash -s -- install all --user
  ${AGI_CMD} update
  ${AGI_CMD} auto-update on
  ${AGI_CMD} uninstall ide --purge

Antigravity is a Google product. This tool only downloads Google's official
archives from ${AGI_DOWNLOAD_PAGE}.
EOF
}

COMMAND=""
TARGETS=()

parse_args() {
  local arg
  while [[ $# -gt 0 ]]; do
    arg=$1
    case $arg in
      install | update | uninstall | remove | status | check | fix-sandbox | self-update | help)
        [[ -z $COMMAND ]] || die "only one command at a time ('$COMMAND' and '$arg')"
        COMMAND=$arg
        [[ $COMMAND == remove ]] && COMMAND=uninstall
        ;;
      auto-update)
        COMMAND=auto-update
        if [[ ${2:-} == on || ${2:-} == off || ${2:-} == status ]]; then TARGETS+=("$2"); shift; fi
        ;;
      desktop | ide | cli) TARGETS+=("$arg") ;;
      all) TARGETS+=(desktop ide) ;;
      --desktop | --ide | --cli) TARGETS+=("${arg#--}") ;;
      --all) TARGETS+=(desktop ide) ;;
      --system) OPT_MODE=system ;;
      --user) OPT_MODE=user ;;
      -y | --yes) OPT_YES=1 ;;
      -f | --force) OPT_FORCE=1 ;;
      --purge) OPT_PURGE=1 ;;
      -q | --quiet) OPT_QUIET=1 ;;
      --no-apt) ;; # accepted for compatibility: this tool never calls apt
      -h | --help) COMMAND=help ;;
      -V | --version) COMMAND=version ;;
      *) die "unknown argument '$arg' (see --help)" ;;
    esac
    shift
  done
  COMMAND=${COMMAND:-install}
}

require_tools() {
  local missing=() t
  for t in "$@"; do have "$t" || missing+=("$t"); done
  [[ ${#missing[@]} -eq 0 ]] && return 0
  die "missing required tools: ${missing[*]}
       Debian/Ubuntu: sudo apt install ${missing[*]}
       Fedora:        sudo dnf install ${missing[*]}
       Arch:          sudo pacman -S ${missing[*]}"
}

# Products to act on: explicit ones, or what is installed.
installed_products() {
  local p
  for p in "${PRODUCTS[@]}"; do [[ -f $STATE_DIR/$p.manifest ]] && echo "$p"; done
  return 0
}

with_lock() {
  if have flock; then
    local lock="${XDG_RUNTIME_DIR:-/tmp}/${AGI_CMD}-${EUID}.lock"
    exec 9>"$lock"
    flock -n 9 || die "another ${AGI_CMD} is already running."
  fi
}

cmd_install() {
  local targets=("$@") p wants_cli=0 apps=()
  [[ ${#targets[@]} -gt 0 ]] || targets=(desktop)
  for p in "${targets[@]}"; do
    if [[ $p == cli ]]; then wants_cli=1; else apps+=("$p"); fi
  done
  require_tools curl tar gzip sed grep
  if [[ ${#apps[@]} -gt 0 ]]; then
    set_mode "${OPT_MODE:-system}"
    ensure_sudo
    load_download_page
    compatibility_checks
    for p in "${apps[@]}"; do install_product "$p"; done
    install_self
  fi
  if [[ $wants_cli -eq 1 ]]; then install_cli; fi
  if [[ ${#apps[@]} -gt 0 ]]; then
    note ""
    note "Update later with:  $AGI_CMD update"
    [[ $(auto_update_state) == on ]] || note "Or let it update by itself:  $AGI_CMD auto-update on"
  fi
}

cmd_update() {
  local targets=("$@") m
  if [[ -n $OPT_MODE ]]; then
    m=$OPT_MODE
  else
    m=$(detect_installed_mode) || die "nothing installed yet. Run: $AGI_CMD install"
  fi
  set_mode "$m"
  if [[ ${#targets[@]} -eq 0 ]]; then
    mapfile -t targets < <(installed_products)
    [[ ${#targets[@]} -gt 0 ]] || die "nothing installed ($MODE). Run: $AGI_CMD install"
  fi
  OPT_MODE=$m
  cmd_install "${targets[@]}"
}

cmd_uninstall() {
  local targets=("$@") everything=0 m p
  if [[ -n $OPT_MODE ]]; then
    m=$OPT_MODE
  else
    m=$(detect_installed_mode) || { note "Nothing to uninstall."; return 0; }
  fi
  set_mode "$m"
  if [[ ${#targets[@]} -eq 0 ]]; then
    everything=1
    mapfile -t targets < <(installed_products)
  fi
  ensure_sudo
  for p in "${targets[@]}"; do
    [[ $p == cli ]] && { note "The Antigravity CLI is managed by Google's installer; remove it with its own instructions."; continue; }
    uninstall_product "$p"
  done
  if [[ $everything -eq 1 ]]; then
    auto_update_disable
    priv rm -f -- "$BIN_DIR/$AGI_CMD"
    priv rm -rf -- "$STATE_DIR"
    ok "${AGI_CMD} removed"
  fi
}

cmd_status() {
  local m p found=0 latest version
  load_download_page
  for m in system user; do
    [[ $m == user && $EUID -eq 0 ]] && continue
    set_mode "$m"
    for p in "${PRODUCTS[@]}"; do
      [[ -f $STATE_DIR/$p.manifest ]] || continue
      found=1
      version=$(installed_version "$p")
      latest=$(resolve_latest "$p" 2>/dev/null) || latest="? unavailable"
      printf '%s%-16s%s %-10s %s(%s, %s)%s' "$C_BOLD" "$(product_label "$p")" "$C_RESET" "$version" \
        "$C_DIM" "$m" "$(manifest_get "$STATE_DIR/$p.manifest" dir)" "$C_RESET"
      if [[ ${latest%% *} != "$version" && ${latest%% *} != "?" ]]; then
        printf '  %supdate available: %s%s' "$C_YELLOW" "${latest%% *}" "$C_RESET"
      fi
      printf '\n'
    done
    if [[ -f $SYSTEMD_DIR/$(timer_name).timer ]]; then
      printf '%-16s %s (%s)\n' "Auto-update" on "$m"
    fi
  done
  [[ $found -eq 1 ]] || echo "Nothing installed by ${AGI_CMD}."
  return 0
}

cmd_check() {
  local p targets=("$@") latest
  [[ ${#targets[@]} -gt 0 ]] || targets=("${PRODUCTS[@]}")
  require_tools curl sed grep
  load_download_page
  for p in "${targets[@]}"; do
    [[ $p == cli ]] && { echo "Antigravity CLI: $AGI_CLI_INSTALLER"; continue; }
    latest=$(resolve_latest "$p")
    printf '%s %s: %s\n' "$(product_label "$p")" "${latest%% *}" "${latest#* }"
  done
}

cmd_auto_update() {
  local action=${1:-status} m
  if [[ -n $OPT_MODE ]]; then
    m=$OPT_MODE
  else
    m=$(detect_installed_mode) || m=system
  fi
  set_mode "$m"
  case $action in
    on) ensure_sudo; auto_update_enable ;;
    off) ensure_sudo; auto_update_disable ;;
    status) echo "Automatic updates ($MODE): $(auto_update_state)" ;;
    *) die "usage: $AGI_CMD auto-update on|off" ;;
  esac
}

cmd_fix_sandbox() {
  local m p dest
  if [[ -n $OPT_MODE ]]; then m=$OPT_MODE; else m=$(detect_installed_mode) || die "nothing installed"; fi
  set_mode "$m"
  needs_apparmor_profile || { ok "This system does not restrict the sandbox; nothing to do."; return 0; }
  ensure_sudo
  for p in $(installed_products); do
    dest=$(manifest_get "$STATE_DIR/$p.manifest" dir)
    install_apparmor_profile "$p" "$dest/$(product_exe "$p")"
  done
}

cmd_self_update() {
  local m tmp
  if [[ -n $OPT_MODE ]]; then m=$OPT_MODE; else m=$(detect_installed_mode) || m=system; fi
  set_mode "$m"
  tmp="$(workdir)/self.sh"
  fetch_text "$AGI_SELF_URL" >"$tmp" || die "could not download $AGI_SELF_URL"
  bash -n "$tmp" || die "the downloaded script is invalid"
  ensure_sudo
  priv mkdir -p -- "$BIN_DIR"
  priv install -m 0755 -- "$tmp" "$BIN_DIR/$AGI_CMD"
  ok "${AGI_CMD} updated to $(sed -n 's/^readonly AGI_VERSION="\(.*\)"/\1/p' "$tmp")"
}

main() {
  parse_args "$@"
  case $COMMAND in
    help) usage; return 0 ;;
    version) echo "${AGI_CMD} ${AGI_VERSION}"; return 0 ;;
  esac
  [[ $(uname -s) == Linux ]] || die "this installer is for Linux."
  [[ -n ${HOME:-} ]] || die "HOME is not set"
  detect_platform
  init_workdir
  local t
  for t in "${TARGETS[@]}"; do
    [[ $COMMAND == auto-update ]] && break
    is_product "$t" || [[ $t == cli ]] || die "unknown product '$t'"
  done
  case $COMMAND in
    status) cmd_status ;;
    check) cmd_check "${TARGETS[@]}" ;;
    *)
      with_lock
      case $COMMAND in
        install) cmd_install "${TARGETS[@]}" ;;
        update) cmd_update "${TARGETS[@]}" ;;
        uninstall) cmd_uninstall "${TARGETS[@]}" ;;
        auto-update) cmd_auto_update "${TARGETS[@]}" ;;
        fix-sandbox) cmd_fix_sandbox ;;
        self-update) cmd_self_update ;;
      esac
      ;;
  esac
}

# Tests source this file with AGI_SOURCED=1 to call functions directly.
if [[ ${AGI_SOURCED:-0} != 1 ]]; then
  main "$@"
fi
