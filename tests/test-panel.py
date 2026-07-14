#!/usr/bin/env python3
"""Regression: 观测面板 (zashboard) 开关 + clash_api secret 适配。"""
import importlib.util
import copy
import io
import json
import os
import tarfile
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
os.environ["PDG_VERSIONS_FILE"] = str(ROOT / "lib/versions.sh")
spec = importlib.util.spec_from_file_location("pdg_bot", ROOT / "deploy/bot/pdg-bot.py")
bot = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(bot)

# ── clash_get: 有 secret 带 Bearer, 无 secret 不带 ──────────────────────────
cap = {}
def fake_urlopen(req, timeout=None):
    cap["auth"] = req.get_header("Authorization")
    class R:
        def __enter__(s): return s
        def __exit__(s, *a): pass
        def read(s): return b'{"v":1}'
    return R()
bot.urllib.request.urlopen = fake_urlopen

bot.load = lambda: {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
bot.clash_get("/version")
assert cap["auth"] is None, "无 secret 不该带 Authorization"
bot.load = lambda: {"experimental": {"clash_api": {"secret": "S3CR3T"}}}
bot.clash_get("/version")
assert cap["auth"] == "Bearer S3CR3T", ("有 secret 应带 Bearer", cap["auth"])
print("[OK]   clash_get 按 secret 带/不带 Bearer")

# ── zashboard 版本/哈希只从 lib/versions.sh 读取 ─────────────────────────────
versions = (ROOT / "lib/versions.sh").read_text(encoding="utf-8")
assert bot.ZASHBOARD_VER == "v3.15.0" and bot.ZASHBOARD_VER in versions
assert bot.ZASH_SHA in versions
assert bot.ZASH_URL.endswith(f"/{bot.ZASHBOARD_VER}/dist-no-fonts.zip")
print("[OK]   zashboard 版本与 SHA 来自统一版本清单")

# ── set_panel(on): clash_api 改 0.0.0.0 + secret + external_ui, 生成一键链接 ──
_REAL_ENSURE = bot._ensure_zashboard        # 存真函数, 供后面 SHA 校验用例
bot._ensure_zashboard = lambda: (True, "")
bot._panel_cidr = lambda: "172.22.0.0/16"
_REAL_FW = bot._panel_firewall              # 存真函数, 供后面 firewall 用例
fw = []
bot._panel_firewall = lambda on, cidr: (fw.append((on, cidr)), (True, ""))[1]
bot._server_ip = lambda: "203.0.113.9"
cfg = {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
def fake_apply(mod):
    mod(cfg); return True, ""
bot.load = lambda: cfg
bot.apply_sb = fake_apply

ok, link = bot.set_panel(True)
assert ok, link
api = cfg["experimental"]["clash_api"]
assert api["external_controller"] == "0.0.0.0:9090", api
assert api["external_ui"] == bot.UI_DIST
assert api["external_ui_download_url"] == bot.ZASH_URL
sec = api["secret"]; assert sec and len(sec) >= 16
assert link == f"http://203.0.113.9:9090/ui/#/setup?hostname=203.0.113.9&port=9090&secret={sec}", link
assert bot._panel_on(cfg) is True
assert fw and fw[-1] == (True, "172.22.0.0/16"), "应放行内网卡段 → 9090"
print("[OK]   set_panel(on): clash_api 0.0.0.0+secret+external_ui + 一键链接 + 放行内网 9090")

# ── set_panel(off): 收回 127.0.0.1, 去掉 secret/external_ui, 撤防火墙 ──────────
ok, msg = bot.set_panel(False)
assert ok, msg
api = cfg["experimental"]["clash_api"]
assert api["external_controller"] == "127.0.0.1:9090"
assert "secret" not in api and "external_ui" not in api and "external_ui_download_url" not in api
assert bot._panel_on(cfg) is False
assert fw[-1] == (False, "172.22.0.0/16"), "应撤销 9090 放行"
print("[OK]   set_panel(off): 收回 127.0.0.1 + 去 secret/external_ui + 撤放行")

# ── 无内网段 → 拒绝开启(不裸奔) ──────────────────────────────────────────────
bot._panel_cidr = lambda: ""
ok, err = bot.set_panel(True)
assert not ok and "内网" in err, ("无内网段应拒绝", ok, err)
print("[OK]   读不到内网卡段 → 拒绝开启")

# ── _ensure_zashboard: SHA256 不符 → 拒绝(供应链校验)────────────────────────
bot._ensure_zashboard = _REAL_ENSURE        # 恢复真函数
bot._fetch_bytes = lambda url: b"not-a-real-zashboard-zip"
bot.UI_DIR = tempfile.mkdtemp(); bot.UI_DIST = os.path.join(bot.UI_DIR, "dist")
ok, err = bot._ensure_zashboard()
assert not ok and "SHA256" in err, ("SHA 不符应拒绝", ok, err)
print("[OK]   zashboard SHA256 不符 → 拒绝安装")

# ── 已安装 UI 有指纹；内容被替换后恢复固定版本 ───────────────────────────────
old_pin = (bot.ZASHBOARD_VER, bot.ZASH_SHA, bot.ZASH_URL, bot.UI_DIR, bot.UI_DIST)
with tempfile.TemporaryDirectory() as td:
    raw = io.BytesIO()
    with zipfile.ZipFile(raw, "w") as z:
        z.writestr("dist/index.html", "fixed-index")
        z.writestr("dist/assets/app.js", "fixed-js")
    archive = raw.getvalue()
    bot.ZASHBOARD_VER = "v-test"
    bot.ZASH_SHA = bot.hashlib.sha256(archive).hexdigest()
    bot.ZASH_URL = "https://example.invalid/v-test/dist-no-fonts.zip"
    bot.UI_DIR = td
    bot.UI_DIST = os.path.join(td, "dist")
    bot.UI_META = os.path.join(td, ".pdg-zashboard.json")
    fetched = []
    bot._fetch_bytes = lambda url: (fetched.append(url), archive)[1]
    ok, err = bot._ensure_zashboard()
    assert ok, err
    assert os.path.exists(bot.UI_META), "安装后应记录受管 UI 指纹"
    Path(bot.UI_DIST, "index.html").write_text("tampered", encoding="utf-8")
    ok, err = bot._ensure_zashboard()
    assert ok, err
    assert Path(bot.UI_DIST, "index.html").read_text(encoding="utf-8") == "fixed-index"
    assert len(fetched) == 2, "UI 内容被替换后应重新下载已验证版本"
bot.ZASHBOARD_VER, bot.ZASH_SHA, bot.ZASH_URL, bot.UI_DIR, bot.UI_DIST = old_pin
bot.UI_META = os.path.join(bot.UI_DIR, ".pdg-zashboard.json")
print("[OK]   zashboard 内容指纹不符 → 恢复固定版本")

# ── 配置归属：自定义 clash_api 绝不接管 ─────────────────────────────────────
bot._ensure_zashboard = lambda: (True, "")
bot._panel_cidr = lambda: "172.22.0.0/16"
owner_fw = []
bot._panel_firewall = lambda on, cidr: (owner_fw.append((on, cidr)), (True, ""))[1]
custom = {"experimental": {"clash_api": {
    "external_controller": "0.0.0.0:9999", "secret": "KEEP",
    "external_ui": "/srv/user-ui"}}}
before = copy.deepcopy(custom)
applies = []
def apply_custom(mod):
    applies.append(True); mod(custom); return True, ""
bot.load = lambda: custom
bot.apply_sb = apply_custom
ok, err = bot.set_panel(True)
assert not ok and "自定义" in err, (ok, err)
assert custom == before and not applies and not owner_fw
ok, err = bot.set_panel(False)
assert not ok and "自定义" in err, (ok, err)
assert custom == before and not applies and not owner_fw
print("[OK]   自定义 clash_api 开/关均拒绝且保持原样")

# 升级清单后，旧版本由本项目写入的 download_url 仍属于受管态，必须可收回。
old_managed = {"experimental": {"clash_api": {
    "external_controller": "0.0.0.0:9090", "secret": "OLD",
    "external_ui": bot.UI_DIST,
    "external_ui_download_url": "https://github.com/Zephyruso/zashboard/releases/download/v3.14.0/dist-no-fonts.zip"}}}
assert bot._panel_state(old_managed) == "on"
assert bot._panel_sanitize_config(old_managed) is True
assert old_managed["experimental"]["clash_api"] == {"external_controller": "127.0.0.1:9090"}
print("[OK]   升级后仍识别并收回旧版本受管面板")

# ── 防火墙开启失败：配置必须回滚到关闭态 ────────────────────────────────────
cfg_fail = {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
bot.load = lambda: cfg_fail
bot.apply_sb = lambda mod: (mod(cfg_fail), (True, ""))[1]
fw_fail_calls = []
def fail_open_fw(on, cidr):
    fw_fail_calls.append((on, cidr))
    return (False, "nft insert 失败") if on else (True, "")
bot._panel_firewall = fail_open_fw
ok, err = bot.set_panel(True)
assert not ok and "防火墙" in err, (ok, err)
assert cfg_fail["experimental"]["clash_api"] == {"external_controller": "127.0.0.1:9090"}
assert [x[0] for x in fw_fail_calls] == [True, False], fw_fail_calls
print("[OK]   防火墙失败 → 开启失败并回滚 clash_api")

# ── 定时自动关闭: arm 排定时器 + 记链接; autoclose 关面板+删链接 ──────────────
# 让 set_panel 走前面的 mock(可开可关), _ensure/cidr/firewall/server_ip 已 mock
bot._ensure_zashboard = lambda: (True, "")
bot._panel_cidr = lambda: "172.22.0.0/16"
bot._panel_firewall = lambda on, cidr: (True, "")
cfg2 = {"experimental": {"clash_api": {"external_controller": "127.0.0.1:9090"}}}
bot.load = lambda: cfg2
bot.apply_sb = lambda mod: (mod(cfg2), (True, ""))[1]
deleted = []
bot.delete_message = lambda ch, m: deleted.append((ch, m))
sent2 = []
bot.send_plain = lambda ch, t: sent2.append(t)

bot.set_panel(True)
bot._panel_arm(42, 999, 0.05)                    # 50ms 后自动关
assert bot._panel_link == (42, 999) and bot._panel_timer is not None, "arm 应记链接+排定时器"
assert bot._panel_on(cfg2) is True
import time as _t; _t.sleep(0.2)                 # 等定时器触发
assert bot._panel_on(cfg2) is False, "到时应自动关面板"
assert (42, 999) in deleted, "到时应删掉含密钥的链接消息"
assert bot._panel_link is None and bot._panel_timer is None
print("[OK]   定时到期: 自动关面板 + 删链接消息")

# 手动关也删链接 + 取消定时器
bot.set_panel(True); bot._panel_arm(7, 555, 3600)
bot._panel_cancel_timer(); bot._panel_delete_link()
assert bot._panel_timer is None and bot._panel_link is None and (7, 555) in deleted
print("[OK]   手动关: 取消定时器 + 删链接消息")

# ── _panel_firewall: off 只删(供启动兜底清残留放行), on 删旧+加 ────────────────
bot._panel_firewall = _REAL_FW              # 恢复真函数
calls = []
class _R:
    def __init__(s, out="", rc=0, err=""):
        s.stdout = out; s.returncode = rc; s.stderr = err
rules = ['ip saddr 172.22.0.0/16 tcp dport 9090 accept comment "pdg-panel" # handle 15']
def fake_sh(cmd):
    calls.append(cmd)
    if len(cmd) > 1 and cmd[1] == "-a":
        return _R("\n".join(rules) + ("\n" if rules else ""))
    if "delete" in cmd:
        rules.clear(); return _R()
    if "insert" in cmd:
        rules[:] = ['ip saddr 172.22.0.0/16 tcp dport 9090 accept comment "pdg-panel" # handle 16']
    return _R("")
bot.sh = fake_sh
calls.clear(); ok, err = bot._panel_firewall(False, "172.22.0.0/16")
assert ok, err
assert any(c[:4] == ["nft", "delete", "rule", "inet"] and "15" in c for c in calls), "off 应按 handle 删残留规则"
assert not any("insert" in c for c in calls), "off 不应 insert"
calls.clear(); ok, err = bot._panel_firewall(True, "172.22.0.0/16")
assert ok, err
assert any("insert" in c for c in calls), "on 应 insert 放行规则"
bot.sh = lambda cmd: (_R("", 1, "insert failed") if "insert" in cmd else _R(""))
ok, err = bot._panel_firewall(True, "172.22.0.0/16")
assert not ok and "insert" in err
bot.sh = lambda cmd: (_ for _ in ()).throw(TimeoutError("nft timeout"))
ok, err = bot._panel_firewall(True, "172.22.0.0/16")
assert not ok and "TimeoutError" in err
print("[OK]   _panel_firewall: off 只删残留 / on 删旧+加(启动兜底可清 config-off 的残留放行)")

# ── 链接发送失败：立即关闭；关闭也失败则保留自动重试 ─────────────────────────
real_set_panel = bot.set_panel
real_schedule_retry = bot._panel_schedule_retry
panel_calls = []
bot.send_get_mid = lambda chat, text: None
bot.set_panel = lambda on: (panel_calls.append(on), (True, "closed"))[1]
ok, err = bot._panel_publish(9, "secret-link", 600)
assert not ok and panel_calls == [False], (ok, err, panel_calls)
retry_calls = []
bot.set_panel = lambda on: (False, "close failed")
bot._panel_schedule_retry = lambda chat=None: retry_calls.append(chat)
ok, err = bot._panel_publish(9, "secret-link", 600)
assert not ok and retry_calls == [9] and "关闭失败" in err
bot._panel_schedule_retry = real_schedule_retry
print("[OK]   链接发送失败 → 立即关闭；关闭失败 → 自动重试")

sent_link_text = []
bot.send_get_mid = lambda chat, text: (sent_link_text.append(text), 88)[1]
ok, err = bot._panel_publish(9, "secret-link", 0)
assert ok and "临时观测/控制面板" in sent_link_text[0] and "secret-link" in sent_link_text[0]
bot._panel_clear_state()
print("[OK]   成功说明与密钥链接同属一条可自动删除消息")

# ── 计时器代号：重开删旧链接，过期回调不能关新会话 ─────────────────────────
class FakeTimer:
    made = []
    def __init__(self, interval, function, args=()):
        self.interval = interval; self.function = function; self.args = args
        self.cancelled = False; self.started = False
        self.__class__.made.append(self)
    def start(self): self.started = True
    def cancel(self): self.cancelled = True
    def fire(self): self.function(*self.args)

bot.threading.Timer = FakeTimer
bot._panel_timer = None; bot._panel_link = None; bot._panel_generation = 0; bot._panel_chat = None
deleted.clear(); FakeTimer.made.clear(); panel_calls.clear()
bot.delete_message = lambda ch, m: deleted.append((ch, m))
bot.set_panel = lambda on: (panel_calls.append(on), (True, "closed"))[1]
bot._panel_arm(1, 101, 10); old_timer = FakeTimer.made[-1]
bot._panel_arm(2, 202, 20)
assert (1, 101) in deleted, "重新开启应删除旧的含密钥链接"
old_timer.fire()                                  # 模拟 cancel 时回调已开始
assert panel_calls == [], "过期计时器不能关闭新面板"
assert bot._panel_link == (2, 202), "过期计时器不能删除新链接"
print("[OK]   会话代号隔离旧计时器；重新开启删除旧链接")

# 自动关闭失败保留链接并安排短间隔重试
bot._panel_clear_state(); deleted.clear(); FakeTimer.made.clear()
bot.set_panel = lambda on: (False, "close failed")
bot._panel_arm(3, 303, 10); due = FakeTimer.made[-1]
due.fire()
assert bot._panel_link == (3, 303), "关闭失败不能删除仍可能有效的链接状态"
assert bot._panel_timer is not None and bot._panel_timer is not due, "关闭失败应安排重试"
print("[OK]   自动关闭失败 → 保留状态并安排重试")

# 手动关闭失败也不能先取消保障
bot._panel_clear_state(); FakeTimer.made.clear()
bot._panel_arm(4, 404, 600); original_timer = bot._panel_timer
bot.set_panel = lambda on: (False, "close failed")
ok, err = bot._panel_close(4)
assert not ok and bot._panel_link == (4, 404) and bot._panel_timer is not None
assert original_timer.cancelled and bot._panel_timer.interval == bot.PANEL_RETRY_SECONDS
print("[OK]   手动关闭失败 → 保留链接并补自动重试")

# 启动清理：自定义配置不动；受管面板关闭失败会重试
custom_start = {"experimental": {"clash_api": {
    "external_controller": "0.0.0.0:9999", "secret": "KEEP", "external_ui": "/srv/ui"}}}
startup_calls = []
bot.load = lambda: custom_start
bot.set_panel = lambda on: (startup_calls.append(on), (True, ""))[1]
bot._panel_firewall = lambda on, cidr: (startup_calls.append((on, cidr)), (True, ""))[1]
ok, err = bot._panel_startup_cleanup()
assert not ok and "自定义" in err and startup_calls == []

managed_start = {"experimental": {"clash_api": {
    "external_controller": "0.0.0.0:9090", "secret": "S",
    "external_ui": bot.UI_DIST, "external_ui_download_url": bot.ZASH_URL}}}
bot.load = lambda: managed_start
bot.set_panel = lambda on: (False, "close failed")
retry_calls.clear(); bot._panel_schedule_retry = lambda chat=None: retry_calls.append(chat)
ok, err = bot._panel_startup_cleanup()
assert not ok and retry_calls == [None]
print("[OK]   启动清理尊重配置归属并检查关闭结果")

bot.set_panel = real_set_panel

# ── 备份/恢复净化项目临时面板状态；自定义配置保持原样 ───────────────────────
managed = {"experimental": {"clash_api": {
    "external_controller": "0.0.0.0:9090", "secret": "TEMP",
    "external_ui": bot.UI_DIST, "external_ui_download_url": bot.ZASH_URL}},
    "route": {"rules": []}}
san = copy.deepcopy(managed)
assert bot._panel_sanitize_config(san) is True
assert san["experimental"]["clash_api"] == {"external_controller": "127.0.0.1:9090"}
custom_san = copy.deepcopy(custom_start); custom_before = copy.deepcopy(custom_san)
assert bot._panel_sanitize_config(custom_san) is False and custom_san == custom_before

with tempfile.TemporaryDirectory() as td:
    sb = os.path.join(td, "config.json")
    Path(sb).write_text(json.dumps(managed), encoding="utf-8")
    bot.SB = sb; bot.BACKUP_FILES = [sb]; bot.RS_DIR = os.path.join(td, "missing-rs")
    blob = bot.backup_blob()
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:gz") as tar:
        backed = json.load(tar.extractfile(sb.lstrip("/")))
    assert backed["experimental"]["clash_api"] == {"external_controller": "127.0.0.1:9090"}

with tempfile.TemporaryDirectory() as td:
    sb = os.path.join(td, "current.json")
    mos = os.path.join(td, "mosdns.yaml")
    Path(sb).write_text(json.dumps({"experimental": {"clash_api": {
        "external_controller": "127.0.0.1:9090"}}, "route": {"rules": []}}), encoding="utf-8")
    Path(mos).write_text("", encoding="utf-8")
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w:gz") as tar:
        data = json.dumps(managed).encode()
        info = tarfile.TarInfo("etc/sing-box/config.json"); info.size = len(data)
        tar.addfile(info, io.BytesIO(data))
    bot.SB = sb; bot.MOSDNS_CONF = mos; bot.RS_DIR = os.path.join(td, "rs")
    bot.RESTORE_MAP = {"etc/sing-box/config.json": sb}
    bot.sh = lambda cmd: _R()
    ok, err = bot.restore_from(raw.getvalue())
    assert ok, err
    restored = json.loads(Path(sb).read_text(encoding="utf-8"))
    assert restored["experimental"]["clash_api"] == {"external_controller": "127.0.0.1:9090"}
print("[OK]   备份与恢复均净化受管面板；自定义配置不动")

# ── 菜单/回调接线 ────────────────────────────────────────────────────────────
src = (ROOT / "deploy/bot/pdg-bot.py").read_text(encoding="utf-8")
assert '"callback_data": "panel"' in src, "运维菜单应有观测面板入口"
for cb in ('if data == "panel":', 'if data.startswith("panel:on:"):', 'if data == "panel:off":'):
    assert cb in src, f"缺回调 {cb}"
for token in ('"panel:on:10"', '"panel:on:30"', '"panel:on:0"'):
    assert token in src, f"缺时长按钮 {token}"
assert "_panel_publish(chat, res" in src and "_panel_startup_cleanup()" in src, "缺安全发链接 / 启动兜底调用"
print("[OK]   运维菜单 + 时长按钮 + 回调接线 + 启动兜底(含清残留放行)")

print("panel regression OK")
