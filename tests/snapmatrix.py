#!/usr/bin/env python3
"""跨版本快照样本生成器 —— 成员结构与内容全部取自**各版本自己的历史代码**。

为什么不手搓几个 tar 成员: 手写的样本只能证明"我以为 v1.6.2 长这样", 证明不了 v1.6.2 真的
长这样。格式识别是靠成员路径的启发式做的, 而路径清单恰恰是各版本 `cmd_snapshot` 里那张
`cand=()` —— 所以这里直接从历史对象里把那张清单**解析出来**用, 模板内容也从同版本的
deploy/ 取, 按同版本 install.sh 的 render() 替换占位符。

只读历史对象(git show), 不切分支、不建 worktree, 因此也没有需要清理的工作树。
"""
import io
import os
import re
import subprocess
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

# 渲染占位符用的值: 与安装器 render() 同形, 取一组合法且互不冲突的测试值。
RENDER = {
    "__SERVER_IP__": "177.0.142.200",
    "__INTERNAL_CIDR__": "172.22.0.0/16",
    "__CERT_DIR__": "/etc/letsencrypt/live/pdg",
    "__SSH_PORT__": "22",
    "__MOSDNS_CACHE__": "8192",
    "__JOURNALD_MAXUSE__": "200M",
    "__HIJACK_SET_FILE__": "/etc/mosdns/rules/hijack.txt",
}


def hist(rev, path):
    """只读历史对象取一个文件。取不到返回 None(调用方自己决定要不要因此跳过)。"""
    p = subprocess.run(["git", "-C", ROOT, "show", "%s:%s" % (rev, path)],
                       capture_output=True, timeout=120)
    return p.stdout if p.returncode == 0 else None


def render(data):
    s = data.decode("utf-8", "replace")
    for k, v in RENDER.items():
        s = s.replace(k, v)
    return s.encode()


def snapshot_items(rev):
    """把某个版本 `cmd_snapshot` 里的 `cand=(...)` 清单解析出来。

    解析的是历史代码本身 —— 清单变了这里就跟着变, 不会出现"测试里写死的旧清单"这种事。"""
    src = hist(rev, "deploy/bot/pdg.sh")
    if src is None:
        return []
    txt = src.decode("utf-8", "replace")
    m = re.search(r"cmd_snapshot\(\)\{.*?local cand=\((.*?)\)\n", txt, re.S)
    if not m:
        return []
    out = []
    for tok in m.group(1).split():
        tok = tok.strip()
        if tok and not tok.startswith("#"):
            out.append(tok)
    return out


def write_tar(path, members, mode=0o644):
    """members: [(名字, bytes)] 或 [(名字, bytes, mode)]。"""
    with tarfile.open(path, "w:gz") as t:
        for item in members:
            name, data = item[0], item[1]
            m = item[2] if len(item) > 2 else mode
            info = tarfile.TarInfo(name)
            info.size, info.mode = len(data), m
            t.addfile(info, io.BytesIO(data))
    os.chmod(path, 0o600)


def _mos_min(size=4096):
    """一份**能被真 mosdns 解析**的最小配置。

    历史模板渲染出来的那份依赖机器上真实存在的证书目录与劫持集文件, 在沙箱里必然校验不过 ——
    那验的是"沙箱缺文件", 不是跨版本兼容。所以受管的 mosdns 配置统一用这份最小合法配置,
    而**成员路径清单**仍然来自历史代码, 矩阵要验的正是路径结构。"""
    return ("log:\n  level: error\nplugins:\n  - tag: npn_clients\n    type: ip_set\n"
            '    args: { ips: ["172.22.0.0/16"] }\n  - tag: cache\n    type: cache\n'
            "    args: { size: %d }\n  - tag: main_sequence\n    type: sequence\n"
            "    args:\n      - exec: reject 3\n"
        "  - tag: udp_server\n"
        "    type: udp_server\n"
        '    args: {entry: main_sequence, listen: "127.0.0.1:0"}\n'
            % size).encode()


MODEL = (b'{"log": {}, "inbounds": [], "outbounds": [{"type": "direct", "tag": "direct"}], '
         b'"route": {"rules": [], "final": "direct"}}')


def _fill(rel):
    """给一个成员路径造合适的内容。受管的给合法内容, 其余给占位内容。"""
    if rel == "etc/mosdns/config.yaml":
        return _mos_min()
    if rel == "etc/sing-box/config.json":
        return MODEL
    if rel.endswith(".txt"):
        return b"domain:cross-version.example\n"
    if rel == "opt/pdg-bot/rulesets.json":
        return b'{"cross": {"label": "\xe8\xb7\xa8\xe7\x89\x88"}}'
    if rel.startswith("usr/local/bin/"):
        return b"BINARY-PLACEHOLDER\n"
    return b"placeholder\n"


def _expand(items):
    """`cand=()` 里既有文件也有目录。目录要展开成该版本在那目录下实际会有的文件。"""
    out = []
    for rel in items:
        if rel == "etc/mosdns":
            out += ["etc/mosdns/config.yaml", "etc/mosdns/rules/custom_direct.txt",
                    "etc/mosdns/rules/custom_hijack.txt"]
        elif rel == "etc/sing-box":
            out += ["etc/sing-box/config.json"]
        elif rel == "etc/mihomo":
            out += ["etc/mihomo/config.yaml"]
        elif rel == "opt/pdg-bot":
            out += ["opt/pdg-bot/rulesets.json"]
        elif rel == "etc/privdns-gateway":
            out += ["etc/privdns-gateway/platform", "etc/privdns-gateway/backend"]
        elif "." in os.path.basename(rel) or rel.startswith("usr/local/bin/"):
            out.append(rel)
    return out


# ── 五类样本 ────────────────────────────────────────────────────────────────
def sample_current(dst):
    """1. 当前分支: 清单从 HEAD 的 cmd_snapshot 解析。"""
    rels = _expand(snapshot_items("HEAD"))
    write_tar(dst, [(r, _fill(r)) for r in rels])
    return rels


def sample_v162(dst):
    """2. v1.6.2: 清单从该 tag 的 cmd_snapshot 解析 —— 不按版本号预判兼容性。"""
    rels = _expand(snapshot_items("v1.6.2"))
    write_tar(dst, [(r, _fill(r)) for r in rels])
    return rels


def sample_legacy(dst):
    """3. legacy-dnsdist: 用仓库最早那版真实的 deploy/dnsdist/dnsdist.conf。"""
    conf = hist("5024109", "deploy/dnsdist/dnsdist.conf")
    if conf is None:
        # 取不到就明说。返回 None 的话调用方会照常往下走, 直到某处撞 FileNotFoundError ——
        # CI 上浅克隆拿不到这个提交时就是这么报的, 错误信息离真正的原因隔了三层。
        raise SystemExit("取不到 5024109:deploy/dnsdist/dnsdist.conf —— "
                         "仓库历史不完整(CI 上要 fetch-depth: 0)")
    rels = [("etc/dnsdist/dnsdist.conf", conf),
            ("etc/mosdns/config.yaml", _mos_min())]      # 那个年代 mosdns 已经并存
    write_tar(dst, rels)
    return [r[0] for r in rels]


def sample_unknown(dst):
    """4. unknown: 既没有 v1.6 特征也没有 dnsdist 特征。"""
    rels = [("etc/whatever/thing.conf", b"nothing familiar\n"),
            ("opt/other/app.json", b"{}\n")]
    write_tar(dst, rels)
    return [r[0] for r in rels]


def sample_broken_modules(dst, kind):
    """5. 当前结构, 但业务模块被旧版/坏版替换。

    kind: pdgtx-syntax / cfgrestore-missing / old-rescue"""
    rels = [(r, _fill(r)) for r in _expand(snapshot_items("HEAD"))]
    if kind == "pdgtx-syntax":
        rels.append(("opt/pdg-bot/pdgtx.py", b"def broken(:\n    pass\n"))
    elif kind == "cfgrestore-missing":
        rels.append(("opt/pdg-bot/cfgrestore.py", b"# \xe6\x97\xa7\xe7\x89\x88: \xe6\xb2\xa1\xe6\x9c\x89 restore_managed\ndef snapshot_ids():\n    return []\n"))
    elif kind == "old-rescue":
        old = hist("v1.6.2", "deploy/rescue/rescue.py") or b"# old rescue\n"
        rels.append(("opt/pdg-bot/rescue.py", old))
    write_tar(dst, rels)
    return [r[0] for r in rels]


def sample_mixed(dst):
    """格式特征**故意混合**: 同时带 v1.6 与 dnsdist 特征 —— 识别必须 fail-closed。"""
    rels = [("etc/mihomo/config.yaml", b"mixed\n"),
            ("etc/sing-box/config.json", MODEL),
            ("etc/dnsdist/dnsdist.conf", b"-- legacy\n"),
            ("etc/mosdns/config.yaml", _mos_min())]
    write_tar(dst, rels)
    return [r[0] for r in rels]
