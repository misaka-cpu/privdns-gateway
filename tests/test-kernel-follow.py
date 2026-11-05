#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""内核跟随上游(kernelfollow.py)的判定与记录 + doctor 两条 mihomo 判据的跟随分支。

kernelfollow.py 是"认不认 / 能不能换"的唯一一份: pdg update 的保留判据、doctor、`pdg kernel`
都调它。所以这里把每条判据都配一份**只差一处**的反例, 先确认基线那份确实通过(不是空测),
再看反例被拒:
  · 版本护栏: 已是 / 低于钉值 / 跨大版本 / 形态不对;
  · 上游取件信息: prerelease / draft 必须明确是 False、tag 形态、资产精确名恰好一个、
    必须有 sha256 digest、下载 URL 由我们拼(不用应答里的 browser_download_url);
  · ELF: 架构 / 位数 / 字节序;
  · 本机记录: 默认跟发布、原子写 0600、坏记录不被静默抹平、previous 的挪动规则;
  · 认不认: 五件事同时成立, 且**先证内容再执行**(摘要不符的文件一次都不跑);
  · 体检对照: 只认"前像 ok → 后像不 ok"为退步;
  · doctor: 跟上游且被认 → ok 并说明是跟随; 其余照旧按钉值判。
网络与管理面全部打桩: 本测试不连外网, 也不连任何管理端口。
"""
import contextlib
import datetime
import hashlib
import io
import json
import os
import stat
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))
import kernelfollow as kf  # noqa: E402
import checks  # noqa: E402
import tmpguard  # noqa: E402  一次性临时目录: 建了就登记, 退出即清

PASS = [0]
FAIL = [0]


def ok(m):
    print("[OK]   %s" % m)
    PASS[0] += 1


def bad(m):
    print("[FAIL] %s" % m)
    FAIL[0] += 1


def check(cond, m):
    (ok if cond else bad)(m)


WORK = tmpguard.mkdtemp(prefix="pdg-kfollow.")
ETC = os.path.join(WORK, "etc")
os.makedirs(ETC)
kf.STATE = os.path.join(ETC, "kernel.json")
PIN = "v1.19.33"
D64 = "a" * 64


def reset_state():
    for n in os.listdir(ETC):
        os.unlink(os.path.join(ETC, n))


def write_state(d):
    with open(kf.STATE, "w", encoding="utf-8") as f:
        json.dump(d, f)


def run_main(argv):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = kf.main(argv)
    return rc, buf.getvalue()


print("══ 1. 版本护栏 ══")
check(kf.guard(PIN, "v1.19.34")[0] == kf.GUARD_OK, "基线: 比钉值新、同一个大版本 → 可换")
check(kf.guard(PIN, PIN)[0] == kf.GUARD_OK, "等于钉值 → 可换(不低于钉值)")
check(kf.guard(PIN, "v1.19.34", "v1.19.34")[0] == kf.GUARD_SAME, "已是目标版本 → 已是(不重复换)")
check(kf.guard(PIN, "v1.19.30")[0] == kf.GUARD_REFUSE, "低于钉值 → 拒绝(不降级)")
check(kf.guard(PIN, "v2.0.0")[0] == kf.GUARD_REFUSE, "跨大版本 → 拒绝")
check(kf.guard(PIN, "v1.20.0")[0] == kf.GUARD_OK, "同一个大版本里的次版本升级 → 可换")
for bad_t in ("1.19.34", "v1.19", "v1.19.34-rc1", "v1.19.34 ", ""):
    check(kf.guard(PIN, bad_t)[0] == kf.GUARD_REFUSE, "目标形态不对(%r) → 拒绝" % bad_t)
check(kf.guard("", "v1.19.34")[0] == kf.GUARD_REFUSE, "读不出钉值 → 拒绝(不退回某个默认)")
check(kf.parse_ver("v1.19.10") > kf.parse_ver("v1.19.9"), "按数字比较(v1.19.10 > v1.19.9, 不是字符串序)")

print()
print("══ 2. 上游取件信息 ══")


def rel(**over):
    d = {"tag_name": "v1.19.34", "prerelease": False, "draft": False,
         "published_at": "2026-11-01T10:00:00Z",
         "assets": [{"name": "mihomo-linux-amd64-v1.19.34.gz", "digest": "sha256:" + D64,
                     "browser_download_url": "https://evil.example/x.gz"},
                    {"name": "mihomo-linux-amd64-compatible-v1.19.34.gz", "digest": "sha256:" + "b" * 64},
                    {"name": "mihomo-linux-arm64-v1.19.34.gz", "digest": "sha256:" + "c" * 64}]}
    d.update(over)
    return d


SEEN = []


def serve(obj):
    def _get(url):
        SEEN.append(url)
        if isinstance(obj, Exception):
            raise obj
        return json.dumps(obj).encode() if not isinstance(obj, bytes) else obj
    kf._http_get = _get


def refused(obj, arch="amd64", tag=None):
    serve(obj)
    try:
        kf.fetch_release(arch, tag)
    except kf.KFError as e:
        return str(e)
    return None


serve(rel())
r = kf.fetch_release("amd64")
check(r["tag"] == "v1.19.34" and r["archive_sha256"] == D64, "基线: 合规的 latest → 取到 tag 与归档摘要")
check(r["url"] == "https://github.com/MetaCubeX/mihomo/releases/download/v1.19.34/mihomo-linux-amd64-v1.19.34.gz",
      "下载 URL 按 tag + 精确资产名拼出, 不用应答里的 browser_download_url(那里放的是 evil.example)")
check(SEEN[-1] == "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest", "不带 tag 时查 releases/latest")
check(kf.fetch_release("arm64")["archive_sha256"] == "c" * 64, "arm64 取的是 arm64 那个资产, 不是 -compatible- 之类相似名")
serve(rel())
kf.fetch_release("amd64", "v1.19.34")
check(SEEN[-1].endswith("/releases/tags/v1.19.34"), "带 tag 时查 releases/tags/<tag>")
check(refused(rel(), tag="v1.19.35") is not None, "问 v1.19.35、上游答 v1.19.34 → 拒绝")
check(refused(rel(prerelease=True)) is not None, "prerelease=true → 拒绝")
check(refused(rel(draft=True)) is not None, "draft=true → 拒绝")
d = rel(); del d["prerelease"]
check(refused(d) is not None, "缺 prerelease 字段 → 拒绝(必须明确是 False, 不靠默认)")
check(refused(rel(tag_name="v1.19.34-alpha")) is not None, "tag 形态不对 → 拒绝")
check(refused(rel(published_at="yesterday")) is not None, "发布时刻不合规 → 拒绝")
d = rel(); d["assets"] = [a for a in d["assets"] if a["name"] != "mihomo-linux-amd64-v1.19.34.gz"]
check(refused(d) is not None, "精确资产名不在 → 拒绝(不退到相似名)")
d = rel(); d["assets"].append(dict(d["assets"][0]))
check(refused(d) is not None, "同名资产两个 → 拒绝(恰好一个)")
d = rel(); del d["assets"][0]["digest"]
check(refused(d) is not None, "资产没有 digest → 拒绝(没有交叉证据就不换)")
d = rel(); d["assets"][0]["digest"] = "sha512:" + "a" * 128
check(refused(d) is not None, "digest 不是 sha256 → 拒绝")
d = rel(); d["assets"][0]["digest"] = "sha256:" + "A" * 64
check(refused(d) is not None, "digest 形态不对(大写) → 拒绝")
check(refused([1, 2]) is not None, "应答不是对象 → 拒绝")
check(refused(b"not json") is not None, "应答不是 JSON → 拒绝")
check(refused(OSError("boom")) is not None, "连不上 → 拒绝(判不出来)")
check(refused(rel(), arch="mips") is not None, "不认识的架构 → 拒绝")
check(refused(rel(), tag="latest") is not None, "tag 参数形态不对 → 拒绝, 且不发请求")

print()
print("══ 3. ELF 架构核对 ══")


def mkelf(path, cls=2, data=1, mach=62, n=64):
    h = bytearray(n)
    h[:4] = b"\x7fELF"
    h[4], h[5] = cls, data
    h[18:20] = mach.to_bytes(2, "little")
    with open(path, "wb") as f:
        f.write(bytes(h))
    return path


e = os.path.join(WORK, "elf")
check(kf.elf_ok(mkelf(e), "amd64")[0], "基线: 64 位小端 x86_64 → amd64 通过")
check(kf.elf_ok(mkelf(e, mach=183), "arm64")[0], "基线: 64 位小端 aarch64 → arm64 通过")
check(not kf.elf_ok(mkelf(e, mach=183), "amd64")[0], "aarch64 当 amd64 → 拒绝")
check(not kf.elf_ok(mkelf(e, cls=1), "amd64")[0], "32 位 → 拒绝")
check(not kf.elf_ok(mkelf(e, data=2), "amd64")[0], "大端 → 拒绝")
check(not kf.elf_ok(mkelf(e, n=10), "amd64")[0], "文件太短 → 拒绝")
with open(e, "wb") as f:
    f.write(b"#!/bin/sh\necho hi\n" + b"\0" * 40)
check(not kf.elf_ok(e, "amd64")[0], "脚本(不是 ELF) → 拒绝")
check(not kf.elf_ok(os.path.join(WORK, "nope"), "amd64")[0], "文件不存在 → 拒绝")
REAL = os.environ.get("PDG_TEST_MIHOMO") or os.path.join(ROOT, "tests", ".bin", "mihomo")
if os.path.exists(REAL):
    check(kf.elf_ok(REAL, "amd64")[0], "真 mihomo(钉死版)按 amd64 核对通过")
else:
    print("[SKIP] 没有真 mihomo(bash tests/prepare-mihomo.sh 可备好) —— 这一格未验, 不是通过")

print()
print("══ 4. 本机记录 ══")
reset_state()
check(kf.load_state()["mode"] == "pinned" and not os.path.exists(kf.STATE),
      "没有 kernel.json → 跟发布, 且只读不建文件")
kf.set_mode("upstream")
st = os.stat(kf.STATE)
check(kf.load_state()["mode"] == "upstream", "set_mode upstream 写进记录")
check(stat.S_IMODE(st.st_mode) == 0o600, "记录文件 0600")
check([n for n in os.listdir(ETC) if n != "kernel.json"] == [], "原子写不留临时文件")
kf.set_auto(True)
check(kf.load_state()["auto"] is True, "跟上游下可以开自动")
kf.set_mode("pinned")
check(kf.load_state()["auto"] is False, "切回跟发布时自动一并关掉")
try:
    kf.set_auto(True)
    bad("跟发布下开自动应当被拒")
except kf.KFError:
    ok("跟发布下开自动 → 拒绝")
try:
    kf.set_mode("latest")
    bad("不认识的模式应当被拒")
except kf.KFError:
    ok("不认识的模式 → 拒绝")
with open(kf.STATE, "w") as f:
    f.write("{not json")
try:
    kf.load_state()
    bad("坏 JSON 应当报错")
except kf.KFError:
    ok("坏 JSON → 报错(不当成跟发布)")
try:
    kf.set_mode("upstream")
    bad("坏记录上 set_mode 应当报错")
except kf.KFError:
    ok("坏记录上改模式 → 报错, 不静默覆盖")
check(open(kf.STATE).read() == "{not json", "坏记录原样留着(现场不被抹平)")
write_state({"schema": 2, "mode": "pinned", "auto": False})
try:
    kf.load_state()
    bad("schema 不认识应当报错")
except kf.KFError:
    ok("schema 不认识 → 报错")
write_state({"schema": 1, "mode": "upstream", "auto": "yes"})
try:
    kf.load_state()
    bad("auto 不是布尔应当报错")
except kf.KFError:
    ok("auto 不是布尔 → 报错")
reset_state()
check(kf.record("v1.19.33", D64, "pin", if_exists=True) is False and not os.path.exists(kf.STATE),
      "record --if-exists 在没有记录时不建文件")
check(kf.note("ok", "v1.19.33") is False and not os.path.exists(kf.STATE), "note 在没有记录时不建文件")
kf.set_mode("upstream")
kf.record("v1.19.33", "1" * 64, "pin")
kf.record("v1.19.34", "2" * 64, "upstream", "sha256:" + D64)
s = kf.load_state()
check(s["current"]["version"] == "v1.19.34" and s["previous"]["version"] == "v1.19.33", "record 把上一份挪到 previous")
kf.record("v1.19.34", "2" * 64, "upstream", "sha256:" + D64)
check(kf.load_state()["previous"]["version"] == "v1.19.33", "同一份重复记录不挤掉 previous")
for args, why in ((("v1.19.35", "3" * 64, "upstream", ""), "上游来源不带 digest"),
                  (("v1.19.35", "xyz", "upstream", "sha256:" + D64), "摘要形态不对"),
                  (("1.19.35", "3" * 64, "pin", ""), "版本形态不对"),
                  (("v1.19.35", "3" * 64, "mirror", ""), "来源不认识")):
    try:
        kf.record(*args)
        bad("record: %s 应当被拒" % why)
    except kf.KFError:
        ok("record: %s → 拒绝" % why)
kf.note("fail", "v1.19.35", "体检变差")
check(kf.last_failed("v1.19.35") and not kf.last_failed("v1.19.36"), "last_failed 只对同一版成立")
saved = kf.STATE
kf.STATE = os.path.join(WORK, "no-such-dir", "kernel.json")
try:
    kf.save_state(kf._blank())
    bad("目录不存在时不该替它建")
except kf.KFError:
    ok("/etc/privdns-gateway 不存在(没装) → 报错, 不替它建")
kf.STATE = saved

print()
print("══ 5. 认不认(accept) ══")
BIN = os.path.join(WORK, "mihomo")
MARK = os.path.join(WORK, "executed")


def mkbin(ver, rc=0, marker=False):
    body = "#!/bin/sh\n"
    if marker:
        body += "touch '%s'\n" % MARK
    body += 'echo "Mihomo Meta %s linux amd64 with go1.26"\nexit %d\n' % (ver, rc)
    with open(BIN, "w") as f:
        f.write(body)
    os.chmod(BIN, 0o755)
    with open(BIN, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def up_state(ver, sha, source="upstream", digest="sha256:" + D64, mode="upstream"):
    write_state({"schema": 1, "mode": mode, "auto": False, "previous": None, "last": None,
                 "current": {"version": ver, "sha256": sha, "source": source,
                             "archive_digest": digest, "at": "2026-11-05T00:00:00Z"}})


sha = mkbin("v1.19.34")
up_state("v1.19.34", sha)
good, ver, why = kf.accept(BIN, PIN)
check(good and ver == "v1.19.34", "基线: 跟上游 + 记录来自上游带 digest + 摘要一致 + 自报一致 → 认(%s)" % (why or ver))
up_state("v1.19.34", sha, mode="pinned")
check(not kf.accept(BIN, PIN)[0], "跟发布 → 不认")
up_state("v1.19.34", sha, source="pin")
check(not kf.accept(BIN, PIN)[0], "记录来源是钉值 → 不认(钉值那份由钉值判据管)")
up_state("v1.19.34", sha, digest="")
check(not kf.accept(BIN, PIN)[0], "记录没有上游 digest → 不认")
sha30 = mkbin("v1.19.30")
up_state("v1.19.30", sha30)
check(not kf.accept(BIN, PIN)[0], "记录版本低于钉值 → 不认(发版把钉值抬上去之后, 旧的上游版要被换掉)")
sha2 = mkbin("v2.0.0")
up_state("v2.0.0", sha2)
check(not kf.accept(BIN, PIN)[0], "记录版本跨大版本 → 不认")
sha = mkbin("v1.19.34")
up_state("v1.19.34", sha)
mkbin("v1.19.34", marker=True)            # 内容换了(多了一行), 版本串留着
if os.path.exists(MARK):
    os.unlink(MARK)
check(not kf.accept(BIN, PIN)[0], "内容与记录不一致 → 不认")
check(not os.path.exists(MARK), "先证内容再执行: 摘要不符的文件一次都没被运行")
sha = mkbin("v1.19.35")
up_state("v1.19.34", sha)
check(not kf.accept(BIN, PIN)[0], "自报版本与记录不符 → 不认")
sha = mkbin("v1.19.34", rc=1)
up_state("v1.19.34", sha)
check(not kf.accept(BIN, PIN)[0], "-v 退出码非零 → 不认(打印出来的版本不算数)")
with open(kf.STATE, "w") as f:
    f.write("garbage")
check(not kf.accept(BIN, PIN)[0], "记录读不出 → 不认")
reset_state()
check(not kf.accept(BIN, PIN)[0], "没有记录 → 不认")

print()
print("══ 6. 自动的等待期 ══")


def ago(days, hours=0):
    t = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(days=days, hours=hours)
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


check(kf.due(ago(4)), "发布 4 天 → 到期")
check(not kf.due(ago(2, 23)), "发布不到 3 天 → 未到期")
check(kf.due(ago(3, 1)), "发布 3 天多 → 到期")
check(not kf.due("2026-11-01"), "时刻形态不对 → 未到期(判不出来就不动)")
check(not kf.due(None), "没有时刻 → 未到期")

print()
print("══ 7. 体检对照 ══")
check(kf.compare({"dns": "ok", "out:a": "ok"}, {"dns": "ok", "out:a": "fail"}) == ["out:a"], "前像 ok、后像 fail → 退步")
check(kf.compare({"dns": "ok", "out:a": "fail"}, {"dns": "ok", "out:a": "fail"}) == [],
      "换核前就不通的出口, 换核后仍不通 → 不算新内核的错")
check(kf.compare({"dns": "ok"}, {"dns": "ok", "out:new": "fail"}) == [], "后像里新出现的项 → 无从对照, 不算")
check(kf.compare({"dns": "ok", "ctrl": "ok"}, {"dns": "ok"}) == ["ctrl"], "后像里少了前像 ok 的项 → 退步")
check(kf.compare({"ctrl": "na"}, {"ctrl": "na"}) == [], "管理面前后都没配 → 不算退步")

print()
print("══ 8. 体检采样(管理面打桩, 不连任何端口) ══")
_saved = (checks.check_dns, checks._clash_ctrl, kf._ctl_get)
PROX = {"DIRECT": {"type": "Direct"}, "REJECT": {"type": "Reject"}, "GLOBAL": {"type": "Selector"},
        "auto": {"type": "URLTest"}, "jp1": {"type": "Shadowsocks"}, "us 2/x": {"type": "Vless"}}
CALLS = []


def fake_get(base, path, timeout):
    CALLS.append(path)
    if path == "/proxies":
        return {"proxies": PROX}
    if "/jp1/" in path:
        raise OSError("timeout")
    return {"delay": 88}


checks.check_dns = lambda: ("ok", "本机DNS", "")
checks._clash_ctrl = lambda: ("http://127.0.0.1:9090", "")
kf._ctl_get = fake_get
h = kf.health()
check(h.get("dns") == "ok" and h.get("ctrl") == "ok", "DNS 与管理面各成一项")
check("out:GLOBAL" not in h and "out:auto" not in h and "out:REJECT" not in h, "组与拒绝类不当出口测")
check(h.get("out:DIRECT") == "ok", "DIRECT 当出口测(内核整个坏掉时它也会失败)")
check(h.get("out:jp1") == "fail", "延迟测试失败的出口记 fail")
check(h.get("out:us 2/x") == "ok" and any(c.startswith("/proxies/us%202%2Fx/delay?") for c in CALLS),
      "出口名进路径前整体转义(空格与斜杠都转, 不会拼出别的路径)")
check(all(c == "/proxies" or c.startswith("/proxies/") for c in CALLS), "只问管理面的 /proxies 与 /proxies/<名>/delay")
for i in range(20):
    PROX["n%02d" % i] = {"type": "Trojan"}
outs = [k for k in kf.health() if k.startswith("out:")]
check(len(PROX) > kf.HEALTH_MAX_OUTBOUNDS + 4 and len(outs) == kf.HEALTH_MAX_OUTBOUNDS,
      "出口多于上限时只测前 %d 个(实得 %d)" % (kf.HEALTH_MAX_OUTBOUNDS, len(outs)))
checks._clash_ctrl = lambda: (None, "未配置")
check(kf.health() == {"dns": "ok", "ctrl": "na"}, "管理面没配 → ctrl=na, 不去猜地址")
checks._clash_ctrl = lambda: ("http://127.0.0.1:9090", "")
kf._ctl_get = lambda b, p, t: (_ for _ in ()).throw(OSError("refused"))
check(kf.health().get("ctrl") == "fail", "管理面连不上 → ctrl=fail")
checks.check_dns, checks._clash_ctrl, kf._ctl_get = _saved

print()
print("══ 9. 命令行退出码 ══")
check(run_main(["guard", "--pin", PIN, "--target", "v1.19.34"])[0] == 0, "guard 可换 → 0")
check(run_main(["guard", "--pin", PIN, "--target", "v1.19.34", "--installed", "v1.19.34"])[0] == 3, "guard 已是 → 3")
check(run_main(["guard", "--pin", PIN, "--target", "v1.19.1"])[0] == 4, "guard 拒绝 → 4")
check(run_main(["due", "--published-at", ago(5)])[0] == 0 and run_main(["due", "--published-at", ago(1)])[0] == 3,
      "due 到期 0 / 未到期 3")
serve(rel())
rc, out = run_main(["release", "--arch", "amd64"])
f = out.rstrip("\n").split("\t")
check(rc == 0 and len(f) == 5 and f[0] == "v1.19.34" and f[3] == D64, "release 输出 5 列: tag 资产 URL 摘要 时刻")
serve(rel(draft=True))
rc, out = run_main(["release", "--arch", "amd64"])
check(rc == 2 and out.startswith("❌"), "release 被拒 → 2 且说原因")
b0, b1 = os.path.join(WORK, "h0.json"), os.path.join(WORK, "h1.json")
json.dump({"dns": "ok", "out:a": "ok"}, open(b0, "w"))
json.dump({"dns": "ok", "out:a": "ok"}, open(b1, "w"))
check(run_main(["compare", b0, b1])[0] == 0, "compare 不比前像差 → 0")
json.dump({"dns": "fail", "out:a": "ok"}, open(b1, "w"))
rc, out = run_main(["compare", b0, b1])
check(rc == 1 and "dns" in out, "compare 有退步 → 1 并列出")
open(b1, "w").write("nope")
check(run_main(["compare", b0, b1])[0] == 2, "compare 读不出 → 2(不当成没退步)")
reset_state()
check(run_main(["state", "--get", "mode"]) == (0, "pinned\n"), "state --get mode 默认 pinned")
check(run_main(["accept", "--pin", PIN, "--bin", BIN])[0] == 1, "accept 不认 → 1")

print()
print("══ 10. status ══")
serve(rel(tag_name="v1.19.34", assets=rel()["assets"]))
kv = dict(l.split("=", 1) for l in kf.status(PIN, PIN, "pin", True, "amd64", True).splitlines())
check(kv.get("mode") == "pinned" and kv.get("verdict") == "upgrade" and kv.get("latest") == "v1.19.34",
      "kv: 跟发布 / 上游 v1.19.34 → upgrade")
kv = dict(l.split("=", 1) for l in kf.status(PIN, "v1.19.34", "upstream", True, "amd64", True).splitlines())
check(kv.get("verdict") == "same", "已装就是上游最新 → same")
d = rel(tag_name="v2.0.0")
d["assets"] = [{"name": "mihomo-linux-amd64-v2.0.0.gz", "digest": "sha256:" + D64}]
serve(d)
kv = dict(l.split("=", 1) for l in kf.status(PIN, PIN, "pin", True, "amd64", True).splitlines())
check(kv.get("verdict") == "major", "上游跨大版本 → major")
serve(OSError("down"))
kv = dict(l.split("=", 1) for l in kf.status(PIN, PIN, "pin", True, "amd64", True).splitlines())
check(kv.get("verdict") == "error", "查不到上游 → error(不冒充已是最新)")
txt = kf.status(PIN, "", "unknown")
check("对不上" in txt and "跟发布" in txt, "人读版本: 内容对不上时明说")

print()
print("══ 11. doctor: 跟随分支 ══")
# 这里不注入 _pin: 钉值取真的 lib/versions.sh, 桩的摘要必然不等于钉值 —— 正好走到跟随那条路。
checks_kf = checks._kernel_follow_version
REALPIN = checks._pinned_mihomo_ver()
nxt = "v%d.%d.%d" % (kf.parse_ver(REALPIN)[0], kf.parse_ver(REALPIN)[1], kf.parse_ver(REALPIN)[2] + 1)
sha = mkbin(nxt)
reset_state()
lvl, _, dt = checks.check_core_version(_bin=BIN)
check(lvl == "fail", "没有跟随记录: 自报 %s ≠ 钉值 → fail(行为与以前相同)" % nxt)
lvl, _, dt = checks.check_mihomo_binary(_bin=BIN, _arch="amd64")
check(lvl == "fail", "没有跟随记录: 内容 ≠ 钉值 → fail")
up_state(nxt, sha)
lvl, _, dt = checks.check_core_version(_bin=BIN)
check(lvl == "ok" and "跟随上游" in dt and REALPIN in dt, "跟上游且被认: 版本判据 ok, 文案说是跟随、并给出钉值(%s)" % dt[:60])
lvl, _, dt = checks.check_mihomo_binary(_bin=BIN, _arch="amd64")
check(lvl == "ok" and "跟随" in dt and "E2E" in dt, "跟上游且被认: 内容判据 ok, 文案说明不是钉值、没过 E2E")
up_state(nxt, sha, mode="pinned")
check(checks.check_core_version(_bin=BIN)[0] == "fail" and checks.check_mihomo_binary(_bin=BIN, _arch="amd64")[0] == "fail",
      "改回跟发布 → 两条都按钉值判(fail)")
up_state(nxt, "0" * 64)
check(checks.check_mihomo_binary(_bin=BIN, _arch="amd64")[0] == "fail", "记录摘要与文件不符 → 内容判据 fail")
up_state(nxt, sha)
check(checks.check_mihomo_binary(_bin=BIN, _arch="amd64", _pin="f" * 64)[0] == "fail",
      "测试注入钉值时不走跟随分支(既有用例的口径不变)")
reset_state()

print("-" * 62)
print("test-kernel-follow.py: 通过 %d, 失败 %d" % (PASS[0], FAIL[0]))
sys.exit(1 if FAIL[0] else 0)
