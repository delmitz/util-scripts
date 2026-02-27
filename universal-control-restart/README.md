# universal-control-restart

Universal Control can become unstable after the screen locks and unlocks — the session stays active but input becomes sluggish or unresponsive. This script automates a full reset on every screen unlock, keeping the connection reliable without manual intervention.

## Features

- Detects screen unlock via macOS system notifications
- Waits 3 seconds after unlock before restarting (lets macOS stabilize)
- 15-second debounce to prevent duplicate triggers
- Restarts `sharingd`, `remoted`, and `UniversalControl` — a full reset
- Persistent across reboots via LaunchAgent (auto-starts on login)
- Daemon is kept alive automatically if it crashes
- Logs all restart events to `~/Library/Logs/universal_control_restart.log`
- One-command install and uninstall

## Requirements

- macOS with Universal Control support (macOS 12.3+)
- Xcode Command Line Tools

```bash
xcode-select --install
```

## Installation

```bash
bash install_uc_restart.sh
```

The installer will:

1. Create `~/Scripts/restart_universal_control.sh`
2. Compile a Swift screen-unlock watcher (`~/Scripts/WatchUnlock`)
3. Register a LaunchAgent that starts the watcher on login

### Uninstall

```bash
bash install_uc_restart.sh --uninstall
```

Removes all installed files and unregisters the LaunchAgent.

## How it works

```
Screen unlock
  │
  └─ WatchUnlock detects com.apple.screenIsUnlocked
       │
       ├─ Debounce check (skip if < 15s since last trigger)
       └─ Wait 3 seconds
            │
            └─ restart_universal_control.sh
                 ├─ killall sharingd
                 ├─ killall remoted
                 └─ killall UniversalControl
                      │
                      └─ macOS auto-relaunches all three
```

## File structure

```
~/Scripts/
├── restart_universal_control.sh   # Kills and resets UC processes
├── WatchUnlock.swift              # Swift source (screen unlock watcher)
└── WatchUnlock                    # Compiled binary (run by LaunchAgent)

~/Library/LaunchAgents/
└── com.user.watchunlock.plist     # Registers WatchUnlock as a login daemon

~/Library/Logs/
├── universal_control_restart.log  # Restart event log
├── watchunlock.log                # Daemon stdout
└── watchunlock_error.log          # Daemon stderr
```

## View logs

```bash
# See restart history
cat ~/Library/Logs/universal_control_restart.log

# See daemon output
cat ~/Library/Logs/watchunlock.log
```

## Manual restart

Run the restart script directly at any time:

```bash
~/Scripts/restart_universal_control.sh
```
