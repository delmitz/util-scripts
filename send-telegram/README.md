# send-telegram

A shell script for sending Telegram messages from the command line. Supports scheduled delivery via a file-based job queue and background daemon — no long-running processes while waiting.

## Features

- Send messages via stdin (`echo "msg" | send-telegram`)
- Scheduled delivery: relative (`+30`) or absolute (`1430`, `202603011430`)
- File-based job queue — schedules survive terminal close
- Background daemon that exits automatically when the queue is empty
- Adaptive sleep: wakes up precisely when the next job is due
- Default chat ID saved to config (omit `-c` after first setup)
- Bot token stored in config file, survives script updates
- Log rotation (512 KB limit, keeps one backup)
- Failed jobs retried up to 3 times before giving up
- Works on macOS and Linux

## Requirements

- `bash` 4.0+
- `curl`

> macOS ships with bash 3.2. Install a newer version via Homebrew: `brew install bash`

## Installation

```bash
curl -fsSL https://raw.githubusercontent.com/delmitz/util-scripts/main/send-telegram/install.sh | bash
```

Pass an argument to skip the interactive prompt:

```bash
# System-wide (non-interactive)
curl -fsSL https://raw.githubusercontent.com/delmitz/util-scripts/main/send-telegram/install.sh | bash -s -- --system

# Current user (non-interactive)
curl -fsSL https://raw.githubusercontent.com/delmitz/util-scripts/main/send-telegram/install.sh | bash -s -- --user
```

### Manual install

```bash
# macOS (Apple Silicon)
sudo cp send-telegram /opt/homebrew/bin/send-telegram

# macOS (Intel) / Linux
sudo cp send-telegram /usr/local/bin/send-telegram

# Current user only
mkdir -p ~/.local/bin
cp send-telegram ~/.local/bin/send-telegram
```

## Configuration

Credentials are stored in `~/.send-telegram/config` (permissions: `600`).

```bash
# Set bot token (required)
send-telegram --set-bot-token "123456789:ABCdef..."

# Set default chat ID (optional — lets you omit -c)
send-telegram --set-chat-id 123456789
```

### Getting a bot token

1. Open Telegram and search for **@BotFather**
2. Send `/newbot` and follow the prompts
3. Copy the token (format: `123456789:ABCdef...`)

### Finding your chat ID

1. Send any message to your bot
2. Open `https://api.telegram.org/bot<TOKEN>/getUpdates` in a browser
3. Look for `"chat":{"id": <number>}`

## Usage

```bash
# Immediate send
echo "Hello" | send-telegram -c 123456789
send-telegram -c 123456789 <<< "Hello"

# Using saved default chat ID
echo "Hello" | send-telegram

# Interactive input
send-telegram -i
```

### Scheduled delivery

```bash
# 30 minutes from now
send-telegram -s +30 <<< "Message"

# Specific time today (HHmm)
send-telegram -s 1430 <<< "At 14:30 today"

# Specific date and time (yyyyMMddHHmm)
send-telegram -s 202603011430 <<< "March 1st at 14:30"
```

**Behavior when the specified time has already passed:**

| Format | Behavior |
|--------|----------|
| `HHmm` | Scheduled for the **same time tomorrow** |
| `yyyyMMddHHmm` | Sent immediately |

Multiple messages scheduled for the same timestamp are delivered in registration order (FIFO).

### Job management

```bash
# List pending jobs and daemon status
send-telegram --list-jobs

# Cancel a scheduled job
send-telegram --cancel 1740000000_0000_abcd1234
```

## How scheduled delivery works

```
send-telegram -s +30 <<< "msg"
  │
  ├─ Creates ~/.send-telegram/jobs/<timestamp>_<seq>_<rand>.job
  ├─ Starts background daemon (if not already running)
  └─ Exits immediately

Daemon
  ├─ Checks job queue every 60s (or wakes early if a job is due sooner)
  ├─ Sends due jobs via Telegram API
  ├─ Retries failed jobs up to 3 times, then discards
  └─ Exits when the queue is empty
```

## File structure

```
~/.send-telegram/
├── config          # Bot token and default chat ID (chmod 600)
├── daemon.pid      # Daemon PID (present only while running)
├── daemon.log      # Daemon log (rotated at 512 KB)
├── daemon.log.1    # Previous log (one backup kept)
└── jobs/
    ├── <id>.job    # Pending job (chmod 600)
    └── <id>.retry  # Retry counter for failed jobs
```

## All options

```
Usage: send-telegram [-c <chat_id>] [-s <schedule>] <<< "message"

Send options:
  -c, --chat-id <id>        Telegram chat ID
  -s, --schedule <spec>     +N / HHmm / yyyyMMddHHmm
  -i, --interactive         Read message from terminal interactively

Job management:
  --list-jobs               Show pending jobs and daemon status
  --cancel <job_id>         Cancel a scheduled job

Configuration:
  --set-bot-token <token>   Save bot token
  --set-chat-id <id>        Save default chat ID

Help:
  --setup                   Interactive installation guide
  -v, --version             Show version
  -h, --help                Show help
```
