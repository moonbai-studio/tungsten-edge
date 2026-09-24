#!/usr/bin/env python3
"""Helper behind the 「Tungsten Edge 开会话」launcher applet (see launcher.applescript / install.sh).

`parse <url>`  validates a tungsten-cc://open link from the board, stashes the opener text
               and target directory, prints "line / alias / directory label" (the applet launches
               that alias straight away — no model picker since 2026-09-25).
`launch <alias>` opens one Ghostty window in the stashed directory running that shell alias,
               with the opener pre-typed (bracketed paste, so Claude Code keeps it in the box).
"""
import json
import os
import subprocess
import sys
import tempfile
from urllib.parse import parse_qs, urlsplit

APP_DIR = "__APP_DIR__"
WEB_DIR = "__WEB_DIR__"
DIRS = {"app": ("钨极本体", APP_DIR), "web": ("官网", WEB_DIR)}
ALIASES = ("cf", "co", "cv")
STATE = os.path.join(tempfile.gettempdir(), "tungsten-cc")
PENDING = os.path.join(STATE, "pending.json")
OPENER = os.path.join(STATE, "opener.txt")


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def parse(url):
    u = urlsplit(url)
    if u.scheme != "tungsten-cc" or u.netloc != "open":
        fail("不是 tungsten-cc://open 链接")
    q = parse_qs(u.query, keep_blank_values=True)
    get = lambda k: (q.get(k) or [""])[0]
    line, alias, dirkey, text = get("line"), get("model") or "cf", get("dir") or "app", get("text")
    if alias not in ALIASES:
        fail("model 只能是 cf / co / cv")
    if dirkey not in DIRS:
        fail("dir 只能是 app / web")
    if not line or len(line) > 40:
        fail("缺 line")
    if not text.startswith("接着做「" + line + "」"):
        fail("开场白不是看板的格式")
    if len(text) > 20000:
        fail("开场白太长")
    label, path = DIRS[dirkey]
    if not os.path.isdir(path):
        fail("目录不存在：" + path)
    os.makedirs(STATE, exist_ok=True)
    with open(OPENER, "w", encoding="utf-8") as f:
        f.write("\x1b[200~" + text + "\x1b[201~")
    with open(PENDING, "w", encoding="utf-8") as f:
        json.dump({"line": line, "dir": path}, f)
    print(line)
    print(alias)
    print(label)


def launch(alias):
    if alias not in ALIASES:
        fail("model 只能是 cf / co / cv")
    try:
        with open(PENDING, encoding="utf-8") as f:
            pending = json.load(f)
        os.remove(PENDING)
    except OSError:
        fail("没有待开的会话（先从看板点按钮）")
    # Drop any CLAUDE_* variables inherited from whoever sent the link (a Claude Code session
    # testing the launcher, say), or the new session thinks it is a child session and stops
    # saving its transcript.
    env = {k: v for k, v in os.environ.items() if not k.startswith("CLAUDE")}
    subprocess.run(
        ["/usr/bin/open", "-na", "Ghostty.app", "--args",
         "--working-directory=" + pending["dir"], "--input=path:" + OPENER,
         "--quit-after-last-window-closed=true",
         "-e", "zsh", "-ic", alias],
        check=True, env=env,
    )


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "parse":
        parse(sys.argv[2])
    elif len(sys.argv) == 3 and sys.argv[1] == "launch":
        launch(sys.argv[2])
    else:
        fail("用法：open-session.py parse <url> | launch <alias>")
