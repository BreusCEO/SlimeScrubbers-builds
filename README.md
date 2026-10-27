# SlimeScrubbers: Mac test builds

Playable test builds of **SlimeScrubbers**, a janitor-versus-zombies escape game. The source code lives in a private repository; this one only holds the finished Mac app.

## Install (and stay up to date)

Paste this into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/BreusCEO/SlimeScrubbers-builds/main/slimescrubbers.sh -o /tmp/slimescrubbers.sh && bash /tmp/slimescrubbers.sh install
```

Needs macOS 12 or newer and about 2 GB of free space. No password, Homebrew or Xcode needed.

It puts SlimeScrubbers in Applications and adds a small background updater. The updater checks for a new build at login and every 15 minutes and swaps it in while the game is closed, so the app is up to date whenever you open it. No GitHub account needed.

Afterwards:

- `slimescrubbers play` updates, then starts the game
- `slimescrubbers update` fetches the newest build now
- `slimescrubbers status` shows what's installed and what's out
- `slimescrubbers doctor` checks your Mac and prints a report to send if something's wrong
- `slimescrubbers uninstall` removes the updater (it asks before deleting the game)

The app is a universal build (Apple Silicon and Intel) and isn't signed by Apple; the installer signs it for your Mac so it opens normally.

## If it doesn't install

The installer stops with an `ERROR:` line that says what's wrong and what to do (macOS too old, not enough space, GitHub unreachable from your network, and so on). If that doesn't sort it out, run this and send Ilham everything it prints:

```bash
bash /tmp/slimescrubbers.sh doctor
```

Builds and what changed in each: [Releases](https://github.com/BreusCEO/SlimeScrubbers-builds/releases).
