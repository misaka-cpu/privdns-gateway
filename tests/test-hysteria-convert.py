#!/usr/bin/env python3
"""Hysteria v1/v2 转换回归(sb2mihomo)。

历史 bug: hysteria(v1)与 hysteria2 被一并塞进 mihomo type:hysteria2 —— v1 与 v2 是
**不同协议**(不同握手/鉴权/拥塞), 这样转出来 mihomo 能过 `-t` 却运行期连不上(静默错)。

本测试锁定:
  A. v1 → mihomo type:hysteria(auth_str→auth-str, up/down, obfs 字符串, protocol,
     alpn/sni/skip-cert-verify, recv-window*), 不再变成 hysteria2。
  B. v2 → mihomo type:hysteria2(password + obfs{type,password}→obfs/obfs-password), 保持。
  C. 不支持的协议 → convert_proxy 返回 None + meta.unknown_proxies 报告(不静默丢弃)。
  D. 有钉死版 mihomo 时跑真 `mihomo -t`: v1+v2 混合配置被接受(schema 真通过)。
"""
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
import sb2mihomo  # noqa: E402

pass_n = 0


def ok(msg):
    global pass_n
    print("[OK]   " + msg)
    pass_n += 1


# ── A. Hysteria v1 → type:hysteria ───────────────────────────────────────────
v1 = {"type": "hysteria", "tag": "hyv1", "server": "1.2.3.4", "server_port": 443,
      "auth_str": "secretpw", "up_mbps": 50, "down_mbps": 200, "obfs": "myobfs",
      "protocol": "faketcp", "recv_window_conn": 1234, "recv_window": 5678,
      "tls": {"enabled": True, "server_name": "h1.example", "insecure": True, "alpn": ["h3"]}}
p = sb2mihomo.convert_proxy(v1)
assert p["type"] == "hysteria", f"v1 应转成 type:hysteria, 实为 {p['type']}"
ok("v1 → type:hysteria(不再被误判成 hysteria2)")
assert p["auth-str"] == "secretpw" and "password" not in p, "auth_str 应映射成 auth-str, 不带 password"
ok("v1 auth_str → auth-str")
assert p["up"] == "50 Mbps" and p["down"] == "200 Mbps", f"带宽映射错: {p.get('up')}/{p.get('down')}"
ok("v1 up_mbps/down_mbps → up/down '50 Mbps'/'200 Mbps'")
assert p["obfs"] == "myobfs", "v1 obfs 应是字符串(非 {type,password})"
ok("v1 obfs 字符串直传")
assert p["protocol"] == "faketcp", "protocol 应透传"
ok("v1 protocol 透传")
assert p["sni"] == "h1.example" and p["skip-cert-verify"] is True and p["alpn"] == ["h3"]
ok("v1 sni/skip-cert-verify/alpn")
assert p["recv-window-conn"] == 1234 and p["recv-window"] == 5678
ok("v1 recv-window-conn/recv-window")

# v1 用 auth(base64 字节)而非 auth_str
p2 = sb2mihomo.convert_proxy({"type": "hysteria", "tag": "hb", "server": "1.1.1.1",
                              "server_port": 1, "auth": "YWJj", "up": "10 Mbps", "down": "10 Mbps"})
assert p2["auth"] == "YWJj" and "auth-str" not in p2, "auth(字节) 应映射成 auth, 不出 auth-str"
ok("v1 auth(base64 字节)→ auth")

# ── B. Hysteria2 → type:hysteria2(保持) ─────────────────────────────────────
v2 = {"type": "hysteria2", "tag": "hyv2", "server": "5.6.7.8", "server_port": 443,
      "password": "pw2", "obfs": {"type": "salamander", "password": "op"},
      "tls": {"enabled": True, "server_name": "h2.example", "alpn": ["h3"], "insecure": False}}
q = sb2mihomo.convert_proxy(v2)
assert q["type"] == "hysteria2" and q["password"] == "pw2", "v2 应保持 type:hysteria2 + password"
ok("v2 → type:hysteria2 + password")
assert q["obfs"] == "salamander" and q["obfs-password"] == "op", "v2 obfs → obfs/obfs-password"
ok("v2 obfs{type,password} → obfs/obfs-password")
assert q["sni"] == "h2.example" and q["alpn"] == ["h3"]
ok("v2 sni/alpn")
assert "auth-str" not in q and "up" not in q, "v2 不应带 v1 专属字段(auth-str/up)"
ok("v2 不混入 v1 字段")

# ── C. 不支持协议 → None + unknown_proxies 报告(不静默丢弃) ────────────────
# shadowtls 在 PROXY_TYPES 里(sing-box 下是合法出口)但 mihomo 无对应转换 → 必须被报告,
# 否则切 mihomo 时这个出口凭空消失。这正是"列出口前拒绝"守卫要拦的真实场景。
assert "shadowtls" in sb2mihomo.PROXY_TYPES
assert sb2mihomo.convert_proxy({"type": "shadowtls", "tag": "st", "server": "x",
                                "server_port": 1}) is None
ok("不支持协议(shadowtls: 在 PROXY_TYPES 内但 mihomo 无对应)→ convert_proxy None")
sb_bad = {"outbounds": [{"type": "shadowtls", "tag": "st", "server": "x", "server_port": 1},
                        {"type": "direct", "tag": "jp"}],
          "route": {"rules": [], "final": "jp"}}
_, meta = sb2mihomo.singbox_to_mihomo(sb_bad)
assert meta["unknown_proxies"] == ["st"], f"未知出口应被报告, 实为 {meta['unknown_proxies']}"
ok("未知出口进 meta.unknown_proxies(供 switch-core/apply 拒绝, 不静默丢)")

# ── D. 真 mihomo -t: v1+v2 混合配置 schema 通过 ───────────────────────────────
sb_mix = {"outbounds": [v1, v2, {"type": "direct", "tag": "jp"}],
          "route": {"rules": [{"ip_cidr": ["127.0.0.0/8"], "action": "reject"},
                              {"domain_suffix": ["a.test"], "outbound": "hyv1"},
                              {"domain_suffix": ["b.test"], "outbound": "hyv2"}],
                    "final": "jp"}}
cfg, _ = sb2mihomo.singbox_to_mihomo(sb_mix, redir_port=7893)
json.dumps(cfg)  # JSON 即合法 YAML


def _find_mihomo():
    """定位钉死版内核: 一律走共享 helper(tests/mihomobin.py), 不在这里另写一套。

    老写法认 MIHOMO_BIN、PATH、/tmp/mihomo 三处, 且**不核版本** —— 机器上随便一版 mihomo
    都能让这条断言变绿, 而它的全部意义就是"钉死版认不认这份配置"。"""
    sys.path.insert(0, str(ROOT / "tests"))
    import mihomobin
    try:
        return mihomobin.find()[0]
    except mihomobin.MihomoWrongVersion as e:
        raise AssertionError("mihomo 版本不符, 不接受用别的版本顶替: %s" % e) from None
    except mihomobin.MihomoMissing:
        if mihomobin.strict_mode():
            raise AssertionError(
                "严格模式(CI/全量入口)下缺钉死版 mihomo —— 先跑 tests/prepare-mihomo.sh") from None
    got = _download_mihomo()          # 单跑且本机没有: 允许现下一份(仍逐字节校验 SHA256)
    if got and mihomobin.version_of(got) != mihomobin.pinned_version():
        raise AssertionError("下载到的 mihomo 不是钉死版")
    return got


def _download_mihomo():
    """按 lib/versions.sh 钉死的版本+SHA256 下载 mihomo; 失败(无网)返回 None。"""
    vs = (ROOT / "lib" / "versions.sh").read_text()
    ver = re.search(r'MIHOMO_VER="([^"]+)"', vs)
    arch = {"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64"}.get(os.uname().machine)
    if not ver or not arch:
        return None
    ver = ver.group(1)
    sha = re.search(r'\[mihomo-%s\]="([0-9a-f]+)"' % arch, vs)
    if not sha:
        return None
    url = (f"https://github.com/MetaCubeX/mihomo/releases/download/{ver}/"
           f"mihomo-linux-{arch}-{ver}.gz")
    try:
        with urllib.request.urlopen(url, timeout=30) as r:
            gz = r.read()
    except Exception:  # noqa: BLE001  无网/被墙: 环境缺失, 非配置问题
        return None
    if hashlib.sha256(gz).hexdigest() != sha.group(1):
        return None
    dst = Path(tempfile.gettempdir()) / "mihomo"
    dst.write_bytes(gzip.decompress(gz))
    dst.chmod(0o755)
    return str(dst)


mihomo = _find_mihomo()
if mihomo:
    with tempfile.TemporaryDirectory() as d:
        Path(d, "config.yaml").write_text(json.dumps(cfg, ensure_ascii=False, indent=2))
        r = subprocess.run([mihomo, "-t", "-d", d, "-f", os.path.join(d, "config.yaml")],
                           capture_output=True, text=True)
        assert r.returncode == 0, "mihomo -t 拒绝了 v1+v2 渲染:\n" + (r.stdout + r.stderr)[-500:]
    ok(f"真 mihomo -t 接受 v1+v2 混合渲染({os.path.basename(mihomo)})")
else:
    print("[SKIP] 本机无钉死版 mihomo 且下载不到(环境缺失) —— 真 -t 校验未执行, 不是通过")

print(f"────────────────────────────────────────\n通过 {pass_n}")
