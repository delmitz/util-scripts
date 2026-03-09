# Changelog

## 202603100101 (2026-03-10)

### Added
- `-t` / `--token` option to pass bot token at runtime (overrides config)
- Resolution order updated: `-t` option > user config > system config > error

### Fixed
- `save_bot_token` / `save_chat_id`: apply `chmod` after file creation, not before

## 202603081301 (2026-03-08)

### Added
- System-wide config support (`/etc/send-telegram/config`)
- `--global` flag for `--set-bot-token` and `--set-chat-id` to write to system config
- Config resolution order: user config → system config → error

## 202603022301 (2026-03-02)

### Fixed
- Add `parse_mode=Markdown` to Telegram API call — code blocks and markdown formatting now render correctly

## 202603011701 (2026-03-01)

### Added
- `install.sh`: one-liner installer via `curl | bash`
- `--system` / `--user` arguments for non-interactive install
- `VERSION` string and `-v` / `--version` option
- Version displayed at top of help output

### Fixed
- `read < /dev/tty` in install.sh to support `curl | bash` (stdin occupied by pipe)
- `HHmm` past-time scheduling now schedules for next day instead of sending immediately

## 202602280000 (2026-02-28)

### Added
- File-based job queue with background daemon
- Adaptive sleep — daemon wakes precisely when next job is due
- FIFO ordering for same-timestamp jobs (`{send_at}_{seq}_{rand}.job`)
- Bot token stored in config file (`~/.send-telegram/config`)
- `--set-bot-token` / `--set-chat-id` for saving credentials
- `--list-jobs` / `--cancel` for job management
- `--setup` interactive installation guide
- `-i` / `--interactive` for terminal input mode
- Log rotation (512 KB limit, one backup)
- Retry logic — failed jobs retried up to 3 times before discarding
- `yyyyMMddHHmm` past-time sends immediately
