#!/usr/bin/env python3
"""旧结构快照的强确认 + pdgtx/cfgrestore 降级边界(5.2/commit 8 修正)。

两件事:

1. **旧结构(legacy-dnsdist)要更强的确认**。它恢复完可能连 mihomo/mosdns 都起不来, 那不该
   和普通回滚一样"输个末 6 位就走" —— 必须同时勾选风险确认、打出 `LEGACY-<末6位>`, 而且用
   一张**绑着结构版本**的专属票: v1.6 页面上拿到的票到不了这道门后面, 反之亦然。

2. **降级边界要说清也要兜住**。pdgtx.py / cfgrestore.py 有意不在救援保护清单里(它们属于业务
   恢复范围), 所以一次完整恢复完全可能把它们换成旧版或坏版。这时候救援平面必须:
   照样打开状态页、照样能**再做一次**完整恢复(把机器换回去)、把对应按钮禁用并标注"旧核心
   不支持" —— 而不是 500、堆栈, 或者起不来反复重启。

用真 HTTPS 实例 + 真快照文件跑, 不 mock HTTP 层。
"""
import ast
import io
import json
import os
import re
import shutil
import sys
import tarfile
import tempfile
import time
import urllib.parse
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
sys.path.insert(0, os.path.join(ROOT, "deploy", "rescue"))
from rescuebox import Inst, TOKEN, SENTINEL, make_install  # noqa: E402
from txbox import Box  # noqa: E402

import importlib.util as _iu  # noqa: E402
_spec = _iu.spec_from_file_location("rc_port", os.path.join(ROOT, "deploy/bot/rescue_const.py"))
_C = _iu.module_from_spec(_spec)
_spec.loader.exec_module(_C)
RPORT = _C.port()                    # 端口只从单一常量源取(守卫测试盯着字面量)

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


work = tmpguard.mkdtemp(prefix="legacyconf.")
MODEL = json.dumps({"log": {}, "inbounds": [], "outbounds": [
    {"type": "direct", "tag": "direct"}], "route": {"rules": [], "final": "direct"}})

# 假 pdg: 完整恢复走到它这里。本测试关心的是**确认与降级**, 恢复本体另有 test-rescue-breakglass
# 逐项验证, 所以这里只要真的解包落盘(于是"旧模块真的把新模块盖掉了"是真实发生的)。
PDG_STUB = r'''#!/bin/bash
set -uo pipefail
ROOT="__ROOT__"; REPO="__REPO__"
case "${1:-}" in
  snapshot)
    id="$(date +%Y%m%d-%H%M%S)-pre"; id="${id:0:15}"
    d="$ROOT/var/lib/privdns-gateway/backups/$id"; mkdir -p "$d"
    ( cd "$ROOT" && tar czf "$d/snap.tar.gz" etc/sing-box etc/mosdns opt/pdg-bot 2>/dev/null )
    chmod 600 "$d/snap.tar.gz"
    echo "快照: $d/snap.tar.gz"; exit 0;;
  rollback)
    dir=""; preserve=0; shift
    while (( $# )); do
      case "$1" in
        --dir) dir="$2"; shift 2;;
        --preserve-rescue) preserve=1; shift;;
        *) shift;;
      esac
    done
    [[ -f "$dir/snap.tar.gz" ]] || { echo "快照文件缺失"; exit 1; }
    tmp="$(mktemp -d)"; tree="$tmp/tree"; mkdir -p "$tree"
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
    fi
    ( cd "$tree" && tar --no-recursion -cf - -T "$tmp/members" 2>/dev/null ) \
      | tar xpf - -C "$ROOT" 2>/dev/null || { echo "落盘失败"; exit 1; }
    rm -rf "$tmp"
    echo "✅ 已回滚并重启服务"
    exit 0;;
esac
echo "未知子命令"; exit 2
'''


def make_box():
    box = Box()
    box.up("mosdns")
    box.up("mihomo")
    box._write("nft", '#!/bin/sh\nexit 0\n')
    for rel, data in (("etc/sing-box/config.json", MODEL),
                      ("etc/mosdns/config.yaml", "log:\n  level: warn\n"),
                      ("etc/privdns-gateway/platform", "ios\n"),
                      ("etc/privdns-gateway/backend", "mihomo\n"),
                      ("etc/privdns-gateway/bot.env", "PDG_BOT_TOKEN=1:%s\n" % SENTINEL),
                      ("opt/pdg-bot/bot.py", "# 当前 Bot\n")):
        p = os.path.join(box.root, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        open(p, "w", encoding="utf-8").write(data)
    box._write("pdg", PDG_STUB.replace("__ROOT__", box.root).replace("__REPO__", ROOT))
    return box


def write_snap(box, snap_id, items):
    d = os.path.join(box.root, "var/lib/privdns-gateway/backups", snap_id)
    os.makedirs(d, exist_ok=True)
    with tarfile.open(os.path.join(d, "snap.tar.gz"), "w:gz") as t:
        for rel, data in items.items():
            b = data.encode()
            info = tarfile.TarInfo(rel)
            info.size = len(b)
            info.mode = 0o644
            t.addfile(info, io.BytesIO(b))
    os.chmod(os.path.join(d, "snap.tar.gz"), 0o600)
    return snap_id


V16 = {"etc/sing-box/config.json": MODEL, "etc/mosdns/config.yaml": "log: {}\n",
       "opt/pdg-bot/bot.py": "# 旧 Bot\n"}
LEGACY = {"etc/dnsdist/dnsdist.conf": "-- 远古配置\n", "opt/pdg-bot/bot.py": "# 远古 Bot\n"}
UNKNOWN = {"etc/whatever/x.conf": "?\n"}


def env_for(box):
    return {"PDG_TX_FSROOT": box.root, "PDG_TX_ROOT": box.env["PDG_TX_ROOT"],
            "PDG_LOCKFILE": box.env["PDG_LOCKFILE"], "PATH": box.env["PATH"],
            "PDG_SNAP_DIR": os.path.join(box.root, "var/lib/privdns-gateway/backups"),
            "PDG_UNIT_DIR": os.path.join(box.root, "etc/systemd/system"),
            "PDG_BIN": os.path.join(box.bin, "pdg"),
            "PDG_STABLE_SAMPLES": "1", "PDG_STABLE_INTERVAL": "0.05"}


def safe_req(inst, method, path, cookie=None, body=None):
    """降级用例里服务**本来就可能是坏的**。连接断掉要变成一条可读的失败, 而不是把测试进程
    炸掉 —— 否则负控跑出来是堆栈, 看不出到底哪条断言该红。"""
    try:
        return inst.req(method, path, body=body, cookie=cookie)
    except Exception as e:  # noqa: BLE001
        return 0, "<连接失败: %s>" % type(e).__name__, "", {}


def safe_login(inst):
    """同 safe_req: 降级用例里服务可能已经崩了, 登录失败要变成可读的失败而不是堆栈。"""
    try:
        return inst.login()
    except Exception as e:  # noqa: BLE001
        return 0, ""


def field(body, name):
    m = re.search(r"name=%s value='([A-Za-z0-9_.=-]*)'" % name, body)
    return m.group(1) if m else ""


def confirm_post(inst, cookie, body_page, snap, text, ack=False, nonce=None, digest=None):
    """像浏览器那样提交: 表单值一律 percent-encode —— 确认框里完全可能被粘进中文。"""
    fields = [("csrf", field(body_page, "csrf")), ("snapshot", snap),
              ("digest", field(body_page, "digest") if digest is None else digest),
              ("nonce", field(body_page, "nonce") if nonce is None else nonce),
              ("confirm_text", text)]
    if ack:
        fields.append(("legacy_ack", "yes"))
    return safe_req(inst, "POST", "/breakglass/restore",
                    body=urllib.parse.urlencode(fields), cookie=cookie)


# ══ 1. 确认强度: v1.6 末 6 位 / legacy 勾选 + LEGACY-末6位 ═══════════════════
print("── 1. 确认强度 ──")
box = make_box()
sid_v16 = write_snap(box, "20250101-010101", V16)
sid_leg = write_snap(box, "20250202-020202", LEGACY)
sid_unk = write_snap(box, "20250303-030303", UNKNOWN)
inst = Inst(work, extra_env=env_for(box))
if not inst.start():
    bad("救援实例起不来: %r" % (inst.err or "")[:300])
else:
    _st, cookie = inst.login()

    # 确认页本身: 两种结构给的是不同的门
    pv = inst.req("GET", "/breakglass/" + sid_v16, cookie=cookie)[1]
    pl = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    if "末 6 位" in pv and "legacy_ack" not in pv:
        ok("v1.6 确认页: 只要末 6 位, 没有旧结构的勾选框")
    else:
        bad("v1.6 确认页形态不对")
    if ("legacy_ack" in pl and "LEGACY-" in pl
            and "可能无法启动当前 mihomo/mosdns" in pl):
        ok("legacy 确认页: 勾选框 + LEGACY- 前缀 + 明确的「可能起不来」风险文案")
    else:
        bad("legacy 确认页缺少强确认要素")

    # ① legacy 只输末 6 位(即使勾了) → 拒绝
    st, b, _s, _h = confirm_post(inst, cookie, pl, sid_leg, sid_leg[-6:], ack=True)
    if st == 400:
        ok("legacy: 只输末 6 位 → 400(不够, 必须是 LEGACY-<末6位>)")
    else:
        bad("legacy 只输末 6 位却返回 %s" % st)

    # ② legacy 只勾选不输入 → 拒绝
    pl2 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    st, b, _s, _h = confirm_post(inst, cookie, pl2, sid_leg, "", ack=True)
    if st == 400:
        ok("legacy: 只勾选不输入 → 400")
    else:
        bad("legacy 只勾选却返回 %s" % st)

    # ③ legacy 输对了但没勾选 → 拒绝
    pl3 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    st, b, _s, _h = confirm_post(inst, cookie, pl3, sid_leg, "LEGACY-" + sid_leg[-6:], ack=False)
    if st == 400 and "未勾选" in b:
        ok("legacy: 输对了但没勾选 → 400 且点明是没勾选")
    else:
        bad("legacy 未勾选却返回 %s" % st)

    # ④ 错误响应不回显完整确认值(既不回显期望值, 也不回显用户输入)
    typed = "MY-TYPED-GUESS-9k"
    pl4 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    st, b, _s, _h = confirm_post(inst, cookie, pl4, sid_leg, typed, ack=True)
    if st == 400 and ("LEGACY-" + sid_leg[-6:]) not in b and typed not in b:
        ok("确认失败的响应里既没有期望值也没有用户输入(截图/转发也漏不出去)")
    else:
        bad("错误响应回显了确认值: st=%s" % st)

    # ⑤ 非 ASCII 输入不该变成 500(恒定时间比较要能吃下任意字节)
    pl5 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    st, _b, _s, _h = confirm_post(inst, cookie, pl5, sid_leg, "中文确认", ack=True)
    if st == 400:
        ok("非 ASCII 确认输入 → 400(不是 500: 那只是输错了)")
    else:
        bad("非 ASCII 输入返回 %s" % st)

    # ⑥ unknown 结构: 连表单和票都不给, POST 也拒
    pu = inst.req("GET", "/breakglass/" + sid_unk, cookie=cookie)[1]
    if "无法识别" in pu and "<form" not in pu:
        ok("unknown 结构: 确认页直接拒绝, 不给表单")
    else:
        bad("unknown 结构却给了表单")
    # 拿一张**合法**的 CSRF(unknown 页面本身没有表单), 直接冲 POST: 服务端必须自己复核结构
    pv_for_csrf = inst.req("GET", "/breakglass/" + sid_v16, cookie=cookie)[1]
    st, _b, _s, _h = confirm_post(inst, cookie, pv_for_csrf, sid_unk, sid_unk[-6:])
    if st in (400, 409):
        ok("unknown 结构: 带着合法 CSRF 直接 POST 也被拒(服务端复核结构, 不信表单)")
    else:
        bad("unknown 结构 POST 返回 %s" % st)

    # ⑦ 票据不能跨结构版本使用。
    # 注意: 走 HTTP 换快照时, 票同时因为 snap/digest 对不上而失效, 所以那条**证明不了** fmt
    # 这一维本身在起作用 —— 下面另有一段直接打 Nonces, 把 fmt 维度单独隔离出来验。
    pv2 = inst.req("GET", "/breakglass/" + sid_v16, cookie=cookie)[1]
    pl6 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    st, _b, _s, _h = confirm_post(inst, cookie, pl6, sid_leg, "LEGACY-" + sid_leg[-6:],
                                  ack=True, nonce=field(pv2, "nonce"))
    if st == 409:
        ok("v1.6 页面拿到的票不能用于 legacy(票绑着结构版本)")
    else:
        bad("v1.6 票用在 legacy 上返回 %s" % st)
    pl7 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    pv3 = inst.req("GET", "/breakglass/" + sid_v16, cookie=cookie)[1]
    st, _b, _s, _h = confirm_post(inst, cookie, pv3, sid_v16, sid_v16[-6:],
                                  nonce=field(pl7, "nonce"))
    if st == 409:
        ok("legacy 的票不能用于 v1.6(反向也不通)")
    else:
        bad("legacy 票用在 v1.6 上返回 %s" % st)

    # ⑧ 确认之后快照内容变了 → 拒绝
    pl8 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    write_snap(box, sid_leg, dict(LEGACY, **{"etc/dnsdist/extra.conf": "被换过了\n"}))
    st, b, _s, _h = confirm_post(inst, cookie, pl8, sid_leg, "LEGACY-" + sid_leg[-6:], ack=True)
    if st == 409 and "发生了变化" in b:
        ok("确认之后快照内容变化 → 409(确认的是 A 就不能执行 B)")
    else:
        bad("快照被换过却返回 %s" % st)

    # ⑨ 确认之后结构版本变了(legacy → v1.6) → 拒绝
    pl9 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    write_snap(box, sid_leg, V16)
    st, _b, _s, _h = confirm_post(inst, cookie, pl9, sid_leg, "LEGACY-" + sid_leg[-6:], ack=True)
    if st == 409:
        ok("确认之后结构版本变化 → 409")
    else:
        bad("结构版本变了却返回 %s" % st)
    write_snap(box, sid_leg, LEGACY)          # 换回旧结构, 给后面的成功用例用

    # ⑩ v1.6 正常成功
    pv4 = inst.req("GET", "/breakglass/" + sid_v16, cookie=cookie)[1]
    st, b, _s, _h = confirm_post(inst, cookie, pv4, sid_v16, sid_v16[-6:])
    if st == 200 and "紧急完整恢复结果" in b:
        ok("v1.6: 末 6 位确认 → 执行成功并返回结构化结果页")
    else:
        bad("v1.6 正常路径失败: %s" % st)

    # ⑪ legacy 正常成功(勾选 + LEGACY-末6位)
    pl10 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    nonce_used = field(pl10, "nonce")
    st, b, _s, _h = confirm_post(inst, cookie, pl10, sid_leg,
                                 "LEGACY-" + sid_leg[-6:], ack=True)
    if st == 200 and "紧急完整恢复结果" in b:
        ok("legacy: 勾选 + LEGACY-<末6位> → 执行成功")
    else:
        bad("legacy 正常路径失败: %s" % st)

    # ⑫ 重放同一张 legacy 票 → 409(双击只执行一次)
    st, _b, _s, _h = confirm_post(inst, cookie, pl10, sid_leg,
                                  "LEGACY-" + sid_leg[-6:], ack=True, nonce=nonce_used)
    if st == 409:
        ok("legacy: 重放/双击同一张票 → 409(只执行一次)")
    else:
        bad("legacy 票重放返回 %s" % st)

    # ⑬ 伪造/过期票 → 409
    pl11 = inst.req("GET", "/breakglass/" + sid_leg, cookie=cookie)[1]
    st, _b, _s, _h = confirm_post(inst, cookie, pl11, sid_leg, "LEGACY-" + sid_leg[-6:],
                                  ack=True, nonce="nonce-that-never-existed")
    if st == 409:
        ok("legacy: 不存在的票 → 409")
    else:
        bad("伪造票返回 %s" % st)

    # ⑭ 全程不得泄漏哨兵/Token
    leak = []
    for pth in ("/", "/snapshots", "/breakglass/" + sid_leg, "/audit"):
        bb = inst.req("GET", pth, cookie=cookie)[1]
        if SENTINEL in bb or TOKEN in bb:
            leak.append(pth)
    if not leak:
        ok("确认与结果各页面都不含 bot 哨兵与救援 Token")
    else:
        bad("泄漏于: %r" % leak)
inst.stop()

# 审计与服务端日志同样不许出现哨兵
audit_f = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
audit_txt = open(audit_f, encoding="utf-8").read() if os.path.exists(audit_f) else ""
if SENTINEL not in audit_txt and SENTINEL not in (inst.err or ""):
    ok("审计与服务端日志里都没有哨兵")
else:
    bad("哨兵进了审计或日志")
if '"op": "full_breakglass_restore"' in audit_txt:
    ok("两次完整恢复都留下了审计")
else:
    bad("审计缺少 full_breakglass_restore: %s" % audit_txt[-300:])
box.clean()

# ══ 2. 降级: pdgtx / cfgrestore 被旧快照换掉之后 ══════════════════════════════
print()
print("── 2. 降级边界 ──")
BROKEN = "这不是 Python(  语法错误 :::\n"
OLD_TX = ('"""旧版事务核心: import 得进来, 但少一半函数(版本不兼容)。"""\n'
          'FSROOT = ""\n'
          'def pending_recovery(*a, **k):\n    return []\n')

for label, override, degraded_mod in (
        ("pdgtx.py 语法错误", {"pdgtx.py": BROKEN}, "pdgtx"),
        ("pdgtx.py 是旧版(缺函数)", {"pdgtx.py": OLD_TX}, "pdgtx"),
        ("cfgrestore.py 语法错误", {"cfgrestore.py": BROKEN}, "cfgrestore"),
        ("cfgrestore.py 是旧版(缺函数)",
         {"cfgrestore.py": '"""旧版。"""\ndef snapshot_ids():\n    return []\n'}, "cfgrestore")):
    box = make_box()
    sid = write_snap(box, "20250404-040404", V16)
    inst = Inst(work, extra_env=env_for(box),
                install_dir=make_install(work, override=override))
    if not inst.start():
        bad("%s: 救援服务起不来(降级状态下必须仍能启动): %r" % (label, (inst.err or "")[:200]))
        inst.stop()
        box.clean()
        continue
    ok("%s: 救援服务照常启动(不是起不来反复重启)" % label)
    _st, cookie = safe_login(inst)

    st, body, _s, _h = safe_req(inst, "GET", "/", cookie=cookie)
    if st == 200 and "状态总览" in body:
        ok("%s: 状态页仍可访问(200, 不是 500)" % label)
    else:
        bad("%s: 状态页 st=%s" % (label, st))
    if "旧核心不支持" in body:
        ok("%s: 状态页把不可用的能力标成「旧核心不支持」" % label)
    else:
        bad("%s: 状态页没标注降级" % label)
    if "Traceback" not in body:
        ok("%s: 页面里没有堆栈" % label)
    else:
        bad("%s: 页面泄漏堆栈" % label)

    # 对应功能的入口: 禁用/降级页, 而不是 500
    st_tx, b_tx, _s, _h = safe_req(inst, "GET", "/tx", cookie=cookie)
    st_cfg, b_cfg, _s, _h = safe_req(inst, "GET", "/snapshot/" + sid, cookie=cookie)
    if degraded_mod == "pdgtx":
        good = st_tx == 200 and "旧核心不支持" in b_tx
    else:
        good = st_cfg == 200 and "旧核心不支持" in b_cfg
    if good:
        ok("%s: 对应功能给出降级页(200 + 旧核心不支持), 不是 500" % label)
    else:
        bad("%s: 降级入口不对 tx=%s cfg=%s" % (label, st_tx, st_cfg))
    if st_tx != 500 and st_cfg != 500:
        ok("%s: 事务页与配置恢复页都没有 500" % label)
    else:
        bad("%s: 出现 500 tx=%s cfg=%s" % (label, st_tx, st_cfg))

    # 快照列表: 配置恢复入口被禁用, 但完整恢复照常给路
    b_sn = safe_req(inst, "GET", "/snapshots", cookie=cookie)[1]
    if "/breakglass/" + sid in b_sn:
        ok("%s: 快照列表仍然给出完整恢复入口" % label)
    else:
        bad("%s: 快照列表没有完整恢复入口" % label)

    # **仍然能再做一次完整恢复** —— 这是降级状态下把机器换回去的唯一办法
    pg = safe_req(inst, "GET", "/breakglass/" + sid, cookie=cookie)
    if pg[0] == 200 and "紧急完整恢复" in pg[1]:
        ok("%s: 完整恢复确认页仍可打开" % label)
    else:
        bad("%s: 完整恢复确认页 st=%s" % (label, pg[0]))
    st, b, _s, _h = confirm_post(inst, cookie, pg[1], sid, sid[-6:])
    if st == 200 and "紧急完整恢复结果" in b:
        ok("%s: 降级状态下仍能执行完整恢复" % label)
    else:
        bad("%s: 降级状态下完整恢复失败 st=%s" % (label, st))
    if "RESTORED" in b or "pre-rescue" in b or "操作前快照" in b:
        ok("%s: 结果页给出了最终状态与 pre-rescue 快照" % label)
    else:
        bad("%s: 结果页信息不全" % label)

    # 审计必须写完 —— 哪怕事务核心已经不可用
    au = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    au_txt = open(au, encoding="utf-8").read() if os.path.exists(au) else ""
    if '"op": "full_breakglass_restore"' in au_txt:
        ok("%s: break-glass 审计照样写完(不依赖恢复后的旧 pdgtx)" % label)
    else:
        bad("%s: 审计缺失" % label)
    pre_ids = re.findall(r'"pre_rescue_snapshot": "([0-9-]+)"', au_txt)
    if pre_ids and pre_ids[-1]:
        ok("%s: 审计里留下了 pre-rescue 快照 ID(重启后也查得到)" % label)
    else:
        bad("%s: 审计里没有 pre-rescue 快照 ID" % label)

    if SENTINEL not in au_txt:
        ok("%s: 降级路径的审计不含哨兵" % label)
    else:
        bad("%s: 降级审计泄漏哨兵" % label)

    # 模拟救援服务重启: 同一份"装好的目录"重新起一次, 必须还能进降级状态页
    inst2 = Inst(work, extra_env=env_for(box), install_dir=inst.install_dir)
    if inst2.start():
        _st, ck2 = safe_login(inst2)
        st2, b2, _s, _h = safe_req(inst2, "GET", "/", cookie=ck2)
        if st2 == 200 and "状态总览" in b2 and "旧核心不支持" in b2:
            ok("%s: 服务重启后仍进得去降级状态页" % label)
        else:
            bad("%s: 重启后状态页 st=%s" % (label, st2))
        pre = re.findall(r'"pre_rescue_snapshot": "([0-9-]+)"', au_txt)
        if pre and pre[-1] and pre[-1] in b2:
            ok("%s: 重启后状态页仍显示 pre-rescue 快照 ID(可再次完整恢复)" % label)
        else:
            bad("%s: 重启后看不到 pre-rescue ID(pre=%r)" % (label, pre[-1:] ))
        if pre and pre[-1]:
            pg2 = safe_req(inst2, "GET", "/breakglass/" + pre[-1], cookie=ck2)
            if pg2[0] == 200 and "紧急完整恢复" in pg2[1]:
                ok("%s: 降级状态下可选中 pre-rescue 快照再次完整恢复" % label)
            else:
                bad("%s: pre-rescue 快照打不开 st=%s" % (label, pg2[0]))
    else:
        bad("%s: 重启起不来: %r" % (label, (inst2.err or "")[:200]))
    inst2.stop()
    inst.stop()
    box.clean()

# ══ 2b. 恢复**当场**把 live 模块换成旧版 → 同一个进程里立刻降级 ═══════════════
# 这是真机上最常见的那条路: 服务起来时一切正常, 一次完整恢复把 /opt/pdg-bot/pdgtx.py 换成
# 快照里的旧版, 于是**从下一个请求开始**就该显示降级。Python 一个模块只 import 一次, 不主动
# 丢缓存的话页面会拿着内存里那份旧对象继续报"一切正常", 要等重启才暴露。
print()
print("── 2b. 恢复当场换掉 live 模块 ──")
box = make_box()
live = os.path.join(box.root, "opt/pdg-bot")        # 服务从这里 import —— 与真机同构
shutil.rmtree(live, ignore_errors=True)
shutil.copytree(make_install(work), live)
open(os.path.join(live, "bot.py"), "w").write("# 当前 Bot\n")
sid_clob = write_snap(box, "20250505-050505",
                      dict(V16, **{"opt/pdg-bot/pdgtx.py": BROKEN}))
inst = Inst(work, extra_env=env_for(box), install_dir=live)
if not inst.start():
    bad("2b: 实例起不来: %r" % (inst.err or "")[:300])
else:
    _st, cookie = inst.login()
    b0 = safe_req(inst, "GET", "/", cookie=cookie)[1]
    if "旧核心不支持" not in b0:
        ok("2b: 恢复之前, 能力一览显示一切可用")
    else:
        bad("2b: 恢复之前就已经是降级的, 场景没造对")
    pg = safe_req(inst, "GET", "/breakglass/" + sid_clob, cookie=cookie)[1]
    st, b, _s, _h = confirm_post(inst, cookie, pg, sid_clob, sid_clob[-6:])
    if st == 200 and "紧急完整恢复结果" in b:
        ok("2b: 完整恢复走完(它正在把自己依赖的事务核心换成旧版)")
    else:
        bad("2b: 恢复失败 st=%s" % st)
    live_tx = open(os.path.join(live, "pdgtx.py"), encoding="utf-8").read()
    if live_tx == BROKEN:
        ok("2b: live 的 pdgtx.py 确实被快照里的旧版盖掉了(场景真实发生)")
    else:
        bad("2b: pdgtx.py 没被换掉, 后面的断言证明不了什么")
    b1 = safe_req(inst, "GET", "/", cookie=cookie)[1]
    if "旧核心不支持" in b1 and "状态总览" in b1:
        ok("2b: **不重启**, 下一个请求就重新做了能力检测并显示降级")
    else:
        bad("2b: 恢复后仍报一切正常(能力检测没重做)")
    b2 = safe_req(inst, "GET", "/tx", cookie=cookie)[1]
    if "旧核心不支持" in b2:
        ok("2b: 事务页同步降级")
    else:
        bad("2b: 事务页没降级")
    au = os.path.join(box.env["PDG_TX_ROOT"], "index.jsonl")
    au_txt = open(au, encoding="utf-8").read() if os.path.exists(au) else ""
    if '"op": "full_breakglass_restore"' in au_txt:
        ok("2b: 这次恢复的审计写完了(哪怕它换掉的正是审计要用的模块)")
    else:
        bad("2b: 审计缺失")
inst.stop()
box.clean()


# ══ 3. 票据的结构版本维度(直接打 Nonces, 隔离出 fmt 这一维)══════════════════
# HTTP 那条换的是**另一份快照**, 票会因为 snap/digest 对不上而失效 —— 证明不了 fmt。这里把
# 会话/快照/摘要/操作全部固定成同一组, **只**改结构版本, 于是通过与否只取决于这一维。
print()
print("── 3. 票据的结构版本维度 ──")
_rspec = _iu.spec_from_file_location("rescue_mod", os.path.join(ROOT, "deploy/rescue/rescue.py"))
_rescue = _iu.module_from_spec(_rspec)
_rspec.loader.exec_module(_rescue)
N = _rescue.Nonces()
OPB = _rescue.OP_BREAKGLASS
n16 = N.issue("sid-1", "20250101-010101", "deadbeef", OPB, "v1.6")
if not N.consume(n16, "sid-1", "20250101-010101", "deadbeef", OPB, "legacy-dnsdist"):
    ok("Nonces: v1.6 的票在其它维度全同的情况下, 仅因结构版本是 legacy 就被拒")
else:
    bad("v1.6 票被 legacy 用掉了(fmt 维度没起作用)")
nlg = N.issue("sid-1", "20250101-010101", "deadbeef", OPB, "legacy-dnsdist")
if not N.consume(nlg, "sid-1", "20250101-010101", "deadbeef", OPB, "v1.6"):
    ok("Nonces: legacy 的票同样不能当 v1.6 用(反向也不通)")
else:
    bad("legacy 票被 v1.6 用掉了")
nok = N.issue("sid-1", "20250101-010101", "deadbeef", OPB, "legacy-dnsdist")
if N.consume(nok, "sid-1", "20250101-010101", "deadbeef", OPB, "legacy-dnsdist"):
    ok("Nonces: 五个维度全对才放行(正向)")
else:
    bad("五维全对却被拒")
if not N.consume(nok, "sid-1", "20250101-010101", "deadbeef", OPB, "legacy-dnsdist"):
    ok("Nonces: 用过即废(同一张票第二次必失败)")
else:
    bad("票可以重复使用")
n_op = N.issue("sid-1", "20250101-010101", "deadbeef", _rescue.OP_CONFIG, "v1.6")
if not N.consume(n_op, "sid-1", "20250101-010101", "deadbeef", OPB, "v1.6"):
    ok("Nonces: 配置恢复的票不能当完整恢复用(op 维度)")
else:
    bad("op 维度失效")


# ══ 4. 保留边界: 不把 pdgtx/cfgrestore 加进保护清单 ══════════════════════════
print()
print("── 4. 保留边界 ──")
prot = "\n".join(_C.protected_members())
if "pdgtx.py" not in prot and "cfgrestore.py" not in prot:
    ok("pdgtx.py / cfgrestore.py 仍**不在**救援保护清单里(它们是业务恢复目标)")
else:
    bad("保护清单被扩大了: %s" % prot)
bg_src = open(os.path.join(ROOT, "deploy/rescue/breakglass.py"), encoding="utf-8").read()
# _Witness 必须只**见证**: 类体里不许出现任何写文件的调用。事后"悄悄补回来"看着更友好, 但补回
# 来之前盘上已经是旧凭据了 —— 那段时间正是用户最怕失联的时刻, 所以只报不修。
_wt = next((n for n in ast.walk(ast.parse(bg_src))
            if isinstance(n, ast.ClassDef) and n.name == "_Witness"), None)
_writes = []
for _n in ast.walk(_wt) if _wt else []:
    if not isinstance(_n, ast.Call):
        continue
    _fn = _n.func
    _nm = getattr(_fn, "id", None) or getattr(_fn, "attr", None)
    if _nm in ("copy", "copy2", "copyfile", "replace", "rename", "write", "unlink", "remove"):
        _writes.append(_nm)
    if _nm == "open":
        _mode = next((a.value for a in _n.args[1:] if isinstance(a, ast.Constant)), "r")
        if any(c in str(_mode) for c in "wax+"):
            _writes.append("open(%s)" % _mode)
if _wt and not _writes and "PROTECTION_VIOLATED" in bg_src:
    ok("_Witness 仍只检测 PROTECTION_VIOLATED(类体里没有任何写文件调用), 不做事后自动补回")
else:
    bad("_Witness 语义被改动(写操作=%r)" % _writes)

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
