#!/bin/bash
# SlimeScrubbers on a Mac: installs the newest test build and keeps it updated. No accounts needed.
#
#   curl -fsSL https://raw.githubusercontent.com/BreusCEO/SlimeScrubbers-builds/main/slimescrubbers.sh -o /tmp/slimescrubbers.sh && bash /tmp/slimescrubbers.sh install
#
#   slimescrubbers play         update, then start the game
#   slimescrubbers update       fetch the newest build now
#   slimescrubbers status       what's installed and what's out
#   slimescrubbers doctor       check this Mac and print a report to send if something goes wrong
#   slimescrubbers uninstall    remove the updater (and the game, if you say so)
#
# A background job (launchd) checks for a new build at login and every 15 minutes and swaps it in
# while the game isn't running, so the next time you open the app it is already up to date.
# Written for the bash 3.2 that ships with macOS; needs nothing beyond what macOS has. It never calls
# git, lipo or python3: on a Mac without Xcode tools those only pop up an "install developer tools" box.

# Started with zsh or sh by mistake: run again under bash.
if [ -z "${BASH_VERSION:-}" ]; then
  if [ -f "$0" ] && grep -q '^AGENT_ID=' "$0" 2>/dev/null; then exec /bin/bash "$0" "$@"; fi
  echo "Run this with bash:  bash /tmp/slimescrubbers.sh install" >&2
  exit 1
fi

set -euo pipefail

REPO="BreusCEO/SlimeScrubbers-builds"
SCRIPT_URL="https://raw.githubusercontent.com/$REPO/main/slimescrubbers.sh"
APP_NAME="SlimeScrubbers.app"
PROCESS="SlimeScrubbers"
SYSTEM_APPS="/Applications"
BIN_DIRS="/opt/homebrew/bin /usr/local/bin"
SUPPORT="$HOME/Library/Application Support/SlimeScrubbers"
SELF="$SUPPORT/slimescrubbers.sh"
STATE="$SUPPORT/installed-tag"
LOG="$HOME/Library/Logs/SlimeScrubbers-updater.log"
AGENT_ID="com.breusceo.slimescrubbers.updater"
AGENT="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
MIN_MACOS="12.0"   # what current builds ask for (Unity 6); each download's own Info.plist is checked too
NEED_MB=2000       # the zip, the unpacked copy and the installed copy, with room to spare
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then CHIP=arm64; else CHIP=x86_64; fi

say() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { say "WARNING: $*" >&2; }
err() { say "ERROR: $*" >&2; }
notify() { osascript -e "display notification \"$1\" with title \"SlimeScrubbers\"" >/dev/null 2>&1 || true; }
chip_name() { if [ "$CHIP" = arm64 ]; then echo "Apple silicon"; else echo "Intel"; fi; }

# Temp files and the update lock go away however the script ends.
LOCKED=""
TMP_DIR=""
STAGE=""
cleanup() {
  if [ -n "$TMP_DIR" ]; then rm -rf "$TMP_DIR" || true; fi
  if [ -n "$STAGE" ]; then rm -rf "$STAGE" || true; fi
  if [ -n "$LOCKED" ]; then rm -rf "$SUPPORT/update.lock" || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# "12.7.6" -> 120706, so versions compare as plain numbers.
ver_num() {
  local IFS=. major minor patch
  set -- $1
  major="${1:-0}"; minor="${2:-0}"; patch="${3:-0}"
  major="${major%%[!0-9]*}"; minor="${minor%%[!0-9]*}"; patch="${patch%%[!0-9]*}"
  echo $(( 10#${major:-0} * 10000 + 10#${minor:-0} * 100 + 10#${patch:-0} ))
}

has_rosetta() { [ -f /Library/Apple/usr/share/rosetta/rosetta ] || pgrep -q oahd 2>/dev/null; }

# Stops early, with the reason and the fix, when this Mac can't take the game at all.
check_machine() {
  if [ "$(uname -s)" != Darwin ]; then err "SlimeScrubbers is a Mac game; this script only works on macOS."; exit 1; fi
  if [ "$(id -u)" = 0 ]; then
    err "please run this without sudo. It installs for your own user and never needs your password."
    exit 1
  fi
  local t missing=""
  for t in curl ditto xattr codesign file find mktemp pgrep launchctl plutil grep sed cmp df awk; do
    command -v "$t" >/dev/null 2>&1 || missing="$missing $t"
  done
  [ -x /usr/libexec/PlistBuddy ] || missing="$missing PlistBuddy"
  if [ -n "$missing" ]; then
    err "this Mac is missing tools that normally come with macOS:$missing. Run the command in the Terminal app (not another shell or tool), or update macOS."
    exit 1
  fi
  if [ "$(ver_num "$OS_VERSION")" -lt "$(ver_num "$MIN_MACOS")" ]; then
    err "SlimeScrubbers needs macOS $MIN_MACOS or newer and this Mac has macOS $OS_VERSION. Update it in System Settings > General > Software Update (Apple menu > About This Mac > Software Update on older systems). If no update to $MIN_MACOS or later is offered, this Mac is too old for the game."
    exit 1
  fi
  if ! mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs" 2>/dev/null || [ ! -w "$SUPPORT" ]; then
    err "can't write to $SUPPORT. If this was ever run with sudo, fix it with:  sudo chown -R \"$(id -un)\" \"$SUPPORT\" ~/Library/LaunchAgents ~/Library/Logs"
    exit 1
  fi
}

installed_app() {
  local d
  for d in "$SYSTEM_APPS" "$HOME/Applications"; do
    if [ -d "$d/$APP_NAME" ]; then echo "$d/$APP_NAME"; return 0; fi
  done
  return 1
}

# /Applications for admin accounts, ~/Applications for standard ones (no password needed either way).
apps_dir() {
  if [ -w "$SYSTEM_APPS" ]; then echo "$SYSTEM_APPS"; else mkdir -p "$HOME/Applications"; echo "$HOME/Applications"; fi
}

current_tag() { if [ -f "$STATE" ]; then cat "$STATE"; fi; }

# fetch URL FILE [ACCEPT]: body into FILE, prints the HTTP status (000 = no answer at all).
fetch() {
  local code
  code="$(curl --silent --location --retry 2 --connect-timeout 20 ${3:+-H "Accept: $3"} -o "$2" -w '%{http_code}' "$1" 2>/dev/null)" || true
  echo "${code:-000}"
}

# The newest release: sets TAG and ZIP_URL, or WHY when it can't. Asks the GitHub API first and falls
# back to the github.com release pages, because the API answers only 60 requests an hour per network
# (a school, office or phone hotspot shares that between everyone on it) and some networks block it.
latest() {
  TAG=""; ZIP_URL=""; WHY=""
  local f code page
  f="$(mktemp -t slimescrubbers)" || { WHY="couldn't create a temp file"; return 1; }
  code="$(fetch "https://api.github.com/repos/$REPO/releases/latest" "$f" "application/vnd.github+json")"
  if [ "$code" = 200 ]; then
    TAG="$(grep -o '"tag_name": *"[^"]*"' "$f" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')" || true
    ZIP_URL="$(grep -o '"browser_download_url": *"[^"]*\.zip"' "$f" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')" || true
  fi
  if [ -z "$TAG" ] || [ -z "$ZIP_URL" ]; then
    case "$code" in
      403|429) WHY="GitHub's limit of checks for this network is used up for the hour (HTTP $code)" ;;
      000) WHY="api.github.com didn't answer" ;;
      200) WHY="the newest release has no .zip in it" ;;
      *) WHY="api.github.com answered HTTP $code" ;;
    esac
    TAG=""; ZIP_URL=""
    page="$(curl --silent --location --retry 2 --connect-timeout 20 -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null)" || page=""
    case "$page" in */releases/tag/*) TAG="${page##*/releases/tag/}" ;; esac
    if [ -n "$TAG" ] && [ "$(fetch "https://github.com/$REPO/releases/expanded_assets/$TAG" "$f")" = 200 ]; then
      ZIP_URL="$(grep -o 'href="[^"]*/releases/download/[^"]*\.zip"' "$f" | head -n 1 | sed 's/^href="//; s/"$//')" || true
      case "$ZIP_URL" in /*) ZIP_URL="https://github.com$ZIP_URL" ;; esac
    fi
    if [ -z "$TAG" ] || [ -z "$ZIP_URL" ]; then WHY="$WHY, and github.com's release page didn't work either"; fi
  fi
  rm -f "$f"
  [ -n "$TAG" ] && [ -n "$ZIP_URL" ]
}

# One update at a time (the background job and a manual run could otherwise collide). A lock whose
# owner is gone doesn't count, nor does one older than 3 hours (30 minutes for the old pid-less kind).
take_lock() {
  local lock="$SUPPORT/update.lock" pid=""
  if [ -d "$lock" ]; then
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if { [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; } \
      || { [ -z "$pid" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; } \
      || [ -n "$(find "$lock" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
      rm -rf "$lock"
    fi
  fi
  if mkdir "$lock" 2>/dev/null; then
    LOCKED=1
    echo $$ > "$lock/pid" 2>/dev/null || true
    return 0
  fi
  return 1
}

enough_space() {
  local free
  free="$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')" || free=""
  if [ -n "$free" ] && [ "$free" -lt "$NEED_MB" ]; then
    err "not enough free disk space: updating needs about $NEED_MB MB and this Mac has $free MB free. Empty the Bin or delete some files, then run this again."
    return 1
  fi
}

# Refuses a build this Mac can't start, before anything already installed is touched.
can_run() {
  local app="$1" minos exe archs
  minos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null)" || minos="$MIN_MACOS"
  if [ "$(ver_num "$OS_VERSION")" -lt "$(ver_num "$minos")" ]; then
    err "$TAG needs macOS $minos or newer and this Mac has macOS $OS_VERSION. Update it in System Settings > General > Software Update."
    return 1
  fi
  exe="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null)" || exe="$PROCESS"
  archs="$(file -b "$app/Contents/MacOS/$exe" 2>/dev/null)" || archs=""
  case "$archs" in
    *arm64*x86_64*|*x86_64*arm64*) return 0 ;;
    *arm64*)
      if [ "$CHIP" = arm64 ]; then return 0; fi
      err "$TAG is built only for Apple silicon Macs and this one has an Intel chip. Ask Ilham for a universal build."
      return 1 ;;
    *x86_64*)
      if [ "$CHIP" = arm64 ] && ! has_rosetta; then
        warn "$TAG is built for Intel only, so this Mac needs Rosetta to run it. Install it with:  softwareupdate --install-rosetta --agree-to-license"
      fi
      return 0 ;;
  esac
  warn "couldn't tell which chips $TAG is built for; installing it anyway"
}

# Swaps in the newest build unless it's already installed or the game is open.
update() {
  if ! take_lock; then say "another update is already running"; return 0; fi
  if ! latest; then
    err "couldn't find the newest build: $WHY. Check the internet connection (and any VPN or firewall), or try another network."
    return 1
  fi
  local current app dir dest new old out progress=--silent
  current="$(current_tag)"
  app="$(installed_app || true)"
  if [ "$TAG" = "$current" ] && [ -n "$app" ]; then say "up to date ($TAG)"; return 0; fi
  if pgrep -x "$PROCESS" >/dev/null 2>&1; then
    say "$TAG is out; it will be installed once you quit the game"
    return 0
  fi
  if [ -n "$app" ] && [ -w "$(dirname "$app")" ]; then dir="$(dirname "$app")"; else dir="$(apps_dir)"; fi
  dest="$dir/$APP_NAME"
  if ! TMP_DIR="$(mktemp -d)"; then err "couldn't create a temp folder"; return 1; fi
  enough_space "$TMP_DIR" || return 1
  enough_space "$dir" || return 1

  say "downloading $TAG"
  if [ -t 2 ]; then progress=--progress-bar; fi
  if ! curl --fail --show-error --location --retry 3 --retry-delay 3 --connect-timeout 20 --speed-limit 1024 --speed-time 60 \
    "$progress" -o "$TMP_DIR/build.zip" "$ZIP_URL"; then
    err "the download didn't finish (the curl line above says why). Check the internet connection and run this again."
    return 1
  fi
  if ! ditto -x -k "$TMP_DIR/build.zip" "$TMP_DIR/unzipped"; then
    err "couldn't unpack the download (it may be cut short, or the disk is full). Run this again."
    return 1
  fi
  new="$(find "$TMP_DIR/unzipped" -maxdepth 2 -type d -name '*.app' | head -n 1)" || true
  if [ -z "$new" ]; then err "the download has no app in it"; return 1; fi
  can_run "$new" || return 1

  # Unsigned test build: clear the download flags and sign it for this Mac so it opens normally
  # (Apple silicon won't start code with no signature at all).
  chmod -R u+w "$new" 2>/dev/null || true
  if ! xattr -cr "$new" 2>/dev/null; then
    warn "couldn't clear the download flags; if macOS blocks the first launch, right-click the app and choose Open"
  fi
  if ! out="$(codesign --force --deep --sign - "$new" 2>&1)"; then warn "couldn't sign the app for this Mac: $out"; fi

  # Copy next to the old build first and then swap the two by renaming, so a failure at any step
  # leaves the old build in place and working.
  rm -rf "$dir/.$PROCESS-installing-"*.app "$dir/.$PROCESS-old-"*.app 2>/dev/null || true
  STAGE="$dir/.$PROCESS-installing-$$.app"
  if ! ditto "$new" "$STAGE"; then
    err "couldn't copy the game into $dir (the disk may be full)"
    return 1
  fi
  old="$dir/.$PROCESS-old-$$.app"
  if [ -e "$dest" ] && ! mv "$dest" "$old" 2>/dev/null; then
    err "macOS didn't let this script replace the old $dest. Either allow Terminal in System Settings > Privacy & Security > App Management, or drag the old SlimeScrubbers to the Bin. Then run this again."
    return 1
  fi
  if ! mv "$STAGE" "$dest"; then
    if [ -e "$old" ]; then mv "$old" "$dest" 2>/dev/null || true; fi
    err "couldn't move the new build into place at $dest"
    return 1
  fi
  STAGE=""
  if [ -e "$old" ] && ! rm -rf "$old" 2>/dev/null; then
    warn "couldn't delete the previous build (hidden at $old); the next update tries again"
  fi
  rm -rf "$TMP_DIR"
  TMP_DIR=""
  echo "$TAG" > "$STATE" || warn "couldn't note the installed build in $STATE"
  say "installed $TAG at $dest"
  notify "Updated to ${TAG%-mac}. Have fun!"
}

# Is this file a copy of this script (and not, say, an error page or the bash binary)?
is_script() { [ -s "$1" ] && grep -q '^AGENT_ID=' "$1" 2>/dev/null && bash -n "$1" 2>/dev/null; }

# Keeps the copy the updater runs in line with the published one (only if the new one parses).
refresh_self() {
  local fresh="$SUPPORT/slimescrubbers.sh.new"
  if curl -fsSL "$SCRIPT_URL" -o "$fresh" 2>/dev/null && is_script "$fresh"; then
    if ! cmp -s "$fresh" "$SELF"; then mv "$fresh" "$SELF"; chmod +x "$SELF"; say "updater refreshed"; fi
  fi
  rm -f "$fresh"
}

# Background updater: at login and every 15 minutes. bootout finishes asynchronously, so an immediate
# bootstrap can fail with "5: Input/output error"; it gets a few tries and then the older load verb.
install_agent() {
  local domain="gui/$(id -u)" i
  cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$AGENT_ID</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$SELF</string>
    <string>background</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>900</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST
  chmod 644 "$AGENT"
  if ! launchctl print "$domain" >/dev/null 2>&1; then
    warn "there's no logged-in desktop session here (SSH?), so the background updater can't start"
    return 1
  fi
  launchctl bootout "$domain/$AGENT_ID" >/dev/null 2>&1 || true
  for i in 1 2 3 4; do
    if launchctl bootstrap "$domain" "$AGENT" 2>/dev/null; then return 0; fi
    sleep 2
  done
  launchctl load -w "$AGENT" >/dev/null 2>&1 || true
  launchctl print "$domain/$AGENT_ID" >/dev/null 2>&1
}

install_all() {
  check_machine
  # The updater runs its own copy of this script. Piped into bash (curl ... | bash) there is no file
  # to copy and $0 is bash itself, so fetch the published one instead.
  local me="${BASH_SOURCE[0]:-}" b app bin=""
  if [ -n "$me" ] && is_script "$me"; then
    if [ ! "$me" -ef "$SELF" ]; then cp "$me" "$SELF"; fi
  elif ! curl -fsSL --retry 2 "$SCRIPT_URL" -o "$SELF" || ! is_script "$SELF"; then
    err "couldn't save a copy of this script for the updater; check the internet connection and run this again"
    exit 1
  fi
  chmod +x "$SELF"
  say "this Mac: macOS $OS_VERSION, $(chip_name)"

  # A `slimescrubbers` command, if Homebrew's bin folder is there to hold it.
  for b in $BIN_DIRS; do if [ -d "$b" ] && [ -w "$b" ]; then bin="$b"; break; fi; done
  if [ -n "$bin" ] && ! ln -sf "$SELF" "$bin/slimescrubbers" 2>/dev/null; then bin=""; fi

  if ! update; then
    echo
    echo "SlimeScrubbers isn't installed: the ERROR line above says why and what to do."
    echo "If it's still stuck, send Ilham the report from:  bash \"$SELF\" doctor"
    exit 1
  fi

  local updater=on
  if ! install_agent; then
    updater=off
    warn "the game is installed but the background updater couldn't be switched on. The game works; run this installer again later to retry, or update by hand with the update command below."
  fi

  echo
  if app="$(installed_app)"; then
    echo "Done. SlimeScrubbers is in $(dirname "$app"). Open it from Launchpad or that folder."
  else
    echo "Done, but no SlimeScrubbers app turned up; quit the game if it's open and run this again."
  fi
  if [ "$updater" = on ]; then echo "It updates itself in the background (if macOS says a background item was added, that's this; leave it on)."; fi
  if [ -n "$bin" ]; then
    echo "Commands: slimescrubbers play | update | status | doctor | uninstall"
  else
    echo "Commands: bash \"$SELF\" play | update | status | doctor | uninstall"
  fi
}

status() {
  local app
  app="$(installed_app || true)"
  echo "installed: $(current_tag) ${app:+($app)}"
  if latest; then echo "newest:    $TAG"; else echo "newest:    unknown ($WHY)"; fi
  if launchctl print "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1; then echo "updater:   on (log: $LOG)"; else echo "updater:   off"; fi
}

# Everything the installer depends on, in one report to copy and send. Changes nothing.
doctor() {
  local f code left free app b kind where=""
  line() { printf '  %-12s %s\n' "$1" "$2"; }
  echo "SlimeScrubbers doctor, $(date '+%Y-%m-%d %H:%M')"
  if [ "$(ver_num "$OS_VERSION")" -ge "$(ver_num "$MIN_MACOS")" ]; then
    line macOS "$OS_VERSION (needs $MIN_MACOS or newer): ok"
  else
    line macOS "$OS_VERSION: PROBLEM, the game needs macOS $MIN_MACOS or newer"
  fi
  line chip "$(chip_name)$( [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ] && echo ', Terminal is running under Rosetta' )"
  if [ "$CHIP" = arm64 ]; then
    if has_rosetta; then line rosetta "installed"; else line rosetta "not installed (only needed for Intel-only builds)"; fi
  fi
  kind=standard
  case " $(id -Gn) " in *" admin "*) kind=admin ;; esac
  if [ "$(id -u)" = 0 ]; then line user "root: PROBLEM, run it without sudo"; else
    line user "$(id -un) ($kind account), installs to $(if [ -w "$SYSTEM_APPS" ]; then echo "$SYSTEM_APPS"; else echo "$HOME/Applications"; fi)"
  fi
  free="$(df -Pk "$HOME" 2>/dev/null | awk 'NR==2 {print int($4/1024)}')" || true
  if [ -n "$free" ] && [ "$free" -lt "$NEED_MB" ]; then line disk "$free MB free: PROBLEM, needs about $NEED_MB"; else line disk "${free:-?} MB free (needs about $NEED_MB): ok"; fi
  b=""
  for f in curl ditto xattr codesign file find mktemp pgrep launchctl plutil grep sed cmp df awk; do command -v "$f" >/dev/null 2>&1 || b="$b $f"; done
  if [ -z "$b" ]; then line tools "all there (bash $BASH_VERSION)"; else line tools "PROBLEM, missing:$b"; fi

  if f="$(mktemp -t slimescrubbers)"; then
    code="$(fetch "https://api.github.com/rate_limit" "$f" "application/vnd.github+json")"
    left="$(tr -d ' \n' < "$f" | grep -o '"core":{[^}]*}' | grep -o '"remaining":[0-9]*' | head -n 1 | cut -d: -f2)" || true
    rm -f "$f"
    if [ "$code" = 200 ]; then line "github api" "reachable, ${left:-?} of 60 checks left this hour$( [ "${left:-1}" = 0 ] && echo ' (used up; the installer falls back to github.com)' )"; else line "github api" "HTTP $code (the installer falls back to github.com)"; fi
  fi
  code="$(fetch "https://github.com/$REPO/releases" /dev/null)"
  if [ "$code" = 200 ]; then line github.com "reachable"; else line github.com "HTTP $code: PROBLEM, can't reach GitHub (internet, VPN or firewall?)"; fi
  if latest; then
    line newest "$TAG"
    code="$(curl --silent --location --retry 2 --connect-timeout 20 -r 0-0 -o /dev/null -w '%{http_code}' "$ZIP_URL" 2>/dev/null)" || true
    case "$code" in 200|206) line download "reachable" ;; *) line download "HTTP ${code:-000}: PROBLEM, the build's download server isn't reachable from here" ;; esac
  else
    line newest "PROBLEM: $WHY"
  fi

  if app="$(installed_app)"; then
    line installed "$(current_tag) at $app"
    line "app chips" "$(file -b "$app/Contents/MacOS/$PROCESS" 2>/dev/null | grep -oE 'x86_64|arm64' | sort -u | tr '\n' ' ' | sed 's/ $//')"
    line "app needs" "macOS $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$app/Contents/Info.plist" 2>/dev/null || echo '?')"
    if codesign --verify --deep "$app" >/dev/null 2>&1; then line signature ok; else line signature "PROBLEM, broken: run the update command to reinstall"; fi
    if xattr -p com.apple.quarantine "$app" >/dev/null 2>&1; then line quarantine "set: macOS may refuse to open it; run the update command"; else line quarantine none; fi
  else
    line installed "no"
  fi
  if launchctl print "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1; then line updater on; elif [ -f "$AGENT" ]; then line updater "off (set up but not running)"; else line updater "not set up"; fi
  for b in $BIN_DIRS; do if [ -L "$b/slimescrubbers" ]; then where="$b/slimescrubbers"; fi; done
  line command "${where:-bash \"$SELF\"}"
  if [ -f "$LOG" ]; then echo "  last updater lines:"; tail -n 8 "$LOG" | sed 's/^/    /'; fi
}

uninstall() {
  local b
  launchctl bootout "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1 || true
  rm -f "$AGENT"
  for b in $BIN_DIRS; do if [ -L "$b/slimescrubbers" ]; then rm -f "$b/slimescrubbers" || true; fi; done
  echo "Background updater removed."
  local app answer
  app="$(installed_app || true)"
  if [ -n "$app" ]; then
    printf "Also delete %s? [y/N] " "$app"
    read -r answer
    if [ "$answer" = y ] || [ "$answer" = Y ]; then rm -rf "$app" "$SUPPORT"; echo "Removed."; fi
  fi
}

case "${1:-install}" in
  install) install_all ;;
  update) check_machine; update ;;
  background) check_machine; refresh_self || true; update ;;
  play)
    check_machine
    update || true
    if app="$(installed_app)"; then open -a "$app"; else err "SlimeScrubbers isn't installed yet; run:  bash \"$SELF\" install"; exit 1; fi ;;
  status) status ;;
  doctor) doctor ;;
  uninstall) uninstall ;;
  *) echo "usage: slimescrubbers [install|update|play|status|doctor|uninstall]"; exit 2 ;;
esac
