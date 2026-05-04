import asyncio
import json
import logging
import logging.handlers
import os
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

from telegram import (
    BotCommand,
    BotCommandScopeAllGroupChats,
    BotCommandScopeDefault,
    InlineKeyboardButton,
    InlineKeyboardMarkup,
    Update,
)
from telegram.ext import Application, CallbackQueryHandler, CommandHandler, ContextTypes

VERSION = "202605041200"

CONFIG_PATH = Path.home() / ".claude-session-bot" / "config.json"
CLAUDE_PROJECTS_DIR = Path.home() / ".claude" / "projects"
BOT_SCRIPT = Path.home() / ".claude-session-bot" / "bot.py"
PLIST_FILE = Path.home() / "Library" / "LaunchAgents" / "com.user.claude-session-bot.plist"
REPO_RAW = "https://raw.githubusercontent.com/delmitz/util-scripts/main/claude-session-bot"
URL_PATTERN = re.compile(r"https://claude\.ai/code/session_[A-Za-z0-9]+")
ANSI_ESCAPE = re.compile(
    r"\x1b(?:"
    r"\[[0-?]*[ -/]*[@-~]"       # CSI sequences  e.g. \x1b[1m
    r"|\][^\x07\x1b]*(?:\x07|\x1b\\)"  # OSC sequences  e.g. \x1b]0;title\x07
    r"|[ -~]"                    # any other 2-byte sequence e.g. \x1b7 \x1b8
    r")"
)
URL_TIMEOUT = 30

config: dict = {}
sessions: dict = {}  # alias -> {"proc": Popen, "master_fd": int, "url": str}
_bot_loop: asyncio.AbstractEventLoop | None = None
_bot_app: Application | None = None

logger = logging.getLogger(__name__)


def setup_logging() -> None:
    log_dir = Path.home() / ".claude-session-bot"
    log_dir.mkdir(exist_ok=True)
    handler = logging.handlers.RotatingFileHandler(
        log_dir / "bot.log", maxBytes=5 * 1024 * 1024, backupCount=3
    )
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    root = logging.getLogger()
    root.addHandler(handler)
    root.addHandler(logging.StreamHandler())
    root.setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("telegram").setLevel(logging.WARNING)


def load_config() -> None:
    global config
    with open(CONFIG_PATH) as f:
        config = json.load(f)


def get_projects() -> list[str]:
    root = Path(config["projects_root"])
    return sorted(
        d.name for d in root.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )


def find_latest_session_uuid(alias: str) -> str | None:
    project_path = Path(config["projects_root"]) / alias
    encoded = str(project_path).replace("/", "-")
    sessions_dir = CLAUDE_PROJECTS_DIR / encoded
    if not sessions_dir.exists():
        return None
    files = list(sessions_dir.glob("*.jsonl"))
    if not files:
        return None
    return max(files, key=lambda f: f.stat().st_mtime).stem


def is_authorized(update: Update) -> bool:
    return update.effective_chat.id == config["allowed_chat_id"]


def kill_session(alias: str) -> None:
    if alias not in sessions:
        return
    proc = sessions.pop(alias)["proc"]
    try:
        proc.terminate()
    except Exception:
        pass


def _capture_url(master_fd: int) -> str | None:
    buffer = b""
    deadline = time.monotonic() + URL_TIMEOUT
    while time.monotonic() < deadline:
        remaining = deadline - time.monotonic()
        try:
            r, _, _ = select.select([master_fd], [], [], min(remaining, 1.0))
        except (ValueError, OSError):
            break
        if r:
            try:
                chunk = os.read(master_fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buffer += chunk
            text = ANSI_ESCAPE.sub("", buffer.decode("utf-8", errors="replace"))
            m = URL_PATTERN.search(text)
            if m:
                return m.group(0)
    logger.warning("_capture_url failed. raw_tail=%r", buffer[-2000:])
    return None


def _monitor(alias: str, proc: subprocess.Popen, master_fd: int) -> None:
    while proc.poll() is None:
        try:
            r, _, _ = select.select([master_fd], [], [], 1.0)
            if r:
                os.read(master_fd, 4096)
        except OSError:
            break

    proc.wait()
    try:
        os.close(master_fd)
    except OSError:
        pass

    if alias in sessions and sessions[alias]["proc"] is proc:
        sessions.pop(alias, None)
        logger.info("Session [%s] terminated unexpectedly", alias)
        if _bot_loop and _bot_app:
            asyncio.run_coroutine_threadsafe(
                _bot_app.bot.send_message(
                    chat_id=config["allowed_chat_id"],
                    text=f"[{alias}] 세션이 예기치 않게 종료되었습니다.",
                ),
                _bot_loop,
            )


async def launch_session(alias: str, resume: bool) -> tuple[str | None, str | None]:
    project_path = Path(config["projects_root"]) / alias

    claude_bin = config.get("claude_bin") or shutil.which("claude")
    if not claude_bin:
        return None, "claude 바이너리를 찾을 수 없습니다. PATH를 확인해주세요."

    if not project_path.is_dir():
        return None, f"디렉토리가 존재하지 않습니다: {project_path}"

    cmd = [claude_bin, "--remote-control"]
    if resume:
        uuid = find_latest_session_uuid(alias)
        if not uuid:
            return None, f"[{alias}]의 이전 세션을 찾을 수 없습니다."
        cmd += ["--resume", uuid]

    if alias in sessions:
        kill_session(alias)
        await asyncio.sleep(1)

    master_fd, slave_fd = pty.openpty()
    try:
        proc = subprocess.Popen(
            cmd,
            cwd=str(project_path),
            stdin=slave_fd,
            stdout=slave_fd,
            stderr=slave_fd,
        )
    finally:
        os.close(slave_fd)

    url = await asyncio.to_thread(_capture_url, master_fd)

    if url is None:
        try:
            proc.terminate()
            proc.wait(timeout=3)
        except Exception:
            proc.kill()
        try:
            os.close(master_fd)
        except OSError:
            pass
        return None, f"[{alias}] 세션 URL을 가져오지 못했습니다 (타임아웃)."

    sessions[alias] = {"proc": proc, "master_fd": master_fd, "url": url}
    threading.Thread(target=_monitor, args=(alias, proc, master_fd), daemon=True).start()
    logger.info("Session [%s] started: %s", alias, url)
    return url, None


def _start_keyboard(projects: list[str]) -> InlineKeyboardMarkup:
    rows = [
        [InlineKeyboardButton(projects[i], callback_data=f"pick:{projects[i]}")]
        + ([InlineKeyboardButton(projects[i + 1], callback_data=f"pick:{projects[i + 1]}")] if i + 1 < len(projects) else [])
        for i in range(0, len(projects), 2)
    ]
    rows.append([InlineKeyboardButton("✕", callback_data="dismiss")])
    return InlineKeyboardMarkup(rows)


def _action_keyboard(alias: str) -> InlineKeyboardMarkup:
    return InlineKeyboardMarkup([
        [
            InlineKeyboardButton("🆕 New session", callback_data=f"start:{alias}"),
            InlineKeyboardButton("↩️ Resume", callback_data=f"resume:{alias}"),
        ],
        [InlineKeyboardButton("← Back", callback_data="back"), InlineKeyboardButton("✕", callback_data="dismiss")],
    ])


def _stop_keyboard(aliases: list[str]) -> InlineKeyboardMarkup:
    rows = [[InlineKeyboardButton(a, callback_data=f"stop:{a}")] for a in aliases]
    return InlineKeyboardMarkup(rows)


async def cmd_ping(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return
    await update.effective_chat.send_message("pong")


async def cmd_list(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return
    projects = get_projects()
    if not projects:
        await update.effective_chat.send_message("프로젝트가 없습니다.")
        return
    await update.effective_chat.send_message(
        "사용 가능한 프로젝트:\n" + "\n".join(f"• {p}" for p in projects)
    )


async def cmd_start(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return
    projects = get_projects()
    if not projects:
        await update.effective_chat.send_message("프로젝트가 없습니다.")
        return
    await update.effective_chat.send_message(
        "프로젝트를 선택하세요:",
        reply_markup=_start_keyboard(projects),
    )


async def cmd_stop(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return
    running = list(sessions.keys())
    if len(running) == 0:
        await update.effective_chat.send_message("실행 중인 세션이 없습니다.")
    elif len(running) == 1:
        alias = running[0]
        kill_session(alias)
        await update.effective_chat.send_message(f"[{alias}] 세션을 종료했습니다.")
    else:
        await update.effective_chat.send_message(
            "종료할 세션을 선택하세요:",
            reply_markup=_stop_keyboard(running),
        )


async def cmd_create(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return

    args = context.args or []
    if not args:
        await update.effective_chat.send_message("사용법: /create <프로젝트명>")
        return

    name = args[0]
    if not re.match(r'^[a-zA-Z0-9][a-zA-Z0-9_\-\.]*$', name):
        await update.effective_chat.send_message(
            "프로젝트명은 영문자/숫자로 시작하고 영문자, 숫자, -, _, . 만 사용할 수 있습니다."
        )
        return

    project_path = Path(config["projects_root"]) / name
    if project_path.exists():
        await update.effective_chat.send_message(f"이미 존재하는 프로젝트입니다: {name}")
        return

    project_path.mkdir()
    logger.info("Project created: %s", project_path)

    keyboard = InlineKeyboardMarkup([[
        InlineKeyboardButton("🆕 세션 시작", callback_data=f"start:{name}"),
        InlineKeyboardButton("닫기", callback_data="dismiss"),
    ]])
    await update.effective_chat.send_message(
        f"프로젝트 생성 완료: {name}",
        reply_markup=keyboard,
    )


async def cmd_reset(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return

    own_pid = os.getpid()

    managed = list(sessions.keys())
    for alias in managed:
        info = sessions.pop(alias, None)
        if info:
            try:
                info["proc"].kill()
            except Exception:
                pass

    extra_pids = []
    try:
        result = subprocess.run(["pgrep", "-f", "claude"], capture_output=True, text=True)
        for token in result.stdout.split():
            try:
                pid = int(token)
                if pid != own_pid:
                    extra_pids.append(pid)
            except ValueError:
                pass
        for pid in extra_pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    except Exception as e:
        await update.effective_chat.send_message(f"Error during kill: {e}")
        return

    lines = []
    if managed:
        lines.append(f"Managed sessions killed: {', '.join(managed)}")
    if extra_pids:
        lines.append(f"Extra processes killed: {len(extra_pids)} (PID: {', '.join(map(str, extra_pids))})")
    if not lines:
        lines.append("No Claude processes found.")

    await update.effective_chat.send_message("\n".join(lines))


async def cmd_update(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return

    await update.effective_chat.send_message("Downloading latest bot.py...")

    result = subprocess.run(
        ["curl", "-fsSL", f"{REPO_RAW}/bot.py", "-o", str(BOT_SCRIPT)],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        await update.effective_chat.send_message(f"Download failed:\n{result.stderr.strip()}")
        return

    await update.effective_chat.send_message("Update complete. Restarting service...")

    subprocess.Popen(
        ["bash", "-c", f"sleep 1 && launchctl unload '{PLIST_FILE}' 2>/dev/null; launchctl load '{PLIST_FILE}'"],
        start_new_session=True,
    )


async def cmd_status(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    if not is_authorized(update):
        return
    lines = [f"ver.{VERSION}"]
    if sessions:
        lines += [f"• {alias}: {info['url']}" for alias, info in sessions.items()]
    else:
        lines.append("실행 중인 세션이 없습니다.")
    await update.effective_chat.send_message("\n".join(lines))


async def on_callback(update: Update, context: ContextTypes.DEFAULT_TYPE) -> None:
    query = update.callback_query
    await query.answer()

    if not is_authorized(update):
        return

    if query.data == "back":
        projects = get_projects()
        await query.edit_message_text("프로젝트를 선택하세요:", reply_markup=_start_keyboard(projects))
        return

    if query.data == "dismiss":
        await query.edit_message_reply_markup(reply_markup=None)
        return

    if ":" not in query.data:
        return

    action, alias = query.data.split(":", 1)

    if action == "pick":
        await query.edit_message_text(f"{alias}", reply_markup=_action_keyboard(alias))
        return

    if action in ("start", "resume"):
        resume = action == "resume"
        action_text = "재개" if resume else "시작"
        await query.edit_message_text(f"[{alias}] 세션을 {action_text}합니다...")
        url, error = await launch_session(alias, resume)
        if error:
            await query.edit_message_text(f"오류: {error}")
        else:
            await query.edit_message_text(url)

    elif action == "stop":
        if alias not in sessions:
            await query.edit_message_text(f"[{alias}] 실행 중인 세션이 없습니다.")
            return
        kill_session(alias)
        await query.edit_message_text(f"[{alias}] 세션을 종료했습니다.")

    elif action == "dismiss":
        await query.edit_message_reply_markup(reply_markup=None)


_network_error_count = 0


async def on_error(update: object, context: ContextTypes.DEFAULT_TYPE) -> None:
    global _network_error_count
    from telegram.error import NetworkError, TimedOut
    if isinstance(context.error, (NetworkError, TimedOut)):
        _network_error_count += 1
        logger.warning("Network error #%d: %s", _network_error_count, context.error)
        if _network_error_count >= 5:
            logger.error("Too many consecutive network errors — restarting process")
            sys.exit(1)
    else:
        _network_error_count = 0
        logger.error("Unhandled exception", exc_info=context.error)


async def post_shutdown(app: Application) -> None:
    for alias in list(sessions.keys()):
        kill_session(alias)
    logger.info("All sessions terminated")


async def post_init(app: Application) -> None:
    global _bot_loop, _bot_app
    _bot_loop = asyncio.get_running_loop()
    _bot_app = app
    commands = [
        BotCommand("ping", "Check if the bot is alive"),
        BotCommand("list", "Show available projects"),
        BotCommand("start", "Start a Claude session"),
        BotCommand("stop", "Stop a running session"),
        BotCommand("status", "Show running sessions"),
        BotCommand("create", "Create a new project directory"),
        BotCommand("reset", "Force-kill all Claude Code processes"),
        BotCommand("updatebot", "Update bot to latest version and restart"),
    ]
    await app.bot.set_my_commands(commands, scope=BotCommandScopeDefault())
    await app.bot.set_my_commands(commands, scope=BotCommandScopeAllGroupChats())
    await app.bot.send_message(chat_id=config["allowed_chat_id"], text=f"Bot started. ver.{VERSION}")
    logger.info("Bot initialized")


def main() -> None:
    setup_logging()
    load_config()

    if not Path(config["projects_root"]).is_dir():
        logger.error("projects_root does not exist: %s", config["projects_root"])
        raise SystemExit(1)

    app = (
        Application.builder()
        .token(config["bot_token"])
        .connect_timeout(10.0)
        .read_timeout(30.0)
        .write_timeout(10.0)
        .post_init(post_init)
        .post_shutdown(post_shutdown)
        .build()
    )
    app.add_handler(CommandHandler("ping", cmd_ping))
    app.add_handler(CommandHandler("list", cmd_list))
    app.add_handler(CommandHandler("start", cmd_start))
    app.add_handler(CommandHandler("stop", cmd_stop))
    app.add_handler(CommandHandler("status", cmd_status))
    app.add_handler(CommandHandler("create", cmd_create))
    app.add_handler(CommandHandler("reset", cmd_reset))
    app.add_handler(CommandHandler("updatebot", cmd_update))
    app.add_handler(CallbackQueryHandler(on_callback))
    app.add_error_handler(on_error)

    logger.info("Starting bot...")
    app.run_polling(drop_pending_updates=True)


if __name__ == "__main__":
    main()
