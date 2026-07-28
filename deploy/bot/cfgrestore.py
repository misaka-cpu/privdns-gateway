#!/usr/bin/env python3
"""受管配置恢复的**共享实现**: 安全解包 + 白名单 + 成员→pdgtx 逻辑目标映射。

Bot(从 Telegram 收备份包)与救援平面(从本机快照恢复)都要做同一件事: 把一个 tar 里的受管配置
安全地取出来、映射成 pdgtx 的白名单目标、再由事务落盘。两边各写一份的下场很具体 —— 白名单
一处加了新目标另一处没加, 于是"恢复成功"的机器少了一份配置; 或者解包限额只在一边生效。

所以这里是**唯一一份**: 限额、成员白名单、流式安全解包、成员→逻辑目标映射。生产路径一律由
pdgtx.resolve_target() 解析, 本模块不自己写死任何绝对路径。

本模块**不导入 bot / Telegram 交互层**: 救援服务要能在 Bot 起不来时照样工作。
"""
import os
import re
import shutil
import sys
import tempfile
import tarfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/pdg-bot")
import mihomorender  # noqa: E402
import pdgtx  # noqa: E402


# 成员路径(tar 里的相对路径)→ pdgtx 的**逻辑目标名**。生产路径由 pdgtx 解析, 不在这里写死。
MEMBER_TARGET = {
    "etc/sing-box/config.json": "model",
    "etc/mosdns/config.yaml": "mosdns_conf",
    "etc/mosdns/rules/custom_direct.txt": "mosdns_rule:custom_direct.txt",
    "etc/mosdns/rules/custom_hijack.txt": "mosdns_rule:custom_hijack.txt",
    "opt/pdg-bot/rulesets.json": "rs_meta",
}
# 兼容 bot 里既有的名字(它只用来判成员是否在白名单内)
RESTORE_MAP = MEMBER_TARGET

# 备份包是**外部输入**(bot 从 Telegram 收文件, 谁都能发一个) → 解包必须按白名单来。
RESTORE_RS_PREFIX = "etc/sing-box/rs/"
# 受管规则集的文件名白名单: 与 pdgtx 的 ruleset:<name> 目标同形(只认单个文件名 + 当前支持的
# 两种扩展名)。历史遗留的 .srs 是 sing-box 二进制格式, mihomo 读不了 → 明确拒绝, 不隐式转换。
_RS_LEAF_RE = re.compile(r"^[A-Za-z0-9_.-]+\.(json|mrs)$")
# 备份里的路径是**导出那台机器**上的路径, 只可能是生产规范目录; 而镜像沙箱(用例/E2E)把整棵树
# 挪了根, 所以也接受本机 RS_DIR。两者都是精确相等, 不做 endswith —— 否则
# /evil/etc/sing-box/rs/foo.json 会被当成合法。
_RS_DIR_CANON = "/etc/sing-box/rs"          # etc/sing-box/rs/ 下的规则集

def _rs_dir():
    """受管规则集目录 —— 由 pdgtx 的目标解析给出, 不在这里写死路径。"""
    try:
        path, _m, _s, _v = pdgtx.resolve_target("ruleset:probe.json")
        return os.path.dirname(path)
    except Exception:  # noqa: BLE001
        return "/etc/sing-box/rs"


def _log(msg):
    """本模块不依赖 bot 的日志设施(救援场景下 bot 可能根本起不来)。"""
    sys.stderr.write("[cfgrestore] %s\n" % msg)


def _limit(name, default, lo, hi):
    """解包限额: 可用 bot.env 里的 PDG_RESTORE_* 调整, 但**只在安全区间内**。

    写死上限的代价很实在 —— 规则集多一点的机器备份就恢复不了, 用户除了改代码没别的办法。
    但也不能随便调: 一个 0 或者天文数字就把这道防线关掉了, 那正是它要挡的东西。故越界一律
    夹回区间, 写成非数字就用默认值(不让一个笔误把恢复功能整个搞瘫), 两种情况都写一行日志。"""
    raw = os.environ.get(name, "")
    if not str(raw).strip():
        return default
    try:
        v = int(str(raw).strip())
    except (TypeError, ValueError):
        print("[restore] %s=%r 不是整数, 用默认值 %d" % (name, raw, default), file=sys.stderr)
        return default
    c = max(lo, min(hi, v))
    if c != v:
        print("[restore] %s=%d 超出安全区间 [%d, %d], 按 %d 生效" % (name, v, lo, hi, c),
              file=sys.stderr)
    return c


def _fs_free(path):
    """path 所在文件系统的可用字节(路径还不存在就往上找存在的祖先); 问不出来返回 0。"""
    p = os.path.abspath(path or "/")
    while True:
        try:
            return shutil.disk_usage(p).free
        except OSError:
            up = os.path.dirname(p)
            if up == p:
                return 0
            p = up


def _total_ceiling():
    """总量上限能调到多高。

    拍一个 2GiB 的常数有两头不对: 盘大的机器调不上去(超大备份还是得改代码), 盘小的机器
    却能配到 2GiB 把根分区写满。真正该守的是"别把盘写满" —— 天花板取可用空间的一半。
    问不出磁盘信息(容器里的怪文件系统)就退回保守常数, 不借机放开。"""
    free = _fs_free(_rs_dir())
    if not free:
        return 2 * 1024 * 1024 * 1024
    return max(64 * 1024 * 1024, free // 2)


MAX_MEMBERS = MAX_FILE_BYTES = MAX_TOTAL_BYTES = 0


def reload_limits():
    """按当前环境重算三道限额。

    调用方(bot)每次以新环境重新导入时都要刷一遍 —— 限额是 import 期算出来的常量, 而本模块
    只会被导入一次, 不刷新的话"改了 PDG_RESTORE_* 却不生效"。"""
    global MAX_MEMBERS, MAX_FILE_BYTES, MAX_TOTAL_BYTES
    MAX_MEMBERS = _limit("PDG_RESTORE_MAX_MEMBERS", 512, 16, 20000)
    MAX_FILE_BYTES = _limit("PDG_RESTORE_MAX_FILE_BYTES", 8 * 1024 * 1024,
                            64 * 1024, 512 * 1024 * 1024)
    MAX_TOTAL_BYTES = _limit("PDG_RESTORE_MAX_TOTAL_BYTES", 64 * 1024 * 1024,
                             1024 * 1024, _total_ceiling())
    # 单文件上限比总量还大时, 总量按单文件抬上去(否则一个合法的大文件永远解不出来)
    MAX_TOTAL_BYTES = max(MAX_TOTAL_BYTES, MAX_FILE_BYTES)
    return MAX_MEMBERS, MAX_FILE_BYTES, MAX_TOTAL_BYTES


reload_limits()


def member_allowed(name):
    """成员是否在恢复白名单内: RESTORE_MAP 的键, 或 rs/ 下的规则集文件。"""
    if name in RESTORE_MAP:
        return True
    if name.startswith(RESTORE_RS_PREFIX):
        rest = name[len(RESTORE_RS_PREFIX):]
        return bool(rest) and "/" not in rest        # 只收 rs/ 下一层, 不收子目录
    return False


def safe_extract(tar, dest, unmanaged="reject"):
    """安全解包: 只落地白名单内的**普通文件**, 任何可疑成员一律**拒绝整个备份**。

    设计要点(备份包是外部输入, bot 从 Telegram 收文件, 谁都能发一个):
      · **流式遍历**(逐个 next()), 不用 getmembers() —— 后者会先把整份成员表读进内存,
        一个成员表巨大的包在检查开始前就已经把内存吃掉了。
      · 先看**原始成员名**再做任何规范化: 绝不用 lstrip("./") 之类去"洗白" —— 那会把
        `/etc/...` 洗成 `etc/...`、把 `../../etc/x` 洗成看似合法的相对路径, 等于自己把
        逃逸路径改成合法路径再放行。
      · 可疑成员**拒整包**而不是跳过: 一个包里既有正常配置又混着符号链接/越界路径, 说明它
        本就不可信; 跳过坏成员、留下好成员会让用户以为"恢复成功了"。
      · 数量、单文件声明大小、累计声明大小、**实际读取字节数**四道限额都要卡 —— tar 头里的
        size 是攻击者写的, 只信它挡不住"声明 1KB 实则源源不断"的解压炸弹。
    """
    root = os.path.realpath(dest)
    written = []          # 本次已落地的文件: 一旦判拒整包, 连它们也要清掉
    skipped = []          # unmanaged="skip" 时被跳过的成员(供调用方列成 excluded)
    try:
        _safe_extract_loop(tar, root, written, unmanaged, skipped)
    except Exception:
        # "拒绝整个备份"要名副其实: 已经写下去的成员也不能留(调用方虽然会删临时目录,
        # 但契约本身不该依赖调用方善后)。
        for p_ in reversed(written):
            try:
                os.remove(p_)
            except OSError:
                pass
        raise
    return skipped


def _safe_extract_loop(tar, root, written, unmanaged="reject", skipped=None):
    """safe_extract 的主体; 单独一层好让上面在判拒时统一清理已落地的成员。

    unmanaged 决定**白名单之外的普通文件**怎么处理, 其余安全判据(路径穿越、软/硬链接、设备、
    数量与体积限额)两种模式完全一样、一条都不放宽:
      · "reject"(Bot 收 Telegram 备份包): 外部输入, 混进不受管成员说明整个包不可信 → 拒整包;
      · "skip"(救援从**本机快照**恢复): 快照本来就含二进制/unit/bot.env, 拒整包等于配置恢复
        永远用不了 —— 这些成员一律**不落盘**, 交给调用方列成 excluded 显示给用户。
    """
    declared_total = 0
    written_total = 0
    seen = 0
    seen_names = set()      # 规范化后的成员名(判重用; written 记的是落地路径, 不是名字)
    while True:
        m = tar.next()
        if m is None:
            break
        seen += 1
        if seen > MAX_MEMBERS:
            raise ValueError("备份成员过多(>%d), 拒绝整个备份" % MAX_MEMBERS)
        raw = m.name                       # **原始**成员名, 未经任何规范化
        # 1) 先按原始名判危险形态 —— 绝对路径 / 含 .. / 盘符式绝对路径
        if raw.startswith("/") or raw.startswith("\\"):
            raise ValueError("备份含绝对路径成员, 拒绝整个备份: %s" % raw)
        if any(seg == ".." for seg in raw.replace("\\", "/").split("/")):
            raise ValueError("备份含 `..` 路径成员, 拒绝整个备份: %s" % raw)
        # 2) 类型: 只收普通文件与目录; 链接/设备/FIFO 一律拒整包
        if m.issym() or m.islnk():
            raise ValueError("备份含链接成员(可用于写穿解压目录), 拒绝整个备份: %s" % raw)
        if m.ischr() or m.isblk() or m.isfifo() or m.isdev():
            raise ValueError("备份含设备/FIFO 成员, 拒绝整个备份: %s" % raw)
        if m.isdir():
            continue                       # 需要的目录在写文件时自建, 不按成员落地
        if not m.isreg():
            raise ValueError("备份含非普通文件成员, 拒绝整个备份: %s" % raw)
        # 3) 到这里 raw 已确认是"不以 / 开头、不含 .." 的相对路径, 只去掉无害的 ./ 前缀
        name = raw[2:] if raw.startswith("./") else raw
        # 同一个成员名出现两次: tar 允许, 但"后一个覆盖前一个"是含糊语义 —— 攻击者可以先放一份
        # 干净的过校验、再放一份真正落地的。整包拒绝, 不猜。
        if name in seen_names:
            raise ValueError("备份里同一个成员出现了两次, 拒绝整个备份: %s" % raw)
        seen_names.add(name)
        if not member_allowed(name):
            if unmanaged == "skip":
                if skipped is not None:
                    skipped.append(name)
                continue                      # 不落盘, 也不影响其它成员
            raise ValueError("备份含白名单之外的成员, 拒绝整个备份: %s" % raw)
        # 4) 限额: 声明值先卡一道(便宜), 实际读取再卡一道(声明值是攻击者写的, 不可信)
        if m.size > MAX_FILE_BYTES:
            raise ValueError("备份内文件过大(%s, >%d 字节), 拒绝整个备份" % (raw, MAX_FILE_BYTES))
        declared_total += m.size
        if declared_total > MAX_TOTAL_BYTES:
            raise ValueError("备份声明总量过大(>%d 字节), 拒绝整个备份" % MAX_TOTAL_BYTES)
        target = os.path.realpath(os.path.join(root, name))
        # resolve 之后必须仍在解压根内(挡住经既存符号链接的写穿)
        if target != root and not target.startswith(root + os.sep):
            raise ValueError("备份成员越界, 拒绝整个备份: %s" % raw)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        src = tar.extractfile(m)
        if src is None:
            raise ValueError("备份成员无法读取, 拒绝整个备份: %s" % raw)
        # 落地前再确认目标不是符号链接(TOCTOU 兜底), 并且不跟随既有链接写入
        if os.path.islink(target):
            raise ValueError("备份成员目标是符号链接, 拒绝整个备份: %s" % raw)
        this_file = 0
        with open(target, "wb") as out:
            while True:
                chunk = src.read(64 * 1024)
                if not chunk:
                    break
                this_file += len(chunk)
                written_total += len(chunk)
                # 单成员也要按**实际读到的字节**卡一道。只卡总量的话, 一个声明 1KB 的成员可以
                # 一直吐到把总量吃光 —— 报出来的会是"总量超限", 而真正越界的是这一个成员,
                # 排查时看不出是谁干的。
                if this_file > MAX_FILE_BYTES:
                    raise ValueError("备份内文件实际解出量超限(%s, >%d 字节), 拒绝整个备份"
                                     % (raw, MAX_FILE_BYTES))
                if written_total > MAX_TOTAL_BYTES:
                    raise ValueError("备份实际解出量超限(>%d 字节), 拒绝整个备份"
                                     % MAX_TOTAL_BYTES)
                out.write(chunk)
        os.chmod(target, 0o600)
        written.append(target)



# ── 快照 → 受管配置恢复(救援平面用; Bot 的备份恢复走它自己的身份替换策略)──────
# 快照目录跟随事务核心的沙箱根(PDG_TX_FSROOT): 用例与 E2E 把整棵树挪了根, 写死绝对路径会让
# 救援服务去读宿主的真快照。也允许显式覆盖, 但**不接受来自请求的任何路径**。
SNAP_DIR = os.environ.get("PDG_SNAP_DIR",
                          pdgtx.FSROOT + "/var/lib/privdns-gateway/backups")
# 明确**不恢复**的东西: 它们不在 pdgtx 白名单里, 事务给不了 before-image 与回滚保证。
# 页面必须把这份清单显示出来 —— 用户以为点的是"整机恢复"而实际只换了配置, 比什么都不做更糟。
EXCLUDED_KINDS = (
    ("二进制", ("usr/local/bin/",)),
    ("Bot 程序", ("opt/pdg-bot/",)),              # 只有 rulesets.json 例外(见 MEMBER_TARGET)
    ("平台/内核标记", ("etc/privdns-gateway/platform", "etc/privdns-gateway/backend")),
    ("Bot 凭据", ("etc/privdns-gateway/bot.env",)),
    ("systemd unit", ("etc/systemd/",)),
    ("证书与其它", ("etc/letsencrypt/",)),
)


def snapshot_ids():
    """服务端快照索引: 只返回目录名(逻辑 ID), 不接受也不返回任何路径。"""
    out = []
    try:
        names = sorted(os.listdir(SNAP_DIR), reverse=True)
    except OSError:
        return out
    for n in names:
        if _SNAP_ID_RE.match(n) and os.path.isfile(os.path.join(SNAP_DIR, n, "snap.tar.gz")):
            out.append(n)
    return out


_SNAP_ID_RE = re.compile(r"^[0-9]{8}-[0-9]{6}$")        # pdg snapshot 的 %Y%m%d-%H%M%S


def snapshot_path(snap_id):
    """逻辑 ID → 快照文件路径。**只接受索引里存在的 ID** —— 不接受绝对路径、相对路径、
    `..`、软链接或任意文件名; 解析结果还要落在 SNAP_DIR 之内且是普通文件。"""
    if not _SNAP_ID_RE.match(snap_id or "") or snap_id not in snapshot_ids():
        return None
    p = os.path.join(SNAP_DIR, snap_id, "snap.tar.gz")
    real = os.path.realpath(p)
    if os.path.realpath(SNAP_DIR) != os.path.dirname(os.path.dirname(real)):
        return None                                      # 目录被换成软链等
    if os.path.islink(p) or not os.path.isfile(real):
        return None
    return real


def snapshot_digest(snap_id):
    """快照内容摘要。确认页与执行时各算一次, 不一致说明中途被换过。"""
    p = snapshot_path(snap_id)
    if not p:
        return ""
    h = __import__("hashlib").sha256()
    try:
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    except OSError:
        return ""
    return h.hexdigest()


def classify(members):
    """把快照成员分成: 可事务恢复 / 明确排除 / 未知(既不受管也不在排除清单里)。

    只看**成员名**, 不落盘 —— 确认页要在动手之前告诉用户"这次会换什么、不会换什么"。"""
    restorable, excluded, unknown = {}, [], []
    for name in members:
        t = target_for(name)
        if t:
            restorable[name] = t
            continue
        kind = ""
        for label, prefixes in EXCLUDED_KINDS:
            if any(name == p_ or name.startswith(p_) for p_ in prefixes):
                kind = label
                break
        (excluded if kind else unknown).append((name, kind or "未知"))
    return restorable, excluded, unknown


def target_for(name):
    """成员名 → pdgtx 逻辑目标; 不受管返回 ""。"""
    if name in MEMBER_TARGET:
        return MEMBER_TARGET[name]
    if name.startswith(RESTORE_RS_PREFIX):
        leaf = name[len(RESTORE_RS_PREFIX):]
        if leaf and "/" not in leaf and _RS_LEAF_RE.match(leaf):
            return "ruleset:" + leaf
    return ""


def list_members(snap_id):
    """读快照的成员清单(不解包)。返回 (成员名列表, 错误)。"""
    p = snapshot_path(snap_id)
    if not p:
        return [], "快照不存在或不可用"
    try:
        with tarfile.open(p, "r:gz") as tar:
            names, n = [], 0
            while True:
                m = tar.next()
                if m is None:
                    break
                n += 1
                if n > MAX_MEMBERS:
                    return [], "快照成员过多(>%d), 拒绝处理" % MAX_MEMBERS
                if m.isfile():
                    names.append(m.name)
        return names, ""
    except (tarfile.TarError, OSError) as e:
        return [], "快照读取失败(%s)" % type(e).__name__


def snap_format(members):
    """快照的结构版本。**只做识别, 不做转换** —— 旧结构无法安全映射时如实说明"只能走紧急完整
    恢复", 不在恢复途中顺手迁移(那等于把一次未经批准的迁移混进恢复里)。"""
    has = set(members)
    if any(n.startswith("etc/mihomo/") for n in has) or "etc/sing-box/config.json" in has:
        return "v1.6"                       # 当前格式: 数据模型 + mihomo 配置
    if any(n.startswith("etc/dnsdist/") for n in has):
        return "legacy-dnsdist"             # 远古结构, 映射不过来
    return "unknown"


def restore_managed(snap_id, *, expect_digest="", trigger_source="legacy"):
    """把快照里的**受管配置**按一笔 pdgtx 事务恢复。返回结构化结果, 不抛异常给 HTTP 层。

    只做配置: 二进制、Bot 程序、platform/backend、bot.env 一律不碰(它们不在 pdgtx 白名单里,
    事务给不了 before-image 与回滚保证)。**失败绝不自动降级**成完整恢复 —— 那是另一件事,
    要用户自己在明确知道风险时去做。

    repair 语义: 允许"操作前就坏的硬门"保持原状, 但候选本身的语法/安全校验一条不放宽, 原来
    正常、恢复后异常的硬门照样触发回滚。
    """
    out = {"ok": False, "snapshot": snap_id, "state": "", "restored": [], "derived": [], "skipped": [],
           "excluded": [], "failed": [], "error": "", "txid": ""}
    p = snapshot_path(snap_id)
    if not p:
        out["error"] = "快照不存在或不可用(只接受服务端索引里的快照)"
        return out
    # 锁内复核: 确认页到执行之间快照被换掉的话, 摘要对不上 —— 拒绝, 不去恢复一个用户没看过的东西
    if expect_digest and snapshot_digest(snap_id) != expect_digest:
        out["error"] = "快照内容在确认之后发生了变化, 已中止(请重新确认)"
        return out
    pend = []
    try:
        pend = pdgtx.pending_recovery()
    except Exception:  # noqa: BLE001
        out["error"] = "读不到事务目录, 未做任何改动"
        return out
    if pend:
        out["error"] = ("有 %d 笔未完成的配置事务, 必须先逐笔处理(pdg tx recover)才能恢复配置"
                        % len(pend))
        out["pending"] = [str(m.get("txid")) for m in pend[:5]]
        return out

    stage = tempfile.mkdtemp(prefix="pdg-cfgrestore.")
    os.chmod(stage, 0o700)
    try:
        try:
            with tarfile.open(p, "r:gz") as tar:
                # 与 Bot 同一份安全解包(路径穿越/软硬链接/设备/限额判据完全一致); 区别只在
                # "白名单之外的成员"怎么办: 本机快照本来就含二进制与 unit, 那些一律不落盘。
                skipped_members = safe_extract(tar, stage, unmanaged="skip")
        except Exception as e:  # noqa: BLE001
            out["error"] = "快照解包被拒绝或失败(%s), 未做任何改动" % type(e).__name__
            return out
        landed = []
        for root_, _d, files in os.walk(stage):
            for fn in files:
                landed.append(os.path.relpath(os.path.join(root_, fn), stage))
        members = landed + list(skipped_members)
        restorable, excluded, unknown = classify(members)
        out["excluded"] = [n for n, _k in excluded] + [n for n, _k in unknown]
        out["format"] = snap_format(members)
        if out["format"] not in ("v1.6",):
            out["error"] = ("这份快照的结构(%s)无法安全映射成当前的受管配置目标 —— "
                            "只能使用紧急完整恢复。本操作不做结构转换。" % out["format"])
            out["incompatible"] = True
            return out
        if not restorable:
            out["error"] = "这份快照里没有可事务恢复的受管配置"
            return out
        # 先算出**内容确实变了**的目标: 服务动作只能由它推导, 不能按"快照里有什么"推 ——
        # 只换了一份元数据却把 DNS 和内核一起重启, 既是无谓的中断, 也会让"那两个本来就坏着"
        # 变成一次安全恢复失败的理由。
        changed, unchanged_t = {}, []
        for member, target in sorted(restorable.items()):
            with open(os.path.join(stage, member), "rb") as f:
                data = f.read()
            try:
                path, _m, _sec, _v = pdgtx.resolve_target(target)
            except Exception as e:  # noqa: BLE001
                # 本模块的成员映射与 pdgtx 白名单对不上 = 两份定义漂移了。这不是"跳过一个文件"
                # 那么轻的事: 谁也不知道还有多少目标错了, 所以整个恢复 fail-closed。
                out["error"] = ("目标 %s 不在事务白名单里(%s) —— 恢复映射与事务核心不一致, "
                                "拒绝执行" % (target, type(e).__name__))
                return out
            cur, _st = pdgtx._read_target(path)
            if cur is not None and cur == data:
                unchanged_t.append(target)
                continue
            changed[target] = data
        out["unchanged"] = unchanged_t
        if not changed:
            # 一个字节都不用动: 不开事务、不发服务动作、也不写审计(什么都没发生)
            out["ok"] = True
            out["state"] = "NO_CHANGE"
            return out
        try:
            planned = pdgtx.actions_for_targets(changed)
        except Exception as e:  # noqa: BLE001
            # 未知目标 / 没有明确动作语义的目标: fail-closed, 现网一个字节都不碰
            out["error"] = pdgtx.redact(str(e))
            return out
        t = pdgtx.Tx(source="rescue", op="config_restore", mode="repair")
        out["txid"] = t.txid
        out["planned_actions"] = list(planned)
        # 审计的补充维度: 全是标量与计数, 没有文件内容、没有凭据、没有调用方自由串。
        # 由核心随事务那**一条**记录一起写, 救援页不再另写。
        t.audit_extra = {"trigger_source": trigger_source, "snapshot": snap_id,
                         "snapshot_digest": (expect_digest or snapshot_digest(snap_id))[:16],
                         "snapshot_format": snap_format(members),
                         "excluded_count": len(out["excluded"])}
        try:
            for target, data in sorted(changed.items()):
                try:
                    _cur, sha = t.read_for_update(target)
                except Exception as e:  # noqa: BLE001
                    out["skipped"].append("%s(%s)" % (target, type(e).__name__))
                    continue
                t.stage(target, data, expect=sha)
                out["restored"].append(target)
            t.audit_extra["restored_count"] = len(out["restored"])
            t.audit_extra["skipped_count"] = len(out["skipped"])
            t.audit_extra["unchanged_count"] = len(unchanged_t)
            t.audit_extra["changed_targets"] = sorted(out["restored"])
            t.audit_extra["planned_actions"] = list(planned)
            if not out["restored"]:
                out["error"] = "没有可落盘的目标"
                t.abort_unstarted("没有可落盘的目标")
                return out
            # model 换了就必须在**同一笔事务**里重渲内核配置。
            # 快照里带的是 config.json(数据模型), 而 mihomo 跑的是 /etc/mihomo/config.yaml ——
            # 只换 model 再 restart:mihomo, 内核重启后加载的仍是旧的那一份: 恢复"成功"了, 运行
            # 中的内核纹丝不动。派生走 mihomorender(与 bot 的 tx_apply 同一份实现), 渲染失败
            # 或有出口/规则会被静默丢弃时判废, model 与 mihomo_cfg 一起回滚。
            if "model" in out["restored"]:
                t.derive("mihomo_cfg", mihomorender.deriver_from_paths(
                    rs_meta_path=pdgtx.FSROOT + "/opt/pdg-bot/rulesets.json",
                    mitm_hijack_file=pdgtx.FSROOT + "/etc/mosdns/rules/mitm_hijack.txt",
                    platform_file=pdgtx.FSROOT + "/etc/privdns-gateway/platform"))
                out["derived"] = ["mihomo_cfg"]
            # 动作由**实际落盘的目标**推导(read_for_update 失败被跳过的不算数)
            for a in pdgtx.actions_for_targets(out["restored"] + out.get("derived", [])):
                t.service(a)
            res = t.commit()
        except pdgtx.TxBusy:
            out["error"] = "已有配置操作正在执行, 本次未做任何改动"
            out["busy"] = True
            return out
        except pdgtx.TxRefused as e:
            out["error"] = pdgtx.redact(str(e))
            out["state"] = "REFUSED"
            return out
        except pdgtx.TxError as e:
            out["error"] = pdgtx.redact(str(e))
            return out
        out["state"] = res.get("state", "")
        out["ok"] = out["state"] == pdgtx.COMMITTED
        out["failed"] = [pdgtx.redact(str(x)) for x in (res.get("rollback_failed_items") or [])]
        out["executed_actions"] = list(t.meta.get("executed_actions", []))
        if res.get("error"):
            out["error"] = pdgtx.redact(str(res["error"]))
        return out
    finally:
        shutil.rmtree(stage, ignore_errors=True)     # staging 精确清理(0700, 退出即删)
