#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: **跨版本回滚**。更新器来自 v1.5.12(真的那一版), 目标代码是当前版本。
#
# 现场还原(P0):
#   1) 机器跑 v1.5.12, 执行**该版本的** `pdg update`;
#   2) 更新器把仓库切到当前版本, 装上新脚本, 并跑新版 `pdg __migrate` —— sing-box→mihomo
#      迁移**成功**;
#   3) 随后的校验门(这里注入 doctor 失败)判失败;
#   4) **仍在内存里运行的旧更新器**执行 cmd_rollback, 但它 `source "$REPO_DIR/lib/units.sh"`
#      拿到的已经是**新版**;
#   5) 旧代码照旧调 `pdg_write_unit pdg_unit_singbox` —— 新版早已删掉该生成函数。
#   旧实现 `"$fn" > "$path"` 会让 shell **先截断目标**再报 command not found →
#   sing-box.service 变成 0 字节, 机器既回不到 sing-box 也没了可用 unit, 界面还可能说"已回滚"。
#
# 断言: 回滚后 sing-box unit 非空且可用、服务 active+enabled、backend 标记与仓库版本都已复位。
#
# 覆盖范围: 要踩到这个 P0, 旧版必须同时满足两条 ——
#   ① 回滚里会调 pdg_write_unit pdg_unit_singbox(v1.5.8 起);
#   ② 自检门失败时**真的会触发回滚**。v1.5.8/v1.5.9 的门是 `doctor ... || true` 且依赖 jq,
#      自检失败会被吞掉、update 直接报成功(那是 v1.5.10 修掉的另一个缺陷) —— 那两版压根走不到
#      回滚, 也就踩不到本 P0。
# 故实际受影响区间是 **v1.5.10~v1.5.12**; 这里取其中最旧与最新各跑一遍(中间版本该处代码一致)。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

# 受影响版本(既调 pdg_unit_singbox, 自检门又真会回滚): v1.5.10~v1.5.12 —— 全跑, 不抽样。
# 只跑首尾是拿"中间那版大概一样"当假设: 这三个 tag 之间 cmd_update / cmd_rollback 的实现
# 各有改动, 中间版本恰好走了另一条分支的话就永远测不到。三个版本各一遍, 用例本身不长。
OLD_TAGS="${PDG_XVER_TAGS:-v1.5.10 v1.5.11 v1.5.12}"
AVAIL=""
for _t in $OLD_TAGS; do
  git -C "$E2E_ROOT" rev-parse "$_t" >/dev/null 2>&1 && AVAIL="$AVAIL $_t"
done
[[ -n "${AVAIL// /}" ]] || e2e_skip "本地没有任何受影响旧 tag($OLD_TAGS; 浅克隆?), 跨版本用例跳过"

# 每个受影响旧版跑一遍完整现场(装机 → 该版本 update → 迁移成功 → 注入 doctor 失败 → 该版本回滚)
# 函数体不缩进: 内部有 heredoc, 缩进会把结束定界符一起缩进而破坏它。
run_case_for_tag(){
OLD_TAG="$1"
echo; echo "══════════ 更新器版本: $OLD_TAG ══════════"
e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft
printf 'android\n' > /etc/privdns-gateway/platform
e2e_seed_cert || e2e_skip "无 openssl, 造不出占位证书"
mkdir -p /var/lib/privdns-gateway

# ── 造出"仍在跑 v1.5.12 + sing-box"的机器 ───────────────────────────────────
printf 'singbox\n' > /etc/privdns-gateway/backend
# unit 用 v1.5.12 的 pdg_unit_singbox 真的生成(既是真实形态, 也让归属判定认得出是本项目装的)
( eval "$(git -C "$E2E_ROOT" show "$OLD_TAG:lib/units.sh")"; pdg_unit_singbox ) \
  > /etc/systemd/system/sing-box.service
chmod 644 /etc/systemd/system/sing-box.service
SB_UNIT_SHA="$(sha256sum /etc/systemd/system/sing-box.service | cut -d' ' -f1)"
printf '#!/bin/sh\ncase "$1" in version) echo "sing-box version 1.12.25";; check) exit 0;; esac\nexit 0\n' \
  > /usr/local/bin/sing-box; chmod 755 /usr/local/bin/sing-box
. "$E2E_ROOT/lib/versions.sh"
printf '#!/bin/sh\ncase "$1" in -v|version) echo "Mihomo Meta %s linux amd64";; -t) exit 0;; esac\nexit 0\n' \
  "$MIHOMO_VER" > /usr/local/bin/mihomo; chmod 755 /usr/local/bin/mihomo
# 让假 systemd 认为 sing-box 正在跑(迁移前的真实状态)
echo 1 > $E2E_TMP/e2e-svc/sing-box.ac; echo 1 > $E2E_TMP/e2e-svc/sing-box.en

# ── 造发布源: v1.5.12(旧) 与 vNEXT(当前代码) 两个 tag ────────────────────────
REPO=/opt/privdns-gateway
ORIGIN=$E2E_TMP/e2e-xver-origin.git
rm -rf "$REPO/.git" "$ORIGIN"
git -C "$REPO" init -q -b main
e2e_guard_repo "$REPO" || exit 1     # 刚 init 出来的一次性库才准动 ref
e2e_git "$REPO" config user.email t@t; e2e_git "$REPO" config user.name t
e2e_git "$REPO" config commit.gpgsign false
# 第一个提交 = v1.5.12 的全部代码(更新器就来自它)
rm -rf "${REPO:?}"/* 2>/dev/null || true
git -C "$E2E_ROOT" archive "$OLD_TAG" | tar -x -C "$REPO"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm "$OLD_TAG" >/dev/null 2>&1
e2e_git "$REPO" tag "$OLD_TAG"
OLD_SHA="$(git -C "$REPO" rev-parse HEAD)"
# 第二个提交 = 当前工作树(被测代码)
rm -rf "${REPO:?}"/* 2>/dev/null || true
tar -C "$E2E_ROOT" --exclude=.git -cf - . | tar -x -C "$REPO"
e2e_git "$REPO" add -A >/dev/null 2>&1
e2e_git "$REPO" commit -qm "vNEXT(current)" >/dev/null 2>&1
e2e_git "$REPO" tag v9.9.9
git clone -q --bare "$REPO" "$ORIGIN"
e2e_git "$REPO" remote add origin "$ORIGIN"
e2e_git "$REPO" tag -d v9.9.9 >/dev/null            # 逼更新器真去 origin 取新 tag
e2e_git "$REPO" checkout -q "$OLD_TAG"
# 装上**旧版**更新器 —— 这是本用例的关键: 跑的是 v1.5.12 的 cmd_update/cmd_rollback
install -m755 "$REPO/deploy/bot/pdg.sh" /usr/local/bin/pdg
for f in "$REPO"/deploy/bot/*.py; do install -m755 "$f" /opt/pdg-bot/; done
install -m755 "$REPO/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py
[[ "$(git -C "$REPO" describe --tags)" == "$OLD_TAG" ]] \
  && ok "现场就位: 机器停在 $OLD_TAG, 更新器来自该版本" || bad "发布源没造对"

# ── 注入: 迁移成功之后, 让校验门里的 doctor 判失败 ───────────────────────────
# doctor.py 由更新器从**新版**仓库装到 /opt/pdg-bot, 故要在 update 跑起来后才生效 ——
# 用 wrapper 覆盖 python3 太粗暴; 直接让新版 doctor.py 在被调用时返回失败即可。
cat > $E2E_TMP/e2e-doctor-fail.py <<'P'
import sys
print('[{"status":"fail","name":"注入","msg":"e2e 注入的自检失败"}]')
sys.exit(1)
P
# 更新器装完新版文件后才调 doctor(`python3 /opt/pdg-bot/doctor.py --json`), 所以不能预先改
# doctor.py —— install 会把它覆盖回去。改为在 PATH 前面放一层 python3 包装: **只**拦 doctor.py
# 这一次调用, 其余(py_compile / 迁移渲染 / checks 取内网段)一律透传给真 python3。
INJ=$E2E_TMP/e2e-inject; rm -rf "$INJ"; mkdir -p "$INJ"
{ printf '#!/bin/sh\nFAKE=%s/e2e-doctor-fail.py\n' "$E2E_TMP"   # 引号 heredoc 不展开, 路径走头行
  cat <<'P'
for a in "$@"; do
  case "$a" in */doctor.py|doctor.py) exec /usr/bin/python3 "$FAKE" ;; esac
done
exec /usr/bin/python3 "$@"
P
} > "$INJ/python3"
chmod 755 "$INJ/python3"
export PATH="$INJ:$PATH"
python3 /opt/pdg-bot/doctor.py --json >/dev/null 2>&1 \
  && bad "注入未生效: doctor 仍返回成功" || ok "已注入: doctor 判失败(迁移成功之后才会触发)"

# ── 跑旧版更新器: 迁移会成功, 随后 doctor 失败 → 旧版 cmd_rollback 接管 ──────
echo; echo "── 跑 v1.5.12 的 pdg update(目标: 当前版本) ──"
out=$(PATH="$INJ:$PATH" bash /usr/local/bin/pdg update 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "校验门判失败 → update 返回非0(未谎报成功)" || bad "doctor 失败却报成功 rc=$rc"
grep -qE '回滚|自检' <<<"$out" && ok "输出说明了回滚原因" || bad "没说回滚原因: $(tail -3 <<<"$out")"

# ── 核心断言: 回滚后 sing-box unit 必须完好 ─────────────────────────────────
echo; echo "── 回滚后现场 ──"
[[ -s /etc/systemd/system/sing-box.service ]] \
  && ok "sing-box.service 非空(旧实现在此被截成 0 字节)" \
  || bad "sing-box.service 是 0 字节/不存在 —— 正是 P0 现场"
grep -q 'ExecStart=/usr/local/bin/sing-box' /etc/systemd/system/sing-box.service 2>/dev/null \
  && ok "sing-box.service 内容可用(ExecStart 在)" || bad "unit 内容坏了: $(head -3 /etc/systemd/system/sing-box.service 2>/dev/null)"
[[ "$(sha256sum /etc/systemd/system/sing-box.service | cut -d' ' -f1)" == "$SB_UNIT_SHA" ]] \
  && ok "sing-box.service 与回滚前逐字节一致" || bad "unit 内容被改写了"
[[ "$(systemctl is-active sing-box)" == active ]] \
  && ok "sing-box 服务 active" || bad "sing-box 未 active: $(systemctl is-active sing-box)"
[[ "$(systemctl is-enabled sing-box)" == enabled ]] \
  && ok "sing-box 服务 enabled(重启后仍在)" || bad "sing-box 未 enabled: $(systemctl is-enabled sing-box)"
[[ -x /usr/local/bin/sing-box ]] \
  && ok "sing-box 二进制已恢复" || bad "sing-box 二进制没了"
[[ "$(cat /etc/privdns-gateway/backend)" == singbox ]] \
  && ok "backend 标记已复位为 singbox" || bad "backend=$(cat /etc/privdns-gateway/backend)"
[[ "$(git -C "$REPO" rev-parse HEAD)" == "$OLD_SHA" ]] \
  && ok "仓库版本已复位到 $OLD_TAG" || bad "仓库停在 $(git -C "$REPO" describe --tags 2>/dev/null)"

}

for _tag in $AVAIL; do run_case_for_tag "$_tag"; done

e2e_summary
