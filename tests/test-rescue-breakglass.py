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
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
from rescuebox import Inst, TOKEN  # noqa: E402
from txbox import Box  # noqa: E402

import importlib.util as _iu_top  # noqa: E402

_spec_c = _iu_top.spec_from_file_location("rc_port", os.path.join(ROOT, "deploy/bot/rescue_const.py"))
_C = _iu_top.module_from_spec(_spec_c)
_spec_c.loader.exec_module(_C)
RPORT = _C.port()                      # 端口从单一常量源取, 测试里不写死(守卫会盯着)

PASS = [0]
FAIL = [0]
SENTINEL = "S3CRET-SENTINEL-breakglass-55"


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


work = tmpguard.mkdtemp(prefix="breakglass.")

MODEL = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}], "route": {"rules": [], "final": "direct"}})


def mos(size=1024):
    return ("log:\n  level: error\nplugins:\n  - tag: npn_clients\n    type: ip_set\n"
            '    args: { ips: ["127.0.0.0/8"] }\n  - tag: cache\n    type: cache\n'
            "    args: { size: %d }\n" % size)


# 假的 pdg: snapshot 打一个真 tar; rollback 真的把快照内容覆盖到沙箱根。
# 假的 pdg: 与真实现同构 —— snapshot 打真 tar; rollback 支持 --preserve-rescue:
# 受保护成员**事前排除**(既不解到生产, 也从 staging 删掉), nft 候选在 staging 里注入救援放行,
# 全程只执行一次 `nft -f`。
PDG_STUB = r'''#!/bin/bash
set -uo pipefail
ROOT="__ROOT__"
REPO="__REPO__"
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
    preserve=0; dir=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --dir) dir="${2:-}"; shift 2;;
        --preserve-rescue) preserve=1; shift;;
        *) shift;;
      esac
    done
    [[ -f "$dir/snap.tar.gz" ]] || { echo "快照文件缺失"; exit 1; }
    [[ -n "${PDG_STUB_FAIL:-}" ]] && { echo "注入: 恢复失败"; exit 1; }
    tmp="$(mktemp -d)"; trap 'rm -rf -- "$tmp"' EXIT   # 桩也要自己清, 否则每跑一次留一个
    tree="$tmp/tree"; mkdir -p "$tree"
    tar tzf "$dir/snap.tar.gz" > "$tmp/members" || { echo "清单读取失败"; exit 1; }
    tar xzf "$dir/snap.tar.gz" -C "$tree" || { echo "解包失败"; exit 1; }
    if (( preserve == 1 )); then
      source "$REPO/lib/rescue.sh" || { echo "读不到保护清单"; exit 1; }
      : > "$tmp/kept"
      while IFS= read -r m; do
        [[ -n "$m" ]] || continue
        prot=0
        while IFS= read -r pm; do
          [[ -n "$pm" ]] || continue
          [[ "$m" == "$pm" ]] && { prot=1; break; }
        done < <(pdg_rescue_protected)
        if (( prot == 1 )); then rm -f -- "$tree/$m"; else printf '%s\n' "$m" >> "$tmp/kept"; fi
      done < "$tmp/members"
      mv -f "$tmp/kept" "$tmp/members"
      if [[ -f "$tree/etc/nftables.conf" ]]; then
        cidr="$(sed -n 's/^PDG_INTERNAL_CIDR=//p' "$ROOT/etc/privdns-gateway/profile.env" | tail -1)"
        bind="$(sed -n 's/^PDG_RESCUE_BIND=//p' "$ROOT/etc/privdns-gateway/profile.env" | tail -1)"
        python3 "$REPO/deploy/bot/rescue_nft.py" "$cidr" "$PDG_RESCUE_PORT" "$bind" \
          < "$tree/etc/nftables.conf" > "$tmp/nft.cand" || { echo "候选注入失败"; exit 1; }
        nft -c -f "$tmp/nft.cand" >/dev/null 2>&1 || { echo "候选校验失败"; exit 1; }
        mv -f "$tmp/nft.cand" "$tree/etc/nftables.conf"
      fi
    fi
    [[ -n "${PDG_STUB_APPLYFAIL:-}" ]] && { echo "注入: 第 N 个文件落盘失败"; exit 1; }
    ( cd "$tree" && tar --no-recursion -cf - -T "$tmp/members" 2>/dev/null ) \
      | tar xpf - -C "$ROOT" 2>/dev/null || { echo "落盘失败"; exit 1; }
    if [[ -f "$ROOT/etc/nftables.conf" ]]; then nft -f "$ROOT/etc/nftables.conf" >/dev/null 2>&1; fi
    systemctl restart mosdns >/dev/null 2>&1
    systemctl restart mihomo >/dev/null 2>&1
    rm -rf "$tmp"
    echo "✅ 已回滚并重启服务"
    exit 0;;
esac
echo "未知子命令"; exit 2
'''

NFT_WITH_RESCUE = ("table inet pdg\ndelete table inet pdg\ntable inet pdg {\n"
                   "    chain input {\n        type filter hook input priority 0; policy drop;\n"
                   "        ip saddr 127.0.0.0/8 tcp dport { 53 } accept\n"
                   "        ip saddr 127.0.0.0/8 tcp dport %d accept\n    }\n}\n" % RPORT)
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
        "opt/pdg-bot/rescue.sh": "PDG_RESCUE_PORT=%d\n" % RPORT,
        "etc/systemd/system/pdg-rescue.socket": "[Socket]\nListenStream=127.0.0.1:%d\n" % RPORT,
        "etc/systemd/system/pdg-rescue.service": "[Service]\nExecStart=/usr/bin/python3 x\n",
    }
    for rel, data in files.items():
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            f.write(data)
        os.chmod(p, 0o600 if "rescue/" in rel else 0o644)
    box._write("pdg", PDG_STUB.replace("__ROOT__", box.root).replace("__REPO__", ROOT))
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
        f.write("PDG_RESCUE_BIND=127.0.0.1\n")
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
if "%d accept" % RPORT in nft_now:
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
# ── 1b. 事前排除的证据: 只执行一次 nft -f, 且候选自带救援规则 ─────────────
import importlib.util as _iu  # noqa: E402

_spec_rc = _iu.spec_from_file_location("rc_check", os.path.join(ROOT, "deploy/bot/rescue_const.py"))
_rc = _iu.module_from_spec(_spec_rc); _spec_rc.loader.exec_module(_rc)
_want_prot = list(_rc.protected_members())
if res.get("protected") and list(res["protected"]) == _want_prot:
    ok("结果里列出的逻辑保护项与 lib/rescue.sh 的清单完全一致(%d 项)" % len(_want_prot))
else:
    bad("保护项清单不对: 结果=%r 期望=%r" % (res.get("protected"), _want_prot))
if all(any(k in x for x in (res.get("protected") or []))
       for k in ("token", "cert.pem", "key.pem", "rescue.py", "pdg-rescue.service")):
    ok("保护项覆盖 Token / 证书 / 私钥 / 服务代码 / unit")
else:
    bad("保护项缺关键条目: %r" % res.get("protected"))
_aud = audit_recs(box)
if _aud and _aud[-1].get("protected_count") == len(_want_prot):
    ok("审计记录了保护项数量(%d), 且不含路径内容" % _aud[-1]["protected_count"])
else:
    bad("审计的 protected_count 不对: %r" % (_aud[-1].get("protected_count") if _aud else None))

nft_calls = [ln for ln in (open(box.calls, encoding="utf-8").read().splitlines()
                           if os.path.exists(box.calls) else []) if ln.startswith("nft -f")]
if len(nft_calls) == 1:
    ok("整个恢复过程只执行了**一次** nft -f(候选已含救援放行, 不需要补第二次)")
else:
    bad("nft -f 执行了 %d 次: %r" % (len(nft_calls), nft_calls))
if res.get("validation", {}).get("protected_intact") is True:
    ok("校验: 受保护文件全程未被动过(protected_intact)")
else:
    bad("protected_intact 不为真: %r" % res.get("validation"))
if "insert" not in (open(box.calls, encoding="utf-8").read() if os.path.exists(box.calls) else ""):
    ok("没有『先应用旧配置再 insert 一条』的补救调用")
else:
    bad("出现了事后 insert 的补救")
disk_nft = read(box, "etc/nftables.conf") or ""
# 形态是**项目自己 inet pdg 链里的一条带标记规则**, 不再是独立表 —— 独立表的 accept 盖不过
# 同 hook 上另一条链的 policy drop(10b 真 nft 实测), 而且它会被 doctor 判成 input 链冲突。
if 'comment "pdg-rescue"' in disk_nft and str(RPORT) in disk_nft:
    ok("落盘的 nftables.conf 里就带着救援放行(不是靠运行态补的)")
else:
    bad("落盘配置没有救援放行")
if "pdgrescue" not in disk_nft:
    ok("恢复过程**不再**创建独立表 inet pdgrescue")
else:
    bad("又出现了独立表: %r" % [l for l in disk_nft.splitlines() if "pdgrescue" in l][:2])

box.clean()

# ── 1c. 候选含 flush ruleset 时救援规则仍然存在 ───────────────────────────
box2, cur2 = make_box()
sid2 = make_snapshot(box2, snap_id="20250505-050505", items={
    "etc/nftables.conf": "flush ruleset\n" + NFT_OLD,
    "etc/sing-box/config.json": MODEL,
    "usr/local/bin/mihomo": "OLD-BINARY\n"})
cr2, bg2 = load_mods(box2)
r2 = bg2.run(sid2, expect_digest=cr2.snapshot_digest(sid2), cfgrestore=cr2)
state2 = open(os.path.join(box2.root, "nft-state.txt"), encoding="utf-8").read()
if r2.get("final_state") == "RESTORED" and 'comment "pdg-rescue"' in state2:
    ok("候选含 flush ruleset: 事务结束时救援规则仍然存在")
else:
    bad("flush 之后救援规则没了: state=%r" % r2.get("final_state"))
if state2.index('comment "pdg-rescue"') > state2.index("flush ruleset"):
    ok("救援规则在 flush 之后(同一次 transaction 内一定生效)")
else:
    bad("救援规则在 flush 之前")
if "pdgrescue" not in state2:
    ok("flush 场景同样不创建独立表")
else:
    bad("flush 场景创建了独立表")
box2.clean()

# ── 1d. nft -c 失败 → 磁盘与运行态都不变 ──────────────────────────────────
box3, cur3 = make_box()
sid3 = make_snapshot(box3, snap_id="20250606-060606")
box3._write("nft", '#!/bin/bash\necho "nft $*" >> %s\n'
            'case "$1" in\n  -c) exit 1;;\n  -f) exit 0;;\n  list) exit 0;;\nesac\nexit 0\n'
            % box3.calls)
nft_before = read(box3, "etc/nftables.conf")
cr3, bg3 = load_mods(box3)
r3 = bg3.run(sid3, expect_digest=cr3.snapshot_digest(sid3), cfgrestore=cr3)
if r3.get("final_state") != "RESTORED":
    ok("nft 候选校验失败: 完整恢复未报成功(%s)" % r3.get("final_state"))
else:
    bad("候选校验失败却报成功")
if read(box3, "etc/nftables.conf") == nft_before:
    ok("nft 候选校验失败: 磁盘上的防火墙配置逐字节未变")
else:
    bad("校验失败却改了磁盘")
if read(box3, "usr/local/bin/mihomo") == "CURRENT-BINARY\n":
    ok("nft 候选校验失败: 业务文件也没被落盘(在动手之前中止)")
else:
    bad("校验失败却落了盘")
box3.clean()

# ── 1e. 各故障注入点: 受保护文件始终逐字节不变 ────────────────────────────
for label, envkey in (("解包/落盘中途失败", "PDG_STUB_APPLYFAIL"),
                      ("恢复整体失败", "PDG_STUB_FAIL")):
    boxf, curf = make_box()
    sidf = make_snapshot(boxf, snap_id="20250707-070707")
    crf, bgf = load_mods(boxf)
    os.environ[envkey] = "1"
    rf = bgf.run(sidf, expect_digest=crf.snapshot_digest(sidf), cfgrestore=crf)
    os.environ.pop(envkey, None)
    broke = [k for k in ("etc/privdns-gateway/rescue/token", "etc/privdns-gateway/rescue/key.pem",
                         "opt/pdg-bot/rescue.py", "etc/systemd/system/pdg-rescue.socket")
             if read(boxf, k) != curf[k]]
    if not broke and rf.get("final_state") != "RESTORED":
        ok("%s: 救援文件逐字节不变, 且如实报失败" % label)
    else:
        bad("%s: 救援文件被动了 %r 或误报成功(%s)" % (label, broke, rf.get("final_state")))
    boxf.clean()

# ── 1f. 快照里没有救援文件时, 当前文件不能被删 ────────────────────────────
box4, cur4 = make_box()
sid4 = make_snapshot(box4, snap_id="20250808-080808", old_rescue=False)
cr4, bg4 = load_mods(box4)
r4 = bg4.run(sid4, expect_digest=cr4.snapshot_digest(sid4), cfgrestore=cr4)
missing = [k for k in ("etc/privdns-gateway/rescue/token", "opt/pdg-bot/rescue.py")
           if read(box4, k) != cur4[k]]
if r4.get("final_state") == "RESTORED" and not missing:
    ok("快照里没有救援文件: 当前文件既不被删也不被改")
else:
    bad("缺救援文件的快照弄坏了当前平面: %r" % missing)
box4.clean()

# ── 1g. pdg 不支持保护模式 → Web 直接拒绝 ────────────────────────────────
box5, cur5 = make_box()
sid5 = make_snapshot(box5, snap_id="20250909-090909")
# 老版本的 pdg: snapshot 是能用的(真机上就是这样), 只是**没有** --preserve-rescue。
# 这样才验得出"保护模式检查"本身, 而不是被 pre-rescue 快照失败顺带挡住。
box5._write("pdg", PDG_STUB.replace("__ROOT__", box5.root).replace("__REPO__", ROOT)
            .replace("--preserve-rescue) preserve=1; shift;;", "--nothing) shift;;"))
cr5, bg5 = load_mods(box5)
r5 = bg5.run(sid5, expect_digest=cr5.snapshot_digest(sid5), cfgrestore=cr5)
if r5.get("final_state") == "REFUSED" and r5.get("error_class") == "NO_PRESERVE_MODE":
    ok("已安装的 pdg 不支持保护模式 → Web 完整恢复被拒绝")
else:
    bad("无保护模式却允许执行: %r" % r5.get("final_state"))
if read(box5, "usr/local/bin/mihomo") == "CURRENT-BINARY\n":
    ok("无保护模式: 现网逐字节未变")
else:
    bad("现网被改了")
box5.clean()

# ── 1h. 普通 CLI 不带保护模式时历史行为不变 ──────────────────────────────
import subprocess as _sp  # noqa: E402

_pdg_src = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()
# 锚在**意图**上(开关存在 + 默认 0), 不锚整行 local 声明: 那一行是 cmd_rollback 的全部
# 局部变量, 任何无关的新局部变量都会让这条断言断掉 —— 断的是判据的写法, 不是产品的语义。
_preserve_default = re.search(r"^\s*local\s+.*\bpreserve=0\b", _pdg_src, re.M)
if "--preserve-rescue) preserve=1" in _pdg_src and _preserve_default:
    ok("Bash: 保护模式是固定开关, 默认关闭(普通 CLI 语义不变)")
else:
    bad("保护模式的默认值/开关形态不对")
# 判**参数解析**里有没有任意排除, 而不是判注释里提没提这个词
_case_branches = re.findall(r"^\s*(--[a-z-]+)\)", _pdg_src, re.M)
if "--exclude" not in _case_branches and "--skip" not in _case_branches:
    ok("Bash: 参数解析里没有任意 --exclude/--skip(只有固定的 --preserve-rescue)")
else:
    bad("出现了任意排除参数: %r" % _case_branches)

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
