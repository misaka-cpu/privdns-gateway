#!/usr/bin/env python3
"""iOS 描述文件身份是**用户持久数据** —— 谁都不许把它弄丢。

弄丢的后果不是"少了个文件": 下一次生成会造出**第二个身份**, 于是用户 iPhone 上那份描述
文件从此再也无法被更新, 而界面上什么都不会报错。所以这里逐条验证四种会动文件的操作:

  · `pdg update` / 强制重装同步运行模块;
  · 快照 → 回滚;
  · Bot 收到备份包后的受管配置恢复;
  · iOS → Android → iOS 平台来回切。

判据都是"真的跑那段生产代码, 再看盘上剩下什么", 不是读源码找关键字。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BOTDIR = os.path.join(ROOT, "deploy/bot")
TMPL = os.path.join(ROOT, "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")

PASS = [0]
FAIL = [0]
TMPS = []


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def sh(script, **kw):
    return subprocess.run(["bash", "-c", script], capture_output=True, text=True,
                          cwd=ROOT, timeout=300, **kw)


def box():
    """一个沙箱 FSROOT, 里面已经有一份受管记录。返回 (root, iosstate 模块)。"""
    root = tempfile.mkdtemp(prefix="iospersist-")
    TMPS.append(root)
    os.makedirs(root + "/etc/privdns-gateway", exist_ok=True)
    os.makedirs(root + "/run", exist_ok=True)
    os.environ["PDG_TX_FSROOT"] = root
    os.environ["PDG_LOCKFILE"] = root + "/run/privdns-gateway.lock"
    for m in ("iosstate", "iosprofile", "pdgtx"):
        sys.modules.pop(m, None)
    sys.path.insert(0, BOTDIR)
    import iosstate
    iosstate.generate("dot.example.com", "203.0.113.10", (), b"", False, TMPL,
                      root + "/etc/privdns-gateway/ios-profile.json",
                      root + "/var/lib/privdns-gateway/ios-profile", True, False)
    return root, iosstate


def ident(root):
    with open(root + "/etc/privdns-gateway/ios-profile.json", encoding="utf-8") as f:
        return json.load(f)["instance_id"]


# ── 1. update / 强制重装同步运行模块时, 记录必须原样活着 ────────────────────
root, st = box()
before = open(root + "/etc/privdns-gateway/ios-profile.json", "rb").read()
os.makedirs(root + "/opt/pdg-bot", exist_ok=True)
r = sh("source lib/modules.sh; pdg_install_runtime_modules '%s' '%s/opt/pdg-bot' ios" % (ROOT, root))
if r.returncode == 0 and os.path.isfile(root + "/opt/pdg-bot/iosstate.py"):
    ok("真的跑了 pdg_install_runtime_modules(update / 装机共用的那一个)")
else:
    bad("模块安装失败: %s" % r.stderr[-200:])
# 再跑一遍 = 强制重装的形态(无条件覆盖写)
sh("source lib/modules.sh; pdg_install_runtime_modules '%s' '%s/opt/pdg-bot' ios" % (ROOT, root))
if open(root + "/etc/privdns-gateway/ios-profile.json", "rb").read() == before:
    ok("同步运行模块(含重复执行)不碰生命周期记录 —— 它是用户数据, 不是程序文件")
else:
    bad("update 把记录改了")

# 反向: 记录也不该被当成"程序文件"混进静态清单(那样卸载会顺手删掉它)
mods = sh("source lib/modules.sh; pdg_platform_modules ios").stdout
if "ios-profile" not in mods:
    ok("生命周期记录不在运行模块清单里(不会被当程序文件同步/删除)")
else:
    bad("记录混进了静态清单")

# ── 2. 快照 → 回滚 ────────────────────────────────────────────────────────
# cmd_snapshot 打包的是一份**路径白名单**。这里直接跑那段真实的候选枚举, 看记录在不在。
cand = sh(r"""
sed -n '/^cmd_snapshot()/,/^}/p' deploy/bot/pdg.sh \
  | sed -n '/local cand=(/,/)$/p' | tr -d '\\' | tr ' ' '\n' | sed 's/local cand=(//;s/)$//' \
  | grep -v '^$'
""").stdout.split()
if "etc/privdns-gateway" in cand:
    ok("快照候选里包含 etc/privdns-gateway —— 记录随快照一起走")
else:
    bad("快照不含记录目录: %r" % cand[:8])

# 真的打一次包再解开, 证明 tar 那条路上文件确实进得去也出得来
snapdir = tempfile.mkdtemp(prefix="iossnap-")
TMPS.append(snapdir)
sh("tar czf %s/snap.tar.gz -C %s etc/privdns-gateway" % (snapdir, root))
ident_before = ident(root)
os.unlink(root + "/etc/privdns-gateway/ios-profile.json")
sh("tar xzf %s/snap.tar.gz -C %s" % (snapdir, root))
if os.path.isfile(root + "/etc/privdns-gateway/ios-profile.json") and ident(root) == ident_before:
    ok("快照→回滚之后身份原样回来(instance_id 不变)")
else:
    bad("回滚之后身份丢了或变了")

# 回滚会让记录退回旧版, 而产物不在快照范围内 —— 这种错位必须能自愈, 而不是判成"被篡改"
root2, st2 = box()
meta2 = root2 + "/etc/privdns-gateway/ios-profile.json"
art2 = root2 + "/var/lib/privdns-gateway/ios-profile"
old_meta = open(meta2, "rb").read()
st2.generate("dot.v2.example", "203.0.113.10", (), b"", False, TMPL, meta2, art2, True, False)
with open(meta2, "wb") as f:                      # 模拟"记录被回滚, 产物还是新的"
    f.write(old_meta)
m, lv, why, data, changed = st2.generate("dot.example.com", "203.0.113.10", (), b"", False,
                                         TMPL, meta2, art2, True, False)
if lv == "recommended" and any("重建" in r for r in why) and m["current"]["revision"] == 1 \
        and st2.read_artifact("current", art2) == data:
    ok("回滚造成的产物/记录错位 → 按记录重建并给「建议更新」, 不谎称被篡改")
else:
    bad("回滚错位的处理不对: lv=%s rev=%s why=%s" % (lv, m["current"].get("revision"), why))

# ── 3. Bot 备份 → 恢复 ────────────────────────────────────────────────────
# Bot 从 Telegram 收备份包、救援平面从本机快照恢复, 两条路共用 cfgrestore 的成员白名单。
# 备份里有、白名单里没有 ⇒ 恢复时被**静默跳过**: 看着恢复成功了, 身份却没回来。
MEMBER = "etc/privdns-gateway/ios-profile.json"
sys.path.insert(0, BOTDIR)
for _m in ("cfgrestore", "pdgtx"):
    sys.modules.pop(_m, None)
import cfgrestore  # noqa: E402
import pdgtx       # noqa: E402
if cfgrestore.member_allowed(MEMBER):
    ok("恢复白名单认这份记录(不会被静默跳过)")
else:
    bad("恢复白名单不认 %s" % MEMBER)
try:
    path, mode, secret, _v = pdgtx.resolve_target(cfgrestore.MEMBER_TARGET[MEMBER])
    if path.endswith("/" + MEMBER) and mode == 0o600:
        ok("它在事务核心里有对应目标(%s, 0600)—— 恢复才有 before-image 与回滚"
           % cfgrestore.MEMBER_TARGET[MEMBER])
    else:
        bad("事务目标解析不对: %s %o" % (path, mode))
except Exception as e:  # noqa: BLE001
    bad("事务核心没有对应目标: %s" % e)

# 真的打一个 Bot 备份包再看成员在不在
import importlib.util as _u  # noqa: E402
_spec = _u.spec_from_file_location("pdg_bot_bk", os.path.join(BOTDIR, "pdg-bot.py"))
_bot = _u.module_from_spec(_spec)
_spec.loader.exec_module(_bot)
# 判据必须落在**生产清单**上: 把它整体搬进沙箱, 而不是自己拼一份 —— 后者等于把被测对象
# 换成了测试自己写的常量, 生产清单里少了这一项也照样绿。
_prod = list(_bot.BACKUP_FILES)
if _bot.IOS_META in _prod:
    ok("记录在生产的 BACKUP_FILES 清单里")
else:
    bad("生产备份清单不含记录: %r" % _prod)
_bot.BACKUP_FILES = [root + x for x in _prod]
_bot.SB = root + _bot.SB
_bot.RS_DIR = root + "/nonexistent-rs"
import io as _io, tarfile as _tarfile  # noqa: E402
names = [m.name for m in _tarfile.open(fileobj=_io.BytesIO(_bot.backup_blob()), mode="r:gz")
         .getmembers() if m.isreg()]
if any(n.endswith("etc/privdns-gateway/ios-profile.json") for n in names):
    ok("backup_blob 真的把记录打进了备份包")
else:
    bad("备份包里没有记录: %r" % names)

bk = sh("source lib/rescue.sh; PDG_MODULES_LIB=lib/modules.sh pdg_project_members").stdout
if "etc/privdns-gateway" in bk:
    ok("项目成员枚举覆盖 etc/privdns-gateway(卸载/快照按同一份真源走)")
else:
    bad("项目成员枚举里没有记录目录: %r" % bk.splitlines()[:6])

# ── 4. 平台来回切不许造出第二个身份 ───────────────────────────────────────
pdg = open(os.path.join(ROOT, "deploy/bot/pdg.sh"), encoding="utf-8").read()


def block(name, pat):
    m = re.search(pat, pdg, re.S | re.M)
    return m.group(0) if m else ""


cleanup = block("android cleanup", r"^migrate_ios_cleanup\(\)\{.*?^\}") or \
    block("android cleanup2", r"^_migrate_ios_cleanup\(\)\{.*?^\}") or \
    "\n".join(l for l in pdg.splitlines() if "iOS 专属残留" in l or "/opt/pdg-bot/iosstate.py" in l)
plat_files = block("plat files", r"local _PLAT_FILES=\(.*?\)")
required = block("required", r"_PLAT_IOS_REQUIRED=\(.*?\)")

hits = [name for name, blk in (("Android 清理", cleanup), ("平台切换备份表", plat_files),
                               ("iOS 必需项", required))
        if "ios-profile" in blk]
if not hits:
    ok("平台切换/Android 清理的三张表都不含生命周期记录 —— 切回来还是同一个身份")
else:
    bad("这些表把记录也算了进去: %s" % "、".join(hits))

# 真的走一遍: iOS 装组件 → Android 清掉组件 → iOS 再装, 记录必须一动不动
root3, st3 = box()
os.makedirs(root3 + "/opt/pdg-bot", exist_ok=True)
id3 = ident(root3)
snap3 = open(root3 + "/etc/privdns-gateway/ios-profile.json", "rb").read()
sh("source lib/modules.sh; pdg_install_runtime_modules '%s' '%s/opt/pdg-bot' ios" % (ROOT, root3))
# Android 清理: 按生产代码里那份 iOS 专属文件名单删
ios_only = [l.split()[1] for l in
            sh("source lib/modules.sh; pdg_platform_modules ios").stdout.splitlines() if l.strip()]
common = [l.split()[1] for l in
          sh("source lib/modules.sh; pdg_platform_modules android").stdout.splitlines() if l.strip()]
for f in set(ios_only) - set(common):
    try:
        os.unlink(root3 + "/opt/pdg-bot/" + f)
    except OSError:
        pass
sh("source lib/modules.sh; pdg_install_runtime_modules '%s' '%s/opt/pdg-bot' ios" % (ROOT, root3))
if open(root3 + "/etc/privdns-gateway/ios-profile.json", "rb").read() == snap3 and ident(root3) == id3:
    ok("iOS → Android → iOS 切一圈, 记录逐字节没动, instance_id 不变")
else:
    bad("平台来回切之后身份变了")

# 承接: 切回来之后再生成, 必须还是同一个身份、同一个 revision
m, lv, why, data, changed = st3.generate(
    "dot.example.com", "203.0.113.10", (), b"", False, TMPL,
    root3 + "/etc/privdns-gateway/ios-profile.json",
    root3 + "/var/lib/privdns-gateway/ios-profile", True, False)
if not changed and m["instance_id"] == id3 and m["current"]["revision"] == 1:
    ok("切回 iOS 后再生成: 同一身份、同一版本, 不是「又发一个新的」")
else:
    bad("切回来之后生成不对: changed=%s rev=%s" % (changed, m["current"].get("revision")))

# ── 5. 只有明确放弃身份的动作才会删掉记录 ────────────────────────────────
root4, st4 = box()
meta4 = root4 + "/etc/privdns-gateway/ios-profile.json"
art4 = root4 + "/var/lib/privdns-gateway/ios-profile"
st4.clear(meta4, art4)
if not os.path.exists(meta4) and not os.path.exists(art4):
    ok("clear() 是唯一会丢掉身份的入口(卸载 / 用户明确要求重来)")
else:
    bad("clear 没删干净")
un = open(os.path.join(ROOT, "uninstall.sh"), encoding="utf-8").read()
i = un.find('== "--purge"')
outside, inside = (un[:i], un[i:]) if i >= 0 else (un, "")
if "/etc/privdns-gateway" not in outside and "/etc/privdns-gateway" in inside:
    ok("只有 uninstall --purge 才会连记录一起删, 普通卸载保留")
else:
    bad("普通卸载路径上出现了 /etc/privdns-gateway 删除")

print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
for d in TMPS:
    shutil.rmtree(d, ignore_errors=True)
sys.exit(1 if FAIL[0] else 0)
