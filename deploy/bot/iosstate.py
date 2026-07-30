#!/usr/bin/env python3
"""iOS 描述文件的**受管生命周期**(5.4): 稳定身份、修订号、三档更新判定、current/previous。

先说清楚这个模块**不知道**什么: 它不知道用户手机上此刻装没装、装的是哪一版。本项目不是
MDM, 服务器没有任何渠道能知道这件事。所以这里记录的一律是"我们生成/发送了什么", 绝不
表述成"设备上是什么"。任何调用方都不许把这里的数据翻译成"已安装""设备已是最新版"。

三块状态:

  1. 身份 —— 首次启用时生成一次 instance_id(uuid4), 此后**永不再变**。所有 payload 的
     UUID 由 uuid5(NS, instance_id + ":" + 角色) 派生。对 iOS 来说 identifier+UUID 就是
     描述文件的身份: 稳定 ⇒ 再装一次是"更新同一份"; 变了 ⇒ 手机上多堆一个。
     它**不从** DoT 域名 / IP / 主机名 / SSID / WLOC 状态推导 —— 那些都会变, 一变就等于
     换了身份, 那正是要修的病。

  2. 修订号 revision —— 独立于 Apple 的 PayloadVersion(那个恒为 1, iOS 并不拿它判新旧)。
     只有**规范化语义输入**变化才 +1。时间戳、文件名、随机值一律不参与, 于是"点一下重新
     生成"在输入没变时产出逐字节相同的文件, 不会凭空造出一个新版本。

  3. current / previous —— 只留一版历史, 够用来对比和手工回退, 不做无限历史。

文件位置与备份语义见 docs/ios-profile-lifecycle.md。
"""
import hashlib
import json
import os
import shutil
import stat
import sys
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import iosprofile                                            # noqa: E402
import pdgtx                                                 # noqa: E402
# 复用 pdgtx 的锁而不是自己再写一把: 描述文件生成会读 mitm.json / CA / 证书, 这些正是
# pdgtx 事务在改的东西。两把不同的锁等于没有锁。
# ⚠️ 因此**不能**在已持有该锁的路径里调用本模块的写操作(`pdg update` 持锁调 __migrate 就是
# 这种路径), 否则自死锁 —— 这个坑在 v1.7.1/v1.7.2 真踩过。生命周期只在用户主动生成时初始化。

SCHEMA = 1
FSROOT = os.environ.get("PDG_TX_FSROOT", "")
META = FSROOT + "/etc/privdns-gateway/ios-profile.json"
ART_DIR = FSROOT + "/var/lib/privdns-gateway/ios-profile"
CUR = "current.mobileconfig"
PREV = "previous.mobileconfig"

# payload 身份的派生命名空间。这是个常量, 换掉它等于把所有已存在的网关身份作废。
NS = uuid.UUID("6f9d5a2c-3f2a-5f7b-9c1e-8d4a2b6c0e11")
ROLES = ("root", "dns", "ca")

# ── 三档更新判定的**唯一**分级表 ────────────────────────────────────────────
# 集中在这一处: Bot 和 CLI 都读它。两边各写一份的下场是同一个变化在两个界面上是不同的
# 严重程度, 而用户只会记住"上次那个提示没那么严重"。
NONE, RECOMMENDED, REQUIRED = "none", "recommended", "required"
LEVEL_ORDER = {NONE: 0, RECOMMENDED: 1, REQUIRED: 2}
LEVEL_LABEL = {NONE: "无需更新", RECOMMENDED: "建议更新", REQUIRED: "必须更新"}

FIELD_LEVELS = {
    "schema": REQUIRED,             # 生成格式本身变了
    "dot_host": REQUIRED,           # 改了不更新 = 连不上
    "server_addresses": REQUIRED,   # 同上
    "dns_protocol": REQUIRED,       # 同上
    "probe_url": REQUIRED,          # 探测地址错了 = DoT 该开的时候不开 / 不该开的时候开
    "ondemand_core": REQUIRED,      # 规则骨架变了
    "wloc_enabled": REQUIRED,       # 关了却还信任 CA, 或开了却没有 CA
    "wloc_ca_sha256": REQUIRED,     # CA 换了 ⇒ 手机信任的是旧的 ⇒ 全站证书报错
    "ssids": RECOMMENDED,           # 强制直连名单; 核心连接仍可用
}
FIELD_LABEL = {
    "schema": "描述文件格式",
    "dot_host": "DoT 主机名",
    "server_addresses": "网关地址",
    "dns_protocol": "DNS 协议",
    "probe_url": "探测地址",
    "ondemand_core": "按需连接规则",
    "wloc_enabled": "位置改写(WLOC)",
    "wloc_ca_sha256": "根证书指纹",
    "ssids": "强制直连 Wi-Fi",
}


class StateError(Exception):
    """生命周期状态不可用。消息面向用户, 说清楚为什么以及怎么办。"""


# ── 身份 ────────────────────────────────────────────────────────────────────
def derive_ids(instance_id):
    """从永久 instance_id 派生各 payload 的 UUID。同一 instance_id 永远得到同一组。"""
    if not instance_id:
        raise StateError("缺少 instance_id, 无法派生描述文件身份。")
    return {r: str(uuid.uuid5(NS, "%s:%s" % (instance_id, r))).upper() for r in ROLES}


def new_instance_id():
    return str(uuid.uuid4())


# ── 规范化输入与 digest ─────────────────────────────────────────────────────
def ondemand_core(template=None):
    """模板里那套与 SSID 无关的按需规则骨架(去掉随输入变化的探测 URL)。

    模板才是这套 Apple 语义的出处。把它纳入 digest, 于是"升级换了模板"能被识别成一次
    必须更新, 而不是让用户拿着一份规则骨架已经过时的描述文件继续用。
    """
    ids = {r: "00000000-0000-0000-0000-00000000000%d" % i for i, r in enumerate(ROLES)}
    raw = iosprofile.render("x.invalid", "192.0.2.1", (), b"", ids, template)
    import plistlib
    rules = plistlib.loads(raw)["PayloadContent"][0]["OnDemandRules"]
    out = []
    for r in rules:
        r = dict(r)
        if "URLStringProbe" in r:
            r["URLStringProbe"] = "<probe>"
        out.append(r)
    # 只用 JSON 原生类型(dict/list/str)。用元组的话, 从元数据读回来的是 list, 与内存里刚算出
    # 来的元组不相等 —— digest 一致(json 都序列化成数组)而字段比对却说"变了", 于是"什么都
    # 没改"会被判成必须更新。这种自相矛盾比判错更难查。
    return out


def make_inputs(dot_host, server_addresses, ssids=(), wloc_enabled=False, ca_der=b"",
                template=None):
    """把一次生成的**语义输入**规范化。只有这里出现的字段参与 digest。

    刻意排除: 生成时间、发送时间、临时文件名、随机值、模板路径。它们变了不代表配置变了,
    纳进来会让"什么都没改也提示要更新"变成常态, 而常态化的提示等于没有提示。
    """
    return {
        "schema": SCHEMA,
        "dot_host": iosprofile.norm_host(dot_host),
        "server_addresses": iosprofile.norm_addrs(server_addresses),
        "dns_protocol": "TLS",
        "probe_url": "http://%s:81/probe" % iosprofile.norm_addrs(server_addresses)[0],
        "ondemand_core": ondemand_core(template),
        "ssids": iosprofile.norm_ssids(ssids),
        "wloc_enabled": bool(wloc_enabled),
        # 只留指纹。证书正文既不进元数据也不进任何输出 —— 元数据是会被备份、被贴进工单的。
        "wloc_ca_sha256": hashlib.sha256(ca_der).hexdigest() if ca_der else "",
    }


def digest_of(inputs):
    return "sha256:" + hashlib.sha256(
        json.dumps(inputs, sort_keys=True, ensure_ascii=False,
                   separators=(",", ":")).encode("utf-8")).hexdigest()


def diff_fields(old, new):
    """字段级差异。返回 [(字段, 等级, 旧, 新)], 按等级从重到轻。

    CA 只比指纹, 不输出证书正文; 其余字段原样给出 —— 它们本来就是用户自己填的配置。
    """
    out = []
    for k in sorted(set(old or {}) | set(new or {})):
        ov, nv = (old or {}).get(k), (new or {}).get(k)
        if ov != nv:
            out.append((k, FIELD_LEVELS.get(k, REQUIRED), ov, nv))
    out.sort(key=lambda t: (-LEVEL_ORDER[t[1]], t[0]))
    return out


# ── 元数据读写 ──────────────────────────────────────────────────────────────
def _blank():
    return {"schema": SCHEMA, "instance_id": None, "created_at": None,
            "migration_pending": False, "current": None, "previous": None}


def load(path=None):
    """读元数据。不存在 → None(还没启用受管生命周期)。

    **坏了不自动重建**: 重建意味着造出第二个 instance_id, 于是用户手机上那份描述文件立刻
    变成孤儿 —— 服务器再也没法更新它, 而用户只会看到"又多了一个描述文件"。所以这里 fail
    closed, 让人先去看看那个文件出了什么事。
    """
    p = path or META
    try:
        with open(p, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        return None
    except OSError as e:
        raise StateError("读不到 iOS 描述文件记录 %s(%s) —— 为避免生成出第二个身份, "
                         "本次拒绝执行。" % (p, e.strerror))
    try:
        meta = json.loads(raw)
    except ValueError:
        raise StateError("iOS 描述文件记录 %s 已损坏。不自动重建: 重建会生成一个新身份, "
                         "而你手机上那份描述文件将永远无法再被更新。请先修复或删除该文件"
                         "(删除等于放弃现有身份, 之后必须手工删掉手机上的旧描述文件)。" % p)
    if not isinstance(meta, dict) or meta.get("schema") != SCHEMA:
        raise StateError("iOS 描述文件记录 %s 的格式版本不认识(schema=%r), 拒绝继续。"
                         % (p, (meta or {}).get("schema") if isinstance(meta, dict) else None))
    if not meta.get("instance_id"):
        raise StateError("iOS 描述文件记录 %s 里没有身份标识, 拒绝继续。" % p)
    try:
        derive_ids(meta["instance_id"])
    except Exception:  # noqa: BLE001
        raise StateError("iOS 描述文件记录 %s 里的身份标识不合法, 拒绝继续。" % p)
    return meta


def art_path(which, root=None):
    return os.path.join(root or ART_DIR, CUR if which == "current" else PREV)


def read_artifact(which, root=None):
    try:
        with open(art_path(which, root), "rb") as f:
            return f.read()
    except OSError:
        return None


# ── 三档判定 ────────────────────────────────────────────────────────────────
def classify(meta, inputs, artifact=None):
    """(等级, [理由]) —— Bot 与 CLI 唯一的判定入口。

    artifact 是当前产物字节(None = 读不到)。产物本身**不参与** digest: 它可以由元数据 +
    当前配置确定性重建, 所以"文件不见了"先尝试重建, 重建得出同样的字节就不算变化。
    """
    if not meta:
        return REQUIRED, ["还没有生成过受管描述文件"]
    reasons, level = [], NONE
    if meta.get("migration_pending"):
        level = REQUIRED
        reasons.append("正在从旧的随机身份迁移: 必须先删掉手机上那份旧描述文件, 再装新的")
    if not meta.get("current"):
        reasons.append("还没有生成过受管描述文件")
        return REQUIRED, reasons
    for k, lv, ov, nv in diff_fields(meta["current"].get("inputs"), inputs):
        if LEVEL_ORDER[lv] > LEVEL_ORDER[level]:
            level = lv
        reasons.append("%s 已变化" % FIELD_LABEL.get(k, k))
    # 产物对不上记录有三种来路: 被改动过、快照回滚后产物与记录错位(产物不在快照范围内)、
    # 生成中途崩溃。三种的处理是同一个: 按记录**确定性重建**。所以这里不判"必须更新" ——
    # 记录里那一版才是真的, 而它能被逐字节复原。但也不能当没事: 用户可能在这期间恰好装过
    # 那份对不上的文件, 而服务器无从知道。于是给"建议更新"并把话说清楚。
    if artifact is None:
        reasons.append("服务器上的产物文件缺失, 已按记录重建")
    elif meta["current"].get("sha256") and \
            hashlib.sha256(artifact).hexdigest() != meta["current"]["sha256"]:
        if LEVEL_ORDER[RECOMMENDED] > LEVEL_ORDER[level]:
            level = RECOMMENDED
        reasons.append("服务器上的产物文件与记录不一致, 已按记录重建; "
                       "若你在此期间装过, 建议重新安装一次")
    if level == NONE and not reasons:
        reasons.append("网关配置与已生成版本一致")
    return level, reasons


# ── 写事务 ──────────────────────────────────────────────────────────────────
class _Txn:
    """最小文件事务: 精确 before-image → 落盘 → 复核 → 失败逐项还原并再复核。

    要么元数据和产物一起是新的, 要么一起是旧的。半成功(产物换了但 revision 没动, 或者反过来)
    比失败更糟: 之后每一次判定都建立在一个不成立的前提上。

    落盘顺序是**元数据最后**。中途崩溃时产物可能比元数据新, 那种偏差下一次 load 能发现
    (sha 对不上)并按元数据重建; 反过来则无法恢复 —— 元数据说的那一版已经没有文件了。
    """

    def __init__(self, lock=True):
        self.lock = lock
        self._lk = None
        self.before = []      # [(path, data 或 None, mode, uid, gid)]

    def __enter__(self):
        if self.lock:
            self._lk = pdgtx._Lock()
            try:
                self._lk.__enter__()
            except pdgtx.TxBusy:
                raise StateError("已有配置操作正在执行, 本次不生成描述文件(避免并发写坏记录)。")
            except pdgtx.TxRefused as e:
                raise StateError(str(e))
        return self

    def capture(self, path):
        try:
            st = os.lstat(path)
        except OSError:
            self.before.append((path, None, None, None, None))
            return
        if not stat.S_ISREG(st.st_mode):
            raise StateError("%s 不是普通文件, 拒绝覆盖。" % path)
        with open(path, "rb") as f:
            self.before.append((path, f.read(), stat.S_IMODE(st.st_mode), st.st_uid, st.st_gid))

    def write(self, path, data, mode=0o600):
        self.capture(path)
        pdgtx.atomic_write(path, data, mode=mode)

    def remove(self, path):
        self.capture(path)
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass

    def _restore(self):
        problems = []
        for path, data, mode, uid, gid in reversed(self.before):
            try:
                if data is None:
                    if os.path.exists(path):
                        os.unlink(path)
                else:
                    pdgtx.atomic_write(path, data, mode=mode or 0o600, uid=uid, gid=gid)
            except OSError as e:
                problems.append("%s(%s)" % (path, e.strerror))
                continue
            # 还原之后复核: 只做"我试过还原了"是不够的, 那正是最需要证据的时刻。
            try:
                if data is None:
                    if os.path.exists(path):
                        problems.append("%s(应删除却仍在)" % path)
                else:
                    with open(path, "rb") as f:
                        if f.read() != data:
                            problems.append("%s(内容与还原前不一致)" % path)
            except OSError as e:
                problems.append("%s(复核读失败: %s)" % (path, e.strerror))
        return problems

    def __exit__(self, et, ev, tb):
        try:
            if et is not None:
                problems = self._restore()
                if problems:
                    # 还原也失败 —— 把两件事都说出来, 不许只报后一件。
                    raise StateError("生成失败且回滚不完整: %s。原始错误: %s"
                                     % ("; ".join(problems), ev))
        finally:
            if self._lk:
                self._lk.__exit__(None, None, None)
                self._lk = None
        return False


def _stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def _cleanup_candidates(root=None):
    """崩溃后残留的候选文件。它们不是产物, 留着只会让人以为有第三个版本。"""
    d = root or ART_DIR
    n = 0
    try:
        names = os.listdir(d)
    except OSError:
        return 0
    for f in names:
        if f.endswith(".cand") or f.startswith(".pdgtx."):
            try:
                os.unlink(os.path.join(d, f))
                n += 1
            except OSError:
                pass
    return n


def generate(dot_host, server_addresses, ssids=(), ca_der=b"", wloc_enabled=False,
             template=None, meta_path=None, art_root=None, lock=True, legacy_seen=False):
    """生成(或确认无需生成)受管描述文件。返回 (meta, level, reasons, data, changed)。

    输入没变时**不产生新 revision**: 产物逐字节相同, previous 不被顶掉。这正是"点一下重新
    生成"应有的样子 —— 重新拿一份文件, 而不是制造一次版本变更。
    """
    mp = meta_path or META
    ar = art_root or ART_DIR
    inputs = make_inputs(dot_host, server_addresses, ssids, wloc_enabled, ca_der, template)
    meta = load(mp)
    fresh = meta is None
    if fresh:
        meta = _blank()
        meta["instance_id"] = new_instance_id()
        meta["created_at"] = _stamp()
        # 这台机器以前用随机身份发过描述文件 ⇒ 手机上那份我们**管不着**, 只能请用户手工删。
        meta["migration_pending"] = bool(legacy_seen)
    ids = derive_ids(meta["instance_id"])
    data = iosprofile.render(inputs["dot_host"], inputs["server_addresses"], inputs["ssids"],
                             ca_der, ids, template)
    sha = hashlib.sha256(data).hexdigest()

    cur = meta.get("current")
    same = bool(cur) and cur.get("digest") == digest_of(inputs)
    on_disk = read_artifact("current", ar)
    # 判定必须在改写之前算: 它回答的是"相对**上一次生成的那一版**要不要重新装"。
    # 写完再算就是拿新记录跟它自己比, 永远得到"无需更新" —— 那正好把这个功能的意义抹掉。
    level, reasons = classify(meta, inputs, on_disk)
    if same and on_disk == data:
        return meta, level, reasons, data, False

    with _Txn(lock=lock) as tx:
        os.makedirs(ar, mode=0o700, exist_ok=True)
        _cleanup_candidates(ar)
        new = dict(meta)
        if same:
            # 语义没变, 只是产物文件丢了/被改了 —— 按记录重建, revision 不动。
            tx.write(art_path("current", ar), data, 0o644)
            new["current"] = dict(cur, sha256=sha)
        else:
            if cur and on_disk is not None:
                tx.write(art_path("previous", ar), on_disk, 0o644)
                new["previous"] = dict(cur)
            elif cur:
                # 上一版的产物文件已经不在盘上了。那就不要在记录里假装还留着一份可回退的
                # 版本 —— 用户点「发送上一版」时拿不到文件, 比一开始就说没有更糟。
                tx.remove(art_path("previous", ar))
                new["previous"] = None
            tx.write(art_path("current", ar), data, 0o644)
            new["current"] = {
                "revision": (cur or {}).get("revision", 0) + 1,
                "digest": digest_of(inputs),
                "inputs": inputs,
                "sha256": sha,
                "generated_at": _stamp(),
                "sent_at": None,
            }
        tx.write(mp, json.dumps(new, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n", 0o600)
        meta = new

    return meta, level, reasons, data, True


def _update_meta(fn, meta_path=None, lock=True):
    mp = meta_path or META
    meta = load(mp)
    if not meta:
        raise StateError("还没有受管描述文件记录。")
    with _Txn(lock=lock) as tx:
        new = fn(dict(meta))
        tx.write(mp, json.dumps(new, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n", 0o600)
    return new


def mark_sent(meta_path=None, lock=True):
    """记录"我们把 current 发出去了"。注意措辞: 发出去 ≠ 装上了。"""
    def f(m):
        if m.get("current"):
            m["current"] = dict(m["current"], sent_at=_stamp())
        return m
    return _update_meta(f, meta_path, lock)


def ack_migration(meta_path=None, lock=True):
    """用户自述"旧描述文件我删了、新的装了"。这只是**用户告诉我们的**, 不是设备状态的证据,
    所以它只关掉迁移提示, 不产生任何"已安装"的结论。"""
    return _update_meta(lambda m: dict(m, migration_pending=False), meta_path, lock)


def recover(meta_path=None, art_root=None):
    """崩溃残留清理 + 产物与元数据的一致性检查。返回人话说明的列表。"""
    ar = art_root or ART_DIR
    out = []
    n = _cleanup_candidates(ar)
    if n:
        out.append("清理了 %d 个中断留下的候选文件" % n)
    meta = load(meta_path)
    if not meta or not meta.get("current"):
        return out
    cur = read_artifact("current", ar)
    if cur is None:
        out.append("当前产物文件缺失(可按记录重建)")
    elif meta["current"].get("sha256") and \
            hashlib.sha256(cur).hexdigest() != meta["current"]["sha256"]:
        out.append("当前产物文件与记录不一致(可能被改动过)")
    return out


def status_lines(meta, inputs=None, artifact=None):
    """状态展示的**唯一**文案来源(Bot 与 CLI 共用措辞)。

    只讲"我们生成/发送了什么"。服务器无从知道 iPhone 上此刻是什么, 所以这里永远不会出现
    "已安装""设备已是最新版""更新已在手机生效""已替换手机上的旧描述文件"。
    """
    out = []
    if not meta or not meta.get("current"):
        return ["还没有生成过受管描述文件。"]
    cur = meta["current"]
    out.append("当前版本: 第 %d 版(生成于 %s)" % (cur["revision"], cur["generated_at"]))
    out.append("上次发送: %s" % (cur.get("sent_at") or "尚未通过本机发送过"))
    out.append("DoT 主机名: %s" % cur["inputs"]["dot_host"])
    out.append("网关地址: %s" % ", ".join(cur["inputs"]["server_addresses"]))
    if cur["inputs"].get("ssids"):
        out.append("强制直连 Wi-Fi: %s" % ", ".join(cur["inputs"]["ssids"]))
    if cur["inputs"].get("wloc_enabled"):
        out.append("含根证书: 是(指纹 %s…)" % cur["inputs"]["wloc_ca_sha256"][:16])
    if meta.get("previous"):
        out.append("上一版: 第 %d 版" % meta["previous"]["revision"])
    if inputs is not None:
        lv, why = classify(meta, inputs, artifact)
        out.append("状态: %s" % LEVEL_LABEL[lv])
        out += ["  · " + r for r in why]
    return out


def clear(meta_path=None, art_root=None):
    """放弃受管身份(卸载 / 用户明确要求重来)。删掉之后再生成就是**另一个身份**, 手机上
    那份旧的会变成孤儿 —— 调用方必须先把这句话讲清楚。"""
    for p in (art_path("current", art_root), art_path("previous", art_root)):
        try:
            os.unlink(p)
        except OSError:
            pass
    try:
        shutil.rmtree(art_root or ART_DIR)
    except OSError:
        pass
    try:
        os.unlink(meta_path or META)
    except OSError:
        pass


# ── 命令行(供 pdg.sh 调用)───────────────────────────────────────────────
def _val(v):
    if isinstance(v, bool):
        return "是" if v else "否"
    if v in (None, "", []):
        return "(无)"
    if isinstance(v, (list, tuple)):
        return ", ".join(str(x) for x in v)
    s = str(v)
    return s if len(s) <= 24 else s[:16] + "…"


UNKNOWN = ("提示: 服务器无法确认 iPhone 上此刻装的是哪一版, 以上只反映本机的生成/发送记录。")


def main(argv=None):
    import argparse
    argv = list(sys.argv[1:] if argv is None else argv)
    ap = argparse.ArgumentParser(prog="iosstate.py")
    sub = ap.add_subparsers(dest="cmd")

    def common(p):
        p.add_argument("--dot-host")
        p.add_argument("--server-ip", action="append")
        p.add_argument("--ssid", action="append", default=[])
        p.add_argument("--wloc-config")
        p.add_argument("--ca-crt")
        p.add_argument("--template")

    g = sub.add_parser("generate", help="生成/更新受管描述文件")
    common(g)
    g.add_argument("--out", required=True, help="把产物另存一份到这里(供临时下载用)")
    g.add_argument("--legacy", action="store_true",
                   help="这台网关以前发过旧版(随机身份)描述文件")
    s = sub.add_parser("status", help="只看状态, 不生成")
    common(s)
    sub.add_parser("diff", help="current ↔ previous 的字段级差异")
    sub.add_parser("ack", help="用户自述旧描述文件已删除, 关掉迁移提示")
    pv = sub.add_parser("previous", help="取出上一版产物")
    pv.add_argument("--out", required=True)
    sub.add_parser("recover", help="清理中断残留并检查产物与记录是否一致")

    a = ap.parse_args(argv)
    if not a.cmd:
        ap.print_help(sys.stderr)
        return 2

    def _inputs():
        der = iosprofile.ca_der_for(iosprofile.wloc_enabled(a.wloc_config), a.ca_crt) \
            if a.wloc_config else b""
        return make_inputs(a.dot_host, a.server_ip, a.ssid, bool(der), der, a.template), der

    try:
        if a.cmd == "generate":
            der = iosprofile.ca_der_for(iosprofile.wloc_enabled(a.wloc_config), a.ca_crt) \
                if a.wloc_config else b""
            meta, lv, why, data, changed = generate(
                a.dot_host, a.server_ip, a.ssid, der, bool(der), a.template,
                legacy_seen=a.legacy)
            pdgtx.atomic_write(a.out, data, mode=0o644)
            print("\n".join(status_lines(meta)))
            print("本次: %s" % ("生成了第 %d 版" % meta["current"]["revision"] if changed
                              else "网关配置没有变化, 内容与上次完全相同"))
            for r in why:
                print("  · " + r)
            if meta.get("migration_pending"):
                print("\n⚠️ 安装前请先在 iPhone 上删除旧的「PrivDNS Gateway」描述文件 —— "
                      "旧版是随机身份, 不删的话这份会作为**另一个**描述文件并存。")
            print("\n" + UNKNOWN)
        elif a.cmd == "status":
            meta = load()
            inputs = None
            if a.dot_host and a.server_ip:
                inputs, _ = _inputs()
            print("\n".join(status_lines(meta, inputs, read_artifact("current"))))
            print("\n" + UNKNOWN)
        elif a.cmd == "diff":
            meta = load() or {}
            prev, cur = meta.get("previous"), meta.get("current")
            if not (prev and cur):
                print("还没有上一版可对比。")
                return 0
            print("第 %d 版 → 第 %d 版" % (prev["revision"], cur["revision"]))
            d = diff_fields(prev["inputs"], cur["inputs"])
            for k, lv, ov, nv in d:
                print("  · %s(%s): %s → %s"
                      % (FIELD_LABEL.get(k, k), LEVEL_LABEL[lv], _val(ov), _val(nv)))
            if not d:
                print("  两版的语义输入相同。")
        elif a.cmd == "ack":
            ack_migration()
            print("已关闭迁移提示。记录的是「你告诉我们旧描述文件已删除」, 服务器无从核实。")
        elif a.cmd == "previous":
            blob = read_artifact("previous")
            meta = load() or {}
            if not (meta.get("previous") and blob):
                sys.stderr.write("上一版的文件已不在服务器上, 无法取回。\n")
                return 4
            pdgtx.atomic_write(a.out, blob, mode=0o644)
            print("已取出第 %d 版。这只是把旧文件再给你一次 —— 记录的当前版本不会回退。"
                  % meta["previous"]["revision"])
        elif a.cmd == "recover":
            msgs = recover()
            print("\n".join(msgs) if msgs else "没有需要清理的残留, 产物与记录一致。")
    except (StateError, iosprofile.ProfileError) as e:
        sys.stderr.write("%s\n" % e)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
