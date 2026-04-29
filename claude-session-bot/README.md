# claude-session-bot

A Telegram bot that starts a `claude --remote-control` session on your local machine from a specified project directory. Runs as a persistent macOS LaunchAgent using long polling — no inbound ports or internet exposure required.

## Features

- Start a new Claude Code remote session in any project directory
- Resume the most recent session for a project
- Manage multiple concurrent sessions
- Inline keyboard UI — no typing required
- Unexpected session termination alerts via Telegram
- Works in group chats (commands appear in the menu button)
- Rotating log files (5 MB × 3)

## Requirements

- macOS
- Python 3.9+
- [Claude Code](https://claude.ai/code) CLI (`claude` in PATH)
- A Telegram bot token from [@BotFather](https://t.me/BotFather)

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/delmitz/util-scripts/main/claude-session-bot/install.sh | bash
```

The installer will prompt for:
- **Bot token** — from BotFather
- **Chat ID** — auto-detected or entered manually (supports DM and group chats)
- **Projects root** — a directory whose immediate subdirectories are treated as individual projects

## Usage

| Command | Description |
|---------|-------------|
| `/ping` | Check if the bot is alive |
| `/list` | Show available projects |
| `/start` | Start or resume a Claude session (inline keyboard) |
| `/stop` | Stop a running session (inline keyboard if multiple) |
| `/status` | Show running sessions and their URLs |
| `/create <name>` | Create a new project directory |
| `/reset` | Force-kill all Claude Code processes |
| `/updatebot` | Pull latest bot.py from GitHub and restart |

After `/start`, select a project and choose **🆕 new session** or **↩️ resume last**.

## Update

```bash
curl -fsSL https://raw.githubusercontent.com/delmitz/util-scripts/main/claude-session-bot/install.sh | bash -s -- --update
```

## Reload service

```bash
curl -fsSL https://raw.githubusercontent.com/delmitz/util-scripts/main/claude-session-bot/install.sh | bash -s -- --reload
```

## Files

After installation:

| Path | Description |
|------|-------------|
| `~/.claude-session-bot/bot.py` | Bot script |
| `~/.claude-session-bot/config.json` | Configuration (chmod 600) |
| `~/.claude-session-bot/bot.log` | Stdout log |
| `~/.claude-session-bot/bot.err` | Stderr log |
| `~/Library/LaunchAgents/com.user.claude-session-bot.plist` | launchd service |
