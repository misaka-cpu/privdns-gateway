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
import errno
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
# ⚠️ 因此在已持有该锁的路径里调用本模块的写操作(`pdg update` 持锁调 __migrate 就是这种路径),
# 必须走**继承锁**那条: _LifecycleLock 会先用 pdgtx.inherited_lock_fd() 证明那把锁确实在手,
# 证明得了就借用(且不释放), 证明不了才自己去抢。不这么做就是每次 TxBusy —— 这个坑在
# v1.7.1/v1.7.2 真踩过。生命周期只在用户主动生成时初始化。

SCHEMA = 2
# 能**读懂并迁移**的历史格式。它们不是运行时 —— 本版本写出去的记录永远是 SCHEMA。
# 把 schema 1 留在这里而不是一删了之, 是因为记录里有 instance_id: 丢了就会造出第二个身份,
# 用户手机上那份描述文件从此永远无法再被更新, 而界面上什么都不会报。
SCHEMA_HISTORY = (1,)

# schema 1 → 2 变了什么(只有这一处说明, 别处引用它):
#   · inputs 去掉 wloc_enabled / wloc_ca_sha256 —— WLOC 位置改写已退役;
#   · 产物里**不许**再有 com.apple.security.root 那一格;
#   · 顶层多一个 retired_revision: 退役迁移丢弃掉的那一版的版本号(见 _migrate_1_to_2)。
# **没变**的: instance_id 与由它派生的各 payload 身份、顶层与 DNS 的语义、SSID 规则、
# 以及 OnDemand 骨架 —— 两个 schema 的按需连接语义**完全相同**, 所以骨架只有一份常量
# (_ONDEMAND_CORE), 不按 schema 分派。抄成两份迟早漂移成一松一紧, 而松的那份就是出口。
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
    "ssids": RECOMMENDED,           # 强制直连名单; 核心连接仍可用
    # wloc_enabled / wloc_ca_sha256 曾在这里。schema 2 的 inputs 里没有这两个字段, 所以
    # diff_fields 永远比不出它们; 真要出现(一份没迁移干净的记录), 缺省是 REQUIRED, 那也对。
}
FIELD_LABEL = {
    "schema": "描述文件格式",
    "dot_host": "DoT 主机名",
    "server_addresses": "网关地址",
    "dns_protocol": "DNS 协议",
    "probe_url": "探测地址",
    "ondemand_core": "按需连接规则",
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
    raw = iosprofile.render("x.invalid", "192.0.2.1", (), ids, template)
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


def probe_url_for(server_addresses):
    """探测地址的**唯一**公式。

    schema 1 没有"单独配置探测 URL"这个入口 —— 它由第一个规范化服务器地址推导。生成
    (make_inputs)与校验(_check_inputs_canonical)共用这一份, 否则校验那边就得再抄一遍公式,
    而两份公式迟早会漂移成"备份说什么就是什么"。
    """
    return "http://%s:81/probe" % iosprofile.norm_addrs(server_addresses)[0]


def make_inputs(dot_host, server_addresses, ssids=(), template=None):
    """把一次生成的**语义输入**规范化。只有这里出现的字段参与 digest。

    刻意排除: 生成时间、发送时间、临时文件名、随机值、模板路径。它们变了不代表配置变了,
    纳进来会让"什么都没改也提示要更新"变成常态, 而常态化的提示等于没有提示。
    """
    return {
        "schema": SCHEMA,
        "dot_host": iosprofile.norm_host(dot_host),
        "server_addresses": iosprofile.norm_addrs(server_addresses),
        "dns_protocol": "TLS",
        "probe_url": probe_url_for(server_addresses),
        "ondemand_core": ondemand_core(template),
        "ssids": iosprofile.norm_ssids(ssids),
        # schema 1 这里还有 wloc_enabled 与 wloc_ca_sha256(根证书指纹)。WLOC 退役后
        # 描述文件不再携带任何根证书, 这两个字段没有对象了 —— 见 _migrate_1_to_2。
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
    if cur:
        return list((cur.get("inputs") or {}).get("ssids") or ())
    # current 是空的: 要么从没生成过(那本来就没有名单可沿用), 要么那一栏在 WLOC 退役迁移里
    # 被丢掉了。后一种情况下用户的名单还在 retired_inputs 里 —— 不看它就等于把"撤掉 WLOC"
    # 顺手做成了"清空他的强制直连名单"。
    ri = (meta or {}).get("retired_inputs") or {}
    return list(ri.get("ssids") or ())


def effective_inputs(meta, dot_host, server_addresses, ssids, template=None):
    """按"沿用"语义算出这一刻的规范化输入。status / 判定 / 生成共用它, 于是三处不会各算各的。"""
    return make_inputs(dot_host, server_addresses, effective_ssids(meta, ssids), template)


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
def _blank(schema=None):
    """某个 schema 下一份空记录的**完整**字段集。字段白名单直接拿它做基准。

    按 schema 分开给, 不给一个"两版并集": 并集会让 schema 1 的记录多带一个 retired_revision
    也照样过关, 而那种记录不是任何版本的本项目写得出来的。
    """
    schema = SCHEMA if schema is None else schema
    base = {"schema": schema, "instance_id": None, "created_at": None,
            "migration_pending": False, "current": None, "previous": None}
    if schema >= 2:
        # 退役迁移丢弃掉的那一版的版本号。留着它有两个用处, 都不能少:
        #   · 下一次生成从这个号往下数, 而不是退回第 1 版(用户与我们对不上版本号);
        #   · 它同时是"这台手机上很可能装着一份带根证书的旧描述文件"的唯一标记。
        base["retired_revision"] = None
        # 被退役那一版的**输入**(schema 2 形态)。退役撤的是 WLOC, 不是用户的 Wi-Fi 名单:
        # "没传 SSID = 沿用记录里的"这条语义原本从 current.inputs 取, 而 current 被退役后
        # 那一栏是空的 —— 不留一份的话, 下一次**普通生成**会把用户配好的强制直连名单当成
        # "用户要清空", 悄悄抹掉并推进一个版本。他既没做过这个决定, 界面上也不会报。
        #
        # 只留**输入**, 不留 revision / sha256 / generated_at / sent_at —— 那些一带上就成了
        # 一条"曾经发过这一版"的记录, 而它对应的产物已经因为嵌着根证书被删掉了。留意图, 不
        # 留凭证。
        base["retired_inputs"] = None
    return base


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
    sc = meta.get("schema") if isinstance(meta, dict) else None
    if not isinstance(meta, dict) or (sc != SCHEMA and sc not in SCHEMA_HISTORY):
        raise StateError("iOS 描述文件记录 %s 的格式版本不认识(schema=%r), 拒绝继续。"
                         % (p, sc))
    # 走**同一份**完整契约(_check_meta_object): 本地这份记录一样可能被手工改坏、被半截
    # 恢复写坏。放行的下场是 status_lines 拿着一条缺字段的记录直接 KeyError —— 用户看到
    # 的是一个打不开的页面, 而那份记录还是我们自己写进去的。
    # 判据只有一份, 这里只把门名与原因换成本机的说法。
    #
    # schema 1 走**同一个** _migrate_1_to_2: 严格验 schema 1 → 迁移 → 严格复核 schema 2。
    # 为什么读的时候就迁: 一台还没跑过 `pdg __migrate` 的机器上, 记录里那份 current 可能
    # 嵌着已退役的根证书 —— 原样交出去, 状态页会把它显示成"可以重新发送的当前版本"。
    # 读路径与写路径共用同一份迁移实现, 于是两处不会得出不同的结论。
    #
    # **这里不写盘**: load 是读。改写盘上那份由 migrate_schema() 负责, 那是个看得见的动作。
    try:
        if sc == SCHEMA:
            _check_meta_object(meta, schema=SCHEMA)
        else:
            meta, _retired = _migrate_1_to_2(meta)
    except RestoreRefused as e:
        raise StateError("iOS 描述文件记录 %s 没通过「%s」这道门: %s\n"
                         "**不自动重建**: 重建会生成一个新身份, 而你手机上那份描述文件将"
                         "永远无法再被更新。请先修复或删除该文件(删除等于放弃现有身份, "
                         "之后必须手工删掉手机上的旧描述文件)。" % (p, e.gate, e.why))
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


def _read_artifact_checked(meta, which, root):
    """磁盘检查 + 读取 + 内容校验, **只读一次**。返回 (状态, 说明, 字节或 None)。

    为什么必须收成一个实现: 原来是 artifact_health() 打开文件读到字节 A、校验通过, 然后
    verified_artifact() **再按路径打开一次**读到字节 B 并返回。两次打开之间把文件换掉
    (os.replace 一下就够), 发出去的就是没有被任何人看过的 B —— 而两边都以为一切正常。

    所以: 一次 os.open(带 O_NOFOLLOW), 之后全部判据都落在**这个 fd** 上 —— fstat 看类型/
    硬链接/权限/属主, read 取内容, 校验也校验这份内存里的字节。路径在这中间被换掉不影响
    已经打开的 fd(它指着旧 inode), 于是"校验的"和"返回的"必然是同一份。
    lstat(path) 之后再按路径重新打开, 中间那一瞬就是这条缝本身。
    """
    rec = _slot(meta, which)
    name = "当前版本" if which == "current" else "上一版"
    if not rec:
        return MISSING, "记录里没有%s" % name, None
    path = art_path(which, root)
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags)
    except OSError as e:
        # O_NOFOLLOW 下最后一段是符号链接会给 ELOOP。软链不认: 那意味着"发出去的字节"
        # 取决于链接指向哪儿, 而不是我们写下的那份。
        if e.errno == errno.ELOOP:
            return CORRUPT, "%s产物是符号链接, 拒绝使用" % name, None
        if e.errno == errno.ENOENT:
            return MISSING, "%s产物文件不在服务器上(%s)" % (name, path), None
        return CORRUPT, "%s产物打不开: %s" % (name, e.strerror), None
    try:
        try:
            st = os.fstat(fd)
        except OSError as e:
            return CORRUPT, "%s产物读不出来: %s" % (name, e.strerror), None
        if not stat.S_ISREG(st.st_mode):
            return CORRUPT, "%s产物不是普通文件, 拒绝使用" % name, None
        if st.st_nlink != 1:
            return CORRUPT, "%s产物存在硬链接(nlink=%d), 拒绝使用" % (name, st.st_nlink), None
        # 组/其它可写 = 别人能改这份文件, 那"它与记录一致"就只是**此刻**成立。描述文件本身
        # 是公开内容, 可读没问题; 可写不行。属主同理: 不是 root(或当前有效用户)写下的, 就
        # 不该由我们担保。两者都能靠 repair_current 按记录重写来纠正。
        if st.st_mode & 0o022:
            return (CORRUPT, "%s产物可被其它用户写入(mode %o), 拒绝使用"
                    % (name, st.st_mode & 0o777), None)
        if st.st_uid not in (0, os.geteuid()):
            return CORRUPT, "%s产物的属主(uid %d)不对, 拒绝使用" % (name, st.st_uid), None
        try:
            with os.fdopen(os.dup(fd), "rb") as f:
                data = f.read()
        except OSError as e:
            return CORRUPT, "%s产物读不出来: %s" % (name, e.strerror), None
    finally:
        os.close(fd)
    if not data:
        return CORRUPT, "%s产物是空文件" % name, None
    # 结构层: 不是一份合法描述文件 = 这个**文件**坏了 → corrupt。
    try:
        iosprofile.reject_key_material(data, "%s产物" % name)
        iosprofile.validate(data)
    except iosprofile.ProfileError as e:
        return CORRUPT, "%s产物不是一份合法的描述文件: %s" % (name, e), None
    # 内容层: 走**同一份** schema 1 严格契约(记录 + 产物), 与恢复的联合校验、写后复核
    # 共用一处实现。恢复严一点、健康宽一点的下场很具体: 一份恢复会被拒的产物, 只要已经
    # 落在盘上就照样判 healthy, 于是 verified_artifact 把它发到用户手机上。
    try:
        strict_artifact_check(meta, which, data)
    except StateError as e:
        return STATE_MISMATCH, str(e), None
    except iosprofile.ProfileError as e:
        return CORRUPT, "%s产物不是一份合法的描述文件: %s" % (name, e), None
    return HEALTHY, "%s产物与记录一致(第 %s 版)" % (name, rec.get("revision")), data


def artifact_health(meta, which="current", root=None):
    """(状态, 说明)。**只看服务端**: 文件在不在、是不是普通文件、内容有没有被动过、
    身份对不对、是不是另一版串过来的。任何一项不成立都不许当成"手机需要更新"。"""
    state, detail, _data = _read_artifact_checked(meta, which, root)
    return state, detail


def verified_artifact(meta, which="current", root=None):
    """**所有**读取/发送入口的唯一出口。校验不过就抛, 绝不退而求其次发一份旧的。

    返回的就是刚刚校验过的**那一份内存字节**, 不再按路径打开第二次 —— 否则校验的和发出去
    的可以是两份东西(见 _read_artifact_checked)。

    "先看看有没有, 有就发" 是这类功能最容易写成的样子, 也是最坏的样子: 用户拿到一份与
    服务器记录对不上的描述文件, 而两边都以为一切正常。
    """
    state, detail, data = _read_artifact_checked(meta, which, root)
    if state != HEALTHY:
        raise IntegrityError("%s —— %s" % (HEALTH_LABEL[state], detail))
    return data


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
    retired = meta.get("retired_revision")
    if retired is not None and not meta.get("current"):
        # 说"还没有生成过"是假话: 生成过, 而且那一版现在还装在用户手机上 —— 只是它嵌着
        # 一张已经退役的根证书, 我们不再留着它、也不再发它。两件要做的事都得说出来。
        return REQUIRED, reasons + [
            "位置改写(WLOC)已退役: 第 %d 版描述文件里嵌着已退役的根证书, 已不再保留。"
            "请重新生成一份(新的不含根证书), 并到 iPhone「设置 → 通用 → 关于本机 → "
            "证书信任设置」里取消对 PrivDNS Gateway MITM CA 的信任" % retired]
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
        self.inherited = False        # 锁是父进程的 → 我们只借用, 退出时不还

    def __enter__(self):
        if not self.enabled:
            return self
        # `pdg update` 持锁调 `__migrate`, 迁移又要调本模块的写操作 —— 那条路上这把锁**已经
        # 在手**(在父进程的 fd 上)。再去 flock 一次同一个文件是新的 OFD, 必然撞上父进程自己。
        # 所以先找有没有**可证明**的继承锁(判据见 pdgtx.inherited_lock_fd: fd 开着 + 指向的
        # 就是锁文件 + 在那个 fd 上真跑过一次非阻塞 flock)。
        #
        # 这里**不是** lock=False: 没有继承锁时照旧自己去抢, 抢不到照旧拒绝。差别在于借来的
        # 那把**不由我们释放** —— 释放的是父进程那把(同一个 OFD), 窗口期里谁都能进来。
        if pdgtx.inherited_lock_fd() is not None:
            self.inherited = True
            return self
        self._lk = pdgtx._Lock()
        try:
            self._lk.__enter__()
        except pdgtx.TxBusy:
            raise StateError("已有配置操作正在执行, %s已跳过(避免并发写坏记录)。" % self.what)
        except pdgtx.TxRefused as e:
            raise StateError(str(e))
        return self

    def __exit__(self, *exc):
        if self.inherited:
            return False              # 借来的不还 —— 父进程还要用它
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


def generate(dot_host, server_addresses, ssids=None, template=None,
             meta_path=None, art_root=None, lock=True, legacy_seen=False):
    """生成(或确认无需生成)受管描述文件。返回 (meta, level, reasons, data, changed)。

    输入没变时**不产生新 revision**: 产物逐字节相同, previous 不被顶掉。这正是"点一下重新
    生成"应有的样子 —— 重新拿一份文件, 而不是制造一次版本变更。
    """
    with _LifecycleLock(lock, "本次生成"):
        return _generate_locked(dot_host, server_addresses, ssids,
                                template, meta_path, art_root, legacy_seen)


def _generate_locked(dot_host, server_addresses, ssids,
                     template, meta_path, art_root, legacy_seen):
    """**必须在持锁状态下调用。** 读记录 → 算候选 → 落盘 → 写后复核, 整段在同一把锁里。"""
    mp = meta_path or META
    ar = art_root or ART_DIR
    meta = load(mp)
    # ssids=None ⇒ 沿用记录里的名单。必须在 load 之后算 —— 它要读记录。
    inputs = effective_inputs(meta, dot_host, server_addresses, ssids, template)
    fresh = meta is None
    if fresh:
        meta = _blank()
        meta["instance_id"] = new_instance_id()
        meta["created_at"] = _stamp()
        # 这台机器以前用随机身份发过描述文件 ⇒ 手机上那份我们**管不着**, 只能请用户手工删。
        meta["migration_pending"] = bool(legacy_seen)
    ids = derive_ids(meta["instance_id"])
    data = iosprofile.render(inputs["dot_host"], inputs["server_addresses"], inputs["ssids"],
                             ids, template)
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
        meta = _repair_current_locked(template, mp, ar)
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
        # 版本号接着**曾经发出去过的最高版**往下数。退役迁移丢弃过槽位时 current 是空的,
        # 光看 current 会退回第 1 版 —— 于是用户手机上装着"第 3 版", 而网关说这是"第 1 版"。
        base = (cur or {}).get("revision")
        if base is None:
            base = meta.get("retired_revision") or 0
        new["current"] = {
            "revision": base + 1,
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


def repair_current(template=None, meta_path=None, art_root=None, lock=True):
    """按记录**逐字节复原** current。复原不了就拒绝 —— 不猜、不新建身份、不推进 revision。

    允许复原的全部条件(缺一不可):
      · 元数据完整可读;
      · 记录里有 current, 且带 inputs 与 sha256;
      · 用记录里的 inputs + 稳定身份重新渲染, 结果的 sha256 与记录**精确相等**。

    (WLOC 退役前这里还有一条: 手上那张根 CA 的指纹要与记录里那一版一致。描述文件不再携带
    根证书, 那条判据没有对象了 —— 而且**退役前的那些版本根本不可复原**: 它们的记录已经在
    schema 迁移时被丢弃了, 走不到这里。)
    然后才写盘, 且: revision 不变、previous 一个字节不动、写完复核。
    """
    with _LifecycleLock(lock, "本次复原"):
        return _repair_current_locked(template, meta_path, art_root)


def _repair_current_locked(template=None, meta_path=None, art_root=None):
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
    ids = derive_ids(meta["instance_id"])
    data = iosprofile.render(inp["dot_host"], inp["server_addresses"], inp.get("ssids") or (),
                             ids, template)
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



# ── schema 1 → 2 迁移 ───────────────────────────────────────────────────────
# 退役的最后一段, 也是最容易做错的一段。做错的样子很具体: 把 `!= SCHEMA` 放宽成
# `in (1, 2)` 就宣称"兼容完成" —— 记录于是同时被两套契约放行, 而**产物一个字节没动**:
# 那份嵌着根证书的 .mobileconfig 还躺在 /var/lib 下, 还能被「重新发送」发出去。
#
# 真正要回答的是: 这条记录描述的那份产物, 在 schema 2 里还成不成立?
#
#   · inputs.wloc_enabled 为 False ⇒ 那份产物里**本来就没有**根证书那一格。它逐字节就是一份
#     合法的 schema 2 产物(渲染只取 dot_host / 地址 / SSID / 身份 / 模板, 与 schema 无关)。
#     所以记录原地迁移: 去掉两个 WLOC 字段、inputs.schema 置 2、**按新字段集重算摘要**。
#     revision / sha256 / 时间戳一概不动 —— 产物没变, 说它变了就是假话。
#   · inputs.wloc_enabled 为 True  ⇒ 那份产物里嵌着根证书。schema 2 没有任何办法描述它,
#     而它更不该再被发出去。这个槽位**退役**: 记录丢弃、盘上的文件删掉, 版本号记进
#     retired_revision, 由用户重新生成一份不含根证书的。
#
# 摘要必须重算而不是照抄: 字段集变了摘要却没变, 等于说"配置没变过" —— 而一份 schema 1 的
# 记录与一份 schema 2 的记录本来就不该有相同的摘要。
def _migrate_record_1_to_2(rec):
    inp = dict(rec["inputs"])
    inp.pop("wloc_enabled", None)
    inp.pop("wloc_ca_sha256", None)
    inp["schema"] = 2
    return dict(rec, inputs=inp, digest=digest_of(inp))


def _migrate_1_to_2(meta):
    """(新记录, 被退役的版本号列表)。**不碰盘**, 纯函数 —— 落盘由调用方决定。

    三段式, 每一段都不能省:
      ① 按**严格的 schema 1 契约**验旧记录。恶意或损坏的旧记录要在这里就被拒掉 ——
         迁移是一次改写, 拿一份没验过的东西去改写, 等于把伪造的输入洗成"当前格式";
      ② 明确迁移(上面那段说明);
      ③ 按**严格的 schema 2 契约**复核结果。少了这一步, 迁移里任何一个手滑都会直接落盘。
    """
    _check_meta_object(meta, schema=1)                       # ① 严格 schema 1
    out = {"schema": 2,
           "instance_id": meta["instance_id"],               # 身份**必须**原样带过来
           "created_at": meta["created_at"],
           "migration_pending": meta["migration_pending"],
           "current": None, "previous": None,
           "retired_revision": None, "retired_inputs": None}
    retired, keep = [], {}
    for which in ("current", "previous"):                    # ②
        rec = meta.get(which)
        if rec is None:
            continue
        if rec["inputs"]["wloc_enabled"]:
            retired.append(rec["revision"])
        else:
            keep[which] = _migrate_record_1_to_2(rec)
    # current 被退役而 previous 还在: "有上一版却没有当前版本"这一组不成立(见 _check_meta_object)。
    # 把 previous 提成 current 是造假 —— 它不是当前发出去的那一版。所以一起退役, 版本号一起记下。
    if "current" not in keep and "previous" in keep:
        retired.append(keep.pop("previous")["revision"])
    out["current"] = keep.get("current")
    out["previous"] = keep.get("previous")
    out["retired_revision"] = max(retired) if retired else None
    # current 那一栏被退役 ⇒ 用户的非 WLOC 意图(SSID、DoT 主机名、网关地址…)会跟着一起没。
    # 取**它**的输入而不是 previous 的: current 才是最新的那次意图, 退回上一版等于把用户
    # 后来改过的设置又改回去。current 保住了就不必留 —— 意图还在它自己那份 inputs 里。
    if meta.get("current") is not None and "current" not in keep:
        out["retired_inputs"] = _migrate_record_1_to_2(meta["current"])["inputs"]
    _check_meta_object(out, schema=SCHEMA)                   # ③ 严格 schema 2
    return out, sorted(set(retired))


def migrate_schema(meta_path=None, art_root=None, lock=True):
    """把盘上那份记录迁到当前 schema。幂等; 返回一份可打印的报告。

    这是**明确的**迁移入口(`pdg __migrate` 调它), 与 load() 里那次只读迁移分开:
    load 是读, 读不该写盘; 而"什么时候真正改写用户的记录"应该是一个看得见的动作。
    """
    with _LifecycleLock(lock, "本次格式迁移"):
        return _migrate_schema_locked(meta_path, art_root)


def _migrate_schema_locked(meta_path=None, art_root=None):
    """**必须在持锁状态下调用。**"""
    mp = meta_path or META
    ar = art_root or ART_DIR
    try:
        with open(mp, encoding="utf-8") as f:
            raw = f.read()
    except FileNotFoundError:
        # 从没生成过描述文件。**不造记录** —— 造一份就等于凭空造出一个身份。
        return {"changed": False, "reason": "没有受管描述文件记录, 无需迁移"}
    except OSError as e:
        raise StateError("读不到 iOS 描述文件记录 %s(%s), 本次迁移未做任何改动。"
                         % (mp, e.strerror))
    try:
        meta = json.loads(raw)
    except ValueError:
        raise StateError("iOS 描述文件记录 %s 已损坏, 拒绝迁移 —— 不自动重建: 重建会生成一个"
                         "新身份, 而你手机上那份描述文件将永远无法再被更新。" % mp)
    missing = []
    try:
        sc = _schema_of(meta, "iOS 描述文件记录 %s" % mp)
        if sc == SCHEMA:
            _check_meta_object(meta, schema=SCHEMA)     # 幂等这一格也要复核, 不是直接返回
            return {"changed": False, "reason": "记录已是 schema %d" % SCHEMA}
        # 先把**旧记录整份**验过(严格 schema 1)。
        _check_meta_object(meta, schema=sc)
        # 再验**产物**, 而且必须在动任何东西之前。
        #
        # 只验记录是不够的: 迁移接下来要删掉带根证书的那几份产物、并改写记录。一份被改过的
        # 产物在这两步之后就**再也查不出来**了 —— 文件没了, 记录说的是新格式, 现场干干净净。
        # 那正是"把损坏洗成当前格式"的样子, 比留着损坏更糟: 留着至少 doctor 还会报。
        #
        # 缺失与损坏要分开(既有契约就是这么分的, 见 artifact_health):
        #   · 文件**不在** = MISSING。那台机器只是丢了文件, 身份与记录都还在, 迁移照走,
        #     报告里如实说哪一栏不在 —— 迁移前后它都是 MISSING, 不是迁移弄坏的;
        #   · 文件**在但对不上** = 被改过。整笔拒, 一个字节都不动。
        ids = derive_ids(meta["instance_id"])
        for which in ("current", "previous"):
            if meta.get(which) is None:
                continue
            data = read_artifact(which, ar)
            if data is None:
                missing.append(which)
                continue
            _check_artifact(meta, which, data, ids, schema=sc)
        new, retired = _migrate_1_to_2(meta)
    except RestoreRefused as e:
        raise StateError("iOS 描述文件记录 %s 没通过「%s」这道门: %s\n"
                         "本次迁移未做任何改动。请先修复或删除该文件(删除等于放弃现有身份, "
                         "之后必须手工删掉手机上的旧描述文件)。" % (mp, e.gate, e.why))
    with _Txn(lock=False) as tx:
        # 被退役的槽位, 盘上的文件也要删掉。留着它是留了一条路: 那是一份嵌着根证书、
        # 而且已经没有任何记录能解释它的 .mobileconfig。
        for which in ("current", "previous"):
            if meta.get(which) is not None and new.get(which) is None:
                tx.remove(art_path(which, ar))
        tx.write(mp, json.dumps(new, ensure_ascii=False, indent=2,
                                sort_keys=True).encode("utf-8") + b"\n", 0o600)
        # 写后复核放在**事务里面**: 从盘上重新读一遍再验一次。上面验的是内存里那个对象,
        # 而落盘可能坏在序列化、权限、磁盘满上 —— 那几种坏法都不会抛异常。
        #
        # 放在 with 外面(第一版就是)的后果很具体: 复核失败时记录已经改写、产物已经删掉,
        # 而异常没有经过 _Txn.__exit__, 于是既没回滚也没人知道现场是半截的。放进来之后
        # 任何一条不成立都会走 _restore(), 内容 + mode + uid/gid 逐项还原并复核。
        back = load(mp)
        _check_meta_object(back, schema=SCHEMA)
        if back != new:
            raise StateError("迁移写盘后读回来的记录与预期不一致, 请检查 %s。" % mp)
        for which in ("current", "previous"):
            # 缺失的那一栏迁移前就缺, 不能拿它当"迁移把产物弄丢了"。
            if back.get(which) is not None and which not in missing:
                verified_artifact(back, which, ar)   # 保留下来的产物仍要对得上它的记录
    return {"changed": True, "from": sc, "to": SCHEMA,
            "retired_revisions": retired,
            "retired_revision": new["retired_revision"],
            "missing_artifacts": missing,
            "reason": (("已迁移到 schema %d" % SCHEMA) if not retired else
                       ("已迁移到 schema %d; 第 %s 版描述文件里嵌着已退役的根证书, 已退役"
                        % (SCHEMA, "、".join(str(x) for x in retired))))
                      + ("" if not missing else
                         "; 注意: %s 的产物文件本来就不在服务器上(迁移前后都缺)"
                         % "、".join("当前版本" if w == "current" else "上一版"
                                     for w in missing))}


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
    """生命周期这一组不成立。消息里点名是哪一道门。

    带着 gate / why 两个属性: 同一份判据在"外部恢复"和"本地状态"两条路上要说不同的话
    (一句"备份里的…"对着本机文件是错的), 但**判据不许有两份**。调用方按需要重新组织
    措辞, 行为完全一致。
    """

    def __init__(self, gate, why):
        self.gate = gate
        self.why = why
        StateError.__init__(self, "备份里的 iOS 描述文件没通过「%s」这道门: %s" % (gate, why))


_HEX64 = re.compile(r"^[0-9a-f]{64}$")
_DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
# 本项目写下的 instance_id 是 uuid4 的规范小写字符串; 时间一律是 _stamp() 那个 UTC 格式。
# 两者都只认"本项目会写出来的那一种形态" —— uuid5 什么字符串都收得下, 时间字段"是不是
# 字符串"也拦不住 2026-02-30T99:99:99Z。
_UUID_CANON = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_STAMP_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def valid_instance_id(v):
    """是不是本项目生成的那种身份: 规范小写的 UUID **version 4**。"""
    if not isinstance(v, str) or not _UUID_CANON.match(v):
        return False
    try:
        u = uuid.UUID(v)
    except ValueError:
        return False
    return u.version == 4 and str(u) == v


def valid_stamp(v):
    """是不是 _stamp() 那种真实存在的 UTC 时刻。正则只管长相, 还要真能解析成一个日期
    —— 2026-02-30T99:99:99Z 长相完全合格。"""
    if not isinstance(v, str) or not _STAMP_RE.match(v):
        return False
    try:
        time.strptime(v, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError:
        return False
    return True

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
# 一条 current / previous 记录**恰好**有这几个字段。少一个的代价很具体: generated_at 没了
# 照样能"恢复成功", 然后状态页一读就 KeyError —— 用户看到一个打不开的页面, 而那份记录正是
# 恢复操作自己写进去的。多一个则说明这份记录不是本版本写的, 而我们没有能力判断它是什么意思。
# 不补默认值、不静默修复、不推进 revision: 这三样都是在替用户猜。
_RECORD_KEYS = frozenset(("revision", "digest", "inputs", "sha256",
                          "generated_at", "sent_at"))

# ── schema 1 的按需规则契约 ────────────────────────────────────────────────
# 只限制键名是不够的: ondemand_core 取自备份自己, 于是"同时改产物和记录再把摘要配平"就能
# 过。多一条 {"Action": "Connect"} 的后果很具体 —— 探测还没跑, DoT 就被无条件启用。
#
# 所以 schema 1 对应**一套固定语义**, 这里是它的唯一出处(与 deploy/ios/*.tmpl 的骨架一致;
# tests/test-ios-profile-backup-trust.py 有一条漂移守卫: 现渲染的四种标准组合必须全部通过,
# 于是模板改了而这里没跟上会先红)。将来渲染语义有意变化 ⇒ 升 SCHEMA 或按 schema 分派另一个
# 校验器, **不**靠放宽未知规则来兼容未来版本。
_PROBE = "<probe>"
# **一份**骨架, 两个 schema 共用。schema 1 与 schema 2 的按需连接语义完全相同 —— 退役动的是
# 根证书那一格与 inputs 的字段集, 没有动 OnDemand 的任何一条规则。所以这里不按 schema 分派、
# 也不复制第二份: 两份判据迟早漂移成一松一紧, 而松的那份就是出口。
# 将来 OnDemand 语义真要变 ⇒ 再升一次 SCHEMA 并在那时才分派, **不**靠放宽未知规则来兼容。
_ONDEMAND_CORE = [
    {"InterfaceTypeMatch": "WiFi", "Action": "Connect", "URLStringProbe": _PROBE},
    {"InterfaceTypeMatch": "WiFi", "Action": "Disconnect"},
    {"InterfaceTypeMatch": "Cellular", "Action": "Connect", "URLStringProbe": _PROBE},
    {"Action": "Disconnect"},
]


def _ssid_rule(ssids):
    """SSID 强制直连那一条。只允许出现在最前面, 且只在名单非空时出现 ——
    OnDemand 是"第一条命中的说了算", 排在探测规则之后就永远轮不到。"""
    return {"InterfaceTypeMatch": "WiFi", "SSIDMatch": list(ssids), "Action": "Disconnect"}
# 记录里 inputs 的字段与类型。多一个少一个都拒: 少了会让后面的比对静默跳过, 多了说明这份
# 记录不是本版本写出来的, 而我们没有能力判断多出来的那个字段意味着什么。
#
# **按 schema 分成两套完整契约, 不是一个"新旧字段都认"的松并集。** 并集的后果很具体: 一份
# schema 2 的记录带着 wloc_ca_sha256 也能过关 —— 而那种记录正是"迁移只改了版本号、产物里
# 那张根证书还在"的样子, 也正是恶意备份最想伪造的形态。每个 schema 的字段集都是**闭**的。
_INPUT_TYPES_COMMON = (("schema", int), ("dot_host", str), ("server_addresses", list),
                       ("dns_protocol", str), ("probe_url", str), ("ondemand_core", list),
                       ("ssids", list))
_INPUT_TYPES_BY_SCHEMA = {
    1: _INPUT_TYPES_COMMON + (("wloc_enabled", bool), ("wloc_ca_sha256", str)),
    2: _INPUT_TYPES_COMMON,
}


def _schema_of(meta, where="记录"):
    """记录自称的 schema, 且必须是我们读得懂的。"""
    sc = (meta or {}).get("schema") if isinstance(meta, dict) else None
    if sc != SCHEMA and sc not in SCHEMA_HISTORY:
        _refuse("记录格式", "%s的格式版本不认识(schema=%r) —— 本版本只读得懂 %s"
                % (where, sc, "、".join(str(x) for x in sorted((SCHEMA,) + SCHEMA_HISTORY))))
    return sc

def _refuse(gate, why):
    raise RestoreRefused(gate, why)


def _keys_exact(what, got, want):
    """字段集合必须**正好**是 want。多的、少的都点名报出来。"""
    extra = sorted(set(got) - set(want))
    if extra:
        _refuse("字段白名单", "%s 多了本项目不会写的字段: %s" % (what, "、".join(extra)))
    miss = sorted(set(want) - set(got))
    if miss:
        _refuse("字段白名单", "%s 少了本项目一定会写的字段: %s" % (what, "、".join(miss)))


def _canon(fn, value, field, name):
    """value 必须**等于**规范化函数作用在它自己身上的结果。

    这是"输入是不是本项目生成器可能产出的形式"的判据。只查外层类型是不够的:
    ["B", 7, "A", "A", ""] 是个 list, 里面却有整数、空项、重复和乱序 —— 规范化之后是
    ["7","A","B"], 跟原值差着十万八千里, 而生成器永远写不出前者。
    """
    try:
        got = fn(value)
    except Exception:  # noqa: BLE001
        _refuse("输入规范", "%s 的 inputs.%s 不是本项目能接受的值" % (name, field))
    if got != value:
        _refuse("输入规范", "%s 的 inputs.%s 不是规范形式 —— 本项目的生成器写不出这个值"
                "(空白/空项/重复/未排序/被隐式转成字符串的非字符串, 都会落到这里)"
                % (name, field))


def _check_inputs_canonical(inp, name):
    """记录里的输入必须是**本项目生成器可能产出的**规范形式。

    集中在这一处: 恢复的联合校验、artifact_health、写后复核走的都是它, 不各写一套。
    """
    _canon(iosprofile.norm_host, inp["dot_host"], "dot_host", name)
    _canon(iosprofile.norm_addrs, inp["server_addresses"], "server_addresses", name)
    _canon(iosprofile.norm_ssids, inp["ssids"], "ssids", name)
    if inp["dns_protocol"] != "TLS":
        _refuse("输入规范", "%s 的 inputs.dns_protocol 只能是 TLS(实际 %r)"
                % (name, inp["dns_protocol"]))
    # 探测地址没有独立配置入口, 必须由第一个规范化服务器地址推导。不这么验的话, 把
    # inputs.probe_url 和产物里两条 URLStringProbe 一起改成攻击者的地址就自洽了 ——
    # 而那意味着手机每次判断要不要启用 DoT 都先去打对方的服务器。
    try:
        want = probe_url_for(inp["server_addresses"])
    except Exception:  # noqa: BLE001
        _refuse("输入规范", "%s 的 inputs.server_addresses 推导不出探测地址" % name)
    if inp["probe_url"] != want:
        _refuse("输入规范", "%s 的 inputs.probe_url 不是由第一个服务器地址推导出来的 —— "
                "本项目没有单独配置探测地址的入口(schema 1 与 2 都没有)" % name)


def _check_record(rec, name, schema):
    """一条记录对上**它所属 schema 的那一套**契约。schema 由调用方给, 不由记录自己说了算。"""
    gate = "记录格式"
    if not isinstance(rec, dict):
        _refuse(gate, "%s 那一栏不是一条记录" % name)
    _keys_exact("%s 记录" % name, rec, _RECORD_KEYS)
    rev = rec.get("revision")
    if not isinstance(rev, int) or isinstance(rev, bool) or rev < 1:
        _refuse(gate, "%s 的 revision 不是正整数(%r)" % (name, rev))
    if not isinstance(rec.get("digest"), str) or not _DIGEST_RE.match(rec["digest"]):
        _refuse(gate, "%s 的 digest 不是 sha256:<64 位小写十六进制>(实际 %r)"
                % (name, rec.get("digest")))
    if not isinstance(rec.get("sha256"), str) or not _HEX64.match(rec.get("sha256") or ""):
        _refuse(gate, "%s 的 sha256 不是 64 位十六进制" % name)
    # generated_at 必须有值: 状态页直接读它, 没有就崩。sent_at 允许是 null("还没发过")。
    # 两者都必须是 _stamp() 那种**真实存在**的 UTC 时刻 —— 只判"是不是字符串"连
    # 2026-02-30T99:99:99Z 都拦不住。
    if not valid_stamp(rec.get("generated_at")):
        _refuse("时间格式", "%s 的 generated_at 不是 YYYY-MM-DDTHH:MM:SSZ 形式的真实 UTC "
                "时刻(实际 %r)" % (name, rec.get("generated_at")))
    if rec.get("sent_at") is not None and not valid_stamp(rec.get("sent_at")):
        _refuse("时间格式", "%s 的 sent_at 只能是 null 或 YYYY-MM-DDTHH:MM:SSZ 形式的真实 "
                "UTC 时刻(实际 %r)" % (name, rec.get("sent_at")))
    inp = rec.get("inputs")
    if not isinstance(inp, dict):
        _refuse(gate, "%s 缺 inputs" % name)
    types = _INPUT_TYPES_BY_SCHEMA[schema]
    want = {k for k, _ in types}
    if set(inp) != want:
        _refuse(gate, "%s 的 inputs 字段与 schema %d 对不上(多/少: %s)"
                % (name, schema, "、".join(sorted(set(inp) ^ want)) or "?"))
    for k, ty in types:
        v = inp[k]
        if ty is bool:
            if not isinstance(v, bool):
                _refuse(gate, "%s 的 inputs.%s 不是布尔" % (name, k))
        elif isinstance(v, bool) or not isinstance(v, ty):
            _refuse(gate, "%s 的 inputs.%s 类型不对(%r)" % (name, k, type(v).__name__))
    # inputs.schema 必须与顶层的 schema **一致**。分开放行的话, 一份顶层写 1、inputs 写 2
    # 的混合记录就能一边享受 schema 1 的读入资格、一边用 schema 2 的松字段集绕过 WLOC 那两
    # 个字段的交叉校验。
    if inp["schema"] != schema:
        _refuse(gate, "%s 的 inputs.schema=%r 与记录顶层的 schema=%d 不一致"
                % (name, inp["schema"], schema))
    if schema == 1:
        # schema 1 专属的交叉校验。schema 2 没有这两个字段, 上面的字段白名单已经把带着它们
        # 的记录挡在外面了 —— 所以这里不需要、也不应该有一个"两版都跑"的分支。
        if inp["wloc_enabled"] != bool(inp["wloc_ca_sha256"]):
            _refuse(gate, "%s 的 inputs 自相矛盾: wloc_enabled=%r 而根证书指纹%s"
                    % (name, inp["wloc_enabled"], "有" if inp["wloc_ca_sha256"] else "没有"))
        if inp["wloc_ca_sha256"] and not _HEX64.match(inp["wloc_ca_sha256"]):
            _refuse(gate, "%s 的 inputs.wloc_ca_sha256 不是 64 位十六进制" % name)
    _check_inputs_canonical(inp, name)
    # 记录里的骨架本身也必须是那一套固定骨架 —— 不能只跟产物互相配平。
    # 两个 schema 共用同一份(按需连接语义没变), 见 _ONDEMAND_CORE 上面那段。
    if inp["ondemand_core"] != _ONDEMAND_CORE:
        _refuse("按需规则", "%s 记录里的 ondemand_core 不是本项目的固定骨架 —— "
                "它是判断「这份产物是不是我们生成的」的基准, 不能由备份自己说了算" % name)
    # digest 是"配置有没有变"的唯一依据, 三档判定全靠它。只看格式是不够的 —— 伪造一串
    # 合法形态的 digest 就能让"必须更新"变成"无需更新"。按 inputs 重新算一遍核对。
    if rec["digest"] != digest_of(inp):
        _refuse("digest 自洽", "%s 的 digest 与它自己的 inputs 对不上 —— 记录被改过, "
                "拿它做更新判定会得出相反的结论" % name)


def _check_meta_object(meta, schema=None):
    """一份**完整**的生命周期记录该长什么样 —— 唯一实现。

    共用它的入口: load()(本地状态)、_check_meta()(外部恢复的 UTF-8/JSON 解析之后)、
    strict_artifact_check()(健康检查与发送)。分成几份各查一部分的下场很具体: 顶层多一个
    未知字段、缺 migration_pending、previous.revision 不小于 current 这些样本, 恢复那边
    拒得干干净净, 本地却 load 成功、artifact_health 判 healthy、verified_artifact 照样把
    字节交出去 —— 一份从恢复入口进不来的记录, 只要已经躺在盘上就全程畅通。

    **整份**记录都要过关, 不只是被选中的那个槽位: current 好好的而 previous 是一串字符串,
    这份记录依然是坏的, 而下一次 previous 相关的操作(对比、取回、生成时顶下去)会踩到它。
    """
    gate = "记录格式"
    if not isinstance(meta, dict):
        _refuse(gate, "记录不是一个 JSON 对象 —— 格式版本无法识别")
    got = _schema_of(meta)
    # schema 显式给出时必须**正好**是它: 调用方说"这应该是一份 schema 2 的记录", 而记录
    # 自称 1, 那就是不成立, 不能顺着记录改口。迁移的前后两次复核全靠这一条才有意义。
    if schema is not None and got != schema:
        _refuse(gate, "期望一份 schema %d 的记录, 实际是 schema %r" % (schema, got))
    schema = got
    # instance_id 必须是本项目写下的那种身份: 规范小写的 UUID **version 4**。
    # 光靠"uuid5 收不收得下这个字符串"证明不了任何事 —— 它什么字符串都收。
    if meta.get("instance_id") in (None, ""):
        _refuse("身份", "没有身份标识")
    if not valid_instance_id(meta.get("instance_id")):
        _refuse("身份", "instance_id 不是规范小写的 UUID4(本项目写下的身份都是那种形态)")
    if set(meta) != set(_blank(schema)):
        _refuse(gate, "顶层字段与 schema %d 对不上(多/少: %s)"
                % (schema, "、".join(sorted(set(meta) ^ set(_blank(schema))))))
    if schema >= 2 and meta["retired_revision"] is not None:
        rr = meta["retired_revision"]
        if not isinstance(rr, int) or isinstance(rr, bool) or rr < 1:
            _refuse(gate, "retired_revision 只能是 null 或正整数(实际 %r)" % (rr,))
    if schema >= 2 and meta["retired_inputs"] is not None:
        # 它要被 effective_ssids 当成"用户最后一次的意图"来用, 所以必须过**和记录里的
        # inputs 同一套**契约 —— 松一格, 一份被改过的备份就能借这一栏把 SSID / 探测地址
        # 塞进下一次生成。
        ri = meta["retired_inputs"]
        if not isinstance(ri, dict):
            _refuse(gate, "retired_inputs 只能是 null 或一份输入对象")
        types = _INPUT_TYPES_BY_SCHEMA[schema]
        want = {k for k, _ in types}
        if set(ri) != want:
            _refuse(gate, "retired_inputs 的字段与 schema %d 对不上(多/少: %s)"
                    % (schema, "、".join(sorted(set(ri) ^ want)) or "?"))
        for k, ty in types:
            v = ri[k]
            if ty is bool:
                if not isinstance(v, bool):
                    _refuse(gate, "retired_inputs.%s 不是布尔" % k)
            elif isinstance(v, bool) or not isinstance(v, ty):
                _refuse(gate, "retired_inputs.%s 类型不对(%r)" % (k, type(v).__name__))
        if ri["schema"] != schema:
            _refuse(gate, "retired_inputs.schema=%r 与记录顶层的 schema=%d 不一致"
                    % (ri["schema"], schema))
        _check_inputs_canonical(ri, "retired_inputs")
        if ri["ondemand_core"] != _ONDEMAND_CORE:
            _refuse("按需规则", "retired_inputs 里的 ondemand_core 不是本项目的固定骨架")
    if not isinstance(meta.get("migration_pending"), bool):
        _refuse(gate, "migration_pending 必须是布尔(实际 %r)"
                % type(meta.get("migration_pending")).__name__)
    if not valid_stamp(meta.get("created_at")):
        _refuse("时间格式", "created_at 不是 YYYY-MM-DDTHH:MM:SSZ 形式的真实 UTC 时刻"
                "(实际 %r)" % (meta.get("created_at"),))
    for which in ("current", "previous"):
        if meta.get(which) is not None:
            _check_record(meta[which], which, schema)
    if meta.get("previous") is not None and meta.get("current") is None:
        _refuse("三件配套", "记录里有上一版(previous)却没有当前版本(current) —— 这一组不成立")
    if meta.get("previous") and meta.get("current") \
            and meta["previous"]["revision"] >= meta["current"]["revision"]:
        _refuse("三件配套", "上一版的 revision(%d)必须严格小于当前版本(%d)"
                % (meta["previous"]["revision"], meta["current"]["revision"]))
    return meta


def _check_meta(raw):
    """外部恢复入口: 先把字节解成对象, 再走那份完整契约。"""
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
    return _check_meta_object(meta)


def _check_ondemand(rules, inp, name):
    """产物里的 OnDemandRules 必须**恰好**是那一套固定骨架(schema 1 与 2 相同)。

    判据不是"跟这份备份自己记的骨架对得上" —— 那两边都是攻击者可以改的。judge 的基准是
    _ONDEMAND_CORE 这个常量(两个 schema 共用同一份, 因为语义完全相同):

      · SSID 名单非空 ⇒ 最前面**恰好**多那一条规范化的 Wi-Fi Disconnect 规则, 别处不许再有;
      · SSID 名单为空 ⇒ 任何位置都不许出现 SSIDMatch;
      · 其余规则逐条、按顺序与 schema 1 的骨架完全一致(Action、InterfaceTypeMatch、
        URLStringProbe 出现在哪一条, 都算在内);
      · 产物里真实的探测地址必须等于记录里的 probe_url。
    """
    gate = "按需规则"
    for i, r in enumerate(rules):
        if not isinstance(r, dict):
            _refuse(gate, "%s的按需规则第 %d 条不是一个字典" % (name, i + 1))
    rules = [dict(r) for r in rules]
    ssids = inp["ssids"]
    if ssids:
        want = _ssid_rule(ssids)
        if not rules or rules[0] != want:
            _refuse(gate, "%s里 SSID 强制直连那一条不在最前面, 或者内容与记录的名单不符 —— "
                    "OnDemand 是第一条命中的说了算, 排在探测规则之后就永远轮不到" % name)
        rules = rules[1:]
    stray = [i + 1 for i, r in enumerate(rules) if "SSIDMatch" in r]
    if stray:
        _refuse(gate, "%s里出现了记录中没有的 SSID 规则(第 %s 条) —— 记录里的名单是空的"
                % (name, "、".join(str(x) for x in stray)))
    if len(rules) != len(_ONDEMAND_CORE):
        _refuse(gate, "%s的按需规则有 %d 条, 固定骨架是 %d 条 —— 多出来或少掉的那些"
                "会改变什么时候启用 DoT" % (name, len(rules), len(_ONDEMAND_CORE)))
    for i, (got, want) in enumerate(zip(rules, _ONDEMAND_CORE)):
        probe = got.pop("URLStringProbe", None) if "URLStringProbe" in got else None
        if probe is not None:
            if probe != inp["probe_url"]:
                _refuse(gate, "%s的第 %d 条按需规则里的探测地址与记录不符" % (name, i + 1))
            got["URLStringProbe"] = _PROBE
        if got != want:
            _refuse(gate, "%s的第 %d 条按需规则与固定骨架不符(顺序、Action、"
                    "InterfaceTypeMatch、探测地址有无, 任何一项对不上都算)" % (name, i + 1))


def _check_artifact(meta, which, data, ids, schema=None):
    """一份产物对上它自己那条记录。每道门单独命名 —— 出事时要知道是哪一条不成立。

    根证书那一格按 schema 判, 而且两边都是**硬**判据:
      · schema 1: 有没有那一格必须与 inputs.wloc_enabled 完全一致(退役前的原判据, 未放松);
      · schema 2: **一格都不许有**。schema 2 的产物是"退役之后生成的", 里面出现根证书只有
        两种可能 —— 记录被改过, 或者迁移只改了版本号而没动产物。两种都要拒。
    """
    name = "当前版本" if which == "current" else "上一版"
    schema = _schema_of(meta) if schema is None else schema
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
    # payload 白名单也按 schema 收紧: schema 2 只剩 DNS 这一种。iosprofile 那份常量是**历史
    # 全集**(校验老产物时还要认得根证书那一格), 不能直接拿来当新格式的白名单。
    allowed = (iosprofile.ALLOWED_PAYLOAD_TYPES if schema == 1
               else ("com.apple.dnsSettings.managed",))
    extra = sorted({str(x.get("PayloadType")) for x in items} - set(allowed))
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
    if schema >= 2:
        if cas:
            _refuse("根证书", "%s里含根证书 payload, 而 schema %d 的产物一格都不许有 —— "
                    "WLOC 位置改写已退役, 描述文件不再携带任何根证书。这份东西要么是被改过, "
                    "要么是一份只改了版本号、没有真正迁移的旧产物。" % (name, schema))
    elif bool(cas) != bool(inp["wloc_enabled"]):
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
    if s.get("ServerName") != inp["dot_host"]:
        _refuse("语义一致", "%s里的 ServerName(%r)与记录的 dot_host(%r)不符"
                % (name, s.get("ServerName"), inp["dot_host"]))
    if list(s.get("ServerAddresses") or []) != list(inp["server_addresses"]):
        _refuse("语义一致", "%s里的 ServerAddresses 与记录不符" % name)
    if s.get("DNSProtocol") != inp["dns_protocol"]:
        _refuse("语义一致", "%s里的 DNSProtocol 与记录不符" % name)
    _check_ondemand(dns.get("OnDemandRules") or [], inp, name)


def strict_artifact_check(meta, which, data):
    """「记录 + 产物」的严格契约 —— **唯一**一处实现, 按记录自称的 schema 分派。

    共用它的路径: 备份恢复的联合校验、artifact_health()、verified_artifact()(经
    artifact_health)、生成的写后复核、repair_current() 完成后的复核。分开写的下场很具体:
    恢复那边拒掉的东西, 只要已经躺在盘上就照样判 healthy, 然后被发到用户手机上。

    失败一律抛 StateError 的子类(RestoreRefused), 调用方按自己的口径翻译, 不在这里
    决定是 corrupt 还是 state_mismatch。消息只报字段名与门名, 不带证书正文、私钥、
    完整 mobileconfig 或 base64。
    """
    meta = meta or {}
    # **整份**记录都要过契约, 不只是被选中的那个槽位 —— 见 _check_meta_object。
    _check_meta_object(meta)
    if meta.get(which) is None:
        _refuse("记录格式", "记录里没有 %s" % which)
    _check_artifact(meta, which, data, derive_ids(meta["instance_id"]))


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
        # 旧格式备份这一支同样要过迁移 —— 它带回来的是**记录**, 而一条 schema 1 的记录
        # 落到盘上, 下一次读就又是一次迁移; 更要紧的是 retired_revision 那条提示会丢。
        return _restore_migrate(meta, raw_out, None, None, (note or None))
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
    return _restore_migrate(meta, raw, cur, prev, None)


def _restore_migrate(meta, raw, cur, prev, note):
    """恢复的最后一段: 旧格式的备份要**迁移之后**才落盘。

    到这里为止, 一份 schema 1 的备份已经按 schema 1 的严格契约整份过关了(记录、三件配套、
    两份产物逐一验过)。现在才谈得上迁移 —— 顺序反过来就是"拿一份没验过的东西洗成当前格式"。

    这是退役里最容易漏的一条复活路径: 服务停了、劫持撤了、模块删了, 而用户从一份**退役前的
    备份**恢复一次, 那份嵌着根证书的 .mobileconfig 就又躺回 /var/lib, 又能从「重新发送」
    发出去。所以被退役的槽位在这里变成 None —— 上层会把它翻译成 DELETE(见 plan_restore)。
    """
    if meta["schema"] == SCHEMA:
        return raw, cur, prev, note
    new, retired = _migrate_1_to_2(meta)
    raw = json.dumps(new, ensure_ascii=False, indent=2, sort_keys=True).encode("utf-8") + b"\n"
    if new.get("current") is None:
        cur = None
    if new.get("previous") is None:
        prev = None
    if retired:
        extra = ("ℹ️ 这份备份是 WLOC 退役之前的(schema %d): 第 %s 版描述文件里嵌着已退役的"
                 "根证书, 恢复时**不会**把它放回来。请重新生成一份(新的不含根证书), 并到 "
                 "iPhone 的证书信任设置里取消对 PrivDNS Gateway MITM CA 的信任。"
                 % (meta["schema"], "、".join(str(x) for x in retired)))
        note = (note + " " + extra) if note else extra
    return raw, cur, prev, note


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

    "这份包含不含生命周期组"只有三种答案, 三个入口共用这一处判定:

      · state / current / previous **三件全无** ⇒ 归档确实不含这一组, 返回 (None, None),
        一个字节都不碰;
      · state 不在、但 current 或 previous 任一在 ⇒ 这一组**坏了**。不是"没带这一组" ——
        照"没带"处理的话, 现网的旧记录原地不动、归档里的孤立产物却被覆盖上去, 恢复完就是
        "记录说第 N 版、盘上是别人的第 M 版", 而且返回成功。整笔拒;
      · state 在 ⇒ 进严格联合校验与恢复计划。
    """
    if raw is None:
        have = [n for n, d in (("current.mobileconfig", cur),
                               ("previous.mobileconfig", prev)) if d is not None]
        if have:
            _refuse("三件配套", "归档里有 %s, 却没有 ios-profile.json 这份记录 —— 没有记录就"
                    "没有任何东西能解释这些产物是哪一版; 把它们覆盖上去只会造出"
                    "「现网旧记录 + 来路不明的产物」。整笔拒绝, 现网未被改动。"
                    % "、".join(have))
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
    if meta.get("retired_revision") is not None:
        # 这台机器在 WLOC 退役迁移里丢弃过版本。说出来, 因为"去手机上取消那张根证书的信任"
        # 这件事我们做不到, 只有用户能做 —— 而他没有别的地方能看到这条提示。
        out.append("⚠️ 第 %d 版及更早的描述文件里带着已退役的根证书(WLOC 已退役), 已不再保留。"
                   "请到 iPhone「设置 → 通用 → 关于本机 → 证书信任设置」取消对 "
                   "PrivDNS Gateway MITM CA 的信任。" % meta["retired_revision"])
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
        # --wloc-config / --ca-crt 已随 WLOC 退役。保留下来**显式拒绝**: pdg.sh 里的老
        # 调用还带着它们, 静默忽略会让那条路悄悄改变行为而没人发现。
        p.add_argument("--wloc-config", help="(已退役)")
        p.add_argument("--ca-crt", help="(已退役)")
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

    retired_flags = [f for f, v in (("--wloc-config", getattr(a, "wloc_config", None)),
                                    ("--ca-crt", getattr(a, "ca_crt", None))) if v]
    if retired_flags:
        sys.stderr.write(
            "%s 已随 WLOC 位置改写退役: 描述文件不再携带任何根证书。\n"
            "去掉这些参数重跑即可。手机上那张旧根证书需要你自己到"
            "「设置 → 通用 → 关于本机 → 证书信任设置」里取消信任。\n"
            % "、".join(retired_flags))
        return 3

    def _ssids():
        return [] if getattr(a, "clear_ssid", False) else a.ssid

    def _inputs():
        return effective_inputs(load(), a.dot_host, a.server_ip, _ssids(), a.template), b""

    try:
        if a.cmd == "generate":
            meta, lv, why, data, changed = generate(
                a.dot_host, a.server_ip, _ssids(), a.template, legacy_seen=a.legacy)
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
            meta = repair_current(a.template)
            print("已按记录逐字节复原第 %d 版(revision 未变, 上一版未动)。"
                  % meta["current"]["revision"])
    except (StateError, iosprofile.ProfileError) as e:
        sys.stderr.write("%s\n" % e)
        return 3
    return 0


if __name__ == "__main__":
    sys.exit(main())
