#!/usr/bin/env python3
"""MITM 叶子证书**并发**回归(Item 8)。

旧实现: leaf_cert 多线程共享同一个 crt/key ".tmp" 文件名 + -CAcreateserial 的共享 ca.srl,
首个并发即抛 FileNotFoundError / 签出不匹配的 cert-key。本测试锁定并发安全:
  A. 无预置 CA 下 ≥24 线程并发签发(混合同域 + 多域): 0 异常, 每对 crt/key 都有效、
     互相匹配(同一 EC 公钥)、SAN/EKU 正确、链到 CA; leaf 目录无残留 .tmp。
  B. 同一域名的所有并发结果指向同一对文件(只签一份)。
  C. 跨进程: 多个独立进程同时对同一新域名签发, 全部成功且只产出一份匹配证书(flock 生效)。
"""
import concurrent.futures as cf
import glob
import os
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BOT = ROOT / "deploy" / "bot"
sys.path.insert(0, str(BOT))
import mitm_ca  # noqa: E402

pass_n = 0


def ok(m):
    global pass_n
    print("[OK]  ", m)
    pass_n += 1


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def _pubkey_from_cert(crt):
    return run(["openssl", "x509", "-in", crt, "-noout", "-pubkey"]).stdout.strip()


def _pubkey_from_key(key):
    return run(["openssl", "pkey", "-in", key, "-pubout"]).stdout.strip()


def main():
    if run(["openssl", "version"]).returncode != 0:
        print("[SKIP] 无 openssl")
        return
    tmp = tempfile.mkdtemp()
    mitm_ca.CA_DIR = os.path.join(tmp, "ca")     # 故意不预置 CA: 让 ensure_ca 也被并发压

    # ── A/B. 24 线程并发, 无预置 CA, 混合域名 ──────────────────────────────────
    domains = (["gs-loc.apple.com"] * 16 + ["gs-loc-cn.apple.com"] * 6
               + ["a.example"] * 2)              # 24 次, 同域为主 + 多域
    errors, results = [], {}
    with cf.ThreadPoolExecutor(max_workers=24) as ex:
        futs = {ex.submit(mitm_ca.leaf_cert, d): d for d in domains}
        for fut in cf.as_completed(futs):
            d = futs[fut]
            try:
                results.setdefault(d, []).append(fut.result())
            except Exception as e:  # noqa: BLE001
                errors.append((d, repr(e)))
    assert not errors, f"并发签发出现异常: {errors[:3]}"
    ok("24 线程并发(含 ensure_ca 竞争)0 异常")

    ca = mitm_ca._p("ca.crt")
    for d, pairs in results.items():
        # B. 同域所有并发结果指向同一对文件
        assert len({p for p in pairs}) == 1, f"{d}: 同域并发返回了不同文件路径 {set(pairs)}"
        crt, key = pairs[0]
        assert os.path.isfile(crt) and os.path.isfile(key), f"{d}: crt/key 不存在"
        # 链到 CA
        v = run(["openssl", "verify", "-CAfile", ca, crt])
        assert v.returncode == 0 and "OK" in v.stdout, f"{d}: 验链失败 {v.stdout}{v.stderr}"
        # cert 与 key 公钥匹配(否则是两次签发交叉污染)
        pc, pk = _pubkey_from_cert(crt), _pubkey_from_key(key)
        assert pc and pc == pk, f"{d}: cert 与 key 公钥不匹配(交叉污染)"
        # SAN / EKU
        lt = run(["openssl", "x509", "-in", crt, "-noout", "-text"]).stdout
        assert f"DNS:{d}" in lt, f"{d}: SAN 缺失"
        assert "TLS Web Server Authentication" in lt, f"{d}: serverAuth EKU 缺失"
    ok("每域: 同域并发指向同一对文件, 验链通过, cert/key 公钥匹配, SAN/EKU 正确")

    # 无残留临时文件(私有子目录已随 TemporaryDirectory 清理; leaf 目录只应有 .crt/.key/.lock)
    leaf_dir = mitm_ca._p("leaf")
    stray = [f for f in os.listdir(leaf_dir)
             if not (f.endswith(".crt") or f.endswith(".key") or f.endswith(".lock"))]
    assert not stray, f"leaf 目录残留非预期文件: {stray}"
    assert not glob.glob(os.path.join(leaf_dir, "*.tmp")), "残留 .tmp 文件"
    assert not glob.glob(os.path.join(mitm_ca.CA_DIR, "*.tmp")), "CA 目录残留 .tmp"
    ok("无残留 .tmp(叶子目录 / CA 目录均干净)")

    # ── C. 跨进程并发: 多个独立进程同时对同一新域名签发 ───────────────────────
    dom = "cross.example"
    code = (f"import sys; sys.path.insert(0, {str(BOT)!r}); "
            f"import mitm_ca; mitm_ca.CA_DIR={mitm_ca.CA_DIR!r}; "
            f"c,k=mitm_ca.leaf_cert({dom!r}); print(c)")
    procs = [subprocess.Popen([sys.executable, "-c", code],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
             for _ in range(8)]
    outs = [p.communicate() for p in procs]
    rcs = [p.returncode for p in procs]
    assert all(rc == 0 for rc in rcs), f"跨进程签发有失败: {[o[1][-200:] for o, rc in zip(outs, rcs) if rc]}"
    crts = {o[0].strip() for o in outs}
    assert len(crts) == 1, f"跨进程应产出同一份证书, 实得 {crts}"
    crt = crts.pop()
    key = crt[:-4] + ".key"
    assert _pubkey_from_cert(crt) == _pubkey_from_key(key), "跨进程 cert/key 公钥不匹配"
    assert run(["openssl", "verify", "-CAfile", ca, crt]).returncode == 0, "跨进程证书验链失败"
    ok("8 进程并发同域: 全部成功 + 单份匹配证书(flock 跨进程串行生效)")

    print(f"\n通过 {pass_n} 项断言")


if __name__ == "__main__":
    main()
