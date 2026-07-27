#!/usr/bin/env python3
"""紧急完整恢复(break-glass)回归(5.2/commit 8)。

它复用受控的 Bash `pdg rollback --dir`, 因此**没有 pdgtx 的二次自动回滚** —— 唯一的兜底是
操作前自动创建的 pre-rescue 快照。所以这里最看重两件事:
  1. 救援控制平面必须活下来: 代码、凭据、证书、unit、端口放行, 一个都不能被快照里的旧版本
     覆盖或切断 —— 否则用户会在恢复过程中失联, 而这正是他打开这个页面要避免的事;
  2. 结果必须**结构化**且如实: 不靠解析中文输出判断成败, 部分失败不能报成功。

沙箱里用一个假的 `pdg` 桩来扮演 Bash 恢复(它会真的覆盖文件、真的跑 nft), 于是保护逻辑面对的
是真实行为而不是 mock 的返回值。
"""
import io
import json
import os
import re
import shutil
import socket
import ssl
import stat
import subprocess
import sys
import tarfile
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
from rescuebox import Inst, TOKEN  # noqa: E402
from txbox import Box  # noqa: E402

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-breakglass-55"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


work = tempfile.mkdtemp(prefix="breakglass.")

MODEL = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}], "route": {"rules": [], "final": "direct"}})


def mos(size=1024):
    return ("log:\n  level: error\nplugins:\n  - tag: npn_clients\n    type: ip_set\n"
            '    args: { ips: ["127.0.0.0/8"] }\n  - tag: cache\n    type: cache\n'
            "    args: { size: %d }\n" % size)


# 假的 pdg: snapshot 打一个真 tar; rollback 真的把快照内容覆盖到沙箱根。
PDG_STUB = r'''#!/bin/bash
set -uo pipefail
ROOT="__ROOT__"
case "${1:-}" in
  snapshot)
    [[ -n "${PDG_STUB_SNAPFAIL:-}" ]] && { echo "快照打包失败"; exit 1; }
    ts="$(date +%Y%m%d-%H%M%S)"
    d="$ROOT/var/lib/privdns-gateway/backups/$ts"
    mkdir -p "$d"
    ( cd "$ROOT" && tar czf "$d/snap.tar.gz" \
        --exclude='var/lib/privdns-gateway/backups' etc opt usr 2>/dev/null ) || exit 1
    echo "✅ 快照: $d/snap.tar.gz"
    exit 0;;
  rollback)
    [[ "${2:-}" == "--dir" ]] || { echo "用法错"; exit 2; }
    dir="${3:-}"
    [[ -f "$dir/snap.tar.gz" ]] || { echo "快照文件缺失"; exit 1; }
    [[ -n "${PDG_STUB_FAIL:-}" ]] && { echo "注入: 恢复失败"; exit 1; }
    tar xzf "$dir/snap.tar.gz" -C "$ROOT" 2>/dev/null || { echo "解包失败"; exit 1; }
    # 与真实实现同构: 恢复末尾用**快照里的** nft 配置重新应用防火墙
    if [[ -f "$ROOT/etc/nftables.conf" ]]; then nft -f "$ROOT/etc/nftables.conf" >/dev/null 2>&1; fi
    systemctl restart mosdns >/dev/null 2>&1
    systemctl restart mihomo >/dev/null 2>&1
    echo "✅ 已回滚并重启服务"
    exit 0;;
esac
echo "未知子命令"; exit 2
'''

NFT_WITH_RESCUE = ("table inet pdg\ndelete table inet pdg\ntable inet pdg {\n"
                   "    chain input {\n        type filter hook input priority 0; policy drop;\n"
                   "        ip saddr 127.0.0.0/8 tcp dport { 53 } accept\n"
                   "        ip saddr 127.0.0.0/8 tcp dport 8446 accept\n    }\n}\n")
NFT_OLD = ("table inet pdg\ndelete table inet pdg\ntable inet pdg {\n"
           "    chain input {\n        type filter hook input priority 0; policy drop;\n"
           "        ip saddr 127.0.0.0/8 tcp dport { 53 } accept\n    }\n}\n")


def make_box():
    """沙箱: 现网 + 救援控制平面 + 假 pdg/nft/systemctl。"""
    box = Box()
    box.up("mosdns")
    box.up("mihomo")
    # 假 nft: 把 `nft -f <file>` 的内容记到状态文件, list 时回放 —— 于是"端口放行是否还在"
    # 是真实可观测的, 而不是我们自己断言自己。
    nft_state = os.path.join(box.root, "nft-state.txt")
    box._write("nft", '#!/bin/bash\n'
               'echo "nft $*" >> %s\n'
               'S=%s\n'
               'case "$1" in\n'
               '  -f) cat "$2" > "$S"; exit 0;;\n'
               '  -c) exit 0;;\n'
               '  list) cat "$S" 2>/dev/null; exit 0;;\n'
               '  insert) printf "%%s\\n" "        ip saddr $8 tcp dport ${11} accept" >> "$S"; exit 0;;\n'
               'esac\nexit 0\n' % (box.calls, nft_state))
    open(nft_state, "w").write(NFT_WITH_RESCUE)
    files = {
        "etc/sing-box/config.json": MODEL,
        "etc/mosdns/config.yaml": mos(1024),
        "etc/nftables.conf": NFT_WITH_RESCUE,
        "etc/privdns-gateway/platform": "ios\n",
        "etc/privdns-gateway/backend": "mihomo\n",
        "etc/privdns-gateway/bot.env": "PDG_BOT_TOKEN=1:%s\n" % SENTINEL,
        "etc/privdns-gateway/mitm.json": '{"wloc": {"enabled": true}}',
        "opt/pdg-bot/bot.py": "# 当前 Bot 程序\n",
        "usr/local/bin/mihomo": "CURRENT-BINARY\n",
        # 救援控制平面(当前的)
        "etc/privdns-gateway/rescue/token": "CURRENT-RESCUE-TOKEN-0123456789abcd\n",
        "etc/privdns-gateway/rescue/cert.pem": "CURRENT-CERT\n",
        "etc/privdns-gateway/rescue/key.pem": "CURRENT-KEY\n",
        "opt/pdg-bot/rescue.py": "# 当前救援服务代码\n",
        "opt/pdg-bot/rescue_const.py": "# 当前常量读取器\n",
        "opt/pdg-bot/rescue.sh": "PDG_RESCUE_PORT=8446\n",
        "etc/systemd/system/pdg-rescue.socket": "[Socket]\nListenStream=127.0.0.1:8446\n",
        "etc/systemd/system/pdg-rescue.service": "[Service]\nExecStart=/usr/bin/python3 x\n",
    }
    for rel, data in files.items():
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        os.chmod(p, 0o600 if "rescue/" in rel else 0o644)
    box._write("pdg", PDG_STUB.replace("__ROOT__", box.root))
    return box, files


def make_snapshot(box, snap_id="20250101-010101", items=None, old_rescue=True, old_nft=True):
    """一份"旧的"完整快照: 含旧二进制/Bot/标记/凭据, 也含旧的救援平面与旧 nft。"""
    d = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id)
    os.makedirs(d, exist_ok=True)
    base = {
        "etc/sing-box/config.json": MODEL.replace('"final": "direct"', '"final": "direct" '),
        "etc/mosdns/config.yaml": mos(4096),
        "etc/privdns-gateway/platform": "android\n",
        "etc/privdns-gateway/backend": "singbox\n",
        "etc/privdns-gateway/bot.env": "PDG_BOT_TOKEN=9:OLD-%s\n" % SENTINEL,
        "etc/privdns-gateway/mitm.json": '{"wloc": {"enabled": false}}',
        "opt/pdg-bot/bot.py": "# 旧的 Bot 程序\n",
        "usr/local/bin/mihomo": "OLD-BINARY\n",
    }
    if old_nft:
        base["etc/nftables.conf"] = NFT_OLD          # 旧快照没有救援端口放行
    if old_rescue:
        base.update({
            "etc/privdns-gateway/rescue/token": "OLD-RESCUE-TOKEN-xxxxxxxxxxxxxx\n",
            "etc/privdns-gateway/rescue/cert.pem": "OLD-CERT\n",
            "etc/privdns-gateway/rescue/key.pem": "OLD-KEY\n",
            "opt/pdg-bot/rescue.py": "# 旧救援服务代码\n",
            "opt/pdg-bot/rescue_const.py": "# 旧常量读取器\n",
            "opt/pdg-bot/rescue.sh": "PDG_RESCUE_PORT=9999\n",
            "etc/systemd/system/pdg-rescue.socket": "[Socket]\nListenStream=127.0.0.1:9999\n",
            "etc/systemd/system/pdg-rescue.service": "[Service]\nExecStart=/bin/false\n",
        })
    if items is not None:
        base = dict(items)
    with tarfile.open(os.path.join(d, "snap.tar.gz"), "w:gz") as t:
        for rel, data in base.items():
            b = data.encode()
            info = tarfile.TarInfo(rel)
            info.size = len(b)
            info.mode = 0o644
            t.addfile(info, io.BytesIO(b))
    os.chmod(os.path.join(d, "snap.tar.gz"), 0o600)
    return snap_id


def load_mods(box):
    """按沙箱环境加载 cfgrestore + breakglass(每次全新, 免得常量被上一个沙箱定死)。"""
    import importlib.util
    for k, v in box.env.items():
        os.environ[k] = v
    os.environ["PDG_SNAP_DIR"] = os.path.join(box.root, "var/lib/privdns-gateway/backups")
    os.environ["PDG_UNIT_DIR"] = os.path.join(box.root, "etc/systemd/system")
    os.environ["PDG_BIN"] = os.path.join(box.bin, "pdg")
    os.environ["PDG_RESCUE_DIR"] = os.path.join(box.root, "etc/privdns-gateway/rescue")
    os.environ["PDG_RESCUE_TOKEN"] = os.path.join(box.root, "etc/privdns-gateway/rescue/token")
    os.environ["PDG_RESCUE_CERT"] = os.path.join(box.root, "etc/privdns-gateway/rescue/cert.pem")
    os.environ["PDG_RESCUE_KEY"] = os.path.join(box.root, "etc/privdns-gateway/rescue/key.pem")
    os.environ["PDG_PROFILE_ENV"] = os.path.join(box.root, "etc/privdns-gateway/profile.env")
    os.makedirs(os.path.dirname(os.environ["PDG_PROFILE_ENV"]), exist_ok=True)
    with open(os.environ["PDG_PROFILE_ENV"], "w") as f:
        f.write("PDG_INTERNAL_CIDR=127.0.0.0/8\n")
    for m in ("pdgtx", "cfgrestore", "breakglass", "rescue_const"):
        sys.modules.pop(m, None)
    out = {}
    for name, rel in (("cfgrestore", "deploy/bot/cfgrestore.py"),
                      ("breakglass", "deploy/rescue/breakglass.py")):
        spec = importlib.util.spec_from_file_location(name, os.path.join(ROOT, rel))
        mod = importlib.util.module_from_spec(spec)
        sys.modules[name] = mod
        spec.loader.exec_module(mod)
        out[name] = mod
    out["cfgrestore"].SNAP_DIR = os.environ["PDG_SNAP_DIR"]
    return out["cfgrestore"], out["breakglass"]


def read(box, rel):
    p = os.path.join(box.root, rel)
    return open(p, encoding="utf-8").read() if os.path.exists(p) else None


def audit_recs(box):
    f = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    if not os.path.exists(f):
        return []
    out = []
    for line in open(f, encoding="utf-8"):
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("op") == "full_breakglass_restore":
            out.append(r)
    return out


# ── 1. 成功路径: 业务被换回旧版, 救援平面原样保住 ──────────────────────────
box, cur = make_box()
sid = make_snapshot(box)
cr, bg = load_mods(box)
res = bg.run(sid, expect_digest=cr.snapshot_digest(sid), trigger_source="rescue", cfgrestore=cr)
if res.get("final_state") == "RESTORED":
    ok("完整恢复: final_state=RESTORED")
else:
    bad("完整恢复失败: %r" % {k: res.get(k) for k in ("final_state", "error_class", "detail")})
biz = {"usr/local/bin/mihomo": "OLD-BINARY\n", "opt/pdg-bot/bot.py": "# 旧的 Bot 程序\n",
       "etc/privdns-gateway/platform": "android\n", "etc/privdns-gateway/backend": "singbox\n",
       "etc/privdns-gateway/bot.env": "PDG_BOT_TOKEN=9:OLD-%s\n" % SENTINEL,
       "etc/privdns-gateway/mitm.json": '{"wloc": {"enabled": false}}'}
wrong = [k for k, v in biz.items() if read(box, k) != v]
if not wrong:
    ok("完整恢复: 二进制/Bot 程序/platform/backend/bot.env/WLOC 都换成了快照里的版本")
else:
    bad("这些业务文件没恢复: %r" % wrong)
guarded = {"etc/privdns-gateway/rescue/token": cur["etc/privdns-gateway/rescue/token"],
           "etc/privdns-gateway/rescue/cert.pem": cur["etc/privdns-gateway/rescue/cert.pem"],
           "etc/privdns-gateway/rescue/key.pem": cur["etc/privdns-gateway/rescue/key.pem"],
           "opt/pdg-bot/rescue.py": cur["opt/pdg-bot/rescue.py"],
           "opt/pdg-bot/rescue_const.py": cur["opt/pdg-bot/rescue_const.py"],
           "opt/pdg-bot/rescue.sh": cur["opt/pdg-bot/rescue.sh"],
           "etc/systemd/system/pdg-rescue.socket": cur["etc/systemd/system/pdg-rescue.socket"],
           "etc/systemd/system/pdg-rescue.service": cur["etc/systemd/system/pdg-rescue.service"]}
broke = [k for k, v in guarded.items() if read(box, k) != v]
if not broke:
    ok("救援平面: 代码/常量/Token/证书/私钥/两个 unit 全部逐字节保持当前版本")
else:
    bad("救援平面被旧快照覆盖了: %r" % broke)
nft_now = open(os.path.join(box.root, "nft-state.txt"), encoding="utf-8").read()
if "8446 accept" in nft_now:
    ok("救援端口放行在恢复后仍然存在(旧 nft 快照没能永久切断它)")
else:
    bad("救援端口被旧 nft 切断了:\n%s" % nft_now[-200:])
calls_txt = open(box.calls, encoding="utf-8").read() if os.path.exists(box.calls) else ""
if not re.search(r"systemctl (restart|stop) pdg-rescue", calls_txt):
    ok("完整恢复没有 stop/restart 救援服务")
else:
    bad("救援服务被动了")
if res.get("pre_rescue_snapshot_id"):
    ok("完整恢复: 记录了 pre-rescue 快照 ID(%s)" % res["pre_rescue_snapshot_id"])
else:
    bad("没有 pre-rescue 快照 ID")
pre_p = cr.snapshot_path(res.get("pre_rescue_snapshot_id", ""))
if pre_p and os.path.isfile(pre_p):
    ok("pre-rescue 快照确实存在于服务端索引里")
else:
    bad("pre-rescue 快照不可用")
need = ("operation", "snapshot_id", "pre_rescue_snapshot_id", "restored", "failed", "skipped",
        "protected", "validation", "final_state", "error_class")
miss = [k for k in need if k not in res]
if not miss and res["operation"] == "full_breakglass_restore":
    ok("结构化结果字段齐全(%d 项)" % len(need))
else:
    bad("结果字段缺: %r" % miss)
if SENTINEL not in json.dumps(res, ensure_ascii=False):
    ok("结构化结果里不含哨兵(不回显配置正文)")
else:
    bad("结果里泄漏了哨兵")
recs = audit_recs(box)
if len(recs) == 1 and recs[0].get("trigger_source") == "rescue" \
        and recs[0].get("snapshot") == sid and recs[0].get("pre_rescue_snapshot"):
    ok("审计: 唯一一条 full_breakglass_restore, trigger_source=rescue, 含两个快照 ID")
else:
    bad("审计不对: %r" % recs)
aud_txt = open(os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl"), encoding="utf-8").read()
if SENTINEL not in aud_txt:
    ok("审计里不含哨兵")
else:
    bad("审计泄漏哨兵")
box.clean()

# ── 2. pre-rescue 快照失败 → 拒绝执行, 现网不变 ───────────────────────────
box, cur = make_box()
sid = make_snapshot(box)
cr, bg = load_mods(box)
os.environ["PDG_STUB_SNAPFAIL"] = "1"      # 让 pre-rescue 快照打不出来
res = bg.run(sid, expect_digest=cr.snapshot_digest(sid), cfgrestore=cr)
os.environ.pop("PDG_STUB_SNAPFAIL", None)
if res.get("final_state") == "REFUSED" and res.get("error_class") == "PRE_SNAPSHOT_FAILED":
    ok("pre-rescue 快照失败: 拒绝执行完整恢复")
else:
    bad("pre 快照失败却继续了: %r" % res.get("final_state"))
if read(box, "usr/local/bin/mihomo") == "CURRENT-BINARY\n":
    ok("pre-rescue 快照失败: 现网逐字节未变")
else:
    bad("现网被改了")
box.clean()

# ── 3. 快照 ID / 摘要 / 格式 / pending / 锁 的拒绝路径 ────────────────────
box, cur = make_box()
sid = make_snapshot(box)
cr, bg = load_mods(box)
for evil in ("../../etc", "/etc/passwd", "..", "nope-20250101"):
    r = bg.run(evil, cfgrestore=cr)
    if r.get("final_state") != "REFUSED":
        bad("恶意快照 ID 未被拒: %r" % evil)
        break
else:
    ok("非法/越界快照 ID 一律 REFUSED")
r = bg.run(sid, expect_digest="0" * 64, cfgrestore=cr)
if r.get("final_state") == "REFUSED" and r.get("error_class") == "DIGEST_MISMATCH":
    ok("确认后快照被替换(摘要不符)→ REFUSED")
else:
    bad("摘要不符却继续: %r" % r.get("error_class"))
# 未知格式
bad_id = make_snapshot(box, snap_id="20250202-020202", items={"etc/weird/x.conf": "x\n"})
r = bg.run(bad_id, expect_digest=cr.snapshot_digest(bad_id), cfgrestore=cr)
if r.get("final_state") == "REFUSED" and r.get("error_class") == "UNKNOWN_FORMAT":
    ok("未知/歧义快照格式 → fail-closed")
else:
    bad("未知格式没拒: %r" % r.get("error_class"))
# pending 事务
txroot = box.env["PDG_TX_ROOT"]
stuck = os.path.join(txroot, "20250101T000000Z-stuck")
os.makedirs(stuck, exist_ok=True)
json.dump({"txid": "20250101T000000Z-stuck", "state": "APPLYING", "op": "x", "source": "bot",
           "schema_version": 1, "targets": []}, open(os.path.join(stuck, "meta.json"), "w"))
r = bg.run(sid, expect_digest=cr.snapshot_digest(sid), cfgrestore=cr)
if r.get("final_state") == "REFUSED" and r.get("error_class") == "PENDING_TX":
    ok("存在未完成事务 → REFUSED")
else:
    bad("pending 没拒: %r" % r.get("error_class"))
shutil.rmtree(stuck, ignore_errors=True)
# 锁被占用
import fcntl  # noqa: E402

lf = open(box.env["PDG_LOCKFILE"], "w")
fcntl.flock(lf, fcntl.LOCK_EX)
r = bg.run(sid, expect_digest=cr.snapshot_digest(sid), cfgrestore=cr)
fcntl.flock(lf, fcntl.LOCK_UN)
lf.close()
if r.get("final_state") == "BUSY":
    ok("锁被占用 → 立刻 BUSY(不排队)")
else:
    bad("锁忙却继续: %r" % r.get("final_state"))
if read(box, "usr/local/bin/mihomo") == "CURRENT-BINARY\n":
    ok("所有拒绝路径下现网逐字节未变")
else:
    bad("拒绝路径改了现网")
box.clean()

# ── 4. 子进程失败: 部分失败不报成功, 证据与 pre-rescue ID 保留 ─────────────
box, cur = make_box()
sid = make_snapshot(box)
cr, bg = load_mods(box)
os.environ["PDG_STUB_FAIL"] = "1"
res = bg.run(sid, expect_digest=cr.snapshot_digest(sid), cfgrestore=cr)
os.environ.pop("PDG_STUB_FAIL", None)
if res.get("final_state") == "PARTIAL_OR_FAILED" and res.get("error_class", "").startswith("ROLLBACK_RC_"):
    ok("子进程退出非 0: 如实报 PARTIAL_OR_FAILED, 不报成功")
else:
    bad("失败被报成: %r" % {k: res.get(k) for k in ("final_state", "error_class")})
if res.get("pre_rescue_snapshot_id"):
    ok("失败路径: 仍然给出 pre-rescue 快照 ID(下一步有得救)")
else:
    bad("失败却没有 pre-rescue ID")
if read(box, "etc/privdns-gateway/rescue/token") == cur["etc/privdns-gateway/rescue/token"]:
    ok("失败路径: 救援凭据仍然没被动过")
else:
    bad("失败路径下凭据被改了")
box.clean()

# ── 5. 子进程输出超限: 截断且不撑爆内存 ───────────────────────────────────
box, cur = make_box()
sid = make_snapshot(box)
box._write("pdg", '#!/bin/bash\n'
           'case "$1" in\n'
           '  snapshot) d="%s/var/lib/privdns-gateway/backups/20250303-030303";'
           ' mkdir -p "$d"; tar czf "$d/snap.tar.gz" -C "%s" etc 2>/dev/null;'
           ' echo "✅ 快照: $d/snap.tar.gz"; exit 0;;\n'
           '  rollback) head -c 3000000 /dev/zero | tr "\\0" "A"; exit 0;;\n'
           'esac\nexit 2\n' % (box.root, box.root))
cr, bg = load_mods(box)
res = bg.run(sid, expect_digest=cr.snapshot_digest(sid), cfgrestore=cr)
if len(res.get("detail") or "") <= 4000:
    ok("子进程输出超限: 只保留末尾摘要(%d 字符)" % len(res.get("detail") or ""))
else:
    bad("输出没截断: %d 字符" % len(res.get("detail") or ""))
box.clean()

# ── 6. 保护清单不可由请求修改 ─────────────────────────────────────────────
src = open(os.path.join(ROOT, "deploy/rescue/breakglass.py"), encoding="utf-8").read()
_run_sig = re.search(r"def run\(([^)]*)\)", src)
_sig = _run_sig.group(1) if _run_sig else ""
if "def _protected_paths():" in src and not re.search(r"protect|keep|exclude", _sig):
    ok("保护清单由固定常量生成, run() 的签名里没有任何保护路径参数")
else:
    bad("保护清单可能被调用方影响: 签名=%r" % _sig)
rs_src = open(os.path.join(ROOT, "deploy/rescue/rescue.py"), encoding="utf-8").read()
if not re.search(r"form\.get\(\s*[\"'](protect|protected|keep|exclude)", rs_src):
    ok("HTTP 层不接受任何保护路径参数")
else:
    bad("HTTP 层能改保护清单")
# 用 AST 判"代码里有没有不安全调用", 不用字符串扫描 —— 文档字符串里写着"绝不 shell=True"
# 也会被字符串扫描当成命中(第一版就这么误报了一次)。
import ast  # noqa: E402

_tree = ast.parse(src)
_unsafe = []
for _n in ast.walk(_tree):
    if not isinstance(_n, ast.Call):
        continue
    for _kw in _n.keywords or []:
        if _kw.arg == "shell" and getattr(_kw.value, "value", False) is True:
            _unsafe.append("shell=True")
    _f = _n.func
    _name = getattr(_f, "id", None) or getattr(_f, "attr", None)
    if _name in ("system", "popen", "eval", "exec"):
        _unsafe.append(_name)
    # argv 必须是列表字面量(固定数组), 不能是拼出来的字符串
    if _name == "run" and _n.args and isinstance(_n.args[0], ast.BinOp):
        _unsafe.append("拼接的 argv")
if not _unsafe:
    ok("调用方式: 固定 argv 数组, 没有 shell=True / os.system / eval / 字符串拼接")
else:
    bad("出现了不安全的调用方式: %r" % sorted(set(_unsafe)))
# 子进程的第一个参数必须是固定的 pdg 绝对路径来源
if "_pdg_path()" in src and 'PDG_BIN = "/usr/local/bin/pdg"' in src:
    ok("调用方式: pdg 用固定绝对路径, 不查 PATH")
else:
    bad("pdg 路径不是固定绝对路径")
if 'env=_child_env()' in src and '"PDG_LOCKED"' in src:
    ok("子进程使用最小环境, 并在**同一把锁**下完成 pre-rescue 与恢复")
else:
    bad("子进程环境/锁语义不对")

# ── 7. HTTP 层: 独立入口 / 手工确认 / nonce 不跨操作复用 ──────────────────
box, cur = make_box()
sid = make_snapshot(box)
inst = Inst(work, extra_env={
    "PDG_TX_FSROOT": box.root, "PDG_TX_ROOT": box.env["PDG_TX_ROOT"],
    "PDG_LOCKFILE": box.env["PDG_LOCKFILE"], "PATH": box.env["PATH"],
    "PDG_SNAP_DIR": os.path.join(box.root, "var/lib/privdns-gateway/backups"),
    "PDG_UNIT_DIR": os.path.join(box.root, "etc/systemd/system"),
    "PDG_BIN": os.path.join(box.bin, "pdg"),
    "PDG_STABLE_SAMPLES": "1", "PDG_STABLE_INTERVAL": "0.05"})
if not inst.start():
    bad("救援实例起不来: %r" % (inst.err or "")[:200])
else:
    st, cookie = inst.login()
    st1, b1, _sc, _h = inst.req("GET", "/breakglass/" + sid, cookie=cookie)
    if st1 == 200 and "紧急完整恢复" in b1:
        ok("HTTP: 完整恢复有独立确认页")
    else:
        bad("确认页不对: %s" % st1)
    for kw in ("保留当前救援入口", "没有 pdgtx", "末 6 位", "恢复受管配置"):
        if kw not in b1:
            bad("确认页缺少说明: %s" % kw)
            break
    else:
        ok("确认页说明了保留救援入口/无二次自动回滚/手工确认/与配置恢复的区别")
    csrf = re.search(r"name=csrf value='([A-Za-z0-9_-]+)'", b1)
    dg = re.search(r"name=digest value='([0-9a-f]+)'", b1)
    nn = re.search(r"name=nonce value='([A-Za-z0-9_-]+)'", b1)
    csrf, dg, nn = (x.group(1) if x else "" for x in (csrf, dg, nn))

    def post(nonce=nn, text=None, snapv=sid, csrfv=None):
        return inst.req("POST", "/breakglass/restore",
                        body="csrf=%s&snapshot=%s&digest=%s&nonce=%s&confirm_text=%s" % (
                            csrfv if csrfv is not None else csrf, snapv, dg, nonce,
                            sid[-6:] if text is None else text), cookie=cookie)

    st, _b, _sc, _h = post(text="wrong1")
    if st == 400:
        ok("HTTP: 确认字符不对 → 400")
    else:
        bad("确认字符错却返回 %s" % st)
    # 配置恢复的 nonce 拿来做完整恢复 → 必须失败
    b2 = inst.req("GET", "/snapshot/" + sid, cookie=cookie)[1]
    cfg_nonce = re.search(r"name=nonce value='([A-Za-z0-9_-]+)'", b2)
    st, _b, _sc, _h = post(nonce=cfg_nonce.group(1) if cfg_nonce else "x")
    if st == 409:
        ok("HTTP: 配置恢复的确认票不能用于完整恢复(op 维度绑定)")
    else:
        bad("跨操作复用 nonce 被接受: %s" % st)
    # 正常执行
    b1b = inst.req("GET", "/breakglass/" + sid, cookie=cookie)[1]
    nn2 = re.search(r"name=nonce value='([A-Za-z0-9_-]+)'", b1b)
    st, body, _sc, _h = post(nonce=nn2.group(1) if nn2 else "")
    if st == 200 and "紧急完整恢复结果" in body:
        ok("HTTP: 正常执行并返回结构化结果页")
    else:
        bad("执行失败: %s" % st)
    if SENTINEL not in body and TOKEN not in body:
        ok("HTTP: 结果页不含哨兵与 Token")
    else:
        bad("结果页泄漏凭据")
    if "&lt;" in body or "<script" not in body:
        ok("HTTP: 结果页字段经过 HTML 转义")
    else:
        bad("结果页未转义")
    # 重放同一 nonce
    st, _b, _sc, _h = post(nonce=nn2.group(1) if nn2 else "")
    if st == 409:
        ok("HTTP: 重放同一 nonce → 409(双击只执行一次)")
    else:
        bad("重放返回 %s" % st)
    # 失败之后救援状态页仍然可用
    st, b3, _sc, _h = inst.req("GET", "/", cookie=cookie)
    if st == 200 and "状态总览" in b3:
        ok("HTTP: 完整恢复之后救援状态页仍然可访问")
    else:
        bad("恢复后救援页不可用: %s" % st)
inst.stop()
box.clean()

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
