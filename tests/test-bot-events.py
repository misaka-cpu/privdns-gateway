#!/usr/bin/env python3
"""bot 这一侧的机读事件(docs/events.md): 记什么、不记什么、与 pdg.sh 的 _pdg_event 是同一种格式。

要回答四件事:
  · 格式: pdg_event 与 pdg.sh 的 _pdg_event 对同一组输入打出**逐字相同**的一行(两边各自实现, 不能各漂各的);
  · 不泄露: 按钮只记 callback_data 第一个 ':' 之前、且是小写词形的那段; 文字只记是不是 /命令;
    文件不记文件名; 用户 id / chat id 一律不进事件;
  · 不添乱: syslog 出错时 pdg_event 不抛异常(打日志失败不改变任何操作);
  · 接线: 主循环里只有**放行用户**的更新才记, 且记在处理之前(处理里抛异常也已经留下了这一行)。

syslog 换成记录器, 不写本机 journal; 不连 Telegram、不读真 token。
"""
import importlib.util as u
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
import sys as _pdg_sys; _pdg_sys.path.insert(0, str(ROOT) + "/tests")  # noqa: E702
import pdg_source  # noqa: E402  共享 pdg.sh 源码入口(建议 4 第 0 步; 拆分后给出拼回的整份)
sys.path.insert(0, str(ROOT / "tests"))
import tmpguard          # noqa: E402
PASS, FAIL = [0], [0]


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL[0] += 1
    print("[FAIL] %s" % m)


def check(cond, m):
    (ok if cond else bad)(m)


ROOTFS = tmpguard.mkdtemp(prefix="pdg-bot-events.")
os.makedirs(os.path.join(ROOTFS, "etc", "privdns-gateway"), exist_ok=True)
os.makedirs(os.path.join(ROOTFS, "run"), exist_ok=True)
PROFILE = os.path.join(ROOTFS, "etc", "privdns-gateway", "profile.env")
with open(PROFILE, "w", encoding="utf-8") as _f:
    _f.write("PDG_INTERNAL_CIDR=127.0.0.0/8\nPDG_SERVER_IP=127.0.0.1\n")
os.environ["PDG_PROFILE_ENV"] = PROFILE
os.environ["PDG_TX_FSROOT"] = ROOTFS
os.environ["PDG_LOCKFILE"] = os.path.join(ROOTFS, "run", "privdns-gateway.lock")
os.environ.setdefault("PDG_BOT_ALLOWED", "1")
sys.path.insert(0, str(ROOT / "deploy/bot"))
spec = u.spec_from_file_location("pdg_bot", str(ROOT / "deploy/bot/pdg-bot.py"))
bot = u.module_from_spec(spec)
spec.loader.exec_module(bot)
SRC = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
PDG = pdg_source.path(ROOT)

LOG = []          # (ident, priority, message)
_ident = [None]


def _openlog(ident, *a, **k):
    _ident[0] = ident


def _syslog(pri, msg=None):
    if msg is None:
        pri, msg = None, pri
    LOG.append((_ident[0], pri, msg))


bot.syslog.openlog = _openlog
bot.syslog.syslog = _syslog


def lines():
    out = [m for _, _, m in LOG]
    LOG.clear()
    return out


print("══ 1. 格式与 pdg.sh 的 _pdg_event 逐字相同 ══")
LONG = "换" * 230
CASES = [
    ("kernel.switch", [("result", "ok"), ("via", "cli"), ("from", "v1.19.33"), ("to", "v1.19.34")]),
    ("x.y", [("a", "x y"), ("b", "p\tq\nr"), ("c", ""), ("Bad", "1"), ("d", "\x1b[1;32mok\x1b[0m"),
             ("e", LONG), ("f", "全角　空格"), ("g", "a=b=c")]),
    ("Bad Name", [("a", "1")]),
]
body = re.search(r"^_pdg_event\(\)\{\n.*?^\}\n", PDG.read_text(encoding="utf-8"), re.S | re.M)
check(body is not None, "从 pdg.sh 抽得到 _pdg_event")
if body:
    harness = body.group(0) + (
        'logger(){ local t="" p=""; while [[ $# -gt 0 ]]; do case "$1" in -t) t="$2"; shift;; -p) p="$2"; shift;;'
        ' --) shift; break;; esac; shift; done; printf "[%s|%s] %s\\n" "$t" "$p" "$*" >&3; }\n'
        '_pdg_event "$@" 3>&1\n')   # 生产代码把 logger 的 stdout/stderr 都丢了, 桩走 fd 3 出来
    for name, kv in CASES:
        r = subprocess.run(["bash", "-c", harness, "_", name] + ["%s=%s" % p for p in kv],
                           capture_output=True, text=True, env=dict(os.environ, LC_ALL="C"))
        sh_line = r.stdout.rstrip("\n")
        bot.pdg_event(name, **dict(kv))
        got = lines()
        py_line = got[0] if got else ""
        check(r.returncode == 0 and sh_line.startswith("[pdg-event|user.info] "),
              "%s: shell 一侧打的是 logger -t pdg-event -p user.info" % name)
        same = sh_line[len("[pdg-event|user.info] "):] == py_line
        check(same, "%s: 两边逐字相同" % name
              + ("" if same else "\n         sh=%s\n         py=%s" % (sh_line[:160], py_line[:160])))
check(LOG == [] and _ident[0] == "pdg-event", "python 一侧的标识是 pdg-event")
bot.pdg_event("x.y", e=LONG)
ln = lines()[0]
check(ln.endswith("…") and len(ln.split("e=", 1)[1]) == 201, "超长值截到 200 个字符再加 …")

print()
print("══ 2. 按钮: 只记动作名 ══")


def cb(data, uid=424242, chat=939393):
    return {"update_id": 1, "callback_query": {"id": "q", "data": data, "from": {"id": uid},
                                               "message": {"chat": {"id": chat}, "message_id": 7}}}


for data, want in [("krn_up_ok", "krn_up_ok"), ("plat_ios_ok", "plat_ios_ok"), ("nav:ops", "nav"),
                   ("dosetdot:dot.example.test", "dosetdot"), ("adblock:srcdel:3", "adblock"),
                   ("Weird:x", "other"), ("a" * 41, "other"), ("", "other"), ("ero:1:dot.example.test", "ero")]:
    bot.bot_update_event(cb(data))
    got = lines()
    check(got == ["event=bot.callback action=%s" % want], "callback %-28r → action=%s" % (data[:28], want))
bot.bot_update_event(cb("dtog:secret.example.test", uid=5551234, chat=7776665))
got = " ".join(lines())
check("secret.example.test" not in got and "5551234" not in got and "7776665" not in got,
      "后半段的域名、用户 id、chat id 都不进事件")

print()
print("══ 3. 文字与文件: 不记内容 ══")


def msg(**m):
    base = {"from": {"id": 424242}, "chat": {"id": 939393}, "message_id": 9}
    base.update(m)
    return {"update_id": 2, "message": base}


bot.bot_update_event(msg(text="/start"))
check(lines() == ["event=bot.text kind=command name=start"], "/start → kind=command name=start")
bot.bot_update_event(msg(text="/cancel@SomeBot extra words"))
check(lines() == ["event=bot.text kind=command name=cancel"], "/cancel@bot 带参数 → 只记命令名")
for t in ["123456789:AAH-not-a-real-token", "hunter2", "/Upper", "//x", "/ start", ""]:
    bot.bot_update_event(msg(text=t))
    got = lines()
    check(got == ["event=bot.text kind=input"] and (not t or t not in got[0]),
          "文字 %-30r → kind=input, 正文不进事件" % t)
bot.bot_update_event(msg(document={"file_name": "my-private-config.yaml", "file_id": "F1"}))
got = lines()
check(got == ["event=bot.document"], "文件 → bot.document, 不记文件名")
bot.bot_update_event({"update_id": 3, "edited_message": {"text": "x"}})
check(lines() == [], "不认识的更新类型 → 不记")

print()
print("══ 4. syslog 出错不外溢 ══")


def _boom(*a, **k):
    raise OSError("no /dev/log")


bot.syslog.syslog = _boom
try:
    bot.pdg_event("x.y", a=1)
    bot.bot_update_event(cb("krn"))
    ok("syslog 抛异常 → pdg_event / bot_update_event 都不抛")
except Exception as e:  # noqa: BLE001
    bad("syslog 出错外溢了: %r" % e)
bot.syslog.syslog = _syslog
for weird in [{"callback_query": "不是 dict"}, {"message": ["不是", "dict"]}, {"callback_query": {"data": 123}}]:
    try:
        bot.bot_update_event(weird)
    except Exception as e:  # noqa: BLE001
        bad("形状不对的更新让 bot_update_event 抛了 %r —— 主循环里它排在处理之前, 会挡住这次操作" % e)
        break
else:
    ok("形状不对的更新(callback_query / message 不是 dict)→ bot_update_event 不抛")
lines()

print()
print("══ 5. 主循环接线: 放行之后、处理之前 ══")
main = SRC.split("\ndef main(", 1)[1] if "\ndef main(" in SRC else ""
check(main.count("bot_update_event(u)") == 2, "主循环里恰好两处 bot_update_event(u)(消息一处、按钮一处)")
i_deny = main.find('if m["from"]["id"] not in ALLOWED:')
i_ev1 = main.find("bot_update_event(u)")
i_txt = main.find("handle_text(")
i_allow = main.find('if q["from"]["id"] in ALLOWED:')
i_ev2 = main.find("bot_update_event(u)", i_ev1 + 1)
i_cb = main.find("handle_cb(", i_allow)
check(0 <= i_deny < i_ev1 < i_txt, "消息: 先过 ALLOWED, 再记事件, 再 handle_text")
check(0 <= i_allow < i_ev2 < i_cb, "按钮: 先过 ALLOWED, 再记事件, 再 handle_cb")
check(SRC.count("bot_update_event(") == 3, "除定义外只在主循环里调用(没有别处顺手记)")

print("-" * 62)
print("test-bot-events.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
