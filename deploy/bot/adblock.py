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
import http.client
import ipaddress
import json
import os
import re
import socket
import ssl
import tempfile
import time
import urllib.parse

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
#   max_entries 500000 —— 见下面 LIMITS 里那段实测。(旧值 150000 出自更早的 Phase 0, 那次
#                         的约束是 MemoryMax=96M —— 一个测试时人为加的上限, 产品并不设它;
#                         按"整机 512M 可用"重测之后, 那个数不再是决策依据。)
#   max_skip_ratio 1%  —— 第三方表逐行域名不合格时跳过的比例上限, 见 LIMITS 里的说明。
#   max_bytes   8 MiB  —— 实测 anti-AD 2.0 MiB / AdGuard 4.1 MiB / adblockfilters 4.2 MiB;
#                         8 MiB 留了余量,
#                         同时给下载一个硬边界(防的是"对方返回了一个巨大的东西")。
#   min_entries 1000   —— 真实广告表都在万条以上; 1000 挡的是截断、半截下载与错页。
#   max_drop_ratio 0.5 —— 新表不足上一份 LKG 的一半就拒。源被投毒或半截发布时, 条目数是
#                         最先塌下来的那个量。
LIMITS = {
    "min_entries": 1000,
    # 512M 整机实测重定(旧值 150000 是更早在 MemoryMax=96M 那个更紧的约束下压的, 已不是
    # 今天的决策依据)。真跑 mosdns v5.3.4 + 生产模板 + 145591 条 geosite, 逐档量 RSS:
    #     15 万 61.6 MiB · 30 万 77.8 · 50 万 108.6 · 60 万 109.5 · 80 万 123.0 · 100 万 166.7
    # 选 50 万是因为它正好在一个台阶顶上(50 万与 60 万的 RSS 几乎一样), 再多一点不会突然
    # 多吃内存。512M 机器上非 mosdns 部分实测约 217 MiB(mihomo 36.4 + bot 39.6 + lan 40.9
    # + 系统底噪), 50 万条时整机约 326 MiB, **余量 186 MiB 且不依赖 swap**。
    # 延迟与条数无关: 150 qps 定速下 p50 稳在 0.11 ms、p95 0.18 ms, 从 15 万到 100 万看不出
    # 趋势 —— domain_set 的查询是 O(域名长度) 而不是 O(表大小)。约束只在内存。
    "max_entries": 500000,
    "max_bytes": 8 * 1024 * 1024,
    "max_drop_ratio": 0.5,
    # 逐行域名校验失败允许跳过的比例上限。第三方表是**别人**在维护, 上游一行手滑不该让用户
    # 整张表用不了(线上实测: 21.5 万条的表里一行下划线就全废)。但也不能静默丢 —— 跳过要计数
    # 并上报, 超过这个比例仍然整份拒: 格式真的变了(比如返回半页 HTML), 比例会立刻远超 1%。
    "max_skip_ratio": 0.01,
    # 用户自己那份 block 文件的上限。以前一道都没有 —— 而 compile_effective 把它**逐字节**
    # 拷进 mosdns 要加载的 effective_block.txt, 也就是说上面那个按 512 MiB 定出来的内存预算
    # 可以从这条路完整绕过去。规则是能脚本化追加的(rule-add 就是给 Bot 用的), 一个循环写岔、
    # 或者把一份下载来的表直接 `cat >>` 进去就到了; 触发之后不会有任何提示, 只在下一次
    # enable 或 mosdns 重启时把整台机器的 DNS 打没。
    #
    # 50000 条的依据是同一次 512 MiB 实测: 15 万条 61.6 MiB → 50 万条 108.6 MiB, 边际约
    # 0.134 KiB/条, 50000 条 ≈ 6.7 MiB, 相对那次测出来的 186 MiB 余量不到 4%。手工维护的
    # 名单到不了这个量级 —— 到得了的那都不是手工维护的。
    # 2 MiB 是同一件事的另一面: 50000 条 × 约 40 字符。单行极长的病态文件靠它兜住。
    "max_user_entries": 50000,
    "max_user_bytes": 2 * 1024 * 1024,
    # 一次批量最多接受多少个域名。这个数不是内存约束(那由上面两条兜着), 是**回执可读性**与
    # 事务时长: 100 条的逐条回执在 Telegram 里已经要翻屏了, 再多用户也读不完; 而一笔事务
    # 拖太久, 期间 `pdg update` 就一直抢不到锁。粘贴一屏域名远超这个数的, 那是在导入一份表,
    # 该走 `source add` 而不是手工规则。
    "max_bulk_domains": 100,
}

# 放行下划线: DNS 协议本身允许(`_dmarc` / `_acme-challenge` 就是), 只是 RFC 1123 的
# **hostname** 规范不允许。作为阻断规则的模式串, 下划线不造成任何歧义或注入, 而拒掉它等于
# 对一类真实存在、也确实该拦的名字视而不见(线上那张表里的 fb_servpub-a.akamaihd.net)。
# 放宽的**只有**下划线 —— 连字符不许出现在标签首尾这条没动, 通配符 / 路径 / ABP / 正则 /
# IP 字面量仍然由 _SYNTAX_CHARS 与后面几道判据整份拒。
_DOMAIN_RE = re.compile(r"^(?=.{1,253}$)[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?"
                        r"(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?)+$")
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
    """薄封装: 只要域名列表。整份被拒时返回空列表, 与首版行为一致。"""
    return parse_source_ex(text)[0]


def parse_source_ex(text):
    """(names, skipped, reject_reason)。把一份第三方表解析成域名列表。**拒绝比接受更重要** —— 拒不掉的坏输入会变成一张
    看着正常的假表。任何一行认不出来就整份拒(返回空列表),不做"尽力而为"的部分解析:
    部分解析出来的表少了多少条没人知道,而少掉的正是被跳过的那些。
    """
    if not text or not text.strip():
        return ([], 0, "空内容")
    head = text[:4096].lower()
    if any(h in head for h in _REJECT_HINTS):
        return ([], 0, "看着像 HTML 错页")           # 结构性不对 → 整份拒
    names, skipped = [], 0
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#") or s.startswith("!"):
            continue                                # 注释(# 与 ABP 的 !)
        if any(c in _SYNTAX_CHARS for c in s):
            return ([], 0, "含 ABP / 正则 / URL / 通配语法")   # 结构性不对
        parts = s.split()
        if len(parts) == 2 and _IPV4_RE.match(parts[0]):
            cand = parts[1]                         # hosts 格式: 0.0.0.0 domain
        elif len(parts) == 1:
            cand = parts[0]
        else:
            return ([], 0, "认不出的行形态")         # 结构性不对
        cand = cand.strip().lower().rstrip(".")
        # 纯 IP / localhost: **跳过计数**, 不整份拒。合并型广告表从多个上游拼起来, 掺进
        # 几条 IP 是常态(线上那张 215320 行的表里有 57 条, 占 0.026%), 而 domain_set 里放
        # 一个 IPv4 字面量, mosdns 会拿它当域名匹配 —— 永远匹配不到真实查询, 无害也无用。
        # 为这点比例废掉 21.5 万条不成比例。真拿错成一份 IP 黑名单时, 比例会接近 100%,
        # 下面的 max_skip_ratio 照样把它整份拒掉。
        if (_IPV4_RE.match(cand)
                or cand in ("localhost", "localhost.localdomain", "local")
                or not _DOMAIN_RE.match(cand)):
            skipped += 1                            # 逐行的域名不合格: 跳过并计数
            continue
        names.append(cand)
    total = len(names) + skipped
    if skipped and total and skipped > total * LIMITS["max_skip_ratio"]:
        return ([], skipped,
                "跳过的行 %d / %d 超过上限 %.0f%%(格式可能已经变了)"
                % (skipped, total, LIMITS["max_skip_ratio"] * 100))
    return (normalize(names), skipped, "")


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


def _canonical_block_line(domain):
    """用户 block 源里的规范形态。**只有这一种形态**由本接口产生与删除。

    为什么钉成 `domain:` 而不是裸名: 裸行在 mosdns 的 domain_set 里是后缀语义, 与
    `domain:` 等价, 但两种形态混着写会让"这一行是谁加的、能不能删"变得没法回答。
    工具只产出一种形态, 也只删这一种 —— 用户自己手写的任何形态都不归它管。
    """
    return "domain:" + domain


class BlockListFull(ValueError):
    """用户 block 文件满了。

    **必须与"域名不合法"分开。**继承 ValueError 是为了不破坏既有的 `except ValueError`,
    但调用方要先接这一支: 把"文件满了"报成 INVALID_DOMAIN, 用户会照着那句去改一个完全合法的
    域名, 改多少次都没用 —— 而真正要做的是删几条旧规则。
    """


def user_block_overflow(text):
    """用户 block 文件是否超限。返回 (超了吗, 原因)。

    只看两件事: 非空非注释的行数、字节数。**不做规范化、不去重** —— 那会改变"用户文件里
    到底有多少条"这个事实, 而这道门要拦的正是那个事实。
    """
    n = sum(1 for ln in text.splitlines()
            if ln.strip() and not ln.strip().startswith("#"))
    if n > LIMITS["max_user_entries"]:
        return (True, "用户规则 %d 条, 超过上限 %d 条" % (n, LIMITS["max_user_entries"]))
    b = len(text.encode("utf-8", "replace"))
    if b > LIMITS["max_user_bytes"]:
        return (True, "用户规则文件 %.1f MiB, 超过上限 %.1f MiB"
                % (b / 1048576.0, LIMITS["max_user_bytes"] / 1048576.0))
    return (False, "")


def rule_add(domain, path=None):
    """把域名以 canonical 形态加进用户 block 源。返回 (change, normalized)。

    change ∈ {"added", "none"}。已存在完全相同的规范行时是 no-op —— 不写文件, 于是上层
    的"产物没变就不重启"能一路成立。

    其它行**逐字节保留**: 不排序、不去重、不整理注释与空行。用户手写的东西不归这个接口管,
    动了它就等于替用户做决定。
    """
    good, norm, why = validate_domain(domain)
    if not good:
        raise ValueError(why)
    target = path or USER_BLOCK
    canon = _canonical_block_line(norm)
    try:
        with open(target, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        text = ""
    if any(ln.strip() == canon for ln in text.splitlines()):
        return ("none", norm)
    if text and not text.endswith("\n"):
        text += "\n"
    cand = text + canon + "\n"
    # 在**加的那一刻**撞墙, 而不是几天后 enable 时才发现。这里判的是"加完之后会不会超",
    # 不是"现在超没超" —— 后者会让最后一条压线的规则加进去, 然后 compile 那道门再把整个
    # enable 拒掉, 用户得到的是一次莫名其妙的失败。
    over, why = user_block_overflow(cand)
    if over:
        raise BlockListFull(why + " —— 未添加。先删掉一些用不着的规则(pdg adblock rule-del)。")
    _atomic_write(target, cand)
    return ("added", norm)


def rule_add_many(domains, path=None):
    """一次加多个。返回 (results, changed)。

    **逐条给结果, 不整批拒。** 用户粘贴 20 个域名、其中一个打错就整批退回的话, 他还得自己
    去找是哪一个 —— 那正是他想让机器替他做的事。所以合法的照收, 不合法的逐条点名。

    只有两种情况整批拒: 条数超上限、空输入。那两种下面一个字节都不写。

    写盘只有**一次**: 逐条 append 会让 N 条规则产生 N 次原子写, 中途失败就停在一个谁也说不清
    的中间态。这里先在内存里把最终文本拼好, 一次落盘。
    """
    doms = [d.strip() for d in domains if d and d.strip()]
    if not doms:
        return ([], 0, "EMPTY")
    if len(doms) > LIMITS["max_bulk_domains"]:
        return ([], 0, "TOO_MANY")
    target = path or USER_BLOCK
    try:
        with open(target, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        text = ""
    if text and not text.endswith("\n"):
        text += "\n"
    have = {ln.strip() for ln in text.splitlines() if ln.strip()}
    results = []
    changed = 0
    for raw in doms:
        good, norm, why = validate_domain(raw)
        if not good:
            # **不回显原文** —— 与 check / rule-add 同一条规矩。域名字段回的是用户给的那个串,
            # 用户要靠它认出是哪一条打错了; why 只说是哪一类不合法。
            results.append({"domain": raw, "error": "INVALID_DOMAIN", "why": why})
            continue
        canon = _canonical_block_line(norm)
        if canon in have:
            results.append({"domain": raw, "normalized": norm, "change": "none"})
            continue
        cand = text + canon + "\n"
        over, why2 = user_block_overflow(cand)
        if over:
            # 满了之后**继续走完剩下的**: 每一条都得有回执, 用户才知道谁没进去。
            results.append({"domain": raw, "normalized": norm,
                            "error": "BLOCKLIST_FULL", "why": why2})
            continue
        text = cand
        have.add(canon)
        changed += 1
        results.append({"domain": raw, "normalized": norm, "change": "added"})
    if changed:
        _atomic_write(target, text)
    return (results, changed, "")


def rule_del(domain, path=None):
    """从用户 block 源里删掉 canonical 行。返回 (change, normalized)。

    **只删规范化后完全相等的那一行。** 父域、子域、`full:`、裸规则、注释、包含该字符串的
    其它行, 一律不动 —— 子串匹配在这里等于"用户以为删了一条, 实际被删掉一片"。

    完全相等的重复行(历史原因可能有)**全部删除**: 留一条下来的话, 同一个接口连续两次删除
    会得到不同结果, 幂等就不成立了。
    """
    good, norm, why = validate_domain(domain)
    if not good:
        raise ValueError(why)
    target = path or USER_BLOCK
    canon = _canonical_block_line(norm)
    try:
        with open(target, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        return ("none", norm)
    lines = text.splitlines(keepends=True)
    kept = [ln for ln in lines if ln.strip() != canon]
    if len(kept) == len(lines):
        return ("none", norm)
    _atomic_write(target, "".join(kept))
    return ("removed", norm)


def check_domain(domain, state_dir=None, rules_dir=None):
    """逐层判定一个域名。**只读规则文件** —— 不发 DNS 查询、不读日志、不落 qname。

    读的是 **mosdns 真正读的那四个文件**, 不是"用户写在哪儿":
        infra_allow.txt / effective_block.txt / effective_list.txt  在状态目录
        adblock_allow.txt                                          在 mosdns 规则目录
    这个区分不是洁癖 —— 用户 block 的源文件与**编译产物**是两份不同的东西(停用时后者
    为空而前者原样保留), check 要回答的是"此刻会不会被拦", 那就必须看编译产物。
    第一版把这两者混成一个候选名, 于是在真实布局下永远找不到用户 block。
    """
    base = state_dir or STATE_DIR
    rbase = rules_dir or RULES_DIR
    def p(d, name, fallback):
        cand = os.path.join(d, name)
        return cand if os.path.exists(cand) else fallback
    layers = (
        ("ADBLOCK_INFRA_ALLOW", p(base, "infra_allow.txt", INFRA_ALLOW), False),
        ("ADBLOCK_USER_ALLOW", p(rbase, "adblock_allow.txt",
                                 p(base, "adblock_allow.txt", USER_ALLOW)), False),
        ("ADBLOCK_USER_BLOCK", p(base, "effective_block.txt",
                                 p(base, "adblock_block.txt", EFF_BLOCK)), True),
        ("ADBLOCK_LIST_BLOCK", p(base, "effective_list.txt", EFF_LIST), True),
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
        # rule-add 不是唯一入口 —— 那份文件是用户数据, 可以直接编辑, 也会被快照恢复带回来。
        # 所以这里才是真正的门。超限**整笔不落盘**: 现网继续用上一份编译产物, 与 update 那边
        # "任何一步不成立都不落盘, 继续用 LKG"是同一条规矩。
        ub_text = _read(ub)
        over, why = user_block_overflow(ub_text)
        if over:
            return (False, why)
        _atomic_write(os.path.join(d, "effective_block.txt"), ub_text)
        raw = normalize(_read(lk).splitlines())
        _atomic_write(os.path.join(d, "effective_list.txt"),
                      "".join("domain:%s\n" % x for x in raw))
    else:
        _atomic_write(os.path.join(d, "effective_block.txt"), "")
        _atomic_write(os.path.join(d, "effective_list.txt"), "")
    return True




def update_lists(state_dir=None, sources=None, fetch=None):
    """更新事务。任何一步不成立都**整笔不落盘**, 现网继续用 last-known-good。

    返回 {"ok": bool, "reason": <reason code>, "detail": str, "count": int}
    """
    d = state_dir or STATE_DIR
    os.makedirs(d, exist_ok=True)
    lk = os.path.join(d, "list.lkg")
    prev = read_meta(d).get("count") or None
    src = list(sources or DEFAULT_SOURCES)
    hosts = allowed_fetch_hosts(src)          # 白名单跟着**这一次真正要取的源**算
    fetch = fetch or (lambda u: _safe_fetch(u, LIMITS["max_bytes"], allowed_hosts=hosts))
    errs = []
    for url in src:
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
        names, skipped, rej = parse_source_ex(text)
        if rej:
            errs.append("%s: %s" % (url, rej))
            continue
        good, why = validate_candidate(names, prev_count=prev)
        if not good:
            errs.append("%s: %s" % (url, why))
            continue
        # 候选过关 —— 先写 LKG 的备份, 再原子替换; 失败要能退回去
        backup = _read(lk) if os.path.exists(lk) else None
        try:
            _atomic_write(lk, "\n".join(names) + "\n")
            _atomic_write(os.path.join(d, "meta.json"), json.dumps({
                "count": len(names), "source": url, "skipped": skipped,
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


# ── 安全下载 ─────────────────────────────────────────────────────────────────
# 上一轮安全终审实测到两件事(都是真跑出来的, 不是读代码推的):
#   · urllib 默认**跟随重定向**: 让服务回 `302 → http://127.0.0.1:<port>/`, 客户端照单
#     跟过去并取回内容 —— 上游一旦被劫持或 DNS 被污染, 它就能让网关去访问自己的回环与内网;
#   · 没有 scheme 白名单时, 明文 `http://` 照样能取。
# 对一个墙内 DNS 网关来说这不是遥远的威胁模型, 而它的回环上正跑着 mosdns 53 / witness
# 5399 / probe81 81 / mihomo api 9090 / 救援平面。
#
# 所以这里**不用任何会自己解析域名或自己跟随重定向的 HTTP 客户端**: 自己解析、自己校验、
# 自己连、自己发一个最小请求。多写几十行, 换的是"校验过的地址就是真正连上去的地址"。

SOURCES_FILE = "/etc/privdns-gateway/adblock-sources.txt"     # 用户源, 一行一个; 是用户数据


def check_source_url(url):
    """(ok, reason)。URL 形态的**单一真源** —— `source add` 与 `_safe_fetch` 用同一套。

    分开写是为了让 `source add` 能在**落盘之前**当场拒:等到 update 才报"这个源不合规",
    用户已经把它记进配置里了, 排查起来还得先想起来是什么时候加的。
    这里只判 URL 本身, 不做任何网络动作。
    """
    p = urllib.parse.urlsplit(url or "")
    if p.scheme != "https":
        return (False, "只允许 https(实得 scheme=%s)" % (p.scheme or "空",))
    if p.username or p.password:
        return (False, "URL 里带 userinfo")
    try:
        port = p.port
    except ValueError:
        return (False, "URL 的端口部分非法")
    if port not in (None, 443):
        return (False, "只允许默认 443 端口(实得 %s)" % port)
    host = p.hostname or ""
    if not host:
        return (False, "URL 里没有主机名")
    try:
        ipaddress.ip_address(host)
        return (False, "主机名是 IP 字面量(证书与白名单都无从谈起)")
    except ValueError:
        pass
    if not _DOMAIN_RE.match(host.lower()):
        return (False, "主机名不是合法域名")
    return (True, "")


def read_sources(path=None):
    """用户配置的源; 没配就返回内置默认。允许 # 注释与空行。

    "没配 = 用默认"这条让老机器升上来行为一个字节不变 —— 升级不该顺手改掉别人在用的源。
    """
    try:
        with open(path or SOURCES_FILE, encoding="utf-8") as f:
            urls = [l.strip() for l in f if l.strip() and not l.strip().startswith("#")]
    except OSError:
        urls = []
    return urls or list(DEFAULT_SOURCES)


def allowed_fetch_hosts(sources=None):
    """允许连接的主机名 = 从**生效的源**算出来的精确集合。不是通配、不是后缀匹配,
    也不是"URL 里写了什么就信什么"。

    用户 `source add` 一个主机, 它才进这个集合 —— 那一步本身就是显式授权, 且 add 时已经
    过了 check_source_url。**没被配置过的主机照样连不上**: 这道门挡的是"URL 被改成任意
    地方", 而真正的安全价值在它后面几道(零重定向 / 非公网地址拒绝 / DNS 与连接地址绑定 /
    TLS 用原始主机名校验)—— 那几道一条都没有因为源可配而松动。
    """
    src = sources if sources is not None else read_sources()
    return frozenset(h for h in (urllib.parse.urlsplit(u).hostname for u in src) if h)


# 内置默认算出来的那份, 保留给不传 sources 的老调用点(行为与首版一致)。
ALLOWED_FETCH_HOSTS = frozenset(
    h for h in (urllib.parse.urlsplit(u).hostname for u in DEFAULT_SOURCES) if h)

FETCH_TIMEOUT = 45


class FetchRefused(OSError):
    """下载在**连接之前或期间**被判据拒绝。文案里绝不带原始 URL —— 它可能含 userinfo。"""


def _is_public_addr(addr):
    """这个地址能不能连。

    ⚠️ 只用 `is_global` 是不够的: Python 3.11.2 实测 `224.0.0.1` 与 `ff02::1` 的
    `is_global` 都是 **True**(组播不在它的判定里)。所以下面把每一类分别点名 ——
    宁可写长, 也不把"标准库大概覆盖了吧"当判据。
    """
    try:
        o = ipaddress.ip_address(addr)
    except ValueError:
        return False
    if (o.is_loopback or o.is_private or o.is_link_local or o.is_multicast
            or o.is_reserved or o.is_unspecified):
        return False
    return bool(o.is_global)


def _default_resolve(host):
    infos = socket.getaddrinfo(host, 443, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    out, seen = [], set()
    for ai in infos:
        a = ai[4][0]
        if a not in seen:
            seen.add(a)
            out.append(a)
    return out


def _default_connect(addr, port, timeout):
    return socket.create_connection((addr, port), timeout=timeout)


def _safe_fetch(url, max_bytes, resolve=None, connect=None, ssl_context=None,
                allowed_hosts=None):
    """按固定白名单取一份规则表。返回 (text, content_type, status)。

    每一道都在**连接之前**判完, 判不过就一个字节都不发。
    """
    p = urllib.parse.urlsplit(url)
    if p.scheme != "https":
        raise FetchRefused("只允许 https(实得 scheme=%s)" % (p.scheme or "空",))
    if p.username or p.password:
        raise FetchRefused("URL 里带 userinfo —— 拒绝(不回显内容)")
    try:
        port = p.port
    except ValueError:
        raise FetchRefused("URL 的端口部分非法")
    if port not in (None, 443):
        raise FetchRefused("只允许默认 443 端口(实得 %s)" % port)
    host = p.hostname or ""
    if not host:
        raise FetchRefused("URL 里没有主机名")
    try:
        ipaddress.ip_address(host)
        raise FetchRefused("主机名是 IP 字面量 —— 拒绝(证书与白名单都无从谈起)")
    except ValueError:
        pass
    if host not in (allowed_hosts if allowed_hosts is not None else ALLOWED_FETCH_HOSTS):
        raise FetchRefused("主机名不在允许集合内: %s" % host)

    addrs = (resolve or _default_resolve)(host)
    if not addrs:
        raise FetchRefused("解析不到任何地址: %s" % host)
    bad = [a for a in addrs if not _is_public_addr(a)]
    if bad:
        # **有一个不干净就整次失败**, 不从里面挑一个能用的 —— 挑就等于允许对方混进来一个
        # 内网地址再靠运气避开。
        raise FetchRefused("解析结果里有非公网地址(%d/%d), 整次拒绝" % (len(bad), len(addrs)))

    addr = addrs[0]
    sock = (connect or _default_connect)(addr, 443, FETCH_TIMEOUT)
    try:
        ctx = ssl_context or ssl.create_default_context()      # 系统 CA, 且默认校验主机名
        # server_hostname 用**原始主机名**: SNI 与证书校验都必须对着它, 不是对着 IP。
        tls = ctx.wrap_socket(sock, server_hostname=host)
    except Exception:
        try:
            sock.close()
        except OSError:
            pass
        raise
    try:
        tls.settimeout(FETCH_TIMEOUT)
        path = p.path or "/"
        if p.query:
            path += "?" + p.query
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: privdns-gateway/adblock\r\n"
               "Accept: text/plain\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
               % (path, host))
        tls.sendall(req.encode("ascii"))
        resp = http.client.HTTPResponse(tls, method="GET")
        resp.begin()
        status = resp.status
        ctype = (resp.getheader("Content-Type") or "").lower()
        if status != 200:
            # **重定向一律不跟随。**跟随是这一整段存在的理由。
            raise FetchRefused("只接受 200, 实得 %d(重定向一律不跟随)" % status)
        data = resp.read(max_bytes + 1)
        if len(data) > max_bytes:
            raise FetchRefused("超过最大下载体积 %d" % max_bytes)
        return (data.decode("utf-8", "replace"), ctype, status)
    finally:
        try:
            tls.close()
        except OSError:
            pass


# ── 域名输入契约 ─────────────────────────────────────────────────────────────
_LABEL_RE = re.compile(r"^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


def validate_domain(value):
    """(ok, normalized, reason)。**只接受一个 ASCII DNS 名称。**

    为什么要有它: `check` 原来对空值、换行、`../../etc/passwd`、`*.example.com`、IP 字面量
    一律答"未阻断"。那不是安全洞(纯字符串匹配), 是**诚实性缺口** —— 用户问"这个会不会被
    拦", 工具对一个根本不是域名的东西回答"不会被拦"。诊断命令给出看似确定的错答案,
    比报错更糟。
    """
    if value is None:
        return (False, "", "空值")
    if not isinstance(value, str):
        return (False, "", "不是字符串")
    if value != value.strip():
        return (False, "", "前后有空白")
    if not value:
        return (False, "", "空值")
    if any(ord(c) < 0x20 or ord(c) == 0x7F for c in value):
        return (False, "", "含控制字符")
    if any(ord(c) > 0x7E for c in value):
        return (False, "", "含非 ASCII 字符(请用 xn-- punycode 形式)")
    v = value[:-1] if value.endswith(".") else value           # 允许**一个**末尾点
    if not v:
        return (False, "", "只有一个点")
    if len(v) > 253:
        return (False, "", "总长超过 253")
    try:
        ipaddress.ip_address(v)
        return (False, "", "是 IP 字面量, 不是域名")
    except ValueError:
        pass
    labels = v.split(".")
    # **单 label 是合法查询对象。**用户可以往 adblock_block.txt 里写 `intranet` / `nas`
    # 这类局域网名字(靠搜索域补全), compile_effective 原样透传, mosdns 真的按它拦 ——
    # 诊断工具必须覆盖运行时能生效的规则全集, 否则就存在"能被拦却查不了"的域名。
    #
    # 代价是 `check invalid` 这种笔误会被当成一个合法单 label 来回答。可以接受:
    # check 是只读命令, 只回报阻断状态, 不发 DNS 查询也不改任何状态。
    #
    # 放宽的**只有**"至少两个 label"这一条 —— 下面每个 label 的语法约束一个都不松。
    # 第三方下载表另有 _DOMAIN_RE 把关, 仍要求至少一个点: 那边一行 `com` 就能拦掉整个 TLD。
    for lb in labels:
        if not lb:
            return (False, "", "有空 label")
        if len(lb) > 63:
            return (False, "", "有 label 超过 63 字符")
        if not _LABEL_RE.match(lb):
            return (False, "", "label 只能是字母/数字/连字符, 且不能以连字符开头或结尾")
    return (True, v.lower(), "")


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
        good, norm, why = validate_domain(sys.argv[2])
        if not good:
            # **不回显原始输入** —— 它可能含 shell 标点或换行, 复述一遍等于把危险内容
            # 又抄进日志与用户的排障截图里。只说是哪一类不合法。
            print(json.dumps({"error": "INVALID_DOMAIN", "why": why}, ensure_ascii=False))
            sys.exit(2)
        print(json.dumps(check_domain(norm,
                                      sys.argv[3] if len(sys.argv) > 3 else None,
                                      sys.argv[4] if len(sys.argv) > 4 else None),
                         ensure_ascii=False))
    elif len(sys.argv) >= 3 and sys.argv[1] == "check-source":
        good, why = check_source_url(sys.argv[2])
        print(json.dumps({"ok": good, "why": why}, ensure_ascii=False))
        sys.exit(0 if good else 2)
    elif len(sys.argv) >= 2 and sys.argv[1] == "list-sources":
        print(json.dumps({
            "sources": read_sources(sys.argv[2] if len(sys.argv) > 2 else None),
            "defaults": list(DEFAULT_SOURCES),
        }, ensure_ascii=False))
    elif len(sys.argv) >= 2 and sys.argv[1] == "rule-add-many":
        # 域名走 **stdin**, 一行一个。不走 argv: 条数由用户决定, 而 argv 有长度上限,
        # 超限的表现是 E2BIG —— 一个跟"域名对不对"毫无关系的报错。
        _doms = [l for l in sys.stdin.read().splitlines()]
        _res, _changed, _err = rule_add_many(
            _doms, sys.argv[2] if len(sys.argv) > 2 else None)
        if _err:
            print(json.dumps({"error": _err, "results": [], "changed": 0},
                             ensure_ascii=False))
            sys.exit(2)
        print(json.dumps({"results": _res, "changed": _changed}, ensure_ascii=False))
        # 有任何一条没进去就退非零 —— 调用方不该靠数数组长度才发现出了事。
        sys.exit(0 if all("error" not in r for r in _res) else 2)
    elif len(sys.argv) >= 3 and sys.argv[1] in ("rule-add", "rule-del"):
        # 只吐 JSON, 不吐文案 —— 调用方(pdg.sh → Bot)认字段不认措辞。
        # 与 check 同一条规矩: **非法输入不回显原文**, 只说是哪一类不合法。
        try:
            fn = rule_add if sys.argv[1] == "rule-add" else rule_del
            change, norm = fn(sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else None)
        except BlockListFull as e:
            # 先接这一支: 它也是 ValueError, 落到下面就会被报成"域名不合法"。
            print(json.dumps({"error": "BLOCKLIST_FULL", "why": str(e)}, ensure_ascii=False))
            sys.exit(4)
        except ValueError as e:
            print(json.dumps({"error": "INVALID_DOMAIN", "why": str(e)}, ensure_ascii=False))
            sys.exit(2)
        print(json.dumps({"change": change, "normalized": norm}, ensure_ascii=False))
    elif len(sys.argv) >= 2 and sys.argv[1] == "update":
        # argv[3] 可选: 用户源文件路径。调用方(pdg.sh)手里就有这个真源, 传进来比在这里
        # 再写死一次好, 也让沙箱测试能指到假根。
        _srcs = read_sources(sys.argv[3]) if len(sys.argv) > 3 else None
        print(json.dumps(update_lists(sys.argv[2] if len(sys.argv) > 2 else None, _srcs),
                         ensure_ascii=False))
    elif len(sys.argv) >= 3 and sys.argv[1] == "compile":
        # 第 4 个参数是用户 block 源的路径, 可选。调用方(pdg.sh)手里本来就有 ADB_USER_BLOCK
        # 这个真源, 让它传进来比在这里再写死一次好 —— 也让沙箱测试能指到假根, 而不必去
        # 伪造 /etc/mosdns。不传时沿用模块常量, 现有调用点行为不变。
        _r = compile_effective(sys.argv[2] == "1",
                               sys.argv[3] if len(sys.argv) > 3 else None,
                               sys.argv[4] if len(sys.argv) > 4 else None)
        # 拒绝的理由必须能传到调用方 —— 否则用户拿到的是一次没有原因的失败。
        if _r is not True:
            sys.stderr.write("%s\n" % (_r[1] if isinstance(_r, tuple) else "编译被拒"))
            sys.exit(3)
        print("ok")
    else:
        print("用法: adblock.py check <域名> [规则目录] | update [状态目录] | compile <0|1> [状态目录]")
        sys.exit(2)
