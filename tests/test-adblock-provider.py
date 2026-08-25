#!/usr/bin/env python3
"""基础设施保护闭包:ACME DNS provider 的 API 域名能不能枚举,枚举不到时怎么办。

**为什么不能靠从 dnsapi 脚本里提取。**实测(acme.sh 3.1.4)三种形态并存:

    dns_cf.sh   CF_Api="https://api.cloudflare.com/client/v4"    ← 静态常量, 能提
    dns_he.sh   (赋值行里没有任何 https:// 常量)                  ← 提不到
    dns_aws.sh  AWS_HOST="route53.global.api.aws"                ← 主机名与 scheme 分开
                AWS_URL="https://$AWS_HOST"                      ← 运行期拼
                AWS_WIKI="https://github.com/acmesh-official/…"  ← **赋值行上的文档链接**

只按 `VAR=https://…` 提取, dns_aws 会得到 `github.com` —— 一个公共域, 而且是错的。
所以本模块**不猜**: 维护一张显式的受支持表, 并在运行期与真实安装的 dnsapi 脚本交叉核对;
表里没有的 provider、或核对不上的, 一律判为"无法枚举", 由调用方 fail-closed。

判据的立场: **枚举不到 ≠ 没有 provider。**前者必须挡住启用(否则那个 provider 的 API 域名
可能被第三方表拦掉, 证书续期从此静默失败); 后者是正常情形, 不该报错。
"""
import importlib.util
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tmpguard          # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
MOD = ROOT / "deploy/bot/adblock.py"

PASS, FAIL = [0], []


def ok(m):
    PASS[0] += 1
    print("[OK]   %s" % m)


def bad(m):
    FAIL.append(m)
    print("[FAIL] %s" % m)


spec = importlib.util.spec_from_file_location("adblock", MOD)
A = importlib.util.module_from_spec(spec)
spec.loader.exec_module(A)

WORK = Path(tmpguard.mkdtemp(prefix="adblock-provider."))


def need(fn):
    f = getattr(A, fn, None)
    if f is None:
        bad("adblock.py 缺少 %s()" % fn)
    return f


def acme_home(provider=None, dnsapi_body=None, domain="panel.example.invalid"):
    """造一个 acme.sh 的家目录形态: data/<域名>/<域名>.conf 里记 Le_Webroot。"""
    h = Path(tmpguard.mkdtemp(prefix="acme-home."))
    (h / "dnsapi").mkdir(parents=True, exist_ok=True)
    if provider:
        d = h / "data" / domain
        d.mkdir(parents=True, exist_ok=True)
        (d / (domain + ".conf")).write_text(
            "Le_Domain='%s'\nLe_Webroot='%s'\nLe_Keylength='2048'\n" % (domain, provider),
            encoding="utf-8")
        if dnsapi_body is not None:
            (h / "dnsapi" / (provider + ".sh")).write_text(dnsapi_body, encoding="utf-8")
    return str(h)


# ══ ① 受支持表本身的形状 ═══════════════════════════════════════════════════
tbl = getattr(A, "PROVIDER_API_HOSTS", None)
if tbl is None:
    bad("adblock.py 缺少 PROVIDER_API_HOSTS(受支持 provider → API 主机名)")
else:
    okshape = True
    for prov, hosts in tbl.items():
        if not prov.startswith("dns_"):
            bad("provider 名不像 acme.sh 的 dnsapi: %r" % prov); okshape = False
        for h in hosts:
            # 必须是**具体主机名**: 不许通配、不许只有一个公共后缀
            if h.startswith("*") or h.count(".") < 1 or h in ("com", "net", "cn", "org"):
                bad("API 主机名不够具体(等于放行公共域): %r" % h); okshape = False
    if okshape:
        ok("受支持表形状合法(%d 个 provider, 全是具体主机名)" % len(tbl))
    if "dns_cf" in tbl and "api.cloudflare.com" in tbl["dns_cf"]:
        ok("表里含项目文档举例并已在生产使用的 dns_cf → api.cloudflare.com")
    else:
        bad("表里缺 dns_cf/api.cloudflare.com —— 那是项目唯一文档化的 provider")

# ══ ② 识别"已配置 provider" ════════════════════════════════════════════════
prov_of = need("acme_provider")
if prov_of:
    h = acme_home("dns_cf", 'CF_Api="https://api.cloudflare.com/client/v4"\n')
    (ok if prov_of(h) == "dns_cf" else bad)(
        "从 Le_Webroot 认出已配置的 provider(dns_cf)" if prov_of(h) == "dns_cf"
        else "认不出已配置的 provider: %r" % prov_of(h))
    h0 = acme_home(None)
    (ok if prov_of(h0) is None else bad)(
        "没配 provider → 返回 None(不是报错, 也不是猜一个)" if prov_of(h0) is None
        else "没配 provider 却认出了 %r" % prov_of(h0))

# ══ ③ API 域名能否枚举 —— 三种形态各一格 ═══════════════════════════════════
hosts_of = need("provider_api_hosts")
if hosts_of and tbl:
    # (a) 受支持 + 脚本里的常量对得上 → 完整
    h = acme_home("dns_cf", 'CF_Api="https://api.cloudflare.com/client/v4"\n')
    got, why = hosts_of("dns_cf", h)
    (ok if got and "api.cloudflare.com" in got else bad)(
        "dns_cf: 枚举出 %s" % (list(got),) if got else "dns_cf 应能枚举, 实得 %r/%r" % (got, why))
    # (b) 表里没有的 provider → 明确"无法枚举", 且理由具名
    h = acme_home("dns_he", "# 这个插件的赋值行里没有任何 https 常量\n")
    got, why = hosts_of("dns_he", h)
    (ok if not got and why else bad)(
        "dns_he(表外): 判为无法枚举, 理由=%s" % why if not got and why
        else "dns_he 不该被枚举出东西: %r" % (got,))
    # (c) 表里有、但安装的脚本对不上(上游改了端点)→ 漂移, 同样判无法枚举
    h = acme_home("dns_cf", 'CF_Api="https://api.example-changed.invalid/v4"\n')
    got, why = hosts_of("dns_cf", h)
    (ok if not got and why else bad)(
        "dns_cf 但脚本端点漂移: 判为无法枚举(理由=%s)" % why if not got and why
        else "端点漂移却仍报完整: %r" % (got,))

# ══ ④ 闭包完整性判定 ═══════════════════════════════════════════════════════
closure = need("infra_closure")
if closure:
    h = acme_home("dns_cf", 'CF_Api="https://api.cloudflare.com/client/v4"\n')
    r = closure(h)
    (ok if r.get("complete") else bad)(
        "可枚举 → 闭包完整" if r.get("complete") else "可枚举却判不完整: %r" % r)
    h = acme_home("dns_he", "# 无常量\n")
    r = closure(h)
    if r.get("complete"):
        bad("无法枚举却判成完整 —— 这正是要挡住的那一步")
    else:
        (ok if r.get("provider") == "dns_he" else bad)(
            "无法枚举 → 判不完整并点名 provider=%s" % r.get("provider")
            if r.get("provider") == "dns_he" else "没点名 provider: %r" % r)
    h0 = acme_home(None)
    r = closure(h0)
    (ok if r.get("complete") and r.get("provider") is None else bad)(
        "没配 provider → 闭包完整(不误判失败)" if r.get("complete") and r.get("provider") is None
        else "没配 provider 却判不完整: %r" % r)

# ══ ⑤ 文案不许泄露凭据 / 账号 / zone ═══════════════════════════════════════
if closure:
    h = acme_home("dns_cf", 'CF_Api="https://api.cloudflare.com/client/v4"\n')
    # 在同一个家目录里放一份"像凭据"的东西, 断言它不会被带进任何输出
    Path(h, "data", "account.conf").write_text(
        "ACCOUNT_EMAIL='someone@example.invalid'\nCF_Token='SECRET-TOKEN-VALUE'\n", encoding="utf-8")
    r = closure(h)
    blob = json.dumps(r, ensure_ascii=False)
    leaked = [k for k in ("SECRET-TOKEN-VALUE", "someone@example.invalid") if k in blob]
    (ok if not leaked else bad)(
        "闭包结论里不含凭据/账号" if not leaked else "泄露了: %s" % leaked)

# ══ ⑥ 用户手工 allow 不得被当成"产品已识别 provider" ═══════════════════════
if closure:
    h = acme_home("dns_he", "# 无常量\n")
    rd = WORK / "rules"
    rd.mkdir(parents=True, exist_ok=True)
    # 用户自己往 allow 里写了一条, 不代表产品**枚举出了**该 provider 的全部 API 域名
    (rd / "adblock_allow.txt").write_text("domain:dns.he.net\n", encoding="utf-8")
    r = closure(h, user_allow=str(rd / "adblock_allow.txt"))
    (ok if not r.get("complete") else bad)(
        "用户手工 allow 不改变'产品无法枚举'这个事实" if not r.get("complete")
        else "用户写了一条 allow 就被当成闭包完整 —— 那是把责任偷偷推给用户")

# ══ ⑦ doctor: 停用 + 闭包不完整 → WARN 无结论; 启用 + 不完整 → FAIL ═══════
cspec = importlib.util.spec_from_file_location("checks", ROOT / "deploy/bot/checks.py")
C = importlib.util.module_from_spec(cspec)
sys.path.insert(0, str(ROOT / "deploy" / "bot"))
cspec.loader.exec_module(C)


def doctor_with(enabled, complete):
    """把 doctor 放进一个受控现场: 受管块在位、文件齐、生效表非空, 只切换启用位与闭包。"""
    box = Path(tmpguard.mkdtemp(prefix="adblock-doctor."))
    st = box / "state"; st.mkdir()
    rules = box / "rules"; rules.mkdir()
    # 生效表只在**启用态**才非空 —— 停用却留着非空生效表本身就是状态漂移(另有判据盯),
    # 拿那种现场去测"闭包不完整时怎么判", 测到的是漂移那条分支。
    (st / "infra_allow.txt").write_text("domain:x.invalid\n", encoding="utf-8")
    for n in ("effective_block.txt", "effective_list.txt"):
        (st / n).write_text("domain:x.invalid\n" if enabled else "", encoding="utf-8")
    for n in ("adblock_allow.txt", "adblock_block.txt"):
        (rules / n).write_text("", encoding="utf-8")
    (st / "meta.json").write_text(json.dumps(
        {"count": 5000, "source": "t", "updated": __import__("time").strftime("%Y-%m-%dT%H:%M:%SZ")}),
        encoding="utf-8")
    conf = box / "mosdns.yaml"
    conf.write_text(
        "  - tag: internal_sequence\n"
        "    args:\n"
        "      # >>> pdg-adblock managed block (internal_sequence)\n"
        "      - matches: [qname $adblock_user_block]\n"
        "      # <<< pdg-adblock managed block (internal_sequence)\n"
        "      - exec: $lazy_cache\n"
        "  - tag: main_sequence\n"
        "# >>> pdg-adblock managed block (plugins)\n"
        "# <<< pdg-adblock managed block (plugins)\n", encoding="utf-8")
    home = acme_home("dns_cf", 'CF_Api="https://api.cloudflare.com/client/v4"\n') if complete \
        else acme_home("dns_he", "# 无常量\n")
    old = (C.ADBLOCK_STATE_DIR, C.ADBLOCK_USER_ALLOW, C.ADBLOCK_USER_BLOCK,
           C.MOSDNS_CONF, getattr(C, "_profile", None), getattr(C, "ACME_HOME_DIR", None))
    C.ADBLOCK_STATE_DIR = str(st)
    C.ADBLOCK_USER_ALLOW = str(rules / "adblock_allow.txt")
    C.ADBLOCK_USER_BLOCK = str(rules / "adblock_block.txt")
    C.MOSDNS_CONF = str(conf)
    C.ACME_HOME_DIR = home
    C._profile = lambda k: ("1" if enabled else "0") if k == "PDG_ADBLOCK_ENABLED" else None
    try:
        return C.check_adblock()
    finally:
        (C.ADBLOCK_STATE_DIR, C.ADBLOCK_USER_ALLOW, C.ADBLOCK_USER_BLOCK,
         C.MOSDNS_CONF) = old[:4]
        if old[4]:
            C._profile = old[4]


r = doctor_with(enabled=False, complete=False)
if r and r[0] == "warn" and ("无结论" in r[2] or "不完整" in r[2]):
    ok("doctor: 停用 + 闭包不完整 → WARN 且明说(%s)" % r[2][:44])
else:
    bad("doctor: 停用 + 闭包不完整应 WARN + 无结论, 实得 %r" % (r,))

r = doctor_with(enabled=True, complete=False)
if r and r[0] == "fail":
    ok("doctor: 启用 + 闭包不完整 → FAIL(%s)" % r[2][:44])
else:
    bad("doctor: 启用 + 闭包不完整必须 FAIL, 实得 %r" % (r,))

r = doctor_with(enabled=True, complete=True)
if r and r[0] == "ok":
    ok("doctor: 启用 + 闭包完整 → ok")
else:
    bad("doctor: 启用 + 闭包完整应 ok, 实得 %r" % (r,))

print("-" * 58)
print("通过 %d, 失败 %d" % (PASS[0], len(FAIL)))
sys.exit(1 if FAIL else 0)
