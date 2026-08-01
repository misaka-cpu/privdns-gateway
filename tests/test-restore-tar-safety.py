#!/usr/bin/env python3
"""恢复备份的解包必须是安全解包(P0)。

备份包是**外部输入** —— bot 从 Telegram 收文件, 谁都能发一个。旧实现只挡了成员名里的
绝对路径与 `..`, 然后直接 `tar.extract()`, 于是这些一概放行:
  · 符号链接(先放 `etc/x -> /etc`, 后续成员即可经它写到解压目录之外);
  · 硬链接(linkname 可指向解压根之外的文件);
  · 设备文件 / FIFO 等特殊成员;
  · 没有任何体积与数量上限(压缩炸弹)。
而解出来的 rs/ 目录随后会被 copytree 到 /etc/sing-box/rs —— 链接会一并搬进现网。

本测试直接打被测函数 _safe_extract: 造出各类恶意成员, 断言**解压根之外一个字节都没被写**,
且合法备份仍能正常解出。
"""
import io
import json
import os
import shutil
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "deploy", "bot"))

import importlib.util
spec = importlib.util.spec_from_file_location("bot", os.path.join(ROOT, "deploy/bot/pdg-bot.py"))
bot = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(bot)
except SystemExit:
    pass

pass_n = 0


def ok(msg):
    global pass_n
    pass_n += 1
    print(f"[OK]   {msg}")


def bad(msg):
    print(f"[FAIL] {msg}")
    sys.exit(1)


def mktar(build):
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        build(t)
    return buf.getvalue()


def addfile(t, name, data=b"x"):
    i = tarfile.TarInfo(name)
    i.size = len(data)
    t.addfile(i, io.BytesIO(data))


def extract(data, dest):
    """跑被测的安全解包; 返回 (是否抛错, 错误文本)。"""
    tar = tarfile.open(fileobj=io.BytesIO(data), mode="r:gz")
    try:
        bot._safe_extract(tar, dest)
        return False, ""
    except Exception as e:  # noqa: BLE001
        return True, str(e)


def run_case(label, build, must_raise=True):
    """解包到隔离目录; 断言**整个备份被拒**(而不是跳过坏成员), 解压根之外无写入, 根内不留
    链接/特殊文件。跳过坏成员会让用户以为"恢复成功了", 实际那份包本就不可信。"""
    base = tempfile.mkdtemp(prefix="pdgsafe")
    dest = os.path.join(base, "root")
    os.makedirs(dest)
    outside = os.path.join(base, "OUTSIDE")
    os.makedirs(outside)
    victim = os.path.join(outside, "victim.txt")
    with open(victim, "w") as f:
        f.write("ORIGINAL")
    try:
        raised, err = extract(mktar(build), dest)
        if must_raise and not raised:
            bad(f"{label}: 可疑成员只被跳过, 没有拒绝整个备份")
        if open(victim).read() != "ORIGINAL":
            bad(f"{label}: 解压根之外的文件被改写了!")
        stray = [n for n in os.listdir(outside) if n != "victim.txt"]
        if stray:
            bad(f"{label}: 解压根之外多出了文件 {stray}")
        for dirpath, dirnames, filenames in os.walk(dest):
            for n in dirnames + filenames:
                p = os.path.join(dirpath, n)
                if os.path.islink(p):
                    bad(f"{label}: 解出了符号链接 {p} -> {os.readlink(p)}")
                if os.path.exists(p) and not (os.path.isfile(p) or os.path.isdir(p)):
                    bad(f"{label}: 解出了特殊文件 {p}")
    finally:
        shutil.rmtree(base, ignore_errors=True)


def main():
    if not hasattr(bot, "_safe_extract"):
        bad("bot 里没有 _safe_extract —— 恢复仍在用不受限的 tar.extract")

    run_case("绝对路径", lambda t: addfile(t, "/etc/passwd-pwned"))
    ok("绝对路径成员被拒(未写到解压根外)")

    run_case("..逃逸", lambda t: addfile(t, "../../OUTSIDE/pwned.txt"))
    ok("`..` 逃逸成员被拒")

    def symlink_attack(t):
        i = tarfile.TarInfo("etc/sing-box/rs")
        i.type = tarfile.SYMTYPE
        i.linkname = "/tmp"                       # 指向解压根之外
        t.addfile(i)
        addfile(t, "etc/sing-box/rs/pwned.txt", b"pwned")
    run_case("符号链接", symlink_attack)
    ok("符号链接成员被拒(不给两段式写穿的机会)")

    def symlink_out(t):
        i = tarfile.TarInfo("escape")
        i.type = tarfile.SYMTYPE
        i.linkname = "../../OUTSIDE"
        t.addfile(i)
    run_case("外指符号链接", symlink_out)
    ok("指向解压根之外的符号链接被拒")

    def hardlink(t):
        addfile(t, "etc/sing-box/config.json", b"{}")
        i = tarfile.TarInfo("etc/sing-box/hard")
        i.type = tarfile.LNKTYPE
        i.linkname = "../../../../etc/passwd"
        t.addfile(i)
    run_case("硬链接", hardlink)
    ok("硬链接成员被拒")

    def devs(t):
        for name, ty in (("dev/zero", tarfile.CHRTYPE), ("dev/loop", tarfile.BLKTYPE),
                         ("dev/pipe", tarfile.FIFOTYPE)):
            i = tarfile.TarInfo(name)
            i.type = ty
            i.devmajor = 1
            i.devminor = 3
            t.addfile(i)
    run_case("设备/FIFO", devs)
    ok("设备文件与 FIFO 被拒")

    # ── 白名单之外的普通文件不得落地 ──
    base = tempfile.mkdtemp(prefix="pdgsafe")
    dest = os.path.join(base, "root")
    os.makedirs(dest)
    try:
        def mixed(t):
            addfile(t, "etc/sing-box/config.json", b"{}")
            addfile(t, "root/.ssh/authorized_keys", b"ssh-rsa AAA")
            addfile(t, "etc/cron.d/pwn", b"* * * * * root sh")
        raised, _ = extract(mktar(mixed), dest)
        if not raised:
            bad("合法配置里混入白名单外成员, 却没有拒绝整个备份")
        if os.path.exists(os.path.join(dest, "root/.ssh/authorized_keys")) \
           or os.path.exists(os.path.join(dest, "etc/cron.d/pwn")):
            bad("白名单之外的成员被解出来了")
        ok("合法配置中混入一个非法成员 → 拒绝整个备份(不是只跳过它)")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # ── 白名单形式的**绝对路径**: 不许被 lstrip 洗白成合法相对路径 ──
    run_case("白名单形式绝对路径", lambda t: addfile(t, "/etc/sing-box/config.json", b"{}"))
    ok("白名单形式的绝对路径(/etc/sing-box/config.json)被拒整包")

    # ── `../../` 逃逸到白名单路径 ──
    run_case("..逃逸到白名单路径",
             lambda t: addfile(t, "../../etc/sing-box/config.json", b"{}"))
    ok("`../../etc/sing-box/config.json` 被拒整包(未被规范化洗白)")

    # ── 硬链接两段式: 先放正常配置, 再放一个指向根外的硬链接 ──
    def hardlink_two_stage(t):
        addfile(t, "etc/sing-box/config.json", b"{}")
        addfile(t, "etc/mosdns/config.yaml", b"log: {}\n")
        i = tarfile.TarInfo("etc/sing-box/rs/evil.list")
        i.type = tarfile.LNKTYPE
        i.linkname = "../../../../../../etc/passwd"
        t.addfile(i)
    base = tempfile.mkdtemp(prefix="pdgsafe")
    dest = os.path.join(base, "root")
    os.makedirs(dest)
    try:
        raised, _ = extract(mktar(hardlink_two_stage), dest)
        if not raised:
            bad("硬链接两段式攻击未被拒整包")
        if os.path.exists(os.path.join(dest, "etc/sing-box/config.json")):
            bad("拒整包后仍留下了先落地的合法成员(应当整包不生效)")
        ok("硬链接两段式(正常配置 + 越界硬链接)→ 拒整包, 先落地的成员也不留")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # ── 体积 / 数量上限(压缩炸弹) ──
    base = tempfile.mkdtemp(prefix="pdgsafe")
    try:
        d1 = os.path.join(base, "r1")
        os.makedirs(d1)
        big = b"A" * (bot.RESTORE_MAX_FILE_BYTES + 1024)
        raised, _ = extract(mktar(lambda t: addfile(t, "etc/sing-box/config.json", big)), d1)
        if not raised:
            bad("超大单文件未被拒")
        ok(f"单文件体积上限生效({bot.RESTORE_MAX_FILE_BYTES} 字节)")

        d2 = os.path.join(base, "r2")
        os.makedirs(d2)

        def many(t):
            for i in range(bot.RESTORE_MAX_MEMBERS + 5):
                addfile(t, f"etc/sing-box/rs/r{i}.list", b"x")
        raised, _ = extract(mktar(many), d2)
        if not raised:
            bad("成员数量上限未生效")
        ok(f"成员数量上限生效({bot.RESTORE_MAX_MEMBERS} 个)")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # ── 声明值撒谎: tar 头里的 size 是攻击者写的, 只卡声明值挡不住"声明小、实则源源不断" ──
    base = tempfile.mkdtemp(prefix="pdgsafe")
    dest = os.path.join(base, "root")
    os.makedirs(dest)
    try:
        # 造一份成员表: 每个成员声明很小, 但累计实际内容远超总量上限
        chunk = b"B" * (1024 * 1024)
        n_needed = bot.RESTORE_MAX_TOTAL_BYTES // len(chunk) + 4

        def liar(t):
            for i in range(min(n_needed, bot.RESTORE_MAX_MEMBERS - 1)):
                addfile(t, f"etc/sing-box/rs/big{i}.list", chunk)
        raised, _ = extract(mktar(liar), dest)
        if not raised:
            bad("累计解出量超限却没被拒(只卡声明值挡不住解压炸弹)")
        ok(f"累计解出量上限生效({bot.RESTORE_MAX_TOTAL_BYTES} 字节, 按**实际读取**计)")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # ── 合法备份仍能正常解出(保护不能把功能弄坏) ──
    base = tempfile.mkdtemp(prefix="pdgsafe")
    dest = os.path.join(base, "root")
    os.makedirs(dest)
    try:
        def good(t):
            addfile(t, "etc/sing-box/config.json", b'{"outbounds":[]}')
            addfile(t, "etc/mosdns/config.yaml", b"log: {}")
            addfile(t, "etc/mosdns/rules/custom_direct.txt", b"a.com\n")
            addfile(t, "etc/mosdns/rules/custom_hijack.txt", b"b.com\n")
            addfile(t, "opt/pdg-bot/rulesets.json", b"{}")
            addfile(t, "etc/sing-box/rs/my.list", b"DOMAIN,x.com\n")
        raised, err = extract(mktar(good), dest)
        if raised:
            bad(f"合法备份被误拒: {err}")
        for rel in ("etc/sing-box/config.json", "etc/mosdns/config.yaml",
                    "etc/mosdns/rules/custom_direct.txt", "etc/mosdns/rules/custom_hijack.txt",
                    "opt/pdg-bot/rulesets.json", "etc/sing-box/rs/my.list"):
            if not os.path.exists(os.path.join(dest, rel)):
                bad(f"合法成员未解出: {rel}")
        ok("合法备份(含 rs/ 规则集)完整解出, 保护没误伤正常恢复")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # ── 守卫: 备份产出的成员必须全部在恢复白名单内 ──
    # _safe_extract 的白名单是硬编码的; 将来往 BACKUP_FILES 里加了文件却忘了同步白名单,
    # 那份文件会在恢复时被**静默跳过** —— 备份看着有、恢复回来却没有, 且没有任何报错。
    # 这条守卫把"备份写什么"与"恢复认什么"钉在一起。
    base = tempfile.mkdtemp(prefix="pdgsync")
    try:
        os.makedirs(os.path.join(base, "etc/mosdns/rules"), exist_ok=True)
        os.makedirs(os.path.join(base, "opt/pdg-bot"), exist_ok=True)
        os.makedirs(os.path.join(base, "etc/sing-box/rs"), exist_ok=True)
        bot.SB = os.path.join(base, "etc/sing-box/config.json")
        bot.MOSDNS_CONF = os.path.join(base, "etc/mosdns/config.yaml")
        bot.MOSDNS_DIRECT = os.path.join(base, "etc/mosdns/rules/custom_direct.txt")
        bot.MOSDNS_HIJACK = os.path.join(base, "etc/mosdns/rules/custom_hijack.txt")
        bot.RS_META = os.path.join(base, "opt/pdg-bot/rulesets.json")
        bot.RS_DIR = os.path.join(base, "etc/sing-box/rs")
        os.makedirs(os.path.join(base, "etc/privdns-gateway"), exist_ok=True)
        bot.IOS_META = os.path.join(base, "etc/privdns-gateway/ios-profile.json")
        bot.IOS_ART_DIR = os.path.join(base, "var/lib/privdns-gateway/ios-profile")
        bot.IOS_CURRENT = os.path.join(bot.IOS_ART_DIR, "current.mobileconfig")
        bot.IOS_PREVIOUS = os.path.join(bot.IOS_ART_DIR, "previous.mobileconfig")
        # 造一条**真的**生命周期(rev1 → rev2, 于是 current + previous 都在)。手写一份
        # 假记录 + 空产物是不行的: backup_blob 现在按记录 + verified_artifact 决定打包,
        # 对不上就 fail-closed —— 那正是另一条用例要的行为, 不该在这里被当成"白名单脱节"。
        _tmpl = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                             "deploy/ios/pdg-dot-ondemand.mobileconfig.tmpl")
        # lock=False: 这条用例跑在非 root 下, 拿不到 /run 的锁; 生命周期的并发语义由
        # test-ios-profile-concurrency.py 负责, 这里只需要一份自洽的三件套。
        bot.iosstate.generate("dot.a.example", "203.0.113.10", (), b"", False, _tmpl,
                              bot.IOS_META, bot.IOS_ART_DIR, False, False)
        bot.iosstate.generate("dot.b.example", "203.0.113.10", (), b"", False, _tmpl,
                              bot.IOS_META, bot.IOS_ART_DIR, False, False)
        bot.BACKUP_FILES = [bot.SB, bot.MOSDNS_CONF, bot.MOSDNS_DIRECT, bot.MOSDNS_HIJACK,
                            bot.RS_META, bot.IOS_META, bot.IOS_CURRENT, bot.IOS_PREVIOUS]
        json.dump({"outbounds": [], "route": {"rules": []}}, open(bot.SB, "w"))
        for p in (bot.MOSDNS_CONF, bot.MOSDNS_DIRECT, bot.MOSDNS_HIJACK):
            open(p, "w").write("x\n")
        json.dump({}, open(bot.RS_META, "w"))
        open(os.path.join(bot.RS_DIR, "a.list"), "w").write("DOMAIN,a.com\n")
        blob = bot.backup_blob()
        tar = tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz")
        missed = []
        for m in tar.getmembers():
            if not m.isreg():
                continue
            # 备份用的是本机绝对路径去头; 测试里路径被重定向过, 换算回归档相对形态再判
            rel = m.name.lstrip("./")
            rel = rel.replace(base.lstrip("/") + "/", "")
            if not bot._restore_member_allowed(rel):
                missed.append(rel)
        if missed:
            bad(f"备份产出的成员不在恢复白名单内(恢复时会被静默跳过): {missed}")
        ok("守卫: backup_blob 产出的每个成员都在恢复白名单内(备份/恢复不会脱节)")
    finally:
        shutil.rmtree(base, ignore_errors=True)

    limits_main()
    print(f"\n通过 {pass_n} 项断言")


def _reload_bot(**env):
    """按给定环境变量重新载入模块 —— 限额是 import 期算出来的, 只能整份重载来验。"""
    old = {k: os.environ.get(k) for k in env}
    os.environ.update({k: str(v) for k, v in env.items()})
    try:
        spec2 = importlib.util.spec_from_file_location(
            "bot_env", os.path.join(ROOT, "deploy/bot/pdg-bot.py"))
        m = importlib.util.module_from_spec(spec2)
        try:
            spec2.loader.exec_module(m)
        except SystemExit:
            pass
        return m
    finally:
        for k, v in old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def _free_bytes(path):
    """path 所在文件系统的可用字节(路径不存在就往上找)。测试自备一份, 不用被测代码的。"""
    p = os.path.abspath(path or "/")
    while True:
        try:
            return shutil.disk_usage(p).free
        except OSError:
            up = os.path.dirname(p)
            if up == p:
                return 0
            p = up


def limits_main():
    """限额必须**可调**但**关不掉**。

    写死 512 个成员 / 8MB 单文件的后果很实在: 规则集多一点的机器备份就恢复不了, 而用户
    除了改代码没有别的办法。反过来, 若允许随便调, 一个 PDG_RESTORE_MAX_TOTAL_BYTES=0
    或者天文数字就把这道防线关掉了 —— 那正是它要挡的东西。故: 可调, 但只在安全区间内,
    写错/越界一律落回安全值, 且照样拒得住炸弹。"""
    # ── 1. 不设环境变量 → 保持原默认值(不因为引入可配置而悄悄改行为) ──
    m = _reload_bot()
    if (m.RESTORE_MAX_MEMBERS, m.RESTORE_MAX_FILE_BYTES, m.RESTORE_MAX_TOTAL_BYTES) != \
            (512, 8 * 1024 * 1024, 64 * 1024 * 1024):
        bad("默认限额被改动了: %s" % ((m.RESTORE_MAX_MEMBERS, m.RESTORE_MAX_FILE_BYTES,
                                       m.RESTORE_MAX_TOTAL_BYTES),))
    ok("未配置时限额保持原默认(512 / 8MB / 64MB)")

    # ── 2. 调高之后, 原本被拒的合法大备份能恢复 ──
    n = 600                                        # > 默认 512
    blob = mktar(lambda t: [addfile(t, f"{bot.RESTORE_RS_PREFIX}f{i}.json", b"{}") for i in range(n)])
    with tempfile.TemporaryDirectory() as d, tarfile.open(fileobj=io.BytesIO(blob)) as tar:
        try:
            bot._safe_extract(tar, d)
            bad("600 个成员在默认 512 上限下竟然解开了")
        except ValueError:
            pass
    m = _reload_bot(PDG_RESTORE_MAX_MEMBERS=1000)
    if m.RESTORE_MAX_MEMBERS != 1000:
        bad(f"限额没按 PDG_RESTORE_MAX_MEMBERS 调整: {m.RESTORE_MAX_MEMBERS}")
    with tempfile.TemporaryDirectory() as d, tarfile.open(fileobj=io.BytesIO(blob)) as tar:
        m._safe_extract(tar, d)                     # 调高后应当能解开
        got = len(os.listdir(os.path.join(d, bot.RESTORE_RS_PREFIX.rstrip("/"))))
        if got != n:
            bad(f"调高上限后仍没全部解出: {got}/{n}")
    ok("调高上限后, 原本被拒的大备份(600 个成员)可以正常恢复")

    # ── 3. 关不掉: 0 / 负数 / 天文数字都落回安全区间 ──
    m = _reload_bot(PDG_RESTORE_MAX_MEMBERS=0, PDG_RESTORE_MAX_FILE_BYTES=-1,
                    PDG_RESTORE_MAX_TOTAL_BYTES=10 ** 15)
    if m.RESTORE_MAX_MEMBERS < 16:
        bad(f"成员上限被调到了 {m.RESTORE_MAX_MEMBERS}(等于关掉防线)")
    if m.RESTORE_MAX_FILE_BYTES < 64 * 1024:
        bad(f"单文件上限被调到了 {m.RESTORE_MAX_FILE_BYTES}")
    ceiling = max(64 * 1024 * 1024, _free_bytes(m.RS_DIR) // 2)
    if m.RESTORE_MAX_TOTAL_BYTES > ceiling:
        bad(f"总量上限被调到了 {m.RESTORE_MAX_TOTAL_BYTES}, 超过天花板 {ceiling}"
            "(等于关掉压缩炸弹防线)")
    ok("0 / 负数 / 天文数字一律夹回安全区间(限额可调但关不掉)")

    # 夹回之后, 压缩炸弹照样拒得住(不是只把数字改了而防线已失效)。
    # 造一个"想把总量限制关掉"的配置: 总量写 0(夹回 1MB 下限)、成员数写天文数字(夹回上限)
    m = _reload_bot(PDG_RESTORE_MAX_TOTAL_BYTES=0, PDG_RESTORE_MAX_MEMBERS=999999999)
    chunk = b"A" * (1024 * 1024)
    n_needed = int(m.RESTORE_MAX_TOTAL_BYTES // len(chunk)) + 4
    if n_needed >= m.RESTORE_MAX_MEMBERS:
        bad(f"夹回后的组合不该还需要 {n_needed} 个成员才超限")
    bomb = mktar(lambda t: [addfile(t, f"{bot.RESTORE_RS_PREFIX}b{i}.json", chunk)
                            for i in range(n_needed)])
    with tempfile.TemporaryDirectory() as d, tarfile.open(fileobj=io.BytesIO(bomb)) as tar:
        try:
            m._safe_extract(tar, d)
            bad("夹回安全值后压缩炸弹仍被解开")
        except ValueError:
            pass
    ok("夹回安全值后, 压缩炸弹照样被拒(不是只把数字改了而防线已失效)")

    # ── 3b. 天花板不是拍脑袋的常数, 而是"别把盘写满" ──
    # 固定 2GiB 意味着盘再大也调不上去(超大备份仍得改代码), 盘再小也能配到 2GiB(照样能
    # 把根分区写满)。上限应当跟着恢复目标所在文件系统的可用空间走。
    m = _reload_bot(PDG_RESTORE_MAX_TOTAL_BYTES=10 ** 15)
    free = _free_bytes(m.RS_DIR)       # 用测试自己的一份实现算, 不借被测代码的
    if m.RESTORE_MAX_TOTAL_BYTES > free // 2:
        bad(f"总量上限 {m.RESTORE_MAX_TOTAL_BYTES} 超过可用空间的一半({free // 2})")
    if m.RESTORE_MAX_TOTAL_BYTES < 64 * 1024 * 1024:
        bad(f"天花板把默认值都压下去了: {m.RESTORE_MAX_TOTAL_BYTES}")
    ok("总量上限的天花板跟着可用磁盘走(盘大能调高, 盘小不至于被写满)")

    # 磁盘信息取不到时不能崩, 也不能借机放开限制
    real_du = shutil.disk_usage

    def boom(_p):
        raise OSError("no such fs")

    shutil.disk_usage = boom
    try:
        m = _reload_bot(PDG_RESTORE_MAX_TOTAL_BYTES=10 ** 15)
        if m.RESTORE_MAX_TOTAL_BYTES > 2 * 1024 * 1024 * 1024:
            bad(f"读不到磁盘信息时放开了上限: {m.RESTORE_MAX_TOTAL_BYTES}")
        ok("读不到磁盘信息 → 退回保守天花板(不崩, 也不借机放开)")
    finally:
        shutil.disk_usage = real_du

    # ── 4. 写错(非数字)→ 用默认值, 不让一个笔误把恢复功能整个搞瘫 ──
    m = _reload_bot(PDG_RESTORE_MAX_MEMBERS="八百")
    if m.RESTORE_MAX_MEMBERS != 512:
        bad(f"非数字配置没落回默认: {m.RESTORE_MAX_MEMBERS}")
    ok("配置写成非数字 → 落回默认值(恢复功能不因笔误瘫痪)")

    # ── 5. 单文件上限 > 总量上限是自相矛盾的 → 总量取两者较大, 免得任何文件都过不了 ──
    m = _reload_bot(PDG_RESTORE_MAX_FILE_BYTES=200 * 1024 * 1024,
                    PDG_RESTORE_MAX_TOTAL_BYTES=1024 * 1024)
    if m.RESTORE_MAX_TOTAL_BYTES < m.RESTORE_MAX_FILE_BYTES:
        bad(f"单文件上限比总量上限还大: {m.RESTORE_MAX_FILE_BYTES} > {m.RESTORE_MAX_TOTAL_BYTES}")
    ok("单文件上限 > 总量上限时自动调和(不会配出一个谁都过不了的组合)")


if __name__ == "__main__":
    main()
