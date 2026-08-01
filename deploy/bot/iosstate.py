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
import re
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


def effective_ssids(meta, ssids):
    """`None` = 调用方没指定 → **沿用记录里的**; 传了列表(哪怕是空的)= 明确设置。

    SSID 名单参与 digest, 就等于它是受管配置的一部分。把"没传"当成"用户要清空"会同时坏两
    件事: 状态页永远挂着一条谁也没做过的「建议更新」(每次都拿空名单跟记录比), 而下一次
    普通生成会把用户配好的强制直连名单**悄悄抹掉**并推进一个版本。
    """
    if ssids is not None:
        return list(ssids)
    cur = (meta or {}).get("current") or {}
    return list((cur.get("inputs") or {}).get("ssids") or ())


def effective_inputs(meta, dot_host, server_addresses, ssids, wloc_enabled, ca_der,
                     template=None):
    """按"沿用"语义算出这一刻的规范化输入。status / 判定 / 生成共用它, 于是三处不会各算各的。"""
    return make_inputs(dot_host, server_addresses, effective_ssids(meta, ssids),
                       wloc_enabled, ca_der, template)


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


# ── 服务端产物健康状态 ──────────────────────────────────────────────────────
# 这和"配置变化等级"是**两件事**, 必须分开表达:
#   · 配置变化等级说的是"网关配置变了, 手机上那份可能该换了" —— 关于设备;
#   · 产物健康状态说的是"服务器上这个文件能不能用" —— 关于服务端。
# 把后者混进前者(比如把"文件对不上"说成"建议更新")会同时坏两件事: 用户以为该去动手机,
# 而真正坏掉的服务端文件反倒被一句温和的提示盖过去了。
HEALTHY, MISSING, CORRUPT, STATE_MISMATCH = "healthy", "missing", "corrupt", "state_mismatch"
HEALTH_LABEL = {
    HEALTHY: "✅ 服务端描述文件完整",
    MISSING: "⚠️ 服务端描述文件缺失, 需要先修复后才能发送",
    CORRUPT: "❌ 描述文件与生命周期记录不一致, 已拒绝发送",
    STATE_MISMATCH: "❌ 描述文件与生命周期记录不一致, 已拒绝发送",
}


class IntegrityError(StateError):
    """产物不可用。继承 StateError, 于是既有的调用方照旧接得住。"""


def _slot(meta, which):
    return (meta or {}).get("current" if which == "current" else "previous")


def artifact_health(meta, which="current", root=None):
    """(状态, 说明)。**只看服务端**: 文件在不在、是不是普通文件、内容有没有被动过、
    身份对不对、是不是另一版串过来的。任何一项不成立都不许当成"手机需要更新"。"""
    rec = _slot(meta, which)
    name = "当前版本" if which == "current" else "上一版"
    if not rec:
        return MISSING, "记录里没有%s" % name
    path = art_path(which, root)
    try:
        st = os.lstat(path)
    except OSError:
        return MISSING, "%s产物文件不在服务器上(%s)" % (name, path)
    # 软链/硬链都不认: 那意味着"发出去的字节"取决于链接指向哪儿, 而不是我们写下的那份。
    if stat.S_ISLNK(st.st_mode):
        return CORRUPT, "%s产物是符号链接, 拒绝使用" % name
    if not stat.S_ISREG(st.st_mode):
        return CORRUPT, "%s产物不是普通文件, 拒绝使用" % name
    if st.st_nlink != 1:
        return CORRUPT, "%s产物存在硬链接(nlink=%d), 拒绝使用" % (name, st.st_nlink)
    # 组/其它可写 = 别人能改这份文件, 那"它与记录一致"就只是**此刻**成立。描述文件本身是
    # 公开内容, 可读没问题; 可写不行。属主同理: 不是 root(或当前有效用户)写下的, 就不该
    # 由我们担保。两者都能靠 repair_current 按记录重写来纠正。
    if st.st_mode & 0o022:
        return CORRUPT, "%s产物可被其它用户写入(mode %o), 拒绝使用" % (name, st.st_mode & 0o777)
    if st.st_uid not in (0, os.geteuid()):
        return CORRUPT, "%s产物的属主(uid %d)不对, 拒绝使用" % (name, st.st_uid)
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return CORRUPT, "%s产物读不出来: %s" % (name, e.strerror)
    if not data:
        return CORRUPT, "%s产物是空文件" % name
    try:
        iosprofile.reject_key_material(data, "%s产物" % name)
        p = iosprofile.validate(data)
    except iosprofile.ProfileError as e:
        return CORRUPT, "%s产物不是一份合法的描述文件: %s" % (name, e)
    # 身份必须是本网关的。不是的话, 这份文件根本不该被当成"我们的某一版"。
    try:
        ids = derive_ids((meta or {}).get("instance_id"))
    except StateError as e:
        return STATE_MISMATCH, str(e)
    dns = [x for x in p["PayloadContent"]
           if x.get("PayloadType") == "com.apple.dnsSettings.managed"][0]
    if p.get("PayloadUUID") != ids["root"] or dns.get("PayloadUUID") != ids["dns"]:
        return STATE_MISMATCH, "%s产物的身份与本网关不符(不是这台机器生成的)" % name
    want = rec.get("sha256")
    got = hashlib.sha256(data).hexdigest()
    if want and got != want:
        other = _slot(meta, "previous" if which == "current" else "current") or {}
        if other.get("sha256") == got:
            return STATE_MISMATCH, ("%s的位置上放着的是第 %s 版的文件(串位了)"
                                    % (name, other.get("revision")))
        return STATE_MISMATCH, "%s产物与记录的 sha256 不符(内容被动过)" % name
    # CA 也要对得上: 指纹在元数据里, 正文只在产物里 —— 两边一致才谈得上"这就是那一版"。
    inp = rec.get("inputs") or {}
    cas = [x for x in p["PayloadContent"] if x.get("PayloadType") == "com.apple.security.root"]
    if bool(cas) != bool(inp.get("wloc_enabled")):
        return STATE_MISMATCH, "%s产物是否含根证书与记录不符" % name
    if cas:
        if hashlib.sha256(cas[0]["PayloadContent"]).hexdigest() != inp.get("wloc_ca_sha256"):
            return STATE_MISMATCH, "%s产物里的根证书指纹与记录不符" % name
    return HEALTHY, "%s产物与记录一致(第 %s 版)" % (name, rec.get("revision"))


def verified_artifact(meta, which="current", root=None):
    """**所有**读取/发送入口的唯一出口。校验不过就抛, 绝不退而求其次发一份旧的。

    "先看看有没有, 有就发" 是这类功能最容易写成的样子, 也是最坏的样子: 用户拿到一份与
    服务器记录对不上的描述文件, 而两边都以为一切正常。
    """
    state, detail = artifact_health(meta, which, root)
    if state != HEALTHY:
        raise IntegrityError("%s —— %s" % (HEALTH_LABEL[state], detail))
    with open(art_path(which, root), "rb") as f:
        return f.read()


def health_summary(meta, root=None):
    """两个槽位各一行, 供状态页/恢复报告直接用。"""
    out = []
    for which in ("current", "previous"):
        if which == "previous" and not (meta or {}).get("previous"):
            continue
        state, detail = artifact_health(meta, which, root)
        out.append((which, state, detail))
    return out


# ── 三档判定 ────────────────────────────────────────────────────────────────
def classify(meta, inputs):
    """(等级, [理由]) —— **只回答一个问题**: 网关当前的语义配置相对已生成的那一版变了没有。

    刻意不接收产物字节: 服务端文件坏没坏是另一件事(见 artifact_health), 混进来会让用户
    以为要去动手机, 而真正坏掉的服务端文件反被一句温和提示盖过去。签名里少一个参数, 这条
    界限就不是靠自觉维持的。
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
    if level == NONE and not reasons:
        reasons.append("网关配置与已生成版本一致")
    return level, reasons


# ── 写事务 ──────────────────────────────────────────────────────────────────
class _LifecycleLock:
    """整段读-改-写共用的**一把**锁。

    原来每个写操作是"锁外读 → 锁外算 → 锁内写": 两个进程能同时读到同一版记录, 各自算出
    "下一版 = 第 N+1 版", 再一前一后落盘 —— 后写的把先写的整个盖掉, 而两边都收到成功。
    丢的是用户刚做的那次配置变更, 而且 revision 连号, 事后从记录上看不出中间少了一版。

    所以锁必须从**读记录之前**一直持到**写后复核之后**。内部函数一律写成 `_*_locked`,
    由这里统一持锁后调用; 它们内部的 `_Txn` 传 `lock=False` —— 同一进程用不同 fd 再
    flock 一次同一个文件会把自己挡住(LOCK_NB 直接 EWOULDBLOCK), 那是自死锁。
    """

    def __init__(self, enabled=True, what="本次操作"):
        self.enabled = enabled
        self.what = what
        self._lk = None

    def __enter__(self):
        if self.enabled:
            self._lk = pdgtx._Lock()
            try:
                self._lk.__enter__()
            except pdgtx.TxBusy:
                raise StateError("已有配置操作正在执行, %s已跳过(避免并发写坏记录)。" % self.what)
            except pdgtx.TxRefused as e:
                raise StateError(str(e))
        return self

    def __exit__(self, *exc):
        if self._lk:
            self._lk.__exit__(None, None, None)
            self._lk = None
        return False


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


def generate(dot_host, server_addresses, ssids=None, ca_der=b"", wloc_enabled=False,
             template=None, meta_path=None, art_root=None, lock=True, legacy_seen=False):
    """生成(或确认无需生成)受管描述文件。返回 (meta, level, reasons, data, changed)。

    输入没变时**不产生新 revision**: 产物逐字节相同, previous 不被顶掉。这正是"点一下重新
    生成"应有的样子 —— 重新拿一份文件, 而不是制造一次版本变更。
    """
    with _LifecycleLock(lock, "本次生成"):
        return _generate_locked(dot_host, server_addresses, ssids, ca_der, wloc_enabled,
                                template, meta_path, art_root, legacy_seen)


def _generate_locked(dot_host, server_addresses, ssids, ca_der, wloc_enabled,
                     template, meta_path, art_root, legacy_seen):
    """**必须在持锁状态下调用。** 读记录 → 算候选 → 落盘 → 写后复核, 整段在同一把锁里。"""
    mp = meta_path or META
    ar = art_root or ART_DIR
    meta = load(mp)
    # ssids=None ⇒ 沿用记录里的名单。必须在 load 之后算 —— 它要读记录。
    inputs = effective_inputs(meta, dot_host, server_addresses, ssids, wloc_enabled,
                              ca_der, template)
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
    # 判定必须在改写之前算: 它回答的是"相对**上一次生成的那一版**要不要重新装"。
    # 写完再算就是拿新记录跟它自己比, 永远得到"无需更新" —— 那正好把这个功能的意义抹掉。
    level, reasons = classify(meta, inputs)

    if same:
        # 语义输入没变 ⇒ 这次点"生成"要的是**那一版**, 不是新版本。
        state, detail = artifact_health(meta, "current", ar)
        if state == HEALTHY:
            return meta, level, reasons, data, False
        # 产物不可用 → 只能在"能逐字节复原"的前提下修, 修不了就 fail-closed。
        meta = _repair_current_locked(ca_der, template, mp, ar)
        reasons = list(reasons) + ["%s(%s), 已按记录逐字节复原" % (HEALTH_LABEL[state], detail)]
        return meta, level, reasons, data, False

    cur_state = artifact_health(meta, "current", ar)[0] if cur else None
    with _Txn(lock=False) as tx:            # 锁已由 _generate_locked 的调用方持有
        os.makedirs(ar, mode=0o700, exist_ok=True)
        _cleanup_candidates(ar)
        new = dict(meta)
        if cur and cur_state == HEALTHY:
            tx.write(art_path("previous", ar), read_artifact("current", ar), 0o644)
            new["previous"] = dict(cur)
        elif cur:
            # 现有 current 已经不可信, 就不能把它当成"上一版"存起来 —— 那等于把一份对不上
            # 记录的文件正式登记成历史。也不要在记录里假装还留着可回退的版本。
            tx.remove(art_path("previous", ar))
            new["previous"] = None
            reasons = list(reasons) + ["原当前版本产物不可用(%s), 未留作上一版" % cur_state]
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
    verified_artifact(meta, "current", ar)     # 写完立刻自证: 落盘的就是记录说的那一份
    return meta, level, reasons, data, True


def repair_current(ca_der=b"", template=None, meta_path=None, art_root=None, lock=True):
    """按记录**逐字节复原** current。复原不了就拒绝 —— 不猜、不新建身份、不推进 revision。

    允许复原的全部条件(缺一不可):
      · 元数据完整可读;
      · 记录里有 current, 且带 inputs 与 sha256;
      · 手上这张公开 CA 的指纹与记录里那一版一致(记录里只有指纹, 正文只在产物里 ——
        指纹对不上就说明手上的不是那一版用的证书, 拿它渲染出来的是**另一份文件**);
      · 用记录里的 inputs + 稳定身份重新渲染, 结果的 sha256 与记录**精确相等**。
    然后才写盘, 且: revision 不变、previous 一个字节不动、写完复核。
    """
    with _LifecycleLock(lock, "本次复原"):
        return _repair_current_locked(ca_der, template, meta_path, art_root)


def _repair_current_locked(ca_der=b"", template=None, meta_path=None, art_root=None):
    """**必须在持锁状态下调用。**"""
    mp = meta_path or META
    ar = art_root or ART_DIR
    meta = load(mp)
    if not meta or not meta.get("current"):
        raise IntegrityError("没有可复原的记录 —— 请重新生成一份描述文件。")
    rec = meta["current"]
    inp = rec.get("inputs")
    want = rec.get("sha256")
    if not inp or not want:
        raise IntegrityError("记录里缺 inputs 或 sha256, 无法确定性复原, 已拒绝。")
    have = hashlib.sha256(ca_der).hexdigest() if ca_der else ""
    if have != (inp.get("wloc_ca_sha256") or ""):
        raise IntegrityError(
            "第 %s 版用的根证书指纹与当前手上的不一致, 无法复原那一版 —— "
            "拿现在的证书渲染出来的是另一份文件。请从备份恢复, 或重新生成一版新的。"
            % rec.get("revision"))
    ids = derive_ids(meta["instance_id"])
    data = iosprofile.render(inp["dot_host"], inp["server_addresses"], inp.get("ssids") or (),
                             ca_der, ids, template)
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        raise IntegrityError(
            "重新渲染的结果与第 %s 版的记录对不上(可能模板已随版本更新), 无法逐字节复原, "
            "已拒绝。请从备份恢复, 或重新生成一版新的。" % rec.get("revision"))
    prev_before = read_artifact("previous", ar)
    with _Txn(lock=False) as tx:            # 锁已由调用方持有
        os.makedirs(ar, mode=0o700, exist_ok=True)
        _cleanup_candidates(ar)
        tx.write(art_path("current", ar), data, 0o644)
    if read_artifact("previous", ar) != prev_before:
        raise IntegrityError("复原过程动到了上一版产物, 这不该发生。")
    verified_artifact(meta, "current", ar)
    return meta


def _update_meta(fn, meta_path=None, lock=True, what="本次修改"):
    with _LifecycleLock(lock, what):
        return _update_meta_locked(fn, meta_path)


def _update_meta_locked(fn, meta_path=None):
    """**必须在持锁状态下调用。** 读与写在同一把锁里, 否则两个改记录的操作会互相覆盖。"""
    mp = meta_path or META
    meta = load(mp)
    if not meta:
        raise StateError("还没有受管描述文件记录。")
    with _Txn(lock=False) as tx:
        new = fn(dict(meta))
        tx.write(mp, json.dumps(new, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n", 0o600)
    return new


SENT_MARKED, SENT_SUPERSEDED = "marked", "superseded"


def mark_sent(expect_revision, expect_sha256, meta_path=None, lock=True):
    """记录"我们把**这一版**发出去了"。注意措辞: 发出去 ≠ 装上了。

    必须点名发的是哪一版。原来它无条件给"此刻的 current"盖章 —— 于是发送第 1 版的过程中
    别人生成了第 2 版, 章就盖到第 2 版头上: 记录说第 2 版发过了, 而它其实从没出过门。
    之后用户看到"上次发送"是个时间, 会以为手机上那份就是第 2 版。

    返回 (状态, meta):
      · SENT_MARKED     —— 发的正是当前版, 已盖章;
      · SENT_SUPERSEDED —— 期间 current 已经变了, **不盖章**(旧版的送达与新版无关)。
    两者都不抛异常, 也都不回传路径或文件内容 —— 调用方只需要知道该怎么对用户说。
    """
    with _LifecycleLock(lock, "本次标记"):
        mp = meta_path or META
        meta = load(mp)
        cur = (meta or {}).get("current") or {}
        if not meta or not cur:
            return SENT_SUPERSEDED, meta
        if cur.get("revision") != expect_revision or cur.get("sha256") != expect_sha256:
            return SENT_SUPERSEDED, meta
        def f(m):
            m["current"] = dict(m["current"], sent_at=_stamp())
            return m
        return SENT_MARKED, _update_meta_locked(f, mp)


def ack_migration(meta_path=None, lock=True):
    """用户自述"旧描述文件我删了、新的装了"。这只是**用户告诉我们的**, 不是设备状态的证据,
    所以它只关掉迁移提示, 不产生任何"已安装"的结论。"""
    return _update_meta(lambda m: dict(m, migration_pending=False), meta_path, lock)


def recover(meta_path=None, art_root=None, lock=True):
    """崩溃残留清理 + 产物与元数据的一致性检查。返回人话说明的列表。

    **也要拿同一把锁**: `.cand` / `.pdgtx.*` 不只是"崩溃残留", 正在提交的事务此刻手里
    拿的就是这种文件。无锁清理会把一笔进行中的提交的候选删掉 —— 那笔事务随后要么失败,
    要么落下半成品, 而 recover 这边还会报"已清理 N 个残留", 看上去像做了件好事。
    """
    with _LifecycleLock(lock, "本次清理"):
        return _recover_locked(meta_path, art_root)


def _recover_locked(meta_path=None, art_root=None):
    ar = art_root or ART_DIR
    out = []
    n = _cleanup_candidates(ar)
    if n:
        out.append("清理了 %d 个中断留下的候选文件" % n)
    meta = load(meta_path)
    if not meta or not meta.get("current"):
        return out
    for which, state, detail in health_summary(meta, ar):
        out.append("%s: %s" % (HEALTH_LABEL[state], detail))
    return out


# ── 从备份恢复: 三件套联合校验 ──────────────────────────────────────────────
# 恢复是这套生命周期里唯一一个"内容不是我们自己算出来的"入口 —— 记录、current、previous
# 三份都来自包外。过去这里只做了一件事: 把记录 json.loads 一下。于是之后每一次判定、每一次
# 发送, 前提都是"记录说的那一版就是盘上那一份", 而这个前提恰恰是这里应该证明、却没证明的。
#
# 这里挡两类东西, 性质不同, 别混着说:
#   · **不自洽的一组**: 记录说第 2 版而盘上是第 3 版、current/previous 串位、记录里没有
#     previous 却带着一份 previous 文件。不需要有人使坏就会出现(半程失败、旧快照回滚),
#     危害是从此每一次判定都跑在一个不成立的前提上, 界面却一切正常。
#   · **不是这个项目会生成的东西**: mobileconfig 能装的远不止 DNS(VPN、代理、WebClip、
#     MDM 注册都在里面)。恢复完成之后,「📱 iOS 描述文件」页就是一个可信入口, 用户点
#     「发送」拿到什么就装什么。所以只放行本项目自己会写的 payload, 根证书那一格必须是
#     真的 X.509 公钥证书(见 iosprofile.assert_public_cert_der)。
#
# 说清楚**不**保证什么: 恢复的是用户自己给的配置, 我们不去审"这个 DoT 域名该不该信" ——
# 那和"恢复备份"这件事本身矛盾。挡的是"这一组自相矛盾"和"这里面有描述文件不该有的东西"。
class RestoreRefused(StateError):
    """备份里的生命周期三件套不成立。消息里点名是哪一道门。"""


_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")

# ── 当前 schema 下, 一份产物**允许**长什么样 ────────────────────────────────
# 这是白名单, 不是黑名单: 多一个字段、少一个字段、不认识的字段, 一律拒。
#
# 为什么不能靠"放宽未知字段"来做跨版本兼容: 一份 mobileconfig 的语义几乎全在字段上。
# PayloadRemovalDisallowed 一个键就能让用户在手机上删不掉这份描述文件;
# SupplementalMatchDomains 一个键就能改变哪些域名走这条 DNS。放行"暂时不认识的字段"等于
# 承认我们不知道自己在往用户手机上装什么。将来渲染结构有意变化时升 SCHEMA 或加显式的版本
# 化校验 —— 在那之前只认这一套。
#
# 这份表必须与 iosprofile.render 的输出保持一致。tests/test-ios-profile-backup-trust.py
# 里有一条守卫: 拿当前渲染器现render 的产物过一遍这里, 必须**正好**合规 —— 于是模板或渲染器
# 改了而这里没跟上, 测试就红。
_TOP_KEYS = frozenset(("PayloadContent", "PayloadDisplayName", "PayloadIdentifier",
                       "PayloadUUID", "PayloadType", "PayloadVersion"))
_DNS_KEYS = frozenset(("PayloadType", "PayloadVersion", "PayloadIdentifier", "PayloadUUID",
                       "PayloadDisplayName", "DNSSettings", "OnDemandRules"))
_DNSSET_KEYS = frozenset(("DNSProtocol", "ServerName", "ServerAddresses"))
_CA_KEYS = frozenset(("PayloadType", "PayloadVersion", "PayloadIdentifier", "PayloadUUID",
                      "PayloadDisplayName", "PayloadContent", "PayloadCertificateFileName"))
# 按需规则允许的几种形态(模板里那三条 + SSID 强制直连那一条)
_RULE_KEYSETS = (frozenset(("InterfaceTypeMatch", "Action", "URLStringProbe")),
                 frozenset(("InterfaceTypeMatch", "Action")),
                 frozenset(("InterfaceTypeMatch", "SSIDMatch", "Action")),
                 frozenset(("Action",)))
# 记录里 inputs 的字段与类型。多一个少一个都拒: 少了会让后面的比对静默跳过, 多了说明这份
# 记录不是本版本写出来的, 而我们没有能力判断多出来的那个字段意味着什么。
_INPUT_TYPES = (("schema", int), ("dot_host", str), ("server_addresses", list),
                ("dns_protocol", str), ("probe_url", str), ("ondemand_core", list),
                ("ssids", list), ("wloc_enabled", bool), ("wloc_ca_sha256", str))

def _refuse(gate, why):
    raise RestoreRefused("备份里的 iOS 描述文件没通过「%s」这道门: %s" % (gate, why))


def _keys_exact(what, got, want):
    """字段集合必须**正好**是 want。多的、少的都点名报出来。"""
    extra = sorted(set(got) - set(want))
    if extra:
        _refuse("字段白名单", "%s 多了本项目不会写的字段: %s" % (what, "、".join(extra)))
    miss = sorted(set(want) - set(got))
    if miss:
        _refuse("字段白名单", "%s 少了本项目一定会写的字段: %s" % (what, "、".join(miss)))


def _check_record(rec, name):
    gate = "记录格式"
    if not isinstance(rec, dict):
        _refuse(gate, "%s 那一栏不是一条记录" % name)
    rev = rec.get("revision")
    if not isinstance(rev, int) or isinstance(rev, bool) or rev < 1:
        _refuse(gate, "%s 的 revision 不是正整数(%r)" % (name, rev))
    if not isinstance(rec.get("digest"), str) or not _DIGEST_RE.match(rec["digest"]):
        _refuse(gate, "%s 的 digest 不是 sha256:<64 位小写十六进制>(实际 %r)"
                % (name, rec.get("digest")))
    if not isinstance(rec.get("sha256"), str) or not _HEX64.match(rec.get("sha256") or ""):
        _refuse(gate, "%s 的 sha256 不是 64 位十六进制" % name)
    for k in ("generated_at", "sent_at"):
        if rec.get(k) is not None and not isinstance(rec.get(k), str):
            _refuse(gate, "%s 的 %s 类型不对" % (name, k))
    inp = rec.get("inputs")
    if not isinstance(inp, dict):
        _refuse(gate, "%s 缺 inputs" % name)
    want = {k for k, _ in _INPUT_TYPES}
    if set(inp) != want:
        _refuse(gate, "%s 的 inputs 字段与本版本对不上(多/少: %s)"
                % (name, "、".join(sorted(set(inp) ^ want)) or "?"))
    for k, ty in _INPUT_TYPES:
        v = inp[k]
        if ty is bool:
            if not isinstance(v, bool):
                _refuse(gate, "%s 的 inputs.%s 不是布尔" % (name, k))
        elif isinstance(v, bool) or not isinstance(v, ty):
            _refuse(gate, "%s 的 inputs.%s 类型不对(%r)" % (name, k, type(v).__name__))
    if inp["schema"] != SCHEMA:
        _refuse(gate, "%s 的 inputs.schema=%r, 本版本只认 %d" % (name, inp["schema"], SCHEMA))
    if inp["wloc_enabled"] != bool(inp["wloc_ca_sha256"]):
        _refuse(gate, "%s 的 inputs 自相矛盾: wloc_enabled=%r 而根证书指纹%s"
                % (name, inp["wloc_enabled"], "有" if inp["wloc_ca_sha256"] else "没有"))
    if inp["wloc_ca_sha256"] and not _HEX64.match(inp["wloc_ca_sha256"]):
        _refuse(gate, "%s 的 inputs.wloc_ca_sha256 不是 64 位十六进制" % name)
    # digest 是"配置有没有变"的唯一依据, 三档判定全靠它。只看格式是不够的 —— 伪造一串
    # 合法形态的 digest 就能让"必须更新"变成"无需更新"。按 inputs 重新算一遍核对。
    if rec["digest"] != digest_of(inp):
        _refuse("digest 自洽", "%s 的 digest 与它自己的 inputs 对不上 —— 记录被改过, "
                "拿它做更新判定会得出相反的结论" % name)


def _check_meta(raw):
    """记录本身。用词与 load() 保持一致的判据, 但这里是**包外内容**, 一律 fail-closed。"""
    gate = "记录格式"
    # 文件在、但读不出来 ⇒ 整笔拒, 不是"跳过这一组"。
    # 只有"归档里根本没有这个文件"才解释得成"这份备份不含 iOS 生命周期" —— 那由调用方在
    # 取文件时判断。一份记录损坏的备份如果只跳过 iOS 那一组、照常换掉网关配置, 结果是两边
    # 从此对不上, 而界面上什么都不会说。
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        _refuse(gate, "记录不是 UTF-8 文本(已损坏) —— 备份里有这个文件却读不出来, "
                      "不能当成「这份备份不含 iOS 生命周期」")
    try:
        meta = json.loads(text)
    except ValueError:
        _refuse(gate, "记录不是合法 JSON(已损坏) —— 备份里有这个文件却解析不了, "
                      "整笔恢复已中止")
    if not isinstance(meta, dict):
        _refuse(gate, "记录不是一个 JSON 对象")
    if meta.get("schema") != SCHEMA:
        _refuse(gate, "格式版本不认识(schema=%r)" % meta.get("schema"))
    if not isinstance(meta.get("instance_id"), str) or not meta["instance_id"]:
        _refuse(gate, "没有身份标识")
    try:
        derive_ids(meta["instance_id"])
    except Exception:  # noqa: BLE001
        _refuse(gate, "身份标识不合法")
    if not isinstance(meta.get("migration_pending"), bool):
        _refuse(gate, "migration_pending 不是布尔")
    if meta.get("created_at") is not None and not isinstance(meta.get("created_at"), str):
        _refuse(gate, "created_at 类型不对")
    if set(meta) != set(_blank()):
        _refuse(gate, "记录的字段与本版本对不上(多/少: %s)"
                % "、".join(sorted(set(meta) ^ set(_blank()))))
    for which, name in (("current", "current"), ("previous", "previous")):
        if meta.get(which) is not None:
            _check_record(meta[which], name)
    if meta.get("previous") and not meta.get("current"):
        _refuse("三件配套", "记录里有上一版却没有当前版本 —— 这一组不成立")
    if meta.get("previous") and meta.get("current") \
            and meta["previous"]["revision"] >= meta["current"]["revision"]:
        _refuse("三件配套", "上一版的 revision(%d)不小于当前版本(%d)"
                % (meta["previous"]["revision"], meta["current"]["revision"]))
    return meta


def _ondemand_of(rules, ssids):
    """把产物里的 OnDemandRules 还原成"与 SSID 无关的骨架", 好跟记录里的 ondemand_core 比。

    比的是**这份备份自己记的** ondemand_core, 不是本机模板算出来的 —— 否则跨版本恢复
    (备份是旧模板渲染的)会被自己人挡在门外, 而那恰恰是恢复最该管用的场合。
    """
    rules = [dict(r) for r in rules if isinstance(r, dict)]
    if ssids:
        want = {"InterfaceTypeMatch": "WiFi", "SSIDMatch": list(ssids), "Action": "Disconnect"}
        if not rules or rules[0] != want:
            return None
        rules = rules[1:]
    for r in rules:
        if "URLStringProbe" in r:
            r["URLStringProbe"] = "<probe>"
    return rules


def _check_artifact(meta, which, data, ids):
    """一份产物对上它自己那条记录。每道门单独命名 —— 出事时要知道是哪一条不成立。"""
    name = "当前版本" if which == "current" else "上一版"
    rec = meta[which]
    inp = rec["inputs"]
    if not data:
        _refuse("三件配套", "%s是空文件" % name)
    iosprofile.reject_key_material(data, "备份里的%s产物" % name)
    got = hashlib.sha256(data).hexdigest()
    if got != rec["sha256"]:
        other = meta.get("previous" if which == "current" else "current") or {}
        if other.get("sha256") == got:
            _refuse("内容指纹", "%s的位置上放着的是第 %s 版的文件(current/previous 串位)"
                    % (name, other.get("revision")))
        _refuse("内容指纹", "%s的内容与记录里的 sha256 对不上(第 %s 版)"
                % (name, rec["revision"]))
    try:
        p = iosprofile.validate(data)
    except iosprofile.ProfileError as e:
        _refuse("描述文件结构", "%s不是一份合法的描述文件: %s" % (name, e))
    items = [x for x in (p.get("PayloadContent") or []) if isinstance(x, dict)]
    extra = sorted({str(x.get("PayloadType")) for x in items} - set(iosprofile.ALLOWED_PAYLOAD_TYPES))
    if extra:
        _refuse("payload 白名单", "%s里有本项目不会生成的 payload: %s —— 恢复之后它会从"
                "「📱 iOS 描述文件」页发给用户安装, 拒绝。" % (name, "、".join(extra)))
    if len(items) != len(p.get("PayloadContent") or []):
        _refuse("payload 白名单", "%s的 PayloadContent 里有非字典项" % name)
    # 字段白名单: 多一个、少一个、不认识的一律拒(为什么不放宽, 见 _TOP_KEYS 上面那段)
    _keys_exact("%s的顶层" % name, p, _TOP_KEYS)
    if p.get("PayloadUUID") != ids["root"] \
            or p.get("PayloadIdentifier") != iosprofile.ID_ROOT + "." + ids["root"]:
        _refuse("身份", "%s不是这台网关(instance_id)生成的 —— 顶层身份对不上" % name)
    dns = [x for x in items if x.get("PayloadType") == "com.apple.dnsSettings.managed"][0]
    _keys_exact("%s的 DNS payload" % name, dns, _DNS_KEYS)
    if dns.get("PayloadUUID") != ids["dns"] \
            or dns.get("PayloadIdentifier") != iosprofile.ID_DNS + "." + ids["dns"]:
        _refuse("身份", "%s的 DNS payload 不是这台网关(instance_id)派生的身份" % name)
    cas = [x for x in items if x.get("PayloadType") == "com.apple.security.root"]
    if bool(cas) != bool(inp["wloc_enabled"]):
        _refuse("根证书", "%s是否含根证书与记录不符(记录说%s)"
                % (name, "有" if inp["wloc_enabled"] else "没有"))
    if cas:
        ca = cas[0]
        # 根证书那一格要**整格**核对: 类型、版本、固定 identifier、派生 UUID、证书文件名、
        # DER 指纹、以及它到底是不是一张真的 X.509 公钥证书。少查一样, 手机上信任的那张根
        # 证书就可能不是我们记录的那张 —— 而这一格的后果是"这台设备信任谁"。
        _keys_exact("%s的根证书 payload" % name, ca, _CA_KEYS)
        if ca.get("PayloadVersion") != 1:
            _refuse("根证书", "%s的根证书 payload 的 PayloadVersion 不是 Apple 规定的 1(实际 %r)"
                    % (name, ca.get("PayloadVersion")))
        if ca.get("PayloadIdentifier") != iosprofile.ID_CA:
            _refuse("根证书", "%s的根证书 payload 的 PayloadIdentifier 不是本项目固定的 %s"
                    "(实际 %r)" % (name, iosprofile.ID_CA, ca.get("PayloadIdentifier")))
        if ca.get("PayloadCertificateFileName") != iosprofile.CA_FILENAME:
            _refuse("根证书", "%s的根证书 payload 的证书文件名不是本项目固定的 %s(实际 %r)"
                    % (name, iosprofile.CA_FILENAME, ca.get("PayloadCertificateFileName")))
        if ca.get("PayloadDisplayName") != iosprofile.CA_DISPLAY:
            _refuse("根证书", "%s的根证书 payload 的显示名不是本项目写的那个(实际 %r)"
                    % (name, ca.get("PayloadDisplayName")))
        body = ca.get("PayloadContent")
        if not isinstance(body, (bytes, bytearray)):
            _refuse("根证书", "%s的根证书那一格不是二进制内容" % name)
        if hashlib.sha256(bytes(body)).hexdigest() != inp["wloc_ca_sha256"]:
            _refuse("根证书", "%s里的根证书指纹与记录不符 —— 那不是这一版用的那张证书" % name)
        if ca.get("PayloadUUID") != ids["ca"]:
            _refuse("身份", "%s的根证书 payload UUID 不是这台网关派生的" % name)
        try:
            iosprofile.assert_public_cert_der(bytes(body), "%s里的根证书" % name)
        except iosprofile.ProfileError as e:
            _refuse("根证书", str(e))
    s = dns.get("DNSSettings") or {}
    _keys_exact("%s的 DNSSettings" % name, s, _DNSSET_KEYS)
    for r in (dns.get("OnDemandRules") or []):
        if not isinstance(r, dict):
            _refuse("字段白名单", "%s的按需规则里有非字典项" % name)
        if frozenset(r) not in _RULE_KEYSETS:
            _refuse("字段白名单", "%s的按需规则里有本项目不会写的形态(字段: %s)"
                    % (name, "、".join(sorted(r)) or "空"))
    if s.get("ServerName") != inp["dot_host"]:
        _refuse("语义一致", "%s里的 ServerName(%r)与记录的 dot_host(%r)不符"
                % (name, s.get("ServerName"), inp["dot_host"]))
    if list(s.get("ServerAddresses") or []) != list(inp["server_addresses"]):
        _refuse("语义一致", "%s里的 ServerAddresses 与记录不符" % name)
    if s.get("DNSProtocol") != inp["dns_protocol"]:
        _refuse("语义一致", "%s里的 DNSProtocol 与记录不符" % name)
    rules = dns.get("OnDemandRules") or []
    for r in rules:
        if isinstance(r, dict) and "URLStringProbe" in r \
                and r["URLStringProbe"] != inp["probe_url"]:
            _refuse("语义一致", "%s里的探测地址与记录不符" % name)
    core = _ondemand_of(rules, inp["ssids"])
    if core is None:
        _refuse("语义一致", "%s里的 SSID 强制直连名单与记录不符" % name)
    if core != inp["ondemand_core"]:
        _refuse("语义一致", "%s里的按需规则骨架与记录不符" % name)


def validate_restore_set(raw, cur=None, prev=None):
    """备份里的三件套 → (记录字节, current 字节或 None, previous 字节或 None, 提示或 None)。

    不通过就抛 RestoreRefused, **一个字节都不写**。记录解不开时返回 (None, ...) 让调用方
    按既有口径处理(跳过 iOS 这一组, 不动现网)。
    """
    meta = _check_meta(raw)
    if meta is None:
        return None, None, None, None
    want = {w for w in ("current", "previous") if meta.get(w)}
    have = {w for w, d in (("current", cur), ("previous", prev)) if d is not None}
    if want and not have:
        # 旧格式备份(只带记录、不带产物)。既有口径: 如实说明, 不假装完整恢复。previous 那一版
        # 用的根证书只在产物里有正文, 元数据里只有指纹 —— 它丢了就真的没了, 谁也重建不出来。
        note = ""
        if meta.get("previous"):
            meta = dict(meta, previous=None)
            note = ("ℹ️ 这份备份是旧格式(只带记录、不带描述文件本体): 上一版已标记为不可用 —— "
                    "它用的根证书只在文件里有正文, 无法重建。")
        if meta.get("current"):
            note = ((note + " ") if note else "ℹ️ 这份备份是旧格式(只带记录、不带描述文件本体): ") \
                + "当前版本的文件不在备份里, 请到「📱 iOS 描述文件」页确认服务端状态。"
        raw_out = json.dumps(meta, ensure_ascii=False, indent=2,
                             sort_keys=True).encode("utf-8") + b"\n"
        return raw_out, None, None, (note or None)
    if have - want:
        _refuse("三件配套", "包里带着记录里没有的%s产物 —— 这一组自相矛盾, 不能只按其中一半"
                "恢复(常见成因: 旧快照回滚留下的孤儿文件)"
                % "、".join("上一版" if w == "previous" else "当前版本" for w in sorted(have - want)))
    if want - have:
        _refuse("三件配套", "记录里有%s, 包里却缺这一份产物 —— 恢复回去就是"
                "「记录说有、盘上没有」"
                % "、".join("上一版" if w == "previous" else "当前版本" for w in sorted(want - have)))
    ids = derive_ids(meta["instance_id"])
    if "current" in want:
        _check_artifact(meta, "current", cur, ids)
    if "previous" in want:
        _check_artifact(meta, "previous", prev, ids)
    return raw, cur, prev, None


# ── 恢复计划: Bot / 救援平面 / CLI 回滚共用的**同一份**判断 ──────────────────
# 三个入口过去各写各的: Bot 只 stage 归档里存在的文件, 救援平面把三个成员当成三份独立配置
# 逐个映射, CLI 回滚干脆不校验。于是同一份备份在三条路上恢复出三种结果, 而且都不报错。
#
# 这里给出**目标状态**而不是"要写哪些文件": 归档里没有 previous, 不等于"别动现网的
# previous" —— 恰恰相反, 它等于"那一刻没有上一版", 现网那份必须删掉。把"缺失"表达成删除
# 目标, 才谈得上"恢复完之后盘面就是备份那一刻的样子"。
DELETE = "\x00delete"          # 目标状态 = 删掉它。不能用 None: None 表示"这次不碰"

REL_STATE = "etc/privdns-gateway/ios-profile.json"
REL_CUR = "var/lib/privdns-gateway/ios-profile/current.mobileconfig"
REL_PREV = "var/lib/privdns-gateway/ios-profile/previous.mobileconfig"
PLAN_TARGETS = (("state", "ios_profile_state"),
                ("current", "ios_profile_current"),
                ("previous", "ios_profile_previous"))


def plan_restore(raw, cur=None, prev=None):
    """这一组的恢复计划。返回 (plan, 提示) 或抛 RestoreRefused。

    plan = {"state": bytes, "current": bytes|DELETE, "previous": bytes|DELETE}
    raw 为 None(归档里根本没有记录文件)⇒ 返回 (None, None): 这份包不含这一组, 一个字节都
    不碰。这是**唯一**能解释成"不恢复这一组"的情形。
    """
    if raw is None:
        return None, None
    raw2, cur2, prev2, note = validate_restore_set(raw, cur, prev)
    return {"state": raw2,
            "current": cur2 if cur2 is not None else DELETE,
            "previous": prev2 if prev2 is not None else DELETE}, note


def plan_from_tree(root):
    """从解包出来的目录树里取这一组, 出计划。三个入口都走它, 于是判据只有一份。"""
    def _rd(rel):
        f = os.path.join(root, rel)
        if not os.path.isfile(f):
            return None
        with open(f, "rb") as fh:
            return fh.read()
    return plan_restore(_rd(REL_STATE), _rd(REL_CUR), _rd(REL_PREV))


def stage_plan(tx, plan):
    """把计划挂进一笔 pdgtx 事务, 返回实际进了事务的目标名。

    删除也带 expect sha: 从读到落盘之间别人改了这份文件, 事务必须拒绝而不是照删 ——
    否则一次恢复会把并发写入的东西悄悄抹掉。
    """
    staged = []
    for which, target in PLAN_TARGETS:
        want = plan[which]
        cur, sha = tx.read_for_update(target)
        if want is DELETE or want == DELETE:
            if cur is None:
                continue                        # 本来就没有, 不必进事务
            tx.stage(target, None, expect=sha)
        else:
            if cur == want:
                continue                        # 一个字节都不用动
            tx.stage(target, want, expect=sha)
        staged.append(target)
    return staged


def plan_has_work(plan):
    """这份计划相对现网有没有实际改动。用来判断"一个字节都不用动", 不开事务。"""
    if not plan:
        return False
    for which, target in PLAN_TARGETS:
        path, _m, _s, _v = pdgtx.resolve_target(target)
        cur, _st = pdgtx._read_target(path)
        want = plan[which]
        if want == DELETE:
            if cur is not None:
                return True
        elif cur != want:
            return True
    return False


def plan_summary(plan):
    """给用户看的一句话: 这次会把这一组换成什么样子。"""
    if not plan:
        return ""
    parts = ["身份/修订记录"]
    parts.append("当前版本" if plan["current"] != DELETE else "删除当前版本")
    parts.append("上一版" if plan["previous"] != DELETE else "删除上一版")
    return "iOS 描述文件(" + " + ".join(parts) + ")"


def status_lines(meta, inputs=None, art_root=None):
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
        lv, why = classify(meta, inputs)
        out.append("配置变化: %s" % LEVEL_LABEL[lv])
        out += ["  · " + r for r in why]
    # 服务端产物健康**单独一行**, 不和上面那条混为一谈: 一个说的是手机上那份要不要换,
    # 另一个说的是服务器上这个文件能不能发。
    for which, state, detail in health_summary(meta, art_root):
        out.append("%s: %s" % (HEALTH_LABEL[state], detail))
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
        # 默认 None = "没指定, 沿用记录里的"; --clear-ssid 才是明确清空。
        # 用 default=[] 的话, 任何一次不带 --ssid 的调用都等于"把名单清掉"。
        p.add_argument("--ssid", action="append", default=None)
        p.add_argument("--clear-ssid", action="store_true", help="明确清空强制直连名单")
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
    rp = sub.add_parser("repair", help="按记录逐字节复原 current(复原不了就拒绝)")
    common(rp)
    vr = sub.add_parser("verify-restore",
                        help="对解包出来的目录树做恢复前的联合校验(CLI 回滚用)")
    vr.add_argument("--tree", required=True, help="已解包的快照根目录")

    a = ap.parse_args(argv)
    if not a.cmd:
        ap.print_help(sys.stderr)
        return 2

    def _ssids():
        return [] if getattr(a, "clear_ssid", False) else a.ssid

    def _inputs():
        der = iosprofile.ca_der_for(iosprofile.wloc_enabled(a.wloc_config), a.ca_crt) \
            if a.wloc_config else b""
        return effective_inputs(load(), a.dot_host, a.server_ip, _ssids(), bool(der), der,
                                a.template), der

    try:
        if a.cmd == "generate":
            der = iosprofile.ca_der_for(iosprofile.wloc_enabled(a.wloc_config), a.ca_crt) \
                if a.wloc_config else b""
            meta, lv, why, data, changed = generate(
                a.dot_host, a.server_ip, _ssids(), der, bool(der), a.template,
                legacy_seen=a.legacy)
            # 落到临时下载目录的那一份也必须过校验器 —— 二维码/临时 HTTP 是最终交到手机
            # 手里的那条路, 不能比 Bot 那条松。
            pdgtx.atomic_write(a.out, verified_artifact(meta, "current"), mode=0o644)
            print("\n".join(status_lines(meta)))
            print("本次: %s" % ("生成了第 %d 版" % meta["current"]["revision"] if changed
                              else "网关配置没有变化, 内容与上次完全相同"))
            for r in why:
                print("  · " + r)
            if meta.get("migration_pending"):
                print("\n⚠️ 安装前请先在 iPhone 上删除旧的「PrivDNS Gateway」描述文件 —— "
                      "旧版是随机身份, 不删的话这份会作为**另一个**描述文件并存。")
            print("\n" + UNKNOWN)
        elif a.cmd == "verify-restore":
            # CLI 回滚在**覆盖生产文件之前**调它。与 Bot、救援平面走同一份 plan_restore ——
            # "这是本机快照所以一定可信"不成立: 快照可能损坏、被换掉、或者只恢复了一半。
            plan, note = plan_from_tree(a.tree)
            if plan is None:
                print("快照里没有 iOS 生命周期记录, 这一组不做改动。")
            else:
                print(plan_summary(plan))
                if note:
                    print(note)
        elif a.cmd == "status":
            meta = load()
            inputs = None
            if a.dot_host and a.server_ip:
                inputs, _ = _inputs()
            print("\n".join(status_lines(meta, inputs)))
            print("\n" + UNKNOWN)
        elif a.cmd == "diff":
            meta = load() or {}
            prev, cur = meta.get("previous"), meta.get("current")
            if not (prev and cur):
                print("还没有上一版可对比。")
                return 0
            # 差异读的是**元数据里的 inputs**, 但只要还打算把这两版当成"服务器上有的东西"
            # 展示, 就该先确认它们真的在、真的对得上。对不上时给结论而不是拿旧数字糊过去。
            for which in ("current", "previous"):
                st, detail = artifact_health(meta, which, None)
                if st != HEALTHY:
                    sys.stderr.write("%s —— %s\n" % (HEALTH_LABEL[st], detail))
                    return 4
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
            meta = load() or {}
            if not meta.get("previous"):
                sys.stderr.write("还没有上一版。\n")
                return 4
            blob = verified_artifact(meta, "previous")
            pdgtx.atomic_write(a.out, blob, mode=0o644)
            print("已取出第 %d 版。这只是把旧文件再给你一次 —— 记录的当前版本不会回退。"
                  % meta["previous"]["revision"])
        elif a.cmd == "recover":
            msgs = recover()
            print("\n".join(msgs) if msgs else "没有需要清理的残留, 产物与记录一致。")
        elif a.cmd == "repair":
            # 已经好的就不动它。照旧重写一遍虽然是幂等的, 但对外说"已复原"是不准确的 ——
            # 用户据此会以为刚才真出过问题。
            meta = load()
            if not meta or not meta.get("current"):
                sys.stderr.write("还没有生成过受管描述文件, 没有可复原的对象。\n")
                return 4
            st, detail = artifact_health(meta, "current")
            if st == HEALTHY:
                print("%s: %s" % (HEALTH_LABEL[st], detail))
                print("无需修复。")
                return 0
            print("%s: %s" % (HEALTH_LABEL[st], detail))
            der = iosprofile.ca_der_for(iosprofile.wloc_enabled(a.wloc_config), a.ca_crt) \
                if a.wloc_config else b""
            meta = repair_current(der, a.template)
            print("已按记录逐字节复原第 %d 版(revision 未变, 上一版未动)。"
                  % meta["current"]["revision"])
    except (StateError, iosprofile.ProfileError) as e:
        sys.stderr.write("%s\n" % e)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
