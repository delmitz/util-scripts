#!/usr/bin/env bash
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/delmitz/util-scripts/main/claude-session-bot"
INSTALL_DIR="$HOME/.claude-session-bot"
VENV_DIR="$INSTALL_DIR/.venv"
BOT_SCRIPT="$INSTALL_DIR/bot.py"
CONFIG_FILE="$INSTALL_DIR/config.json"
PLIST_LABEL="com.user.claude-session-bot"
PLIST_FILE="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
TMP_DIR="$INSTALL_DIR/tmp"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# --reload: restart the service without reconfiguring
if [ "${1:-}" = "--reload" ]; then
    if [ ! -f "$PLIST_FILE" ]; then
        echo "ERROR: Service not installed. Run without arguments to install first."
        exit 1
    fi
    echo "Reloading claude-session-bot service..."
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    launchctl load "$PLIST_FILE"
    sleep 2
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        echo "  OK Service reloaded"
    else
        echo "  ERROR Service failed to start. Check logs: $INSTALL_DIR/bot.err"
        exit 1
    fi
    exit 0
fi

# --update: download latest bot.py and reload
if [ "${1:-}" = "--update" ]; then
    if [ ! -f "$PLIST_FILE" ]; then
        echo "ERROR: Service not installed. Run without arguments to install first."
        exit 1
    fi
    echo "Updating claude-session-bot..."
    curl -fsSL "$REPO_RAW/bot.py" -o "$BOT_SCRIPT"
    echo "  OK bot.py updated"
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
    launchctl load "$PLIST_FILE"
    sleep 2
    if launchctl list "$PLIST_LABEL" &>/dev/null; then
        echo "  OK Service reloaded"
    else
        echo "  ERROR Service failed to start. Check logs: $INSTALL_DIR/bot.err"
        exit 1
    fi
    exit 0
fi

echo "=== claude-session-bot installer ==="
echo

# 1. Preflight checks
echo "[1/5] Checking prerequisites..."

if ! command -v python3 &>/dev/null; then
    echo "ERROR: python3 not found. Please install Python 3."
    exit 1
fi
echo "  OK python3: $(python3 --version)"

CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ]; then
    echo "ERROR: claude binary not found in PATH."
    exit 1
fi
echo "  OK claude: $CLAUDE_BIN"

PYTHON_BIN="$(command -v python3)"

# 2. Download and install
echo
echo "[2/5] Downloading and installing..."
mkdir -p "$INSTALL_DIR"

curl -fsSL "$REPO_RAW/bot.py" -o "$BOT_SCRIPT"
echo "  OK bot.py downloaded"

curl -fsSL "$REPO_RAW/requirements.txt" -o "$INSTALL_DIR/requirements.txt"
echo "  OK requirements.txt downloaded"

if [ ! -d "$VENV_DIR" ]; then
    python3 -m venv "$VENV_DIR"
fi
"$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt" --quiet
PYTHON_BIN="$VENV_DIR/bin/python3"
echo "  OK Dependencies installed"

# 3. Interactive configuration
echo
echo "[3/5] Configuration"
echo

# Ensure prompts read from terminal even when piped via curl | bash
exec < /dev/tty

read -rp "Bot token (from BotFather): " BOT_TOKEN
if [ -z "$BOT_TOKEN" ]; then
    echo "ERROR: Bot token cannot be empty."
    exit 1
fi

echo
echo "How would you like to provide the chat ID?"
echo "  1) Auto-detect (bot will wait for you to send a message in Telegram)"
echo "  2) Enter manually"
read -rp "Choice [1/2]: " CHAT_ID_CHOICE

if [ "${CHAT_ID_CHOICE:-1}" = "1" ]; then
    mkdir -p "$TMP_DIR"
    CHAT_ID_FILE="$TMP_DIR/chat_id.txt"
    DETECT_SCRIPT="$TMP_DIR/detect_chat_id.py"

    cat > "$DETECT_SCRIPT" <<'PYEOF'
import sys
import asyncio
from telegram import Update
from telegram.ext import Application, MessageHandler, filters, ContextTypes

token = sys.argv[1]
outfile = sys.argv[2]
detected = asyncio.Event()

async def handle(update: Update, ctx: ContextTypes.DEFAULT_TYPE):
    with open(outfile, "w") as f:
        f.write(str(update.effective_chat.id))
    detected.set()

async def main():
    app = Application.builder().token(token).build()
    app.add_handler(MessageHandler(filters.ALL, handle))
    print("Waiting for a message...", flush=True)
    print("  - DM: send any message to your bot", flush=True)
    print("  - Group chat: send /ping (or any command) in the group", flush=True)
    async with app:
        await app.start()
        await app.updater.start_polling(drop_pending_updates=True)
        await detected.wait()
        await app.updater.stop()
        await app.stop()

asyncio.run(main())
PYEOF

    "$PYTHON_BIN" "$DETECT_SCRIPT" "$BOT_TOKEN" "$CHAT_ID_FILE"
    CHAT_ID="$(cat "$CHAT_ID_FILE" 2>/dev/null || true)"
    echo "Detected chat_id: $CHAT_ID"
    read -rp "Is this correct? [Y/n]: " CONFIRM
    if [[ "${CONFIRM:-Y}" =~ ^[Nn] ]]; then
        read -rp "Chat ID: " CHAT_ID
    fi
else
    read -rp "Chat ID: " CHAT_ID
fi

if [ -z "$CHAT_ID" ]; then
    echo "ERROR: Chat ID cannot be empty."
    exit 1
fi

echo
read -rp "Projects root directory (absolute path): " PROJECTS_ROOT
PROJECTS_ROOT="${PROJECTS_ROOT/#\~/$HOME}"

if [ ! -d "$PROJECTS_ROOT" ]; then
    echo "ERROR: Directory does not exist: $PROJECTS_ROOT"
    exit 1
fi

PROJECT_COUNT="$(find "$PROJECTS_ROOT" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
echo "  OK Found $PROJECT_COUNT project(s) under $PROJECTS_ROOT"

# 4. Write config
echo
echo "[4/5] Writing config..."
cat > "$CONFIG_FILE" <<CONFIGEOF
{
  "bot_token": "$BOT_TOKEN",
  "allowed_chat_id": $CHAT_ID,
  "projects_root": "$PROJECTS_ROOT",
  "claude_bin": "$CLAUDE_BIN"
}
CONFIGEOF
chmod 600 "$CONFIG_FILE"
echo "  OK Config written to $CONFIG_FILE"

# 5. Install launchd service
echo
echo "[5/5] Installing launchd service..."

mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST_FILE" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PYTHON_BIN</string>
    <string>$BOT_SCRIPT</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/bot.log</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/bot.err</string>
</dict>
</plist>
PLISTEOF

if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_FILE" 2>/dev/null || true
fi
launchctl load "$PLIST_FILE"
sleep 2

if launchctl list "$PLIST_LABEL" &>/dev/null; then
    echo "  OK Service registered and running"
else
    echo "  WARN Service registered but may not be running yet"
fi

echo
echo "=== Installation complete ==="
echo
echo "Send /ping to your bot in Telegram to verify it's working."
echo
echo "Useful commands:"
echo "  View logs:   tail -f $INSTALL_DIR/bot.log"
echo "  Reload:      curl -fsSL $REPO_RAW/install.sh | bash -s -- --reload"
echo "  Update bot:  curl -fsSL $REPO_RAW/install.sh | bash -s -- --update"
echo "  Reinstall:   curl -fsSL $REPO_RAW/install.sh | bash"
