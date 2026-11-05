#!/usr/bin/env python3
"""mihomo 内核跟随上游: 本机记录、上游取件信息、版本护栏、"这份内核认不认"、换核前后体检。

默认是「跟发布」(pinned): 内核就是 lib/versions.sh 钉死的那一版, 与以前完全一样, 本机连
kernel.json 都没有。切到「跟上游」(upstream)之后, `pdg kernel upgrade` 直接从
MetaCubeX/mihomo 取最新稳定版换上, 不用等项目发一个新版本。

这里是**判定与状态的唯一一份**: pdg.sh 的 `pdg kernel` / `pdg update`、doctor(checks.py)
都调这里, 不各写一份 —— 两处手写的"认不认"迟早会漂, 漂掉的表现就是 doctor 报红而
pdg update 觉得没事, 或者反过来。

信任模型比钉值弱, 不要读成比实际更强:
  · 钉值是人看过、CI 跑过 E2E 的。跟上游时, 信任锚只剩"GitHub Release API 给出的
    sha256 asset digest 与下载物一致" —— 文件与摘要由同一方托管, 上游被攻破时两者一起变;
  · 新内核没经过 E2E。能补的只有本机这几道: 版本护栏(稳定版 / 不低于钉值 / 不跨大版本)、
    取件核对(digest 必须有且一致 / ELF 架构 / 自报版本精确相等)、换核前后体检对照。
  · doctor 跟上游时核对的是本机记录(kernel.json)里的摘要。有 root 的人能把二进制和记录
    一起改掉; `pdg kernel status --online` 会再向上游核一次 digest, doctor 本身不联网。

用法(pdg.sh 调, 不是给人直接用的):
  kernelfollow.py release --arch A [--tag vX.Y.Z]   → tag 资产名 URL 归档摘要 发布时刻(制表符分隔)
  kernelfollow.py guard --pin P --target T [--installed I]   rc 0 可换 / 3 已是 / 4 拒绝
  kernelfollow.py elf --arch A FILE                 rc 0 是该架构的 64 位小端 ELF
  kernelfollow.py accept --pin P --bin B            rc 0 认(stdout 版本) / 1 不认(stdout 原因)
  kernelfollow.py state --get mode|auto             读一个字段
  kernelfollow.py set-mode pinned|upstream / set-auto on|off
  kernelfollow.py record --version V --sha S --source upstream|pin [--archive-digest D] [--if-exists]
  kernelfollow.py note --result ok|fail|error|skip --version V [--why W]
  kernelfollow.py last-failed --version V           rc 0 = 上次尝试这一版是实质失败(error 那类临时失败不算)
  kernelfollow.py baseline FILE                     rc 0 = 体检结果里至少一项 ok(有东西可对照)
  kernelfollow.py due --published-at T [--days N]   rc 0 已满 N 天 / 3 未满
  kernelfollow.py health                            换核体检, JSON 到 stdout
  kernelfollow.py compare BEFORE AFTER              rc 0 不比前像差 / 1 有退步(stdout 列出)
  kernelfollow.py status --pin P --installed I --source S [--online --arch A] [--kv]
  kernelfollow.py notify TEXT                       经 bot 凭据发 Telegram(尽力而为)
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)          # checks.py / healthcheck.py 与本文件同目录(/opt/pdg-bot 或仓库 deploy/bot)

STATE = "/etc/privdns-gateway/kernel.json"
SCHEMA = 1
MODES = ("pinned", "upstream")
SOURCES = ("upstream", "pin")
UPSTREAM = "MetaCubeX/mihomo"
API = "https://api.github.com"
ARCH_ELF = {"amd64": 62, "arm64": 183}        # e_machine: EM_X86_64 / EM_AARCH64
AUTO_WAIT_DAYS = 3                            # 上游发布满这么多天, 自动模式才换(有问题的版本往往几天内就出修正版)
HTTP_TIMEOUT = 15
HTTP_MAX = 4 << 20                            # Release JSON 的上限; 超了就是不对劲, 不读完
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)$")
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
DIGEST_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
TIME_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
# 体检: 经 mihomo 管理面对每个出口做一次延迟测试。组类型不是出口, 拒绝类测不出东西。
GROUP_TYPES = {"Selector", "URLTest", "Fallback", "LoadBalance", "Relay", "Compatible",
               "Pass", "Reject", "RejectDrop", "Dns"}
HEALTH_URL = "https://www.gstatic.com/generate_204"
HEALTH_MAX_OUTBOUNDS = 16
HEALTH_DELAY_MS = 5000


class KFError(Exception):
    """判不出来 / 数据不合规。调用方一律当"不能换 / 不认", 不退回某个默认值。"""


class KFUnreadable(KFError):
    """记录文件在, 但这个身份读不到(kernel.json 是 0600 root)。doctor 据此说"无结论",
    而不是把一台好好跟着上游的机器报成内容被换过。"""


def parse_ver(s):
    m = TAG_RE.match(s or "")
    return tuple(int(x) for x in m.groups()) if m else None


def _now():
    return datetime.datetime.now(datetime.timezone.utc)


def _iso(t=None):
    return (t or _now()).strftime("%Y-%m-%dT%H:%M:%SZ")


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


# ── 本机记录 ──────────────────────────────────────────────────────────────────
def _blank():
    return {"schema": SCHEMA, "mode": "pinned", "auto": False,
            "current": None, "previous": None, "last": None}


def load_state():
    """读 kernel.json。不存在 = 跟发布(默认)。读得到却不合规 → KFError: 判不出来就不认,
    也不悄悄当成"跟发布"覆盖掉 —— 那样会把一份坏记录静默抹平, 现场就没了。"""
    try:
        with open(STATE, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return _blank()
    except PermissionError:
        raise KFUnreadable("没有权限读 %s(要 root)" % STATE)
    except OSError as e:
        raise KFError("读不到 %s(%s)" % (STATE, e.strerror or e.errno))
    try:
        d = json.loads(raw)
    except ValueError:
        raise KFError("%s 不是合法 JSON" % STATE)
    if not isinstance(d, dict) or d.get("schema") != SCHEMA:
        raise KFError("%s 的 schema 不认识" % STATE)
    if d.get("mode") not in MODES or not isinstance(d.get("auto"), bool):
        raise KFError("%s 的 mode / auto 字段不合规" % STATE)
    for k in ("current", "previous", "last"):
        if d.get(k) is not None and not isinstance(d.get(k), dict):
            raise KFError("%s 的 %s 字段不合规" % (STATE, k))
        d.setdefault(k, None)
    return d


def save_state(d):
    """原子写: 同目录临时文件 → fsync → rename。目录不存在 = 没装, 不替它建。"""
    sdir = os.path.dirname(STATE)
    if not os.path.isdir(sdir):
        raise KFError("%s 不存在(这台机器没装 PrivDNS Gateway?)" % sdir)
    fd, tmp = tempfile.mkstemp(dir=sdir, prefix=".kernel.json.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=1, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, STATE)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
    try:
        dfd = os.open(sdir, os.O_RDONLY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    except OSError:
        pass


def set_mode(mode):
    if mode not in MODES:
        raise KFError("模式只能是 pinned(跟发布)或 upstream(跟上游), 不认 %r" % mode)
    d = load_state()
    d["mode"] = mode
    if mode == "pinned":
        d["auto"] = False            # 自动只对跟上游有意义; 切回跟发布时一并关掉, 免得下次切回来时悄悄生效
    save_state(d)


def set_auto(on):
    d = load_state()
    if on and d["mode"] != "upstream":
        raise KFError("自动只在「跟上游」下可用; 先 sudo pdg kernel mode upstream")
    d["auto"] = bool(on)
    save_state(d)


def record(version, sha, source, archive_digest="", if_exists=False):
    """记下"现在装着的是哪一份"。上一份挪到 previous(同一份重复记录不挤掉 previous)。"""
    if not TAG_RE.match(version or ""):
        raise KFError("版本号形态不对: %r" % version)
    if not SHA_RE.match(sha or ""):
        raise KFError("二进制摘要形态不对")
    if source not in SOURCES:
        raise KFError("来源只能是 upstream / pin")
    if source == "upstream" and not DIGEST_RE.match(archive_digest or ""):
        raise KFError("来自上游的内核必须带上游 asset digest(sha256:…)")
    if if_exists and not os.path.exists(STATE):
        return False
    d = load_state()
    cur = d.get("current")
    new = {"version": version, "sha256": sha, "source": source,
           "archive_digest": archive_digest or "", "at": _iso()}
    if cur and cur.get("sha256") != sha:
        d["previous"] = {"version": cur.get("version"), "sha256": cur.get("sha256"),
                         "source": cur.get("source")}
    d["current"] = new
    save_state(d)
    return True


RESULTS = ("ok", "fail", "error", "skip")


def note(result, version, why=""):
    """记下最近一次尝试(给 status 与"失败过就不自动重试"用)。没有记录文件就不建。

    fail  = 这一版本身有问题(摘要不符 / 不是本机架构 / 换核校验没过 / 体检变差 / 没有可对照的体检);
    error = 这一次没做成, 与版本无关(下载或上游 API 失败 / 建不出临时目录 / 备份失败 / 记录没写成)。
    自动模式只对 fail 不再重试: 把一次网络抖动记成 fail, 自动就会永远停在那一版前面。"""
    if result not in RESULTS:
        raise KFError("result 只能是 " + " / ".join(RESULTS))
    if not os.path.exists(STATE):
        return False
    d = load_state()
    d["last"] = {"at": _iso(), "result": result, "version": version or "",
                 "why": (why or "")[:300]}
    save_state(d)
    return True


def last_failed(version):
    try:
        last = load_state().get("last") or {}
    except KFError:
        return False
    return last.get("result") == "fail" and last.get("version") == version


# ── 上游取件信息 ──────────────────────────────────────────────────────────────
def _http_get(url):
    req = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "User-Agent": "privdns-gateway-kernel-follow",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as r:
        body = r.read(HTTP_MAX + 1)
    if len(body) > HTTP_MAX:
        raise KFError("上游应答超过 %d 字节, 不读" % HTTP_MAX)
    return body


def fetch_release(arch, tag=None):
    """查上游一个稳定版的取件信息。tag=None 取 releases/latest。

    返回 {tag, asset, url, archive_sha256, published_at}。任何一项不合规都 KFError:
      · prerelease / draft 必须**明确是 False**(releases/latest 本来就不含它们, 这里再核一遍,
        不靠默认行为);
      · tag 必须严格是 vX.Y.Z(它会拼进 URL 与文件名);
      · 资产按**精确名** mihomo-linux-<arch>-<tag>.gz 找, 恰好一个(同 tag 下有 20+ 个相似名);
      · 资产必须带 sha256 digest。没有 digest 就没有任何交叉证据, 宁可不换。
    下载 URL 由我们按 tag 与资产名拼出来, **不用** API 里的 browser_download_url ——
    那是应答里的一个字符串, 信它等于让应答决定我们去哪下载。"""
    if arch not in ARCH_ELF:
        raise KFError("不认识的架构 %r" % arch)
    if tag is not None and not TAG_RE.match(tag):
        raise KFError("版本号形态不对: %r(要 vX.Y.Z)" % tag)
    path = "latest" if tag is None else "tags/" + tag
    try:
        data = json.loads(_http_get("%s/repos/%s/releases/%s" % (API, UPSTREAM, path)))
    except KFError:
        raise
    except Exception as e:  # noqa: BLE001  连不上 / 超时 / 404 / 不是 JSON, 一律判不出来
        raise KFError("查不到上游版本(%s)" % (getattr(e, "code", None) or type(e).__name__))
    if not isinstance(data, dict):
        raise KFError("上游应答不是对象")
    t = data.get("tag_name")
    if not isinstance(t, str) or not TAG_RE.match(t):
        raise KFError("上游版本号形态不对: %r" % t)
    if tag is not None and t != tag:
        raise KFError("问的是 %s, 上游答的是 %s" % (tag, t))
    if data.get("prerelease") is not False or data.get("draft") is not False:
        raise KFError("%s 是预发布或草稿(prerelease=%r draft=%r) —— 不跟"
                      % (t, data.get("prerelease"), data.get("draft")))
    pub = data.get("published_at")
    if not isinstance(pub, str) or not TIME_RE.match(pub):
        raise KFError("%s 的发布时刻不合规" % t)
    name = "mihomo-linux-%s-%s.gz" % (arch, t)
    hits = [a for a in (data.get("assets") or []) if isinstance(a, dict) and a.get("name") == name]
    if len(hits) != 1:
        raise KFError("%s 里找不到恰好一个 %s(找到 %d 个)" % (t, name, len(hits)))
    m = DIGEST_RE.match(hits[0].get("digest") or "")
    if not m:
        raise KFError("%s 没有 sha256 asset digest —— 没有交叉证据, 不换" % name)
    return {"tag": t, "asset": name,
            "url": "https://github.com/%s/releases/download/%s/%s" % (UPSTREAM, t, name),
            "archive_sha256": m.group(1), "published_at": pub}


# ── 版本护栏 ──────────────────────────────────────────────────────────────────
GUARD_OK, GUARD_SAME, GUARD_REFUSE = 0, 3, 4


def guard(pin, target, installed=""):
    """能不能从 installed 换到 target。返回 (码, 一句话)。
    已是 target → SAME; 低于发布钉值 / 跨大版本 / 形态不对 → REFUSE。"""
    p, t = parse_ver(pin), parse_ver(target)
    if not p:
        return GUARD_REFUSE, "读不出发布钉值版本(%r)" % pin
    if not t:
        return GUARD_REFUSE, "目标版本形态不对(%r)" % target
    if installed and installed == target:
        return GUARD_SAME, "已是 %s" % target
    if t < p:
        return GUARD_REFUSE, "%s 低于发布钉值 %s —— 跟上游只往上走, 不降级" % (target, pin)
    if t[0] != p[0]:
        return GUARD_REFUSE, ("%s 跨了大版本(钉值是 %s) —— 大版本可能改配置语义, 不自动换, "
                              "要等项目适配后随发布走" % (target, pin))
    return GUARD_OK, "可以换到 %s" % target


def elf_ok(path, arch):
    want = ARCH_ELF.get(arch)
    if want is None:
        return False, "不认识的架构 %r" % arch
    try:
        with open(path, "rb") as f:
            h = f.read(20)
    except OSError as e:
        return False, "读不到(%s)" % (e.strerror or e.errno)
    if len(h) < 20 or h[:4] != b"\x7fELF":
        return False, "不是 ELF"
    if h[4] != 2 or h[5] != 1:
        return False, "不是 64 位小端 ELF"
    mach = int.from_bytes(h[18:20], "little")
    if mach != want:
        return False, "e_machine=%d, 不是 %s(%d)" % (mach, arch, want)
    return True, ""


# ── 认不认 ────────────────────────────────────────────────────────────────────
def _self_version(bin_path):
    """跑一次 `-v` 读自报版本。退出码必须是 0。只在内容已经核过之后调用。"""
    try:
        p = subprocess.run([bin_path, "-v"], capture_output=True, text=True, timeout=10)
    except Exception:  # noqa: BLE001
        return ""
    if p.returncode != 0:
        return ""
    m = re.search(r"v?(\d+\.\d+\.\d+)", (p.stdout or "").split("\n", 1)[0])
    return "v" + m.group(1) if m else ""


def accept(bin_path, pin):
    """跟上游模式下, 这个文件是不是本机记录里那一份。返回 (认?, 版本, 原因)。

    五件事同时成立才认: 模式是跟上游; 记录来源是上游且带 asset digest; 记录版本不低于
    发布钉值、与钉值同一个大版本; 文件内容等于记录的摘要; 自报版本精确等于记录版本。
    **先证内容, 再执行**(与 lib/versions.sh 的 pdg_mihomo_binary_ok 同序): 摘要对不上的
    文件一次都不跑。"""
    try:
        d = load_state()
    except KFError as e:
        return False, "", str(e)
    if d["mode"] != "upstream":
        return False, "", "模式是跟发布"
    cur = d.get("current") or {}
    ver, sha = cur.get("version") or "", cur.get("sha256") or ""
    if cur.get("source") != "upstream":
        return False, "", "本机记录里的这一份不是来自上游"
    if not DIGEST_RE.match(cur.get("archive_digest") or ""):
        return False, "", "本机记录没有上游 asset digest"
    if not SHA_RE.match(sha):
        return False, "", "本机记录的摘要不合规"
    code, why = guard(pin, ver)
    if code != GUARD_OK:
        return False, "", "本机记录的版本不再可接受: " + why
    try:
        got = _sha256(bin_path)
    except OSError as e:
        return False, "", "读不到 %s(%s)" % (bin_path, e.strerror or e.errno)
    if got != sha:
        return False, "", "内容与本机记录不一致(实得 %s…, 记录 %s…)" % (got[:12], sha[:12])
    sv = _self_version(bin_path)
    if sv != ver:
        return False, "", "自报版本 %s 与本机记录 %s 不符" % (sv or "读不出", ver)
    return True, ver, ""


def due(published_at, days=AUTO_WAIT_DAYS):
    if not isinstance(published_at, str) or not TIME_RE.match(published_at):
        return False
    t = datetime.datetime.strptime(published_at, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
    return _now() - t >= datetime.timedelta(days=days)


# ── 换核前后体检 ──────────────────────────────────────────────────────────────
def _ctl_get(base, path, timeout):
    import checks
    req = urllib.request.Request(base + path)
    sec = checks._clash_secret()
    if sec:
        req.add_header("Authorization", "Bearer " + sec)
    with checks._clash_opener().open(req, timeout=timeout) as r:     # 不经代理、不跟重定向(同 doctor)
        return json.load(r)


def health():
    """换核体检: 本机 DNS 应答 + 经 mihomo 管理面对各出口做一次延迟测试。

    返回 {项: "ok"|"fail"|"na"}。它本身不判"好不好" —— 判据是换核前后对照(compare):
    换核前就不通的出口, 换核后不通不算新内核的错。管理面只连回环(同 doctor 的规则集判据)。
    延迟测试会经各出口真的连一次外网, 所以只在换核时跑, doctor 不跑它。"""
    import checks
    items = {}
    try:
        items["dns"] = "ok" if checks.check_dns()[0] == "ok" else "fail"
    except Exception:  # noqa: BLE001
        items["dns"] = "fail"
    base, _why = checks._clash_ctrl()
    if not base:
        items["ctrl"] = "na"
        return items
    try:
        proxies = _ctl_get(base, "/proxies", 5).get("proxies")
        if not isinstance(proxies, dict):
            raise ValueError
    except Exception:  # noqa: BLE001
        items["ctrl"] = "fail"
        return items
    items["ctrl"] = "ok"
    names = sorted(n for n, v in proxies.items()
                   if isinstance(v, dict) and v.get("type") not in GROUP_TYPES)[:HEALTH_MAX_OUTBOUNDS]
    q = urllib.parse.urlencode({"timeout": HEALTH_DELAY_MS, "url": HEALTH_URL})

    def one(n):
        try:
            r = _ctl_get(base, "/proxies/%s/delay?%s" % (urllib.parse.quote(n, safe=""), q),
                         HEALTH_DELAY_MS / 1000 + 3)
            items["out:" + n] = "ok" if isinstance(r.get("delay"), int) and r["delay"] > 0 else "fail"
        except Exception:  # noqa: BLE001
            items["out:" + n] = "fail"
    ts = [threading.Thread(target=one, args=(n,), daemon=True) for n in names]
    for t in ts:
        t.start()
    for t in ts:
        t.join(HEALTH_DELAY_MS / 1000 + 5)
    for n in names:
        items.setdefault("out:" + n, "fail")
    return items


def compare(before, after):
    """换核前是 ok、换核后不是 ok 的项。前像里没有的项不算(新出现的出口无从对照)。"""
    return sorted(k for k, v in before.items() if v == "ok" and after.get(k) != "ok")


def has_baseline(before):
    """前像里至少有一项 ok。一项都没有时 compare 永远找不到退步 —— 那不是"体检通过", 是没体检。"""
    return any(v == "ok" for v in before.values())


# ── 通知 ──────────────────────────────────────────────────────────────────────
def notify(text):
    """经 bot 的凭据发给允许的用户。与 healthcheck 同一套读凭据与发送, 不另存一份。
    凭据没配齐就安静返回 —— 没人可通知不是故障。"""
    try:
        import checks
        if checks.bot_credentials() != "ready":
            return False
        import healthcheck
        if not healthcheck.ALLOWED:
            return False
        healthcheck._notify(text)
        return True
    except Exception:  # noqa: BLE001
        return False


# ── 状态展示 ──────────────────────────────────────────────────────────────────
MODE_TXT = {"pinned": "跟发布", "upstream": "跟上游"}
SRC_TXT = {"pin": "发布钉值", "upstream": "跟随记录(上游)", "unknown": "⚠️ 与钉值和本机记录都对不上"}
VERDICT_TXT = {"upgrade": "可以换", "same": "已是最新", "below_pin": "低于发布钉值",
               "major": "跨大版本, 不换", "refuse": "不换", "error": "查不到"}


def status(pin, installed, source, online=False, arch="", kv=False):
    out = {}
    try:
        d = load_state()
        out["mode"], out["auto"] = d["mode"], ("on" if d["auto"] else "off")
        last = d.get("last") or {}
    except KFError as e:
        out["mode"], out["auto"], last = "error", "off", {}
        out["state_error"] = str(e)
    out["installed"], out["source"], out["pin"] = installed or "", source, pin
    if last:
        out["last"] = "%s %s %s" % (last.get("at", ""), last.get("version", ""), last.get("result", ""))
        out["last_why"] = last.get("why", "")
    if online:
        try:
            r = fetch_release(arch)
            out["latest"], out["latest_published"] = r["tag"], r["published_at"]
            code, why = guard(pin, r["tag"], installed)
            if code == GUARD_OK:
                out["verdict"] = "upgrade"
            elif code == GUARD_SAME:
                out["verdict"] = "same"
            else:
                t, p = parse_ver(r["tag"]), parse_ver(pin)
                out["verdict"] = "below_pin" if (t and p and t < p) else (
                    "major" if (t and p and t[0] != p[0]) else "refuse")
            out["verdict_why"] = why
        except KFError as e:
            out["verdict"], out["verdict_why"] = "error", str(e)
    if kv:
        return "".join("%s=%s\n" % (k, str(v).replace("\n", " ")) for k, v in out.items())
    lines = ["内核跟随: %s%s" % (MODE_TXT.get(out["mode"], "⚠️ 记录读不出"),
                                  "(自动: 开)" if out["mode"] == "upstream" and out["auto"] == "on" else
                                  ("(自动: 关)" if out["mode"] == "upstream" else "")),
             "已装: %s(%s)" % (installed or "?", SRC_TXT.get(source, source)),
             "发布钉值: %s" % pin]
    if out.get("state_error"):
        lines.append("⚠️ " + out["state_error"])
    if out.get("last"):
        lines.append("上次尝试: %s%s" % (out["last"], (" —— " + out["last_why"]) if out.get("last_why") else ""))
    if online:
        if out.get("latest"):
            lines.append("上游最新稳定版: %s(发布于 %s) → %s" % (
                out["latest"], out["latest_published"], VERDICT_TXT.get(out["verdict"], out["verdict"])))
        else:
            lines.append("上游最新稳定版: 查不到(%s)" % out.get("verdict_why", ""))
    return "\n".join(lines) + "\n"


# ── 命令行 ────────────────────────────────────────────────────────────────────
def main(argv=None):
    ap = argparse.ArgumentParser(prog="kernelfollow.py")
    sp = ap.add_subparsers(dest="cmd", required=True)
    a = sp.add_parser("release"); a.add_argument("--arch", required=True); a.add_argument("--tag")
    a = sp.add_parser("guard"); a.add_argument("--pin", required=True); a.add_argument("--target", required=True)
    a.add_argument("--installed", default="")
    a = sp.add_parser("elf"); a.add_argument("--arch", required=True); a.add_argument("file")
    a = sp.add_parser("accept"); a.add_argument("--pin", required=True); a.add_argument("--bin", required=True)
    a = sp.add_parser("state"); a.add_argument("--get", choices=("mode", "auto"), required=True)
    a = sp.add_parser("set-mode"); a.add_argument("mode")
    a = sp.add_parser("set-auto"); a.add_argument("onoff", choices=("on", "off"))
    a = sp.add_parser("record"); a.add_argument("--version", required=True); a.add_argument("--sha", required=True)
    a.add_argument("--source", required=True, choices=SOURCES); a.add_argument("--archive-digest", default="")
    a.add_argument("--if-exists", action="store_true")
    a = sp.add_parser("note"); a.add_argument("--result", required=True); a.add_argument("--version", default="")
    a.add_argument("--why", default="")
    a = sp.add_parser("last-failed"); a.add_argument("--version", required=True)
    a = sp.add_parser("baseline"); a.add_argument("file")
    a = sp.add_parser("due"); a.add_argument("--published-at", required=True)
    a.add_argument("--days", type=int, default=AUTO_WAIT_DAYS)
    sp.add_parser("health")
    a = sp.add_parser("compare"); a.add_argument("before"); a.add_argument("after")
    a = sp.add_parser("status"); a.add_argument("--pin", required=True); a.add_argument("--installed", default="")
    a.add_argument("--source", required=True, choices=("pin", "upstream", "unknown"))
    a.add_argument("--online", action="store_true"); a.add_argument("--arch", default="")
    a.add_argument("--kv", action="store_true")
    a = sp.add_parser("notify"); a.add_argument("text")
    o = ap.parse_args(argv)
    try:
        if o.cmd == "release":
            r = fetch_release(o.arch, o.tag)
            print("\t".join((r["tag"], r["asset"], r["url"], r["archive_sha256"], r["published_at"])))
            return 0
        if o.cmd == "guard":
            code, why = guard(o.pin, o.target, o.installed)
            print(why)
            return code
        if o.cmd == "elf":
            good, why = elf_ok(o.file, o.arch)
            print(why or "ok")
            return 0 if good else 1
        if o.cmd == "accept":
            good, ver, why = accept(o.bin, o.pin)
            print(ver if good else why)
            return 0 if good else 1
        if o.cmd == "state":
            d = load_state()
            print(d["mode"] if o.get == "mode" else ("on" if d["auto"] else "off"))
            return 0
        if o.cmd == "set-mode":
            set_mode(o.mode)
            return 0
        if o.cmd == "set-auto":
            set_auto(o.onoff == "on")
            return 0
        if o.cmd == "record":
            record(o.version, o.sha, o.source, o.archive_digest, o.if_exists)
            return 0
        if o.cmd == "note":
            note(o.result, o.version, o.why)
            return 0
        if o.cmd == "last-failed":
            return 0 if last_failed(o.version) else 1
        if o.cmd == "baseline":
            try:
                with open(o.file, encoding="utf-8") as f:
                    d = json.load(f)
                if not isinstance(d, dict):
                    raise ValueError
            except (OSError, ValueError):
                print("体检结果读不出")
                return 2
            if has_baseline(d):
                return 0
            print("换核前的体检没有一项是好的(%s), 无从对照" % "、".join("%s=%s" % kv for kv in sorted(d.items())))
            return 1
        if o.cmd == "due":
            return 0 if due(o.published_at, o.days) else 3
        if o.cmd == "health":
            print(json.dumps(health(), ensure_ascii=False, sort_keys=True))
            return 0
        if o.cmd == "compare":
            try:
                with open(o.before, encoding="utf-8") as f:
                    b = json.load(f)
                with open(o.after, encoding="utf-8") as f:
                    af = json.load(f)
                if not isinstance(b, dict) or not isinstance(af, dict):
                    raise ValueError
            except (OSError, ValueError):
                print("体检结果读不出")
                return 2
            reg = compare(b, af)
            if reg:
                print("、".join(reg))
                return 1
            return 0
        if o.cmd == "status":
            sys.stdout.write(status(o.pin, o.installed, o.source, o.online, o.arch, o.kv))
            return 0
        if o.cmd == "notify":
            notify(o.text)
            return 0
    except KFError as e:
        print("❌ " + str(e))
        return 2
    return 2


if __name__ == "__main__":
    sys.exit(main())
