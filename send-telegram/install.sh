#!/usr/bin/env bash
# install.sh - Download and install send-telegram from GitHub

set -e

REPO_RAW="https://raw.githubusercontent.com/delmitz/util-scripts/main/send-telegram"
SCRIPT_NAME="send-telegram"
OS="$(uname)"

# Determine install paths
if [[ "$OS" == "Darwin" ]]; then
    if [[ -d "/opt/homebrew/bin" ]]; then
        SYSTEM_BIN="/opt/homebrew/bin"
    else
        SYSTEM_BIN="/usr/local/bin"
    fi
else
    SYSTEM_BIN="/usr/local/bin"
fi
USER_BIN="${HOME}/.local/bin"

# Download: prefer wget, fallback to curl
download() {
    local url="$1" dest="$2" use_sudo="${3:-false}"
    echo "Downloading ${SCRIPT_NAME}..."
    if command -v wget &>/dev/null; then
        if [[ "$use_sudo" == true ]]; then
            sudo wget -q -O "$dest" "$url"
        else
            wget -q -O "$dest" "$url"
        fi
    elif command -v curl &>/dev/null; then
        if [[ "$use_sudo" == true ]]; then
            curl -fsSL "$url" | sudo tee "$dest" > /dev/null
        else
            curl -fsSL -o "$dest" "$url"
        fi
    else
        echo "Error: wget or curl is required." >&2
        exit 1
    fi
}

echo "============================================================"
echo "  send-telegram - Installer"
echo "============================================================"
echo ""
echo "  [1] System-wide  : ${SYSTEM_BIN}/${SCRIPT_NAME}  (requires sudo)"
echo "  [2] Current user : ${USER_BIN}/${SCRIPT_NAME}"
echo ""
read -r -p "Choose [1/2]: " choice < /dev/tty

case "$choice" in
    1)
        if [[ ! -d "$SYSTEM_BIN" ]]; then
            echo "Creating ${SYSTEM_BIN}..."
            sudo mkdir -p "$SYSTEM_BIN" || { echo "Error: failed to create ${SYSTEM_BIN}." >&2; exit 1; }
        fi
        download "${REPO_RAW}/${SCRIPT_NAME}" "${SYSTEM_BIN}/${SCRIPT_NAME}" true
        sudo chmod +x "${SYSTEM_BIN}/${SCRIPT_NAME}"
        echo "Installed: ${SYSTEM_BIN}/${SCRIPT_NAME}"
        ;;
    2)
        mkdir -p "$USER_BIN"
        download "${REPO_RAW}/${SCRIPT_NAME}" "${USER_BIN}/${SCRIPT_NAME}"
        chmod +x "${USER_BIN}/${SCRIPT_NAME}"
        echo "Installed: ${USER_BIN}/${SCRIPT_NAME}"
        if [[ ":${PATH}:" != *":${USER_BIN}:"* ]]; then
            echo ""
            if [[ "$OS" == "Darwin" ]]; then
                echo "  Note: add to ~/.zshrc to make it permanent:"
            else
                echo "  Note: add to ~/.bashrc or ~/.zshrc to make it permanent:"
            fi
            echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
        fi
        ;;
    *)
        echo "Cancelled."
        exit 0
        ;;
esac

echo ""
echo "Next steps:"
echo "  send-telegram --set-bot-token \"123456789:ABCdef...\""
echo "  send-telegram --set-chat-id YOUR_CHAT_ID"
echo "  echo \"Hello!\" | send-telegram"
