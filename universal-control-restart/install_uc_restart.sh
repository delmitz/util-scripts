#!/bin/bash
# ============================================================================
# install_uc_restart.sh
# Universal Control Auto-Restart Installer
#
# Usage:   bash install_uc_restart.sh
# Remove:  bash install_uc_restart.sh --uninstall
# ============================================================================

set -e

SCRIPTS_DIR="$HOME/Scripts"
LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs"
PLIST_LABEL="com.user.watchunlock"
PLIST_PATH="$LAUNCH_AGENTS_DIR/$PLIST_LABEL.plist"
USERNAME=$(whoami)

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[X]${NC} $1"; }

# --- Uninstall mode --------------------------------------------------------
if [[ "$1" == "--uninstall" ]]; then
    echo ""
    echo "=== Universal Control Auto-Restart Uninstaller ==="
    echo ""

    # Unload LaunchAgent
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || \
        launchctl unload "$PLIST_PATH" 2>/dev/null || true
        info "LaunchAgent unloaded"
    else
        warn "LaunchAgent is already unloaded"
    fi

    # Kill process
    pkill -f "WatchUnlock" 2>/dev/null && info "WatchUnlock process terminated" || true

    # Remove files
    for f in "$SCRIPTS_DIR/restart_universal_control.sh" \
             "$SCRIPTS_DIR/WatchUnlock.swift" \
             "$SCRIPTS_DIR/WatchUnlock" \
             "$PLIST_PATH"; do
        if [[ -f "$f" ]]; then
            rm "$f"
            info "Removed: $f"
        fi
    done

    echo ""
    info "Uninstall complete."
    exit 0
fi

# --- Install mode ----------------------------------------------------------
echo ""
echo "=== Universal Control Auto-Restart Installer ==="
echo ""
echo "This script will:"
echo "  1) Create a Universal Control restart script"
echo "  2) Build a screen-unlock watcher (Swift)"
echo "  3) Register a LaunchAgent (auto-start on login)"
echo ""
read -p "Continue? (y/N) " confirm
if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
    echo "Installation cancelled."
    exit 0
fi
echo ""

# --- 1. Create directories ------------------------------------------------
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$LAUNCH_AGENTS_DIR"
mkdir -p "$LOG_DIR"
info "Directories verified"

# --- 2. Universal Control restart script -----------------------------------
cat > "$SCRIPTS_DIR/restart_universal_control.sh" << 'RESTART_SCRIPT'
#!/bin/bash
# restart_universal_control.sh
# Fully resets Universal Control by restarting related daemons.
# Kills sharingd (connection broker), remoted (remote device comm),
# and UniversalControl. macOS will auto-relaunch all of them.

LOG="$HOME/Library/Logs/universal_control_restart.log"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Killing sharingd" >> "$LOG"
killall sharingd 2>/dev/null

echo "$(date '+%Y-%m-%d %H:%M:%S') - Killing remoted" >> "$LOG"
killall remoted 2>/dev/null

echo "$(date '+%Y-%m-%d %H:%M:%S') - Killing UniversalControl" >> "$LOG"
killall UniversalControl 2>/dev/null

# Wait for macOS to relaunch all processes and re-establish sessions
sleep 3

echo "$(date '+%Y-%m-%d %H:%M:%S') - Universal Control full reset complete" >> "$LOG"
RESTART_SCRIPT

chmod +x "$SCRIPTS_DIR/restart_universal_control.sh"
info "Restart script created: $SCRIPTS_DIR/restart_universal_control.sh"

# --- 3. Swift watcher: build & compile -------------------------------------
cat > "$SCRIPTS_DIR/WatchUnlock.swift" << 'SWIFT_SOURCE'
import Cocoa
import Foundation

let home = NSHomeDirectory()
let scriptPath = "\(home)/Scripts/restart_universal_control.sh"
let logPath = "\(home)/Library/Logs/universal_control_restart.log"

func logMessage(_ msg: String) {
    let fmt = DateFormatter()
    fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
    fmt.timeZone = .current
    let timestamp = fmt.string(from: Date())
    let entry = "\(timestamp) - \(msg)\n"
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(entry.data(using: .utf8)!)
        handle.closeFile()
    }
    print(entry, terminator: "")
}

func restartUniversalControl() {
    logMessage("Screen unlock detected - scheduling Universal Control full reset")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [scriptPath]
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            logMessage("Script execution error: \(error)")
        }
    }
}

// Debounce: ignore duplicate triggers within 15 seconds
var lastTrigger: Date = .distantPast

func handleUnlock(_ note: Notification) {
    let now = Date()
    guard now.timeIntervalSince(lastTrigger) > 15 else { return }
    lastTrigger = now
    restartUniversalControl()
}

let dnc = DistributedNotificationCenter.default()

// Screen unlock notification
dnc.addObserver(
    forName: NSNotification.Name("com.apple.screenIsUnlocked"),
    object: nil,
    queue: .main,
    using: handleUnlock
)

// Session active notification (fallback)
dnc.addObserver(
    forName: NSNotification.Name("com.apple.sessionDidBecomeActive"),
    object: nil,
    queue: .main,
    using: handleUnlock
)

logMessage("WatchUnlock started - monitoring screen unlock events...")

// Run main loop
RunLoop.main.run()
SWIFT_SOURCE

info "Swift source created: $SCRIPTS_DIR/WatchUnlock.swift"

# Compile
echo -n "    Compiling... "
if swiftc "$SCRIPTS_DIR/WatchUnlock.swift" -o "$SCRIPTS_DIR/WatchUnlock" 2>/dev/null; then
    echo "done"
    info "Compiled successfully: $SCRIPTS_DIR/WatchUnlock"
else
    error "Swift compilation failed. Make sure Xcode Command Line Tools are installed."
    echo "    Install with: xcode-select --install"
    exit 1
fi

# --- 4. Unload existing LaunchAgent if present -----------------------------
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/$PLIST_LABEL" 2>/dev/null || \
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    warn "Existing LaunchAgent unloaded"
fi
pkill -f "WatchUnlock" 2>/dev/null || true

# --- 5. Create LaunchAgent plist ------------------------------------------
cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/${USERNAME}/Scripts/WatchUnlock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/${USERNAME}/Library/Logs/watchunlock.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/${USERNAME}/Library/Logs/watchunlock_error.log</string>
</dict>
</plist>
PLIST

info "LaunchAgent created: $PLIST_PATH"

# --- 6. Register and start LaunchAgent ------------------------------------
if launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || \
   launchctl load "$PLIST_PATH" 2>/dev/null; then
    info "LaunchAgent registered and started"
else
    error "Failed to register LaunchAgent"
    exit 1
fi

# --- 7. Verify ------------------------------------------------------------
sleep 1
if pgrep -f "WatchUnlock" &>/dev/null; then
    info "WatchUnlock process is running"
else
    warn "WatchUnlock process not detected. Check logs:"
    echo "    cat $LOG_DIR/watchunlock_error.log"
fi

# --- Done -----------------------------------------------------------------
echo ""
echo "=========================================="
info "Installation complete!"
echo "=========================================="
echo ""
echo "  How it works:"
echo "    -> Every time you unlock the screen, Universal Control"
echo "       will be automatically restarted (after a 3s delay)."
echo ""
echo "  View logs:"
echo "    cat ~/Library/Logs/universal_control_restart.log"
echo ""
echo "  Manual restart:"
echo "    ~/Scripts/restart_universal_control.sh"
echo ""
echo "  Uninstall:"
echo "    bash $0 --uninstall"
echo ""
