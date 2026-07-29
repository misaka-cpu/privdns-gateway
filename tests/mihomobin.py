#!/usr/bin/env python3
"""测试用 mihomo 二进制的**唯一**定位入口。

为什么要收口成一个模块: 之前三处各写一份 —— 一处认 `PDG_TEST_MIHOMO`、一处认 `MIHOMO_BIN`、
还有一处自己下载。后果有两层, 都很坏:

  · 开发者得记住每个测试认哪个环境变量, 忘了就看见"找不到 mihomo"而以为是环境坏了;
  · 更糟的是**版本没人管**。`shutil.which("mihomo")` 捡到机器上任意一版就用, 而这两个测试
    的全部意义就是"钉死版内核认不认这份配置"。捡到 v1.18 跑绿了, 等于把关键校验悄悄换成了
    一句安慰。所以这里**无论从哪个来源拿到, 都要跑一次 `-v` 核对版本**, 版本不符直接失败,
    绝不静默使用。

定位顺序(先显式、再项目备好的、最后才是 PATH):
  1. 环境变量 PDG_TEST_MIHOMO —— 人明确指定, 优先级最高;
  2. 项目测试流程备好的钉死版(tests/.bin/mihomo, 由 tests/prepare-mihomo.sh 下载并校验
     SHA256; CI 与全量入口跑它, 单跑的人也可以手动跑一次);
  3. PATH 上的 mihomo —— 只有版本恰好对得上才算数。

找不到的处置分两种, 不能混为一谈:
  · 严格模式(CI / 全量入口 / PDG_TEST_STRICT=1): **失败**。关键真实校验不允许悄悄变绿灯。
  · 单跑(开发者本机随手跑一个测试): 明确输出 [SKIP] 并说明怎么备好, 但整份测试的其它断言
    照常跑。SKIP 与 PASS 在输出里是两个词, 不许混。
"""
import os
import re
import shutil
import subprocess

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PREPARED = os.path.join(ROOT, "tests", ".bin", "mihomo")


class MihomoMissing(Exception):
    """机器上没有可用的钉死版 —— 严格模式下应判失败, 单跑时应 [SKIP]。"""


class MihomoWrongVersion(Exception):
    """找到了, 但不是钉死版 —— 任何模式下都必须失败, 不许拿它凑数。"""


def pinned_version():
    """钉死版本号取自 lib/versions.sh, 不在测试里另写一份字面量。"""
    txt = open(os.path.join(ROOT, "lib", "versions.sh"), encoding="utf-8").read()
    m = re.search(r'^MIHOMO_VER="([^"]+)"', txt, re.M)
    if not m:
        raise RuntimeError("lib/versions.sh 里读不到 MIHOMO_VER")
    return m.group(1)


def version_of(path):
    """跑 `-v` 解析出版本(如 v1.19.29); 跑不起来或解析不出返回空串。"""
    try:
        out = subprocess.run([path, "-v"], capture_output=True, text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    m = re.search(r"v?(\d+\.\d+\.\d+)", out or "")
    return "v" + m.group(1) if m else ""


def strict_mode():
    """严格模式: CI、全量入口, 或显式 PDG_TEST_STRICT=1。"""
    if os.environ.get("PDG_TEST_STRICT", "") not in ("", "0"):
        return True
    return os.environ.get("CI", "") not in ("", "0", "false")


def candidates():
    """(路径, 来源说明) 列表, 按定位顺序。"""
    out = []
    env = os.environ.get("PDG_TEST_MIHOMO", "")
    if env:
        out.append((env, "PDG_TEST_MIHOMO"))
    if os.path.exists(PREPARED):
        out.append((PREPARED, "tests/.bin(prepare-mihomo.sh 备好的钉死版)"))
    which = shutil.which("mihomo")
    if which:
        out.append((which, "PATH"))
    return out


def find():
    """返回 (路径, 来源)。找不到 → MihomoMissing; 找到但版本不符 → MihomoWrongVersion。

    注意"找到但版本不符"绝不降级成"没找到": 那样在严格模式下会被当成环境问题, 而它其实是
    一台装着错版本内核的机器 —— 正是必须拦下来的情形。"""
    want = pinned_version()
    seen = []
    for path, src in candidates():
        got = version_of(path)
        seen.append((path, src, got or "(读不到版本)"))
        if got == want:
            return path, src
        if src == "PDG_TEST_MIHOMO":
            # 人明确指了一个路径, 它却不是钉死版 —— 这时**不许**悄悄退到别的候选:
            # 那样跑出来的绿是另一个二进制给的, 而人以为验的是自己指的那份。
            raise MihomoWrongVersion(
                "PDG_TEST_MIHOMO 指向 %s, 它是 %s, 不是钉死版 %s"
                % (path, got or "(读不到版本)", want))
    if seen:
        raise MihomoWrongVersion(
            "找到 mihomo 但都不是钉死版 %s: %s" % (
                want, "; ".join("%s(来自 %s)=%s" % (p, s, g) for p, s, g in seen)))
    raise MihomoMissing(
        "找不到钉死版 mihomo %s。备一份: bash tests/prepare-mihomo.sh"
        "(会按 lib/versions.sh 的 SHA256 校验后放到 tests/.bin/), "
        "或设 PDG_TEST_MIHOMO=<路径>" % want)


def require(ok, bad, skip):
    """给测试用的统一处置: 返回二进制路径, 或 None(已按规则记 SKIP)。

    ok/bad/skip 是调用方自己的计数函数 —— 这里不替它们决定输出格式, 只保证"缺二进制"在
    严格模式下一定落到 bad、单跑时一定落到 skip, 而"版本不对"任何时候都落到 bad。"""
    want = pinned_version()
    try:
        path, src = find()
    except MihomoWrongVersion as e:
        bad("mihomo 版本不符 —— 关键校验不接受用别的版本顶替: %s" % e)
        return None
    except MihomoMissing as e:
        if strict_mode():
            bad("严格模式(CI/全量入口)下缺钉死版 mihomo: %s" % e)
        else:
            skip("单跑且本机没有钉死版 mihomo → 真内核校验未执行(不是通过): %s" % e)
        return None
    ok("钉死版 mihomo %s 就位(来自 %s)" % (want, src))
    return path
