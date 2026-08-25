#!/usr/bin/env python3
"""DNS 去广告:规则解析、校验、编译、更新事务与 check 判定。

**这个模块不解析 DNS,也不记录任何查询。**它只处理"落盘之前"那一段:拿到的东西是不是
真的规则表、规范化成什么样、坏输入怎么拒、拒了之后现网继续用哪一份。匹配本身交给 mosdns
原生的 `domain_set`(`domain:` 后缀 / `full:` 精确)—— 那是现有 geosite / hijack_set /
explicit_proxy 都在用的同一个加载器,这里绝不另写一套语义。

优先级(六层,从高到低)在 mosdns 配置里用**合取**表达,不在这里排序:
    基础设施 → 用户 allow → 用户 block → 用户显式分流 → 第三方表 → geosite/默认

一条要害:**失败绝不能切成空表。**空表在 mosdns 那边完全合法(domain_set 允许空文件),
所以"拿到 HTML 错页 → 编译出零条 → 一切照常"这条路是通的,而且全程零报错。唯一能挡住它
的是下载侧的判据,不是 mosdns。所以下面每一道校验都是 fail-closed:不达标就整笔不落盘,
现网继续用 last-known-good。
"""
import json
import os
import re
import shutil
import tempfile
import time

# ── 目录与文件(与 mosdns 受管块里的字面路径一一对应)────────────────────────
STATE_DIR = "/var/lib/privdns-gateway/adblock"
RULES_DIR = "/etc/mosdns/rules"
USER_ALLOW = os.path.join(RULES_DIR, "adblock_allow.txt")      # 用户源, 进快照
USER_BLOCK = os.path.join(RULES_DIR, "adblock_block.txt")      # 用户源, 进快照
INFRA_ALLOW = os.path.join(STATE_DIR, "infra_allow.txt")       # 生成物
EFF_BLOCK = os.path.join(STATE_DIR, "effective_block.txt")     # 编译产物(关闭时为空)
EFF_LIST = os.path.join(STATE_DIR, "effective_list.txt")       # 编译产物(关闭时为空)
LKG = os.path.join(STATE_DIR, "list.lkg")                      # last-known-good 原始表
META = os.path.join(STATE_DIR, "meta.json")

# 默认源: anti-AD。选它的三条理由见 docs —— MIT(与本项目同许可)、纯域名格式(不需要
# 实现 ABP)、有非 GitHub 镜像(本项目用户在墙内)。镜像优先, GitHub raw 兜底。
DEFAULT_SOURCES = (
    "https://anti-ad.net/domains.txt",
    "https://raw.githubusercontent.com/privacy-protection-tools/anti-AD/master/anti-ad-domains.txt",
)

# ── 阈值 ─────────────────────────────────────────────────────────────────────
# 每个数字都能解释, 不是"看着合理":
#   max_entries 150000 —— Phase 0 在 MemoryMax=96M、禁 swap 下实测过 15 万条:
#                         RSS 45.1 MiB、200 QPS p99 1.56ms、oom_kill=0。上限取到实测过的
#                         那个点为止, 再高就没有证据了。
#   max_bytes   8 MiB  —— 实测 anti-AD 2.0 MiB / AdGuard 4.1 MiB; 8 MiB 留一倍余量,
#                         同时给下载一个硬边界(防的是"对方返回了一个巨大的东西")。
#   min_entries 1000   —— 真实广告表都在万条以上; 1000 挡的是截断、半截下载与错页。
#   max_drop_ratio 0.5 —— 新表不足上一份 LKG 的一半就拒。源被投毒或半截发布时, 条目数是
#                         最先塌下来的那个量。
LIMITS = {
    "min_entries": 1000,
    "max_entries": 150000,
    "max_bytes": 8 * 1024 * 1024,
    "max_drop_ratio": 0.5,
}

_DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?"
                        r"(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$")
_IPV4_RE = re.compile(r"^\d{1,3}(\.\d{1,3}){3}$")
_REJECT_HINTS = ("<html", "<!doctype", "<head", "<body")
# ABP / 正则 / URL / 通配这些语法一律不吃 —— 首版只做精确与后缀两种匹配。
_SYNTAX_CHARS = set("|@^$*/?()[]{}\\!<>\"'")


def normalize(names):
    """小写 + 去空白 + 去尾点 + 去重,顺序稳定(首次出现的顺序)。

    稳定顺序不是洁癖:编译产物要能逐字节比对,顺序一抖动,"表变没变"这个问题就没法回答。
    """
    out, seen = [], set()
    for raw in names:
        d = (raw or "").strip().lower().rstrip(".")
        if not d or d in seen:
            continue
        seen.add(d)
        out.append(d)
    return out


def parse_source(text):
    """把一份第三方表解析成域名列表。**拒绝比接受更重要** —— 拒不掉的坏输入会变成一张
    看着正常的假表。任何一行认不出来就整份拒(返回空列表),不做"尽力而为"的部分解析:
    部分解析出来的表少了多少条没人知道,而少掉的正是被跳过的那些。
    """
    if not text or not text.strip():
        return []
    head = text[:4096].lower()
    if any(h in head for h in _REJECT_HINTS):
        return []                                   # HTML 错页
    names = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("!"):
            continue                                # 注释(# 与 ABP 的 !)
        if any(c in _SYNTAX_CHARS for c in s):
            return []                               # ABP / 正则 / URL / 通配
        parts = s.split()
        if len(parts) == 2 and _IPV4_RE.match(parts[0]):
            cand = parts[1]                         # hosts 格式: 0.0.0.0 domain
        elif len(parts) == 1:
            cand = parts[0]
        else:
            return []                               # 认不出的形态
        cand = cand.strip().lower().rstrip(".")
        if _IPV4_RE.match(cand) or cand in ("localhost", "localhost.localdomain", "local"):
            return []                               # 纯 IP / localhost
        if not _DOMAIN_RE.match(cand):
            return []
        names.append(cand)
    return normalize(names)


def validate_candidate(domains, prev_count=None):
    """(ok, reason)。fail-closed:任何一条不达标都不落盘。"""
    n = len(domains)
    if n < LIMITS["min_entries"]:
        return (False, "条目数 %d 低于下限 %d(截断/半截下载/错页?)" % (n, LIMITS["min_entries"]))
    if n > LIMITS["max_entries"]:
        return (False, "条目数 %d 超过上限 %d(超出实测过的内存边界)" % (n, LIMITS["max_entries"]))
    if prev_count and n < prev_count * LIMITS["max_drop_ratio"]:
        return (False, "条目数从 %d 骤降到 %d(不足 %.0f%%)" % (prev_count, n, LIMITS["max_drop_ratio"] * 100))
    return (True, "")


def _read(path, default=""):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return default


def _atomic_write(path, text, mode=0o644):
    """同目录临时文件 + rename。跨目录 rename 不是原子的,所以临时文件必须与目标同目录。"""
    d = os.path.dirname(path) or "."
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".adblock.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(text)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _load_set(path):
    """读一份 domain_set 文件, 回显 (精确集, 后缀列表)。只认 full: 与 domain: 两种前缀。"""
    exact, suffix = set(), []
    for line in _read(path).splitlines():
        s = line.strip().lower()
        if not s or s.startswith("#"):
            continue
        if s.startswith("full:"):
            exact.add(s[5:].strip().rstrip("."))
        elif s.startswith("domain:"):
            suffix.append(s[7:].strip().rstrip("."))
        else:
            suffix.append(s.rstrip("."))           # 裸行按 mosdns 的默认语义 = 后缀
    return exact, suffix


def _hit(domain, path):
    """domain 是否命中这份集合。回显命中的**规范化规则**, 没命中回 None。"""
    d = (domain or "").strip().lower().rstrip(".")
    exact, suffix = _load_set(path)
    if d in exact:
        return "full:%s" % d
    for s in suffix:
        if d == s or d.endswith("." + s):
            return "domain:%s" % s
    return None


def check_domain(domain, rules_dir=None):
    """逐层判定一个域名。**只读规则文件** —— 不发 DNS 查询、不读日志、不落 qname。"""
    base = rules_dir or STATE_DIR
    def p(name, fallback):
        cand = os.path.join(base, name)
        return cand if os.path.exists(cand) else fallback
    layers = (
        ("ADBLOCK_INFRA_ALLOW", p("infra_allow.txt", INFRA_ALLOW), False),
        ("ADBLOCK_USER_ALLOW", p("adblock_allow.txt", USER_ALLOW), False),
        ("ADBLOCK_USER_BLOCK", p("adblock_block.txt", EFF_BLOCK), True),
        ("ADBLOCK_LIST_BLOCK", p("effective_list.txt", EFF_LIST), True),
    )
    for reason, path, blocks in layers:
        rule = _hit(domain, path)
        if rule:
            return {"blocked": blocks, "reason": reason, "rule": rule, "layer": reason}
    return {"blocked": False, "reason": None, "rule": None, "layer": None}


def read_meta(state_dir=None):
    d = state_dir or STATE_DIR
    try:
        return json.loads(_read(os.path.join(d, "meta.json"), "{}")) or {}
    except ValueError:
        return {}


def compile_effective(enabled, state_dir=None, user_block=None, lkg=None):
    """把"启用意图 + 用户源 + LKG"编译成 mosdns 真正读的两个文件。

    **关闭不是靠清空用户规则实现的** —— 用户源文件一个字节都不动, 只是编译产物为空。
    这样 disable → enable 不丢任何东西, 也不需要重新下载。
    """
    d = state_dir or STATE_DIR
    ub = user_block or USER_BLOCK
    lk = lkg or os.path.join(d, "list.lkg")
    if enabled:
        _atomic_write(os.path.join(d, "effective_block.txt"), _read(ub))
        raw = normalize(_read(lk).splitlines())
        _atomic_write(os.path.join(d, "effective_list.txt"),
                      "".join("domain:%s\n" % x for x in raw))
    else:
        _atomic_write(os.path.join(d, "effective_block.txt"), "")
        _atomic_write(os.path.join(d, "effective_list.txt"), "")
    return True


def _default_fetch(url, max_bytes):
    import urllib.request
    req = urllib.request.Request(url, headers={"User-Agent": "privdns-gateway/adblock"})
    with urllib.request.urlopen(req, timeout=45) as r:     # noqa: S310 - 固定 https 源
        if r.status != 200:
            raise OSError("HTTP %s" % r.status)
        ctype = (r.headers.get("Content-Type") or "").lower()
        data = r.read(max_bytes + 1)
    if len(data) > max_bytes:
        raise OSError("超过最大下载体积 %d" % max_bytes)
    return (data.decode("utf-8", "replace"), ctype, 200)


def update_lists(state_dir=None, sources=None, fetch=None):
    """更新事务。任何一步不成立都**整笔不落盘**, 现网继续用 last-known-good。

    返回 {"ok": bool, "reason": <reason code>, "detail": str, "count": int}
    """
    d = state_dir or STATE_DIR
    os.makedirs(d, exist_ok=True)
    lk = os.path.join(d, "list.lkg")
    prev = read_meta(d).get("count") or None
    fetch = fetch or (lambda u: _default_fetch(u, LIMITS["max_bytes"]))
    errs = []
    for url in (sources or DEFAULT_SOURCES):
        try:
            got = fetch(url)
            text, ctype = (got[0], got[1]) if isinstance(got, (tuple, list)) else (got, "")
        except Exception as e:                              # noqa: BLE001
            errs.append("%s: %s" % (url, e))
            continue
        if ctype and not any(t in ctype for t in ("text/plain", "text/", "octet-stream")):
            errs.append("%s: Content-Type=%s 不像规则表" % (url, ctype))
            continue
        if len(text.encode("utf-8", "replace")) > LIMITS["max_bytes"]:
            errs.append("%s: 超过最大体积" % url)
            continue
        names = parse_source(text)
        good, why = validate_candidate(names, prev_count=prev)
        if not good:
            errs.append("%s: %s" % (url, why))
            continue
        # 候选过关 —— 先写 LKG 的备份, 再原子替换; 失败要能退回去
        backup = _read(lk) if os.path.exists(lk) else None
        try:
            _atomic_write(lk, "\n".join(names) + "\n")
            _atomic_write(os.path.join(d, "meta.json"), json.dumps({
                "count": len(names), "source": url,
                "updated": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            }, ensure_ascii=False) + "\n")
        except Exception as e:                              # noqa: BLE001
            if backup is not None:
                try:
                    _atomic_write(lk, backup)
                except OSError:
                    pass
            return {"ok": False, "reason": "ADBLOCK_UPDATE_FAILED",
                    "detail": "落盘失败, 已退回 last-known-good: %s" % e, "count": 0}
        return {"ok": True, "reason": None, "detail": "来自 %s" % url, "count": len(names)}
    return {"ok": False, "reason": "ADBLOCK_UPDATE_FAILED",
            "detail": "全部源都不可用: " + "; ".join(errs[:3]), "count": 0}


# ── ACME DNS provider 的基础设施闭包 ─────────────────────────────────────────
# 本项目把 acme.sh 钉版本 clone 到 /opt/pdg-acme, 并以 `--home <家>/data` 调用, 于是
# provider 记在**每域名的配置**里: data/<域名>/<域名>.conf 的 `Le_Webroot='dns_xxx'`。
# (account.conf 里没有这个值 —— 早先在那里找是错的, 表现是永远读不到 provider。)
ACME_DEFAULT_HOME = "/opt/pdg-acme"

# **受支持的 provider → 它的 API 主机名。**
#
# 为什么是一张显式的表, 而不是从 dnsapi 脚本里提取: acme.sh 3.1.4 实测三种形态并存 ——
#   dns_cf.sh   CF_Api="https://api.cloudflare.com/client/v4"    静态常量, 能提
#   dns_he.sh   赋值行里没有任何 https 常量                        提不到
#   dns_aws.sh  AWS_HOST="route53.global.api.aws"                主机名与 scheme 分开
#               AWS_URL="https://$AWS_HOST"                      运行期拼
#               AWS_WIKI="https://github.com/acmesh-official/…"  赋值行上的**文档链接**
# 只按 `VAR=https://…` 提取, dns_aws 会得到 github.com —— 一个公共域, 而且是错的。
# 放行一个公共域比不放行更糟, 所以这里**不猜**。
#
# 每一条都是对着钉死版(lib/versions.sh 的 ACME_SH_VER)的 dnsapi 脚本核过的; 加新条目时
# 必须同样核过, 并且下面的运行期交叉核对会兜住"上游改了端点"这种漂移。
PROVIDER_API_HOSTS = {
    "dns_cf": ("api.cloudflare.com",),
    "dns_ali": ("alidns.aliyuncs.com",),
    "dns_dp": ("dnsapi.cn",),
    "dns_gd": ("api.godaddy.com",),
    "dns_namecheap": ("api.namecheap.com",),
}


def acme_provider(acme_home=None):
    """本机**已配置**的 ACME DNS provider(读不到返回 None)。

    None 的含义是"没有配置 DNS-01 的 provider", 与"配了但认不出"**不是**一回事 ——
    后者由 provider_api_hosts / infra_closure 判成无法枚举。这两者混同是最危险的写法:
    认不出被当成没有, 于是闭包门直接放行。
    """
    home = acme_home or ACME_DEFAULT_HOME
    data = os.path.join(home, "data")
    if not os.path.isdir(data):
        return None
    for entry in sorted(os.listdir(data)):
        conf = os.path.join(data, entry, entry + ".conf")
        if not os.path.isfile(conf):
            continue
        m = re.search(r"^\s*Le_Webroot\s*=\s*'?\"?(dns_[A-Za-z0-9_]+)", _read(conf), re.M)
        if m:
            return m.group(1)
    return None


def provider_api_hosts(provider, acme_home=None):
    """(hosts, reason)。hosts 非空 = 能确定性枚举; 空则 reason 说明为什么不能。

    两道: 表里要有; 且**安装的那份 dnsapi 脚本里真的出现这个主机名**(交叉核对)。
    第二道挡的是"上游换了端点而表没跟上" —— 那时按表放行等于放行一个已经不用的域名,
    而真正在用的那个仍然会被广告表拦掉。
    """
    if not provider:
        return ((), "NO_PROVIDER")
    hosts = PROVIDER_API_HOSTS.get(provider)
    if not hosts:
        return ((), "UNSUPPORTED")
    script = os.path.join(acme_home or ACME_DEFAULT_HOME, "dnsapi", provider + ".sh")
    if not os.path.isfile(script):
        return ((), "NO_SCRIPT")
    body = _read(script)
    missing = [h for h in hosts if h not in body]
    if missing:
        return ((), "DRIFT")
    return (tuple(hosts), "")


_CLOSURE_HINT = {
    "UNSUPPORTED": "本产品还不能确定这个 provider 的 API 域名",
    "NO_SCRIPT": "装的 acme.sh 里找不到这个 provider 的插件脚本",
    "DRIFT": "插件脚本里的端点与本产品记录的对不上(上游可能改过)",
}


def infra_closure(acme_home=None, user_allow=None):
    """基础设施保护闭包是否完整。**不读凭据, 不发任何网络请求。**

    返回 {complete, provider, hosts, reason, detail}。complete=False 时调用方必须
    **拒绝启用** —— 那个 provider 的 API 域名一旦落进第三方广告表, 证书续期会静默失败:
    不是"某个网站打不开"那种一眼可见的故障, 而是几十天后所有面板同时证书过期, 全程零告警。

    user_allow 只用来**说明**用户已经自己写过一条 —— 它不改变"产品无法枚举"这个事实。
    产品说不出该 provider 的全部 API 域名时, 拿用户写的一条来充数, 是把责任偷偷推给用户。
    """
    prov = acme_provider(acme_home)
    if prov is None:
        return {"complete": True, "provider": None, "hosts": (), "reason": "NO_PROVIDER",
                "detail": "未配置 ACME DNS provider —— 没有需要保护的 API 域名"}
    hosts, why = provider_api_hosts(prov, acme_home)
    if hosts:
        return {"complete": True, "provider": prov, "hosts": hosts, "reason": "",
                "detail": "provider %s 的 API 域名已纳入保护: %s" % (prov, ", ".join(hosts))}
    note = ""
    if user_allow and os.path.exists(user_allow):
        # 只作说明, 不参与判定
        if _read(user_allow).strip():
            note = "(你的 allow 名单里已有条目, 但那不能证明该 provider 的**全部** API 域名都在)"
    return {"complete": False, "provider": prov, "hosts": (), "reason": why,
            "detail": "%s: %s%s" % (prov, _CLOSURE_HINT.get(why, why), note)}


def list_is_stale(state_dir=None, max_age_days=14):
    """表是否过期。拿不到元数据 → 返回 None(无结论), 不猜。"""
    m = read_meta(state_dir)
    ts = m.get("updated")
    if not ts:
        return None
    try:
        t = time.mktime(time.strptime(ts, "%Y-%m-%dT%H:%M:%SZ"))
    except ValueError:
        return None
    return (time.time() - t) > max_age_days * 86400


if __name__ == "__main__":
    import sys
    if len(sys.argv) >= 3 and sys.argv[1] == "check":
        print(json.dumps(check_domain(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None),
                         ensure_ascii=False))
    elif len(sys.argv) >= 2 and sys.argv[1] == "update":
        print(json.dumps(update_lists(sys.argv[2] if len(sys.argv) > 2 else None), ensure_ascii=False))
    elif len(sys.argv) >= 3 and sys.argv[1] == "compile":
        compile_effective(sys.argv[2] == "1", sys.argv[3] if len(sys.argv) > 3 else None)
        print("ok")
    else:
        print("用法: adblock.py check <域名> [规则目录] | update [状态目录] | compile <0|1> [状态目录]")
        sys.exit(2)
