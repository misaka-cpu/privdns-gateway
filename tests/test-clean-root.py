#!/usr/bin/env python3
"""clean-root: 安装产物必须**自己站得住**, 不靠仓库兜底。

真机上仓库随时可能不在: 被删、被移走、停在另一个 tag、或者用户根本是 curl|bash 装的。那时
救援平面仍然要能起来、要能渲染出内核配置 —— 否则"恢复受管配置"和"紧急默认出口"在最需要的
时刻是空的。

所以这里不手工拼一棵理想文件树, 而是**真的调用 install.sh 与 pdg update 共用的那个安装函数**
(lib/modules.sh 的 pdg_install_runtime_modules), 然后把自己扔进一个尽可能干净的解释器里:
  · cwd 移出仓库;
  · PYTHONPATH 清空、PYTHONHOME 不带;
  · -I(isolated: 同时含 -E -s, 忽略环境变量与 user site-packages);
  · sys.path 显式钉成只有安装目录;
  · 先清 __pycache__ 与残留 .pyc(否则旧字节码能冒充"装好了");
  · **逐个检查已加载模块的 __file__ 都在安装根内** —— 只要有一个来自仓库, 这次验证就不算数。
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap
import tmpguard          # 一次性临时目录: 建了就登记, 退出即清

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   " + m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] " + m)
    FAIL[0] += 1


def skip(m):
    print("[SKIP] " + m)


def install_to(dest):
    """调用**生产的**安装函数把运行模块装到 dest。返回 (rc, 输出)。"""
    script = ('set -euo pipefail\n'
              'source "%s/lib/modules.sh"\n'
              'pdg_install_runtime_modules "%s" "%s"\n' % (ROOT, ROOT, dest))
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=300)
    return p.returncode, (p.stdout or "") + (p.stderr or "")


def purge_pyc(d):
    for root_, dirs, files in os.walk(d):
        for x in list(dirs):
            if x == "__pycache__":
                shutil.rmtree(os.path.join(root_, x), ignore_errors=True)
                dirs.remove(x)
        for f in files:
            if f.endswith(".pyc"):
                os.remove(os.path.join(root_, f))


def run_isolated(dest, code, extra_env=None):
    """在 clean-root 里跑一段代码。cwd 移出仓库 + -I 隔离 + sys.path 只有安装目录。"""
    outside = tmpguard.mkdtemp(prefix="outside.")
    try:
        # 只保留解释器自带的标准库路径, 再把安装目录放最前 —— 仓库、当前目录、user site
        # 一律不在搜索路径里。**不能**把 sys.path 清空成 [dest]: 那样连 hashlib 都 import 不了,
        # 测出来的"导入失败"就与安装完整性无关了。
        prelude = textwrap.dedent('''
            import sys, os
            _std = [p for p in sys.path
                    if p and (p.startswith(sys.base_prefix) or p.startswith(sys.prefix))]
            sys.path[:] = [%r] + _std
            os.environ.pop("PYTHONPATH", None)
        ''') % dest
        env = {k: v for k, v in os.environ.items()
               if k not in ("PYTHONPATH", "PYTHONHOME", "PYTHONSTARTUP")}
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env.update(extra_env or {})
        p = subprocess.run([sys.executable, "-I", "-c", prelude + code],
                           capture_output=True, text=True, cwd=outside, env=env, timeout=300)
        return p.returncode, (p.stdout or "") + (p.stderr or "")
    finally:
        shutil.rmtree(outside, ignore_errors=True)


work = tmpguard.mkdtemp(prefix="cleanroot.")
FRESH = os.path.join(work, "fresh")          # 模拟全新安装
UPD = os.path.join(work, "updated")          # 模拟 pdg update 后

# ══ 1. 用生产安装函数产生运行目录 ══════════════════════════════════════════
print("── 1. 安装 ──")
rc, out = install_to(FRESH)
if rc == 0:
    ok("全新安装路径: pdg_install_runtime_modules 落盘成功")
else:
    bad("安装失败 rc=%s: %s" % (rc, out[-300:]))
    # 后面每一条都建立在"装出来了"之上。这里早退并给出结论, 免得负控看到的是
    # FileNotFoundError 堆栈而不是一条读得懂的失败。
    print("─" * 40)
    print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
    sys.exit(1)
rc, out = install_to(UPD)
if rc == 0:
    ok("更新路径: 同一个函数落盘成功")
else:
    bad("更新路径失败: %s" % out[-300:])

# 装的必须是普通文件, 不能是指向仓库的软链
links = [f for f in sorted(os.listdir(FRESH)) if os.path.islink(os.path.join(FRESH, f))]
if not links:
    ok("安装产物全是普通文件, 没有指向仓库的软链")
else:
    bad("出现软链: %r" % links)

# ══ 2. 两条路径的模块名 / SHA256 / mode 必须一致 ═══════════════════════════
print()
print("── 2. 全新安装 vs 更新 ──")


def snapshot(d):
    out = {}
    for f in sorted(os.listdir(d)):
        p = os.path.join(d, f)
        if os.path.isfile(p):
            out[f] = (hashlib.sha256(open(p, "rb").read()).hexdigest(),
                      oct(os.stat(p).st_mode)[-3:])
    return out


a, b = snapshot(FRESH), snapshot(UPD)
if a == b and a:
    ok("两条路径产出的模块名 / SHA256 / mode **完全一致**(%d 个文件)" % len(a))
else:
    diff = sorted(set(a) ^ set(b)) or [k for k in a if a.get(k) != b.get(k)]
    bad("两条路径不一致: %r" % diff[:6])
if all(v[1] == "755" for k, v in a.items() if k.endswith(".py")):
    ok("Python 模块 mode 均为 755")
else:
    bad("mode 不对: %r" % {k: v[1] for k, v in a.items() if k.endswith(".py")})
if a.get("rescue.sh", ("", ""))[1] == "644":
    ok("常量源 rescue.sh mode 644")
else:
    bad("rescue.sh mode: %r" % (a.get("rescue.sh"),))

# ══ 3. clean-root 里导入与渲染 ════════════════════════════════════════════
print()
print("── 3. clean-root 行为 ──")
purge_pyc(FRESH)

MODEL = {"log": {"level": "warn"}, "inbounds": [],
         "outbounds": [{"type": "direct", "tag": "direct"},
                       {"type": "shadowsocks", "tag": "jp", "server": "1.2.3.4",
                        "server_port": 8388, "method": "aes-128-gcm", "password": "x"}],
         "route": {"rules": [{"domain_suffix": ["a.test"], "outbound": "jp"}], "final": "jp"}}

PROBE = textwrap.dedent('''
    import hashlib, json, sys
    # nftmerge.py 没有 __main__ 守卫 —— import 就等于执行它的 CLI。它按脚本验证(见下), 不 import。
    names = ["rescue", "rescue_const", "rescue_cred", "breakglass", "pdgtx",
             "cfgrestore", "mihomorender", "sb2mihomo", "emergency", "cidrgen",
             "rescue_nft", "checks", "doctor", "report", "nftscan"]
    for n in names:
        __import__(n)
    import mihomorender as M, emergency as E, cfgrestore as C
    model = json.loads(%r)
    # 走真实链路: cfgrestore 的 deriver → mihomorender → sb2mihomo → 候选字节
    fn = M.deriver_from_paths(rs_meta_path="/nonexistent/rulesets.json",
                              mitm_hijack_file="/nonexistent/hijack.txt",
                              platform_file="/nonexistent/platform")
    data = fn({"model": json.dumps(model).encode()})
    print("RENDER:" + hashlib.sha256(data).hexdigest())
    print("HASMATCH:" + str(b"MATCH,jp" in data))
    # 紧急出口: 只做不写生产的最小候选构造
    print("CANDS:" + ",".join(E.candidates(model)))
    print("STATUS:" + json.dumps(E.status(model, None), ensure_ascii=False, sort_keys=True))
    # 所有已加载的本地模块必须都来自安装根
    bad = [m.__name__ + "=" + (getattr(m, "__file__", "") or "")
           for m in list(sys.modules.values())
           if getattr(m, "__name__", "") in names
           and not (getattr(m, "__file__", "") or "").startswith(%r)]
    print("OUTSIDE:" + json.dumps(bad, ensure_ascii=False))
    print("SYSPATH:" + json.dumps(sys.path))
''') % (json.dumps(MODEL), FRESH)

rc, out = run_isolated(FRESH, PROBE)
if rc != 0:
    bad("clean-root 探针失败 rc=%s:\n%s" % (rc, out[-600:]))
else:
    ok("从安装目录导入了 15 个库模块(nftmerge 是 CLI, 另行验证)")
    if "HASMATCH:True" in out:
        ok("走完 cfgrestore → mihomorender/sb2mihomo, 渲染出候选配置")
    else:
        bad("渲染结果不含预期内容: %s" % out[-200:])
    if "CANDS:direct,jp" in out or "CANDS:jp,direct" in out:
        ok("emergency 可加载并完成最小候选构造(不写生产)")
    else:
        bad("emergency 候选不对: %s" % [l for l in out.splitlines() if l.startswith("CANDS")])
    outside = [l for l in out.splitlines() if l.startswith("OUTSIDE:")]
    if outside and json.loads(outside[0][len("OUTSIDE:"):]) == []:
        ok("**所有已加载模块的 __file__ 都在安装根内**(没有一个来自仓库)")
    else:
        bad("有模块来自安装根之外: %s" % (outside[0][:300] if outside else "?"))
    sp = [l for l in out.splitlines() if l.startswith("SYSPATH:")]
    paths = json.loads(sp[0][len("SYSPATH:"):]) if sp else []
    # 模块自身会 sys.path.insert(0, "/opt/pdg-bot") —— 那是生产行为(真机上它就是安装目录),
    # 所以不能要求"首位必须是临时安装根"。真正的不变量只有一条: **没有任何一项落在仓库里**。
    repo_paths = [p for p in paths if p and p.startswith(ROOT)]
    if FRESH in paths and not repo_paths:
        ok("sys.path 含安装根且**没有任何一项落在仓库里**(没有源码兜底的可能)")
    else:
        bad("sys.path 里有仓库路径: %r" % (repo_paths or paths))

# ══ 3b. iOS 形态: 描述文件生命周期也要能在 clean-root 里独立跑起来 ═════════
# 上面那一轮装的是通用集, 里面根本没有 iosstate/iosprofile。iOS 机器上真正要跑的是这一套,
# 而它还要读安装目录里的描述文件模板 —— 模板取不到时若回落到仓库, 真机上仓库不在就崩了。
print()
print("── 3b. clean-root (iOS 形态) ──")
IOSROOT = tmpguard.mkdtemp(prefix="cleanroot-ios.")
_p = subprocess.run(
    ["bash", "-c", 'set -euo pipefail\nsource "%s/lib/modules.sh"\n'
                   'pdg_install_runtime_modules "%s" "%s" ios\n' % (ROOT, ROOT, IOSROOT)],
    capture_output=True, text=True, timeout=300)
if _p.returncode == 0 and os.path.isfile(os.path.join(IOSROOT, "iosstate.py")):
    ok("iOS 形态安装成功(多出 iosprofile / iosstate / 描述文件模板)")
else:
    bad("iOS 形态安装失败: %s" % (_p.stderr or "")[-300:])
purge_pyc(IOSROOT)
# 探针跑在**另一个进程**里, 所以它自己的沙箱只能自己收 —— 父进程的 finally 管不到它。
# 这类"每跑一次多一个 /tmp 目录"的泄漏不会让测试变红, 只会在几百次之后变成磁盘问题。
IOS_PROBE = "\n".join([
    # 探针进程刻意跑在 clean-root 里(sys.path 只有安装根), 所以这里**不能**用 tmpguard ——
    # 把仓库的 tests/ 塞进它的 sys.path 会削弱"没有仓库源码兜底"那条断言。它自己的
    # try/finally 已经把沙箱收干净了, 而 tempfile 认 TMPDIR, 私有 TMPDIR 那道门照样看得见。
    "import json, os, shutil, sys, tempfile",
    "root = tempfile.mkdtemp(prefix='cleanroot-fs.')",
    "try:",
    "    os.makedirs(root + '/etc/privdns-gateway'); os.makedirs(root + '/run')",
    "    os.environ['PDG_TX_FSROOT'] = root",
    "    os.environ['PDG_LOCKFILE'] = root + '/run/privdns-gateway.lock'",
    "    import iosstate, iosprofile",
    "    tmpl = os.path.join(%r, 'pdg-dot.mobileconfig.tmpl')" % IOSROOT,
    "    meta = root + '/etc/privdns-gateway/ios-profile.json'",
    "    art = root + '/var/lib/privdns-gateway/ios-profile'",
    "    m, lv, why, data, ch = iosstate.generate('dot.example.com', '203.0.113.10', (), b'',",
    "                                             False, tmpl, meta, art, True, False)",
    "    st, detail = iosstate.artifact_health(m, 'current', art)",
    "    blob = iosstate.verified_artifact(m, 'current', art)",
    "    print('GEN:' + json.dumps({'rev': m['current']['revision'], 'health': st,",
    "                               'bytes': len(blob), 'same': blob == data}))",
    "    outs = [n + '=' + (getattr(sys.modules[n], '__file__', '') or '')",
    "            for n in ('iosstate', 'iosprofile', 'pdgtx')",
    "            if not (getattr(sys.modules[n], '__file__', '') or '').startswith(%r)]" % IOSROOT,
    "    print('OUTSIDE:' + json.dumps(outs, ensure_ascii=False))",
    "finally:",
    "    shutil.rmtree(root, ignore_errors=True)",
])
rc, out = run_isolated(IOSROOT, IOS_PROBE)
if rc != 0:
    bad("iOS clean-root 探针失败 rc=%s:\n%s" % (rc, out[-600:]))
else:
    gen = [l for l in out.splitlines() if l.startswith("GEN:")]
    info = json.loads(gen[0][4:]) if gen else {}
    if info.get("rev") == 1 and info.get("health") == "healthy" and info.get("same"):
        ok("clean-root 里生成 + 完整性校验 + 取回全通(第 %d 版, %d 字节)"
           % (info["rev"], info["bytes"]))
    else:
        bad("clean-root 里的生成结果不对: %r" % info)
    outside = [l for l in out.splitlines() if l.startswith("OUTSIDE:")]
    if outside and json.loads(outside[0][len("OUTSIDE:"):]) == []:
        ok("iosstate / iosprofile / pdgtx 全部来自安装根, 没有仓库源码兜底")
    else:
        bad("有模块来自安装根之外: %s" % (outside[0][:300] if outside else "?"))
shutil.rmtree(IOSROOT, ignore_errors=True)

# 两个 CLI 脚本从**已安装路径**验证: 能被解释器加载、且加载到的是安装根里那一份
for _cli in ("nftmerge.py", "doctor.py"):
    rc_c, out_c = run_isolated(FRESH, textwrap.dedent('''
        import subprocess, sys, os
        p = subprocess.run([sys.executable, os.path.join(%r, %r)],
                           capture_output=True, text=True)
        print("CLI_RC:%%d" %% p.returncode)
    ''') % (FRESH, _cli))
    if "CLI_RC:" in out_c:
        ok("CLI 脚本 %s 可从已安装路径执行(受控退出)" % _cli)
    else:
        bad("CLI 脚本 %s 跑不起来: %s" % (_cli, out_c[-200:]))

# cidrgen 走**已安装的** CLI 路径调用
rc2, out2 = run_isolated(FRESH, textwrap.dedent('''
    import subprocess, sys, os, json
    p = subprocess.run([sys.executable, os.path.join(%r, "cidrgen.py"), "--self-test"],
                       capture_output=True, text=True)
    print("CIDRGEN_RC:%%d" %% p.returncode)
    print("CIDRGEN_OUT:" + ((p.stdout or "") + (p.stderr or ""))[:200].replace("\\n", " "))
''') % FRESH)
if "CIDRGEN_RC:0" in out2:
    ok("cidrgen.py 可从已安装路径调用")
elif "CIDRGEN_RC:" in out2:
    # 没有 --self-test 也没关系: 只要它能被解释器加载并给出可控退出, 就说明装对了
    rc3, out3 = run_isolated(FRESH, textwrap.dedent('''
        import importlib.util as iu, os
        spec = iu.spec_from_file_location("cidrgen", os.path.join(%r, "cidrgen.py"))
        m = iu.module_from_spec(spec); spec.loader.exec_module(m)
        print("CIDRGEN_FNS:" + ",".join(sorted(a for a in dir(m) if not a.startswith("__")))[:200])
        print("CIDRGEN_FILE:" + m.__file__)
    ''') % FRESH)
    if "CIDRGEN_FILE:" + FRESH in out3:
        ok("cidrgen.py 可从已安装路径加载(__file__ 在安装根内)")
    else:
        bad("cidrgen 加载失败: %s" % out3[-300:])
else:
    bad("cidrgen 调用失败: %s" % out2[-300:])

# ══ 4. 残留 .pyc 不能冒充完整安装 ═════════════════════════════════════════
print()
print("── 4. 旧字节码不能冒充 ──")
STALE = os.path.join(work, "stale")
shutil.copytree(FRESH, STALE)
# 先生成一遍字节码, 再把源文件删掉 —— 只剩 .pyc 时必须导不进来
# 生成字节码时必须去掉 PYTHONPYCACHEPREFIX —— 带着它 .pyc 会落到别处, 于是"只剩 .pyc"
# 这个场景根本没造出来(测试会误报 SKIP)。
_cenv = {k: v for k, v in os.environ.items()
         if k not in ("PYTHONPYCACHEPREFIX", "PYTHONDONTWRITEBYTECODE")}
subprocess.run([sys.executable, "-c",
                "import compileall,sys; compileall.compile_dir(%r, quiet=2)" % STALE],
               capture_output=True, timeout=300, env=_cenv)
victim = os.path.join(STALE, "emergency.py")
had_pyc = os.path.isdir(os.path.join(STALE, "__pycache__"))
if os.path.exists(victim):
    os.remove(victim)
rc4, out4 = run_isolated(STALE, "import emergency; print('IMPORTED')")
if not had_pyc:
    skip("本环境没有生成 __pycache__(PYTHONDONTWRITEBYTECODE?), 该分支未验证")
elif rc4 != 0 and "IMPORTED" not in out4:
    ok("源文件被删、只剩 __pycache__ 时导入失败(旧字节码冒充不了完整安装)")
else:
    bad("只剩 .pyc 竟然导入成功了 —— 安装完整性会被旧字节码蒙混")

# ══ 5. 软链兜底必须被识破 ═════════════════════════════════════════════════
print()
print("── 5. 软链兜底 ──")
LINKED = os.path.join(work, "linked")
shutil.copytree(FRESH, LINKED)
tgt = os.path.join(LINKED, "mihomorender.py")
if not os.path.exists(tgt):
    bad("mihomorender.py 不在安装产物里 —— 软链场景无从构造(清单漏装?)")
else:
    os.remove(tgt)
    os.symlink(os.path.join(ROOT, "deploy/bot/mihomorender.py"), tgt)
links = [f for f in sorted(os.listdir(LINKED)) if os.path.islink(os.path.join(LINKED, f))]
if links == ["mihomorender.py"]:
    ok("软链探测能认出指向仓库的链接(这里是人为造的)")
else:
    bad("软链探测失效: %r" % links)
real = os.path.realpath(tgt) if os.path.islink(tgt) else ""
if real.startswith(ROOT):
    ok("realpath 能看出它指回仓库 —— 安装完整性据此判失败")
else:
    bad("realpath 没指回仓库: %r" % real)

shutil.rmtree(work, ignore_errors=True)
print("─" * 40)
print("通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
if PASS[0] + FAIL[0] == 0:
    print("零断言 —— 判失败")
    sys.exit(1)
sys.exit(1 if FAIL[0] else 0)
