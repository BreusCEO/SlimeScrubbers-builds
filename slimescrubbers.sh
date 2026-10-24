#!/bin/bash
# SlimeScrubbers on a Mac: installs the newest test build and keeps it updated. No accounts needed.
#
#   curl -fsSL https://raw.githubusercontent.com/BreusCEO/SlimeScrubbers-builds/main/slimescrubbers.sh -o /tmp/slimescrubbers.sh && bash /tmp/slimescrubbers.sh install
#
#   slimescrubbers play         update, then start the game
#   slimescrubbers update       fetch the newest build now
#   slimescrubbers status       what's installed and what's out
#   slimescrubbers uninstall    remove the updater (and the game, if you say so)
#
# A background job (launchd) checks for a new build at login and every 15 minutes and swaps it in
# while the game isn't running, so the next time you open the app it is already up to date.
# Written for the bash 3.2 that ships with macOS; needs nothing beyond what macOS has.

set -euo pipefail

REPO="BreusCEO/SlimeScrubbers-builds"
SCRIPT_URL="https://raw.githubusercontent.com/$REPO/main/slimescrubbers.sh"
APP_NAME="SlimeScrubbers.app"
PROCESS="SlimeScrubbers"
SUPPORT="$HOME/Library/Application Support/SlimeScrubbers"
SELF="$SUPPORT/slimescrubbers.sh"
STATE="$SUPPORT/installed-tag"
LOG="$HOME/Library/Logs/SlimeScrubbers-updater.log"
AGENT_ID="com.breusceo.slimescrubbers.updater"
AGENT="$HOME/Library/LaunchAgents/$AGENT_ID.plist"
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:$PATH"

say() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
notify() { osascript -e "display notification \"$1\" with title \"SlimeScrubbers\"" >/dev/null 2>&1 || true; }

installed_app() {
  local d
  for d in /Applications "$HOME/Applications"; do
    if [ -d "$d/$APP_NAME" ]; then echo "$d/$APP_NAME"; return 0; fi
  done
  return 1
}

apps_dir() {
  if [ -w /Applications ]; then echo /Applications; else mkdir -p "$HOME/Applications"; echo "$HOME/Applications"; fi
}

current_tag() { if [ -f "$STATE" ]; then cat "$STATE"; fi; }

# The newest release: sets TAG and ZIP_URL (works on pretty-printed or compact JSON).
latest() {
  local json
  json="$(curl -fsSL -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest")" || return 1
  TAG="$(printf '%s' "$json" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  ZIP_URL="$(printf '%s' "$json" | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
  [ -n "$TAG" ] && [ -n "$ZIP_URL" ]
}

# One update at a time (the background job and a manual run could otherwise collide).
# A lock left behind by a run that died more than 30 minutes ago doesn't count.
take_lock() {
  local lock="$SUPPORT/update.lock"
  mkdir -p "$SUPPORT"
  if [ -d "$lock" ] && [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then rmdir "$lock" 2>/dev/null || true; fi
  if mkdir "$lock" 2>/dev/null; then
    trap 'rmdir "$SUPPORT/update.lock" 2>/dev/null || true' EXIT
    return 0
  fi
  return 1
}

# Swaps in the newest build unless it's already installed or the game is open.
update() {
  if ! take_lock; then say "another update is already running"; return 0; fi
  if ! latest; then say "couldn't reach GitHub to check for a new build"; return 1; fi
  local current app
  current="$(current_tag)"
  app="$(installed_app || true)"
  if [ "$TAG" = "$current" ] && [ -n "$app" ]; then say "up to date ($TAG)"; return 0; fi
  if pgrep -x "$PROCESS" >/dev/null 2>&1; then
    say "$TAG is out; it will be installed once you quit the game"
    return 0
  fi

  say "downloading $TAG"
  local tmp new dest
  tmp="$(mktemp -d)"
  curl -fL --progress-bar -o "$tmp/build.zip" "$ZIP_URL"
  ditto -x -k "$tmp/build.zip" "$tmp/unzipped"
  new="$(find "$tmp/unzipped" -maxdepth 2 -type d -name '*.app' | head -n 1)"
  if [ -z "$new" ]; then say "the download has no app in it"; rm -rf "$tmp"; return 1; fi
  # Unsigned test build: clear the quarantine flag and sign it for this Mac so it opens normally.
  xattr -cr "$new"
  codesign --force --deep --sign - "$new" >/dev/null 2>&1
  dest="$(apps_dir)/$APP_NAME"
  rm -rf "$dest"
  ditto "$new" "$dest"
  rm -rf "$tmp"
  mkdir -p "$SUPPORT"
  echo "$TAG" > "$STATE"
  say "installed $TAG at $dest"
  notify "Updated to ${TAG%-mac}. Have fun!"
}

# Keeps the copy the updater runs in line with the published one (only if the new one parses).
refresh_self() {
  local fresh="$SUPPORT/slimescrubbers.sh.new"
  if curl -fsSL "$SCRIPT_URL" -o "$fresh" 2>/dev/null && [ -s "$fresh" ] && bash -n "$fresh" 2>/dev/null; then
    if ! cmp -s "$fresh" "$SELF"; then mv "$fresh" "$SELF"; chmod +x "$SELF"; say "updater refreshed"; fi
  fi
  rm -f "$fresh"
}

install_all() {
  mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  local me b bin=""
  me="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  if [ "$me" != "$SELF" ]; then cp "$me" "$SELF"; fi
  chmod +x "$SELF"

  # A `slimescrubbers` command, if Homebrew's bin folder is there to hold it.
  for b in /opt/homebrew/bin /usr/local/bin; do if [ -d "$b" ] && [ -w "$b" ]; then bin="$b"; break; fi; done
  if [ -n "$bin" ]; then ln -sf "$SELF" "$bin/slimescrubbers"; fi

  update

  # Background updater: at login and every 15 minutes.
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
  launchctl bootout "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT"

  echo
  echo "Done. SlimeScrubbers is in $(apps_dir) and updates itself in the background."
  if [ -n "$bin" ]; then
    echo "Commands: slimescrubbers play | update | status | uninstall"
  else
    echo "Commands: bash \"$SELF\" play | update | status | uninstall"
  fi
}

status() {
  local app
  app="$(installed_app || true)"
  echo "installed: $(current_tag) ${app:+($app)}"
  if latest; then echo "newest:    $TAG"; fi
  if launchctl print "gui/$(id -u)/$AGENT_ID" >/dev/null 2>&1; then echo "updater:   on (log: $LOG)"; else echo "updater:   off"; fi
}

uninstall() {
  launchctl bootout "gui/$(id -u)" "$AGENT" >/dev/null 2>&1 || true
  rm -f "$AGENT" /opt/homebrew/bin/slimescrubbers /usr/local/bin/slimescrubbers
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
  update) update ;;
  background) refresh_self || true; update ;;
  play) update || true; open -a "$(installed_app)" ;;
  status) status ;;
  uninstall) uninstall ;;
  *) echo "usage: slimescrubbers [install|update|play|status|uninstall]"; exit 2 ;;
esac
