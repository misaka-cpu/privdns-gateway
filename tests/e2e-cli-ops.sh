#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端: 管理命令不许"假成功"。
#
#   · pdg restart 以前把 systemctl 的返回值直接丢掉(`systemctl restart $svcs 2>/dev/null`),
#     mihomo 配置是空的、服务一直起不来, 它照样 return 0 打印"已重启";
#   · pdg detect-cidr 的快照失败被 `|| true` 吞掉, 出事再按 index 0 回滚(可能回到上周某次
#     无关快照), sed 没命中也照报成功;
#   · pdg update --dry-run 会先跑一遍迁移(改 unit/nft/mosdns), 且 fetch/describe/tag 失败
#     一律吞掉后打印"最新发布: (无 tag)" + return 0 —— 用户当成"已是最新";
#   · 极简 Debian 没有 iproute2, status 的"监听端口"整块是空的而装机不报错;
#   · uninstall 遇到 bind-mount 的 /etc/resolv.conf 直接 rm+mv, 失败也宣布完成 —— 机器
#     从此指着一个已被卸载的本机 mosdns, 整机没 DNS。
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail
E2E_ROOT="${E2E_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# shellcheck source=tests/e2e-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/e2e-lib.sh"
e2e_enter "$@"

export PDG_STABLE_SAMPLES=1     # 假 systemd 没有真实重启动力学; is-active/NRestarts 照常查

e2e_stub_system
e2e_seed_install
e2e_seed_mosdns all
e2e_seed_singbox_model
e2e_seed_nft
printf 'mihomo\n' > /etc/privdns-gateway/backend
printf 'android\n' > /etc/privdns-gateway/platform
e2e_fetch_mihomo || e2e_skip "取不到 mihomo 二进制"

# unit 用**真实形态**(带 ExecStart=…/usr/local/bin/<svc>): 幂等迁移是按 unit 内容判断要不要
# 补 SAFE_PATHS 的, 拿 ExecStart=/bin/true 这种占位 unit 当现场, 那条迁移每次都会重跑一遍并
# 重启内核, 后面"校验没过时一个服务都没重启"就永远测不成。
# shellcheck source=lib/units.sh
source "$E2E_ROOT/lib/units.sh"
pdg_write_unit pdg_unit_mihomo /etc/systemd/system/mihomo.service
for u in pdg-bot mosdns; do
  printf '[Unit]\nDescription=%s\n[Service]\nExecStart=/usr/local/bin/%s\n' "$u" "$u" \
    > "/etc/systemd/system/$u.service"
done
for u in pdg-bot mosdns mihomo; do echo 1 > "/tmp/e2e-svc/$u.ac"; echo 1 > "/tmp/e2e-svc/$u.en"; done
# 有效的 mihomo 配置(下面某些用例会故意写坏它)
printf '{"log-level":"silent","mixed-port":17890,"proxies":[],"rules":["MATCH,DIRECT"]}\n' \
  > /etc/mihomo/config.yaml
GOOD_CFG="$(cat /etc/mihomo/config.yaml)"

# ══ 1. restart: 服务起不来必须返回非 0 ══════════════════════════════════════
echo "── 1. restart 的真实校验 ──"
printf 'PDG_BOT_TOKEN=123456:AAaa\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
out=$(pdg restart 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '已重启并确认运行' <<<"$out"; } \
  && ok "一切正常时 restart 返回 0 并确认运行" || bad "1: rc=$rc: $(tail -3 <<<"$out")"

e2e_svc_crash mihomo                                  # 起得来但立刻崩(restart 返回 0, 随即 inactive)
out=$(pdg restart 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "内核起不来 → restart 返回非 0" || bad "1b: 竟然返回 0: $(tail -3 <<<"$out")"
grep -q 'mihomo' <<<"$out" && ok "点名了起不来的服务" || bad "1c: 没点名: $(tail -3 <<<"$out")"
grep -qE '最近日志|journal' <<<"$out" && ok "附带了近期日志" || bad "1d: 没给日志"
e2e_svc_heal mihomo

e2e_svc_crash mosdns
out=$(pdg restart 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q 'mosdns' <<<"$out"; } \
  && ok "mosdns 起不来 → 返回非 0 并点名" || bad "1e: rc=$rc: $(tail -3 <<<"$out")"
e2e_svc_heal mosdns

# 内核配置坏掉 → 一个服务都不该重启。这条要求 PATH 上是**真** mihomo(桩会把任何配置判过),
# 串行跑时前一个脚本可能留了个桩 —— 明确要一次真内核, 拿不到就说清楚而不是默默判绿。
if ! e2e_mihomo_is_real; then
  e2e_fetch_mihomo || true
fi
if ! e2e_mihomo_is_real; then
  bad "1f: 拿不到真 mihomo(PATH 上是桩), 配置校验这条无法验证"
else
printf 'proxies: [\n' > /etc/mihomo/config.yaml
out=$(pdg restart 2>&1); rc=$?          # 第一次顺带让幂等迁移落定(它自己也会重启服务)
{ [[ "$rc" != 0 ]] && grep -q '校验' <<<"$out"; } \
  && ok "内核配置不合法 → 先报校验失败, 返回非 0" || bad "1f: rc=$rc: $(tail -3 <<<"$out")"
CALLS_BEFORE="$(grep -c 'systemctl restart' /tmp/e2e-calls.log 2>/dev/null)"
out=$(pdg restart 2>&1); rc=$?
CALLS_AFTER="$(grep -c 'systemctl restart' /tmp/e2e-calls.log 2>/dev/null)"
{ [[ "$rc" != 0 ]] && [[ "$CALLS_BEFORE" == "$CALLS_AFTER" ]]; } \
  && ok "校验没过时一个服务都没重启" || bad "1g: rc=$rc 重启计数 $CALLS_BEFORE→$CALLS_AFTER"
printf '%s\n' "$GOOD_CFG" > /etc/mihomo/config.yaml
fi

# ══ 2. restart: 未配 Bot 凭据时明确跳过 pdg-bot ═════════════════════════════
echo; echo "── 2. 未配 Bot 凭据 ──"
: > /etc/privdns-gateway/bot.env
echo 0 > /tmp/e2e-svc/pdg-bot.ac                      # 没配凭据, bot 本来就不该在跑
out=$(pdg restart 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "未配凭据 + pdg-bot 未运行 → restart 仍返回 0" || bad "2: rc=$rc: $(tail -3 <<<"$out")"
grep -q '未配置' <<<"$out" && ok "明确显示「未配置, 未启动」" || bad "2b: 没说明: $(tail -3 <<<"$out")"
grep -q 'pdg-bot' <<<"$(sed -n '/已重启并确认运行/p' <<<"$out")" \
  && bad "2c: 未配凭据却仍去重启 pdg-bot" || ok "未配凭据: 重启清单里没有 pdg-bot"
printf 'PDG_BOT_TOKEN=123456:AAaa\n' > /etc/privdns-gateway/bot.env   # 只配一半
out=$(pdg restart 2>&1)
grep -q '只配了一项' <<<"$out" && ok "只配一半 → 明确提示配置错误" || bad "2d: $(tail -3 <<<"$out")"
printf 'PDG_BOT_TOKEN=123456:AAaa\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
echo 1 > /tmp/e2e-svc/pdg-bot.ac

# ══ 3. restart: iOS 服务集 ═════════════════════════════════════════════════
echo; echo "── 3. iOS 服务集 ──"
printf 'ios\n' > /etc/privdns-gateway/platform
printf '[Unit]\nDescription=probe81\n[Service]\nExecStart=/bin/true\n' > /etc/systemd/system/pdg-probe81.service
echo 1 > /tmp/e2e-svc/pdg-probe81.ac; echo 1 > /tmp/e2e-svc/pdg-probe81.en
out=$(pdg restart 2>&1); rc=$?
{ [[ "$rc" == 0 ]] && grep -q 'pdg-probe81' <<<"$out"; } \
  && ok "iOS: 重启清单含 pdg-probe81" || bad "3: $(tail -3 <<<"$out")"
e2e_svc_crash pdg-probe81
out=$(pdg restart 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q 'pdg-probe81' <<<"$out"; } \
  && ok "iOS: probe81 起不来 → 非 0 并点名" || bad "3b: rc=$rc: $(tail -3 <<<"$out")"
e2e_svc_heal pdg-probe81
# pdg-mitm 已启用时也要核验
printf '[Unit]\nDescription=mitm\n[Service]\nExecStart=/bin/true\n' > /etc/systemd/system/pdg-mitm.service
echo 1 > /tmp/e2e-svc/pdg-mitm.en; echo 1 > /tmp/e2e-svc/pdg-mitm.ac
out=$(pdg restart 2>&1)
grep -q 'pdg-mitm' <<<"$out" && ok "已启用的 pdg-mitm 也纳入核验" || bad "3c: $(tail -3 <<<"$out")"
e2e_svc_crash pdg-mitm
out=$(pdg restart 2>&1); rc=$?
[[ "$rc" != 0 ]] && ok "pdg-mitm 起不来 → 非 0" || bad "3d: 竟然返回 0: $(tail -3 <<<"$out")"
e2e_svc_heal pdg-mitm
rm -f /etc/systemd/system/pdg-mitm.service /etc/systemd/system/pdg-probe81.service
rm -f /tmp/e2e-svc/pdg-mitm.* /tmp/e2e-svc/pdg-probe81.*
printf 'android\n' > /etc/privdns-gateway/platform

# ══ 4. status: 监听端口靠 ss(iproute2) ═════════════════════════════════════
echo; echo "── 4. status 的监听端口 ──"
command -v ss >/dev/null 2>&1 && ok "环境里有 ss(装机依赖已含 iproute2)" \
  || bad "4: 没有 ss —— 装机依赖漏了 iproute2"
grep -qE '^apt-get install .*\biproute2\b' "$E2E_ROOT/install.sh" \
  && ok "install.sh 的依赖列表显式包含 iproute2" || bad "4b: 依赖列表没有 iproute2"
cat > /usr/local/bin/ss <<'S'
#!/bin/sh
cat <<'E'
tcp   LISTEN 0 4096   0.0.0.0:53    0.0.0.0:*
tcp   LISTEN 0 4096   0.0.0.0:853   0.0.0.0:*
tcp   LISTEN 0 4096   0.0.0.0:7893  0.0.0.0:*
tcp   LISTEN 0 4096   0.0.0.0:8445  0.0.0.0:*
tcp   LISTEN 0 4096   0.0.0.0:81    0.0.0.0:*
E
S
chmod 755 /usr/local/bin/ss
out=$(pdg status 2>&1)
for p in 53 853 7893 8445; do
  grep -qE "监听端口.*\b$p\b" <<<"$out" && ok "status 显示端口 $p" || bad "4c: 没显示 $p: $(grep 监听端口 <<<"$out")"
done
printf 'ios\n' > /etc/privdns-gateway/platform
out=$(pdg status 2>&1)
grep -qE "监听端口.*\b81\b" <<<"$out" && ok "iOS: status 还显示 :81(probe81)" || bad "4d: iOS 没显示 81"
printf 'android\n' > /etc/privdns-gateway/platform

# ══ 5. status: 版本读不到要说"未知", 不能空 ════════════════════════════════
echo; echo "── 5. status 的版本显示 ──"
out=$(pdg status 2>&1)
grep -qE '代码版本 +[^ ]' <<<"$out" && ok "正常时显示版本" || bad "5: 版本是空的: $(grep 代码版本 <<<"$out")"
mv /opt/privdns-gateway/.git /opt/privdns-gateway/.git-hidden
out=$(pdg status 2>&1)
grep -qE '代码版本 +未知' <<<"$out" && ok "仓库读不到 → 明确显示「未知」" || bad "5b: $(grep 代码版本 <<<"$out")"
mv /opt/privdns-gateway/.git-hidden /opt/privdns-gateway/.git

# ══ 6. update --dry-run: 严格只读 + 失败要报错 ═════════════════════════════
echo; echo "── 6. update --dry-run ──"
hash_state(){
  { sha256sum /etc/mihomo/config.yaml /etc/nftables.conf /etc/mosdns/config.yaml \
              /etc/privdns-gateway/profile.env 2>/dev/null
    sha256sum /etc/systemd/system/*.service 2>/dev/null
    git -C /opt/privdns-gateway rev-parse HEAD 2>/dev/null
  } | sha256sum | cut -d' ' -f1
}
printf 'PDG_PLATFORM=android\n' > /etc/privdns-gateway/profile.env
# origin 指向**本地** bare 仓库: dry-run 会真的 fetch, 不该依赖外网(串行跑时前一个脚本
# 可能已经把 /etc/resolv.conf 指到本机 mosdns, 那时解析 github.com 必然失败)。
rm -rf /tmp/e2e-cli-origin.git
git init -q --bare /tmp/e2e-cli-origin.git
# `cd` 必须带 `|| exit` —— 目录不在时子 shell **不会**自己退出, 后面 git init / git add -A /
# git commit / remote set-url / tag 会原地落在当时的工作目录上。而跑测试时那通常就是
# 开发者的真仓库: 本机上它真的往仓库里塞了一个 "base" 提交、把 user.name 改成 t、
# 把 origin 换成 /tmp 里的裸库、还打了个 v9.9.9 标签。一个静默失败的 cd 能干这么多事。
( cd /opt/privdns-gateway || { echo "[FAIL] /opt/privdns-gateway 不存在, 拒绝在当前目录执行 git 操作"; exit 1; }
  # 目录存在**证明不了**这个仓库可以随便动: worktree 的路径也存在, 而它的 ref 与主仓库共享。
  # 2026-07-31 丢掉全部 tag 与 remote-tracking 就是从下面这几条开始的。
  # 守卫放在 init 之后: init 之前这里可能还不是仓库(会假拒); 而 `git init` 落在 worktree
  # 上并不会把它从共享 ref 库里摘出来 —— 那种情况守卫照样拦得住。
  git init -q -b main 2>/dev/null            # e2e_git 豁免: 还不是仓库时守卫会假拒
  e2e_git . config user.email t@t || exit 1; e2e_git . config user.name t || exit 1
  e2e_git . config commit.gpgsign false || exit 1
  e2e_git . add -A >/dev/null 2>&1; e2e_git . commit -qm base >/dev/null 2>&1
  e2e_git . remote remove origin >/dev/null 2>&1
  e2e_git . remote add origin /tmp/e2e-cli-origin.git || exit 1
  e2e_git . push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  e2e_git . tag -f v9.9.9 >/dev/null 2>&1
  e2e_git . push -q origin --tags >/dev/null 2>&1 ) || true
BEFORE="$(hash_state)"
out=$(pdg update --dry-run 2>&1); rc=$?
[[ "$rc" == 0 ]] && ok "dry-run 正常返回 0" || bad "6: rc=$rc: $(tail -3 <<<"$out")"
[[ "$(hash_state)" == "$BEFORE" ]] \
  && ok "dry-run 零修改(配置/unit/nft/profile/仓库 HEAD 哈希不变)" || bad "6b: dry-run 改了东西"
grep -qE '当前:.*最新发布:' <<<"$out" && ok "dry-run 报出当前/最新版本" || bad "6c: $(tail -3 <<<"$out")"

# 远端拉不到 tag(remote 不可用)→ 必须返回非 0 并说明, 而不是"最新发布: (无 tag)" + 0
# 改 remote 就是改 config, 而 config 与主仓库共享 —— 这两行以前一条守卫都没有, 是 2026-08-02
# 把开发者 origin 改指到 /tmp 裸库的入口。走 e2e_git 之后守卫与动作绑成一件事, 漏不掉。
e2e_git /opt/privdns-gateway remote remove origin >/dev/null 2>&1
e2e_git /opt/privdns-gateway remote add origin /nonexistent/repo.git >/dev/null 2>&1 || exit 1
BEFORE="$(hash_state)"
out=$(pdg update --dry-run 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -qE '拉取远端 tag 失败|无法判断' <<<"$out"; } \
  && ok "fetch 失败 → 返回非 0 并说明原因" || bad "6d: rc=$rc: $(tail -3 <<<"$out")"
[[ "$(hash_state)" == "$BEFORE" ]] && ok "fetch 失败路径同样零修改" || bad "6e: 失败路径改了东西"

# 远端能拉但一个发布 tag 都没有 → 同样要明说, 不能装作"已是最新"
rm -rf /tmp/e2e-empty-origin.git
git init -q --bare /tmp/e2e-empty-origin.git
# 以前这里是 `( cd /opt/privdns-gateway || exit; git remote add …; git push … )`, 守卫写在
# 整块**之后** —— 先改后守, 守卫报不报警都已经晚了。改成每条动作自带守卫。
e2e_git /opt/privdns-gateway remote remove origin >/dev/null 2>&1
e2e_git /opt/privdns-gateway remote add origin /tmp/e2e-empty-origin.git || exit 1
e2e_git /opt/privdns-gateway push -q origin HEAD:refs/heads/main >/dev/null 2>&1
# xargs 调不了 shell 函数 —— 用数组接住再一次删完, 免得管道右边又变成一条裸 git 改动。
mapfile -t _vtags < <(e2e_git /opt/privdns-gateway tag -l 'v*') || exit 1
[[ ${#_vtags[@]} -gt 0 ]] && { e2e_git /opt/privdns-gateway tag -d "${_vtags[@]}" >/dev/null 2>&1 || exit 1; }
BEFORE="$(hash_state)"
out=$(pdg update --dry-run 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -q 'tag' <<<"$out"; } \
  && ok "没有任何发布 tag → 返回非 0 并说明" || bad "6f: rc=$rc: $(tail -3 <<<"$out")"
[[ "$(hash_state)" == "$BEFORE" ]] && ok "无 tag 路径同样零修改" || bad "6g: 改了东西"

mv /opt/privdns-gateway/.git /opt/privdns-gateway/.git-hidden
out=$(pdg update --dry-run 2>&1); rc=$?
{ [[ "$rc" != 0 ]] && grep -qE 'git 仓库|无法查看' <<<"$out"; } \
  && ok "仓库不可用 → 返回非 0 并说明" || bad "6h: rc=$rc: $(tail -3 <<<"$out")"
mv /opt/privdns-gateway/.git-hidden /opt/privdns-gateway/.git
e2e_git /opt/privdns-gateway tag -f v9.9.9 >/dev/null 2>&1 || exit 1
rm -rf /tmp/e2e-empty-origin.git /tmp/e2e-cli-origin.git

# ══ 7. detect-cidr 事务化 ══════════════════════════════════════════════════
# detect-cidr 走一笔真事务, 候选校验要拿**真 mosdns** 解析新配置。取二进制放在这里而不是
# 脚本开头 —— 前面几节(装机/迁移/update dry-run)中途会把 /usr/local/bin 下的内核清掉,
# 开头取一次到这儿就没了。
#
# 这条以前根本没写。于是单独跑必然 7a/7b/7e/7i/7j/7k/7l 全红(事务在校验门 REFUSED),
# 只有在同一个容器里先跑过 e2e-install.sh 时才碰巧变绿 —— 而 CI 的矩阵是一个脚本一个
# 干净容器, 那里从来没绿过。先前误判成"需要 CAP_NET_ADMIN、只有 privileged 能跑",
# 实测 privileged 与否毫无区别(单独跑都是 38/8), 差别只在前一个脚本留没留下 mosdns。
e2e_fetch_mosdns || e2e_skip "取不到 mosdns 二进制(§7 的候选校验要拿真 mosdns 解析配置)"
mosdns version >/dev/null 2>&1 \
  || { echo "[FAIL] §7 前提: mosdns 取到了却跑不起来"; exit 1; }
echo; echo "── 7. detect-cidr ──"
cp /etc/nftables.conf /tmp/pristine.nft
cp /etc/mosdns/config.yaml /tmp/pristine.mos
NFT_SHA0="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
MOS_SHA0="$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)"
reset_cidr(){ cp /tmp/pristine.nft /etc/nftables.conf; cp /tmp/pristine.mos /etc/mosdns/config.yaml; }
# 抓包桩: 固定报一个与当前不同的网段; 交互确认自动回 y
cat > /usr/local/bin/tcpdump <<'S'
#!/bin/sh
printf 'IP 10.44.0.5.55000 > 10.0.0.1.853: tcp\n10.44.0.5\n10.44.0.5\n'
exit 0
S
chmod 755 /usr/local/bin/tcpdump
detect(){ printf 'y\n' | pdg detect-cidr 1 2>&1; }

# 7a. 回退手段: 5.2 起写入阶段是一笔 pdgtx 事务, 回退靠 before-image + 自动回滚 + 崩溃后
# `pdg tx recover`, 不再自己打整机快照(cmd_snapshot 会先拿走同一把 flock, 子进程里的事务
# 反而拿不到锁)。所以这里验的是**事务确实留下了可恢复的材料**, 而不是"tar 坏了就中止"。
reset_cidr
out=$(detect); rc=$?
{ [[ "$rc" == 0 ]] && grep -q '事务' <<<"$out"; } \
  && ok "成功路径明确说明走的是配置事务" || bad "7a: rc=$rc: $(tail -4 <<<"$out")"
_txdir="$(ls -1dt /var/lib/privdns-gateway/tx/*/ 2>/dev/null | head -1)"
{ [[ -n "$_txdir" ]] && grep -q '"op": "detect-cidr"' "$_txdir/meta.json" 2>/dev/null \
  && grep -q '"state": "COMMITTED"' "$_txdir/meta.json" 2>/dev/null; } \
  && ok "事务留下了 COMMITTED 的 detect-cidr 记录(可查、可审计)" \
  || bad "7b: 没找到本次事务记录: ${_txdir:-无}"
_S7_TX=yes      # 场景标记: 事务真的提交过(见文件末尾的必需场景守卫)
reset_cidr

# 7b. mosdns 是自定义形态(没有可替换的 ips)→ sed 不命中必须报错而不是报成功
reset_cidr
python3 - <<'PY2'
p = "/etc/mosdns/config.yaml"
t = open(p, encoding="utf-8").read().replace("ips:", "ips_custom:")
open(p, "w", encoding="utf-8").write(t)
PY2
MOS_CUSTOM="$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)"
out=$(detect); rc=$?
{ [[ "$rc" != 0 ]] && grep -qE '未能替换|没找到可替换' <<<"$out"; } \
  && ok "sed 不命中 → 报错而不是谎报成功" || bad "7c: rc=$rc: $(tail -4 <<<"$out")"
{ [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$NFT_SHA0" ]] \
  && [[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$MOS_CUSTOM" ]]; } \
  && ok "不命中时两份配置都没被改" || bad "7d: 配置被改了"

# 7c. nft 校验失败 → 用**本次事务**的备份还原
reset_cidr
cp /usr/local/bin/nft /usr/local/bin/nft.real
printf '#!/bin/sh\n[ "$1" = "-c" ] && exit 1\nexec /usr/local/bin/nft.real "$@"\n' > /usr/local/bin/nft
chmod 755 /usr/local/bin/nft
out=$(detect); rc=$?
cp -f /usr/local/bin/nft.real /usr/local/bin/nft
{ [[ "$rc" != 0 ]] && grep -qE 'nft -c|nft_check' <<<"$out"; } \
  && ok "nft 校验失败 → 非 0 并说明是哪个校验门" || bad "7e: rc=$rc: $(tail -4 <<<"$out")"
{ [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$NFT_SHA0" ]] \
  && [[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$MOS_SHA0" ]]; } \
  && ok "nft 校验失败后两份配置都逐字节未变" || bad "7f: 配置被改了"

# 7d. mosdns 起不来 → 用本次事务备份还原(而不是回滚到别的快照)
reset_cidr
e2e_svc_crash mosdns
out=$(detect); rc=$?
e2e_svc_heal mosdns
{ [[ "$rc" != 0 ]] && grep -q 'mosdns' <<<"$out"; } \
  && ok "mosdns 起不来 → 非 0 并点名" || bad "7g: rc=$rc: $(tail -4 <<<"$out")"
{ [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$NFT_SHA0" ]] \
  && [[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$MOS_SHA0" ]]; } \
  && ok "mosdns 失败后用本次事务备份还原(两份配置回到原样)" || bad "7h: 没还原干净"
_S7_ROLLBACK=yes   # 场景标记: 失败回滚真的走过

# 7e. 成功路径: 落盘 + 三处复核
reset_cidr
out=$(detect); rc=$?
{ [[ "$rc" == 0 ]] && grep -qE '同一笔事务落盘' <<<"$out"; } \
  && ok "成功路径: 真源/防火墙/mosdns 同一笔事务落盘" || bad "7i: rc=$rc: $(tail -4 <<<"$out")"
grep -q "^PDG_INTERNAL_CIDR=10.44.0.0/16$" /etc/privdns-gateway/profile.env \
  && ok "成功路径: 真源(profile.env)也在同一笔事务里更新了" \
  || bad "7i2: 真源没更新: $(sed -n 's/^PDG_INTERNAL_CIDR=//p' /etc/privdns-gateway/profile.env)"
grep -q '10.44.0.0/16' /etc/nftables.conf && ok "新网段写进了防火墙" || bad "7j: 防火墙里没有新网段"
grep -q '10.44.0.0/16' /etc/mosdns/config.yaml && ok "新网段写进了 mosdns" || bad "7k: mosdns 里没有新网段"

# 7f. 幂等: 再跑一次什么都不该改
NFT_SHA1="$(sha256sum /etc/nftables.conf | cut -d' ' -f1)"
MOS_SHA1="$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)"
out=$(detect); rc=$?
{ [[ "$rc" == 0 ]] && grep -qE '无需修改' <<<"$out"; } \
  && ok "再跑一次: 三处均已一致 → 明确返回无需修改" || bad "7l: rc=$rc: $(tail -3 <<<"$out")"
{ [[ "$(sha256sum /etc/nftables.conf | cut -d' ' -f1)" == "$NFT_SHA1" ]] \
  && [[ "$(sha256sum /etc/mosdns/config.yaml | cut -d' ' -f1)" == "$MOS_SHA1" ]]; } \
  && ok "幂等: 第二次没有改动任何配置" || bad "7m: 第二次改了配置"
_S7_CLEANUP=yes    # 场景标记: 收尾与幂等复核真的跑过

rm -f /tmp/pristine.nft /tmp/pristine.mos /usr/local/bin/nft.real /usr/local/bin/tar.real

# ── 必需场景守卫 ────────────────────────────────────────────────────────────
# 光看总退出码是不够的: 把 §7 整段删掉或提前 return, 其余部分照样全绿, 退出码 0 —— 而
# §7 恰恰是唯一真跑"改网段 → 事务 → 校验门 → 回滚 → 清理"那条链的地方。所以每个必需场景
# 在跑完时留一个标记, 这里逐项核对; 少一个就判失败并点名是哪个场景没执行。
_missing=""
[[ -n "${_S7_TX:-}" ]]       || _missing="$_missing §7-事务提交"
[[ -n "${_S7_ROLLBACK:-}" ]] || _missing="$_missing §7-失败回滚"
[[ -n "${_S7_CLEANUP:-}" ]]  || _missing="$_missing §7-收尾清理"
if [[ -n "${_missing// /}" ]]; then
  bad "必需场景未执行:$_missing (整段被删/提前 return 时其余用例仍会全绿, 所以这里单独判)"
fi
e2e_summary
