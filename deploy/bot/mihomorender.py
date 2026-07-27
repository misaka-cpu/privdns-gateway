#!/usr/bin/env python3
"""model(sing-box JSON)→ mihomo 运行配置的**共享**渲染实现。

为什么要单独成一个模块: 这些逻辑原先只长在 pdg-bot.py 里, 而 pdg-bot 依赖 Telegram 交互层、
import 期就要读 config.json —— 救援平面的立身之本恰恰是"bot 可能正是坏掉的那一个", 不能
import 它。于是"改了 model 就必须在**同一笔事务**里重渲 mihomo 配置"这条纪律, 救援侧根本
没有办法遵守。

这不是假想的洁癖: cfgrestore 的「恢复受管配置」就栽在这里 —— 它把 config.json 换回了旧版,
`restart:mihomo` 也照常执行, 但 /etc/mihomo/config.yaml 没跟着重渲, 内核重启后跑的仍是旧的
那一份(mihomo 的 ExecStart 读的是 config.yaml, config.json 只是数据模型)。恢复"成功"了,
运行中的内核却纹丝不动。

设计约束(刻意的):
  · 本模块**只依赖标准库 + sb2mihomo**(pdgtx 是软依赖, 只在边界映射异常类型时用到,
    **不用来决定错误安不安全** —— 判废异常自带安全的 str);
  · 绝不 import pdg-bot, 也**绝不读 bot 的可变全局** —— 路径一律由调用方显式传进来。
    bot 侧的 RS_META / MITM_HIJACK_FILE 是测试会 monkeypatch 的入口, 若这里另存一份常量
    别名, patch 了 bot 的那份不会传导过来, 测试就会在"看着改了、其实没改"的状态下变绿;
  · 判据只有这一处 —— bot、cfgrestore、救援三条路调用同一份实现, 不存在"一个拦一个不拦"。
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/pdg-bot")

MIHOMO_REDIR = 7893                     # mihomo redir 入口
MITM_PORT = 7894                        # MITM 服务(socks5); 接管域名路由到这
MRS_BEHAVIORS = ("domain", "ipcidr")
_MRS_BEHAVIOR_BYTE = {0: "domain", 1: "ipcidr"}
# mihomo 有路径安全限制: external-ui 等路径须在工作目录下或 SAFE_PATHS 白名单内。观测面板 UI
# 在 /etc/sing-box/ui/dist(与 sing-box 共用), 不在 /etc/mihomo 下 → 放行, 使所有 `mihomo -t` 都认。
os.environ.setdefault("SAFE_PATHS", "/etc/sing-box/ui/dist")


class RenderRefused(Exception):
    """渲染判废 —— **默认字符串里没有任何用户值**。

    为什么要自己定义而不是借 pdgtx.TxRefused: 原来的做法是"有 pdgtx 就用它的异常类, 没有就
    退回 RuntimeError", 于是**安全性取决于 pdgtx 在不在** —— 没有它时, 出口 tag 与规则集名
    会原样进异常正文, 而那两样都是用户可以随便起名的字段。安全不能是可选项。

    所以: 原始标识只放在结构化的 .items 里, str()/repr() 只给固定 code、类别与**计数**。
    要展示具体名字的调用方, 在自己的边界上用 detail(redact=…) 明确要一次 —— 拿得到脱敏函数
    就脱敏后展示, 拿不到就只能看到安全默认串。"""

    # 固定错误码: 供调用方分类, 不随文案变化
    UNKNOWN_PROXIES = "RENDER_REFUSED_UNKNOWN_PROXIES"
    DROPPED_RULES = "RENDER_REFUSED_DROPPED_RULES"
    _PHRASE = {
        UNKNOWN_PROXIES: ("有出口 mihomo 无法转换(会被静默丢弃)", "个出口无法转换"),
        DROPPED_RULES: ("有规则/规则集无法进入 mihomo 运行配置(会被静默丢弃)", "条规则被丢弃"),
    }

    def __init__(self, code, items):
        self.code = code
        self.items = tuple(items)
        super().__init__(self.safe_message())

    def safe_message(self):
        """不含任何用户值: 只有错误码与计数。"""
        return "%s: %d %s(具体名字需脱敏后才展示)" % (
            self.code, len(self.items), self._PHRASE.get(self.code, ("", "项"))[1])

    def detail(self, redact=None):
        """给**有能力脱敏**的调用方拼可读详情。redact 为 None 时不展示任何原始值。"""
        if redact is None:
            return self.safe_message()
        return "%s: %s" % (self._PHRASE.get(self.code, ("渲染判废", ""))[0],
                           ", ".join(redact(str(x)) for x in self.items))

    def __str__(self):
        return self.safe_message()

    def __repr__(self):
        return "RenderRefused(code=%r, count=%d)" % (self.code, len(self.items))


# ── .mrs 的 behavior 识别(zstd 二进制头)──────────────────────────────────
def _zstd_head_mod(data, n):
    """用 python 的 zstd 实现解出头部(没有任何可用实现则返回 b'')。

    3.14 起标准库自带 compression.zstd; 之前的版本(Debian 12 是 3.11)可能装了 pyzstd /
    zstandard。有模块就不必依赖外部命令。"""
    try:
        from compression import zstd as _cz          # python >= 3.14
        return _cz.decompress(data)[:n]
    except Exception:  # noqa: BLE001
        pass
    try:
        import pyzstd
        return pyzstd.decompress(data)[:n]
    except Exception:  # noqa: BLE001
        pass
    try:
        import zstandard
        return zstandard.ZstdDecompressor().decompressobj().decompress(data)[:n]
    except Exception:  # noqa: BLE001
        return b""


def _zstd_head_cli(data, n):
    """调 zstd 命令解出头部。只读前 n 字节就掐掉 —— 大规则集解出来可能几十 MB,
    为了 5 个字节没必要全解。"""
    if not shutil.which("zstd"):
        return b""
    fd, tmp = tempfile.mkstemp(prefix="pdgmrs")
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        p = subprocess.Popen(["zstd", "-dcq", tmp], stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL)
        try:
            return p.stdout.read(n) or b""
        finally:
            p.stdout.close()
            p.kill()
            p.wait(timeout=10)
    except (OSError, subprocess.SubprocessError):
        return b""
    finally:
        try:
            os.remove(tmp)
        except OSError:
            pass


def _mrs_head(data, n=8):
    """取 .mrs 解压后的头部若干字节(取不到返回 b'')。

    MRS 是 zstd 压缩的二进制: 解压后为 b"MRS" + 版本(1B) + behavior(1B) + …。
    依次: python zstd 模块 → zstd 命令 → 在原始字节里找 b"MRS"。最后那条只对小文件有效 ——
    真实的大规则集头部落在 Huffman 压缩的字面量块里, 盲扫根本找不到(所以装机依赖里带了
    zstd; 见 _mrs_unreadable_hint)。三条都不成立就老实说不知道, 绝不猜。"""
    if not isinstance(data, (bytes, bytearray)):
        return b""
    data = bytes(data)
    if data[:3] == b"MRS":                       # 未压缩(防御性: 万一以后不再压)
        return data[:n]
    if data[:4] != b"\x28\xb5\x2f\xfd":          # 连 zstd 帧头都不是 → 不是 .mrs
        return b""
    for head in (_zstd_head_mod(data, n), _zstd_head_cli(data, n)):
        if head[:3] == b"MRS":
            return head
    i = data.find(b"MRS", 0, 65536)
    return data[i:i + n] if i >= 0 else b""


def mrs_behavior(data):
    """从 .mrs 二进制里**认**出 behavior(domain/ipcidr); 认不出返回 None。

    认不出就返回 None, 由调用方要求用户显式声明 —— 猜错的后果是"规则看着加了却永不命中",
    比直接拒绝难查得多。版本号不是 1 也一律不认: 布局可能已经变了。"""
    h = _mrs_head(data)
    if len(h) < 5 or h[:3] != b"MRS" or h[3] != 1:
        return None
    return _MRS_BEHAVIOR_BYTE.get(h[4])


def mrs_behavior_of_file(path):
    """本地已下好的 .mrs 里认 behavior(读不到/认不出返回 None)。"""
    try:
        with open(path, "rb") as f:
            return mrs_behavior(f.read(1 << 20))
    except OSError:
        return None


# ── 渲染入参 ────────────────────────────────────────────────────────────────
def rulesets_arg(meta):
    """规则集元数据 → mihomo rule-providers 入参: rule-provider 指向原始 url, mihomo 原生抓取解析。
    收文本/yaml/mrs 类。历史遗留的 sing-box 二进制 .srs mihomo 读不了 → 跳过, 于是渲染器会把
    它记进 meta['dropped'], 由 derive/迁移据此判失败并点名(不再静默丢弃)。

    **纯函数**: meta 由调用方读好传进来(bot 读它自己的 RS_META, 恢复/救援读给定路径)——
    这里不碰任何全局路径。"""
    out = {}
    for name, info in (meta or {}).items():
        low = str(info.get("url", "")).lower().split("?", 1)[0]
        if low.endswith(".srs") or str(info.get("format", "")) == "binary":
            continue
        if low.endswith((".yaml", ".yml")):
            behavior, fmt = "classical", "yaml"
        elif low.endswith(".mrs") or str(info.get("format", "")) == "mrs":
            # .mrs 是编译后的二进制。元数据里没记 behavior(老机器上的旧条目就没有)时, 从本地
            # 已下好的文件二进制头认一次; 认得出就用, 认不出**不能猜** —— 猜错的后果是"规则看着
            # 加了却永不命中"。仍认不出的一律不渲染, 让它进 dropped 由上层点名报错。
            bh = str(info.get("behavior", ""))
            if bh not in MRS_BEHAVIORS:
                bh = mrs_behavior_of_file(info.get("path") or "") or ""
            if bh not in MRS_BEHAVIORS:
                continue
            behavior, fmt = bh, "mrs"
        else:                                          # Surge/Clash .list/.txt: DOMAIN/-SUFFIX/-KEYWORD/IP-CIDR 混合
            behavior, fmt = "classical", "text"
        out[name] = {"url": info.get("url", ""), "behavior": behavior, "format": fmt}
    return out


def panel_args(model):
    """把 model 的 experimental.clash_api(面板状态)透传给渲染器 —— mihomo 原生 clash API,
    面板开关/secret/external_ui 语义与 sing-box 一致, 无需另建状态。"""
    api = (model.get("experimental", {}) or {}).get("clash_api", {}) or {}
    if not isinstance(api, dict):
        api = {}
    return {
        "controller": api.get("external_controller") or "127.0.0.1:9090",
        "secret": api.get("secret"),
        "external_ui": api.get("external_ui"),
        "external_ui_url": api.get("external_ui_download_url"),
    }


# ── 读取器(**路径由调用方给**, 本模块不持有可变全局)───────────────────────
def read_rs_meta(path):
    """读规则集元数据。文件不存在 → {}; JSON 坏了 → 抛异常交调用方决定(bot 侧吞成 {})。"""
    if os.path.exists(path):
        return json.load(open(path))
    return {}


def read_mitm_domains(path, platform):
    """接管域名列表(仅 iOS 平台且有插件启用时非空)。读 mosdns 的强制劫持表(去 domain: 前缀),
    与 mosdns 强制劫持同源。"""
    if platform != "ios":
        return []
    out = []
    try:
        for line in open(path, encoding="utf-8"):
            line = line.strip()
            if line and not line.startswith("#"):
                out.append(line.replace("domain:", "").strip())
    except OSError:
        pass
    return out


def read_platform(path):
    """手机平台标记: ios / android(读不到默认 android —— 不启用 iOS 专属的 MITM 等)。"""
    try:
        p = open(path, encoding="utf-8").read().strip()
        if p in ("ios", "android"):
            return p
    except OSError:
        pass
    return "android"


# ── 渲染与判废 ──────────────────────────────────────────────────────────────
def render_bytes(model, *, rulesets, mitm_domains, tls_ports):
    """从给定 model 渲染出 mihomo 配置的**字节**(不落盘)。返回 (bytes, meta)。

    事务在候选阶段用它: 内核配置是 model 的派生物, 必须和 model 在同一笔事务里一起校验、
    一起落盘 —— 否则"model 写进去了、渲染失败"就会留下两份不一致的配置; 而"model 写进去了、
    根本没重渲"更糟: 内核照旧跑旧配置, 页面却报成功。

    所有环境相关入参都是显式的 —— 调用方决定从哪儿读, 这里只负责渲染。"""
    import sb2mihomo
    cfg, meta = sb2mihomo.singbox_to_mihomo(
        model, redir_port=MIHOMO_REDIR, rulesets=rulesets,
        mitm_domains=mitm_domains, mitm_port=MITM_PORT, tls_ports=tls_ports,
        **panel_args(model))
    # mihomo 只吃 YAML; JSON 是 YAML 的子集, 直接可解析
    return json.dumps(cfg, ensure_ascii=False, indent=2).encode("utf-8"), meta


def fmt_dropped(dropped):
    """把渲染器丢弃的规则说人话: 规则集报名字, 其余报它长什么样(供用户定位)。"""
    out = []
    for d in dropped or []:
        if isinstance(d, dict) and d.get("rule_set"):
            out.append(str(d["rule_set"]))
        elif isinstance(d, dict):
            out.append(",".join(f"{k}={v}" for k, v in list(d.items())[:2]) or "未知规则")
        else:
            out.append(str(d))
    return ", ".join(out[:8]) + ("…" if len(out) > 8 else "")


def check_meta(meta):
    """渲染 meta 里的"会被静默丢弃"一律判废。

    抛 RenderRefused: 它的 str() 只有错误码与计数, 具体名字放在 .items 里, 由调用方在自己的
    边界上决定要不要(以及怎么)展示 —— 用户确实需要知道是哪个出口/哪条规则被丢了, 但那必须
    经过脱敏, 而不是靠"反正 pdgtx 在, 上层会 redact"这种默契。"""
    bad = (meta or {}).get("unknown_proxies")
    if bad:
        raise RenderRefused(RenderRefused.UNKNOWN_PROXIES, [str(x) for x in bad])
    dropped = (meta or {}).get("dropped")
    if dropped:
        raise RenderRefused(RenderRefused.DROPPED_RULES, _dropped_items(dropped))


def _dropped_items(dropped):
    """dropped 条目 → 安全标识列表(与 fmt_dropped 的取值口径一致)。"""
    out = []
    for d in dropped or []:
        if isinstance(d, dict) and d.get("rule_set"):
            out.append(str(d["rule_set"]))
        elif isinstance(d, dict):
            out.append(",".join("%s=%s" % (k, v) for k, v in list(d.items())[:2]) or "未知规则")
        else:
            out.append(str(d))
    return out


def derive_bytes(staged, *, rulesets, mitm_domains, tls_ports):
    """pdgtx deriver 的公共主体: 由**候选** model 渲染并判废。

    候选里如果带着 rs_meta, 调用方应当据此算出 rulesets 再传进来 —— 读现网旧文件会让新增的
    规则集"翻译不了"被丢掉, 或者已删的又冒出来。"""
    model = json.loads(staged["model"].decode("utf-8"))
    data, meta = render_bytes(model, rulesets=rulesets, mitm_domains=mitm_domains,
                              tls_ports=tls_ports)
    check_meta(meta)
    return data


def deriver_from_paths(*, rs_meta_path, mitm_hijack_file, platform_file):
    """给**不能 import bot** 的调用方(配置恢复、救援的紧急默认出口)用的 deriver 工厂。

    返回一个 pdgtx 认的 deriver(staged → bytes)。路径显式传入, 因为这些调用方跑在事务沙箱
    里时 FSROOT 不是空串, 读死绝对路径会去错地方。"""
    def _derive(staged):
        staged_meta = staged.get("rs_meta")
        if staged_meta is not None:
            meta = json.loads(staged_meta.decode("utf-8"))
        else:
            try:
                meta = read_rs_meta(rs_meta_path)
            except Exception:  # noqa: BLE001
                meta = {}
        plat = read_platform(platform_file)
        try:
            return derive_bytes(staged, rulesets=rulesets_arg(meta),
                                mitm_domains=read_mitm_domains(mitm_hijack_file, plat),
                                tls_ports=[443] if plat == "ios" else None)
        except RenderRefused as e:
            # 边界映射: 事务层认 TxRefused, 于是配置恢复/救援能给出可解释的拒绝而不是 500。
            # 拿得到脱敏函数就脱敏后点名; 拿不到就只抛安全默认串 —— 绝不退回一个带原始值的
            # 通用异常(安全不取决于 pdgtx 在不在)。
            tx = _tx_mod()
            if tx is None:
                raise
            raise tx.TxRefused(e.detail(redact=tx.redact)) from None
    return _derive


def _tx_mod():
    """事务核心: 可用且带 redact 才返回。只用来做**边界映射**, 不用来决定错误安不安全。"""
    try:
        import pdgtx
    except Exception:  # noqa: BLE001
        return None
    return pdgtx if hasattr(pdgtx, "TxRefused") and hasattr(pdgtx, "redact") else None
