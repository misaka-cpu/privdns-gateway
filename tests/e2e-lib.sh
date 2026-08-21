#!/usr/bin/env bash
# shellcheck shell=bash
# ─────────────────────────────────────────────────────────────────────────────
# 端到端沙盒骨架。用 user+mount namespace + overlayfs 把 /etc /opt /usr/local/bin 覆盖掉,
# 于是可以在**真实绝对路径**上跑真正的 install/migrate/update/switch-core, 而宿主毫发无损
# (所有写入落在 overlay 的 upperdir)。
#
# 为什么要有这层: 现有回归都在函数级别打桩, 跨组件的接缝没人看着 —— 而实践中查出来的 bug
# (GMS 重复插入、backend 标记从不落地、分流规则不进 mosdns)全是接缝问题, 单测全绿照样漏。
#
# 用法(每个 e2e 脚本开头):
#     source "$(dirname "$0")/e2e-lib.sh"
#     e2e_enter "$@"          # 不支持则以 0 退出(跳过); 支持则重入 namespace 并挂好 overlay
#     ... 测试主体(此时已是 namespace 内 root) ...
#     e2e_summary
# ─────────────────────────────────────────────────────────────────────────────

# ref 守卫单独放一个文件: test-update-rollback.sh 这类**不走 e2e harness** 的用例也要用,
# 而整个 source 本文件会连 ok()/bad() 一起覆盖掉它自己的计数器(这个坑踩过)。
# shellcheck source=tests/repoguard.sh
source "$(dirname "${BASH_SOURCE[0]}")/repoguard.sh"

E2E_PASS=0; E2E_FAIL=0
ok(){ echo "[OK]   $1"; E2E_PASS=$((E2E_PASS+1)); }
bad(){ echo "[FAIL] $1"; E2E_FAIL=$((E2E_FAIL+1)); }
e2e_summary(){ echo "────────────────────────────────────────"; echo "通过 $E2E_PASS, 失败 $E2E_FAIL"; [[ "$E2E_FAIL" == 0 ]]; }
# 缺能力时怎么办, 取决于**在哪跑**:
#   · 开发者本机偶尔没网、拉不到内核 → 记 [SKIP] 并退 0 是合理的, 否则没法干活;
#   · CI 或 PDG_TEST_STRICT=1 → 必须 FAIL。这里跳过的都是"取不到真二进制"这类前提,
#     跳过之后整条用例一个断言都不跑, 退 0 就是零断言假绿 —— 而 CI 上没人会去看
#     "通过 0, 失败 0" 这行字, 只会看到一个绿勾。
e2e_skip(){
  echo "[SKIP] $1"
  echo "────────────────────────────────────────"
  if [[ -n "${PDG_TEST_STRICT:-}" && "${PDG_TEST_STRICT}" != "0" ]] || [[ "${CI:-}" == "true" ]]; then
    echo "严格模式(PDG_TEST_STRICT/CI): 缺必需前提 → 判失败, 不拿 SKIP 冒充通过"
    echo "通过 0, 失败 1(前提缺失)"
    exit 1
  fi
  echo "通过 0, 失败 0(已跳过)"
  exit 0
}

# 沙盒里的仓库文件未必归当前 uid(CI 容器 job: 工作区归 runner uid, 容器内是 root),
# git 会以 "dubious ownership" 拒绝一切操作 —— update 那条 e2e 连 tag 都读不到。
# safe.directory 属"受保护配置": 经 -c / GIT_CONFIG_* 环境变量设置会被 git 故意忽略,
# 只认 system/global。所以写沙盒里的 /etc/gitconfig —— 本地是 overlay, CI 是一次性容器,
# 两边都碰不到开发机的真实配置。
_e2e_git_safe(){ grep -q 'directory = \*' /etc/gitconfig 2>/dev/null || printf '[safe]\n\tdirectory = *\n' >> /etc/gitconfig 2>/dev/null || true; }

# 测试桩的所有权标记。清理只认带这行的文件 —— 同名但没有标记的一律当成"用户的真程序",
# 宁可让测试停下来, 也不删一个我们证明不了归属的东西。
E2E_STUB_MARK="# pdg-e2e-managed-stub"

# 影子桩所在目录。默认就是真实的 /usr/local/bin(它排在 PATH 前面, 桩才会遮住系统命令);
# 参数化只为让契约测试能在一个临时目录上验同一份实现 —— **不复制一套清理逻辑去自测**。
E2E_SHADOW_BIN="${E2E_SHADOW_BIN:-/usr/local/bin}"

# 删掉"遮住真程序的桩"。与 e2e_stub_uninstall 的分工:
#   · e2e_stub_uninstall 按"内容里写着本轮 $E2E_TMP"认, 只认得出**自己这一轮**造的;
#   · 这个要认出**别的脚本上一轮留下的**, 那些桩里没有本轮路径可比对, 所以改用所有权标记。
#
# 只处理显式传进来的 allowlist。判据:
#   符号链接 → 目标在 /usr/local/bin 内 = 测试搭的还原链(restore_py 那种) → unlink;
#              **只 unlink 链接本身, 绝不跟随删目标**; 指向别处的是用户的安装, 不碰。
#   普通文件 → 必须含 $E2E_STUB_MARK, 或与已知的历史桩形态逐字节相同(见 _e2e_legacy_stub)。
#   其它类型 / 有标记之外的同名真文件 → **fail-closed**: 报出来并返回非零, 不静默继续。
_e2e_legacy_stub(){
  # 打标记之前就存在的两种桩形态。留这一层是为了"从旧现场升上来"也能清干净 ——
  # 否则升级那天残留的桩仍然没人认领, 而它正是这一整条 bug 的起点。
  local f="$1"
  head -1 "$f" 2>/dev/null | grep -qE '^#!/bin/(sh|bash)$' || return 1
  grep -qE 'ip -4|scope global|inet [0-9]' "$f" 2>/dev/null && return 0    # 老的 ip 桩
  grep -qE 'py3-real|python3' "$f" 2>/dev/null && return 0                 # 老的 python3 桩
  return 1
}

e2e_purge_shadow_stub(){
  local n f rc=0
  for n in "$@"; do
    f="$E2E_SHADOW_BIN/$n"
    [[ -e "$f" || -L "$f" ]] || continue              # 不存在 = 已经干净, 幂等
    if [[ -L "$f" ]]; then
      if [[ "$(readlink "$f")" == "$E2E_SHADOW_BIN"/* ]]; then
        rm -f "$f" 2>/dev/null || true                # 只删链接, 目标不动
      fi
      continue
    fi
    if [[ ! -f "$f" ]]; then
      echo "[FAIL] $f 既不是普通文件也不是符号链接 —— 拒绝处理(fail-closed)" >&2
      rc=1; continue
    fi
    if grep -qF -- "$E2E_STUB_MARK" "$f" 2>/dev/null || _e2e_legacy_stub "$f"; then
      rm -f "$f" 2>/dev/null || true
      continue
    fi
    # 同名、但证明不了是我们的 —— 这就是"未知 shadow binary"。它会遮住系统命令,
    # 让后面每一支测试都在一个说不清的 PATH 上跑; 静默沿用比删错更危险。
    echo "[FAIL] $f 不是受管测试桩(没有 $E2E_STUB_MARK) —— 不删, 也不能带着它继续" >&2
    rc=1
  done
  return $rc
}


# 把机器清回"什么都没装过"的状态。namespace 模式下 overlay 本来就干净, 这里主要给容器模式
# (CI 里多个脚本共用一个容器)用: 二进制、unit、归属/后端标记、快照、仓库副本、服务桩一个不留。
# 只按**本轮登记的 PID** 回收 witness 假 unit 起的真进程。不用 pkill -f, 不碰
# 任何别的占 5399 的进程 —— 那可能是宿主上别人的东西。
e2e_dw_reap(){
  # 登记表刻意放在 $E2E_TMP **之外**: 临时目录清理钩子会把它整个删掉, 登记表放里面就
  # 会被孤儿化 —— 回收函数读不到 pid, 进程活到下一段落, 后续 pdg 撞全局锁一路连锁失败。
  local pid
  if [ -f /run/pdg-e2e-dw.pid ]; then
    pid="$(cat /run/pdg-e2e-dw.pid 2>/dev/null)"
    if [ -n "$pid" ]; then
      kill "$pid" 2>/dev/null
      local i=0; while [ $i -lt 40 ] && kill -0 "$pid" 2>/dev/null; do i=$((i+1)); sleep 0.05; done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
    fi
    rm -f /run/pdg-e2e-dw.pid
  fi
  [ -f /run/pdg-e2e-dw.rundir ] && {
    rm -rf "$(cat /run/pdg-e2e-dw.rundir 2>/dev/null)"; rm -f /run/pdg-e2e-dw.rundir; }
  rm -f /run/pdg-e2e-dw.log
  return 0
}

e2e_reset_box(){
  # **必须是第一句**: 下面紧接着就 `systemctl disable --now …`, 而 /usr/local/bin 排在
  # PATH 前面 —— 上一支留下的桩会在这里被调到。先把影子桩撤掉, 再动任何 PATH 命令。
  e2e_purge_shadow_stub ip python3 py3-real || return 1
  e2e_dw_reap
  systemctl disable --now pdg-bot pdg-probe81 pdg-mitm mosdns mihomo sing-box \
                          pdg-rescue.socket pdg-rescue.service >/dev/null 2>&1 || true
  # sing-box 是**必须**清掉的那个: 装机会把来源不明的 sing-box 判成第三方冲突而中止,
  # 跨版本回滚用例正好留一份在这。mihomo / mosdns 反过来要**留着** —— 它们是从网上下的
  # 真内核(几十 MB), 每个脚本重下一遍既慢又会在没网时把用例整条 skip 掉(假绿)。
  rm -f /usr/local/bin/sing-box \
        /usr/local/bin/pdg /usr/local/bin/pdg-set-token \
        /usr/local/bin/proxy-gateway-open-cert-http.sh \
        /usr/local/bin/proxy-gateway-restore-firewall.sh 2>/dev/null || true
  # 救援平面那两个 unit 一定要在这里删掉。容器模式下多个脚本共用一个 /etc: 前一个脚本
  # (或前一个 case)把救援平面开起来, 留下的 socket unit 会被后面那个当成"机器上本来就有",
  # 于是"不该启用却装了 socket unit"这类断言凭空转红, 而红的原因与被测对象毫无关系。
  # namespace 模式每次都是新 overlay, 所以这个洞一直没露头, 只有 CI 的容器模式会踩到。
  rm -f /etc/systemd/system/{pdg-bot,pdg-probe81,pdg-mitm,mosdns,mihomo,sing-box,pdg-rules-update,pdg-health}.service \
        /etc/systemd/system/pdg-rescue.socket /etc/systemd/system/pdg-rescue.service \
        /run/systemd/system/pdg-rescue.socket /run/systemd/system/pdg-rescue.service \
        /etc/systemd/system/{pdg-rules-update,pdg-health}.timer \
        /etc/systemd/journald.conf.d/50-pdg.conf 2>/dev/null || true
  rm -rf /etc/privdns-gateway /etc/mosdns /etc/mihomo /etc/sing-box /opt/pdg-bot \
         /opt/privdns-gateway /var/lib/privdns-gateway 2>/dev/null || true
  rm -f /etc/nftables.conf.pdg-orig /etc/resolv.conf.pdg-orig 2>/dev/null || true
  # 桩的状态、假规则集、调用日志、各脚本造的裸库 —— 全在 $E2E_TMP 里。
  # 这里仍按名字逐个清而不是 rm -rf "$E2E_TMP": 进场重置发生在脚本**中途**(容器模式下
  # 每个 case 前都会调), 那时探针脚本、pycache 目录等本轮的东西正放在同一个目录里,
  # 一锅端会把它们一起删掉。整个目录的清理归退出钩子。
  rm -rf "$E2E_TMP/e2e-svc" "$E2E_TMP/e2e-nft-ruleset" "$E2E_TMP/e2e-calls.log" \
         "$E2E_TMP/e2e-inject" "$E2E_TMP/e2e-origin.git" "$E2E_TMP/e2e-xver-origin.git" \
         "$E2E_TMP/e2e-cli-origin.git" "$E2E_TMP/e2e-empty-origin.git" 2>/dev/null || true
  # 前一个脚本装的**桩命令**同样是"上一个脚本留下的状态": e2e-install 会留一个假 curl
  # (下载什么都写 "stub" 几个字节), 下一个脚本想取真内核时就只能拿到一个坏档而整条 skip。
  # 每个脚本都会自己造它需要的桩(e2e_stub_system / 各自的 setup), 进场清掉是安全的。
  rm -f /usr/local/bin/{systemctl,nft,curl,tcpdump,apt-get,dpkg,certbot,vnstat,ss,tar} 2>/dev/null || true
  # `ip` / `python3` 不能跟着上面按名字删 —— 真机上它们很可能是用户自己装的真程序。
  # 但它们**确实会**以桩的形态泄漏过来, 而且都不是"上一支正常退出就没事"那种:
  #   · e2e-rescue-migration-lock.sh 造 `ip` 桩(伪造 `ip -4` 的地址列表), 且它**根本没有
  #     任何清理** —— 每跑一次必留;
  #   · e2e-install-nft.sh 用 restore_py 还原 `python3`, 但那只挂在两个正常路径上,
  #     异常退出就留下一个指向 py3-real 的符号链接(py3-real 后来又被别处清掉 → 悬空)。
  # 留着 `ip` 桩的后果不是"某支测试红一下": 它让装机把本机地址看成落在内网段里, 于是
  # 救援平面被自动启用并写下 PDG_RESCUE_BIND, 而沙箱 nft 里没有对应放行 —— 下一支
  # e2e-update.sh 的更新后自检就正确地判红并整次回滚。查起来完全指不到这里。
  # 判据换成"看起来就是我们的桩": 指向 /usr/local/bin 内部的符号链接, 或者小于 4KiB 的
  # 脚本(带 #! 开头)。真的 ip / python3 是 ELF, 两条都不沾。
  # 真内核二进制留着(几十 MB, 每个脚本重下一遍既慢又会在没网时把用例整条 skip 成假绿);
  # 但**桩**版本要清 —— 拿 `-t` 恒 0 的假 mihomo 当内核, 配置校验类用例会静默失效。
  if command -v mihomo >/dev/null 2>&1 && ! e2e_mihomo_is_real; then
    rm -f /usr/local/bin/mihomo 2>/dev/null || true
  fi
  if [[ -f /usr/local/bin/mosdns ]] && [[ "$(stat -c %s /usr/local/bin/mosdns 2>/dev/null || echo 0)" -lt 1000000 ]]; then
    rm -f /usr/local/bin/mosdns 2>/dev/null || true      # 小于 1MB = 桩, 不是真 mosdns
  fi
  mkdir -p /var/lib/privdns-gateway /etc/mosdns/rules /etc/sing-box /etc/mihomo \
           /etc/privdns-gateway /etc/systemd/system /etc/systemd/journald.conf.d \
           "$E2E_TMP/e2e-svc" 2>/dev/null || true
  : > /etc/nftables.conf
  # 清 bash 的命令哈希: 上面刚跑过 mihomo(能力探测)又把它删了, 不清的话后续 `command -v mihomo`
  # 仍会命中缓存里的旧路径, 于是"没有就造个桩"的分支被跳过, 装机改走下载 → 撞上假 curl → SHA 失败。
  hash -r 2>/dev/null || true
}

# ── 一次性沙箱的硬门 ────────────────────────────────────────────────────────
# 为什么需要它: `PDG_E2E_ISOLATED=1` + root 时脚本直接跑在当前容器根上, 而 CI 与本地都会把
# 仓库以**可写**方式挂进去。于是一次失败的 `cd`、一个写错的 `rm -rf`、一句 `git reset`,
# 打的就是开发者的真仓库 —— 这不是假设: 本分支上真的因此多出过一个 author 为 t<t@t> 的
# "base" 提交、origin 被换成 /tmp 里的裸库、还打了个 v9.9.9 标签。
#
# `PDG_E2E_ISOLATED=1` 只是调用方的一句声明, 它不证明任何事, 因此不能再当作安全依据。
# 真正的依据是: 目标路径经 realpath 解析后, 确实位于一个**本轮创建、带 nonce 标记**的
# 一次性根之内。所有破坏性操作都必须先过 e2e_guard_path。
E2E_NONCE=""          # 本轮随机串, 写进 marker; 换一轮就对不上
E2E_SANDBOX=""        # 已验证的一次性根(realpath 后的绝对路径)

e2e_sandbox_init(){
  local root="$1"
  [[ -n "$root" ]] || { echo "[FAIL] 沙箱根为空"; return 1; }
  mkdir -p "$root" 2>/dev/null || { echo "[FAIL] 建不了沙箱根: $root"; return 1; }
  E2E_NONCE="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  [[ ${#E2E_NONCE} -ge 16 ]] || { echo "[FAIL] 取不到随机 nonce"; return 1; }
  local rp; rp="$(realpath -e "$root" 2>/dev/null)" || { echo "[FAIL] realpath 失败: $root"; return 1; }
  printf '%s %s\n' "$E2E_NONCE" "$$" > "$rp/.e2e-disposable" || return 1
  chmod 600 "$rp/.e2e-disposable" || return 1
  E2E_SANDBOX="$rp"
  return 0
}

# 判一个路径能不能当破坏性操作的目标。任何一条不满足立即返回非 0 —— 在动手之前。
e2e_guard_path(){
  local p="$1" why=""
  [[ -n "$p" ]]        || why="路径为空"
  [[ "$p" == /* ]]     || why="${why:-不是绝对路径}"
  local rp=""
  if [[ -z "$why" ]]; then
    # -m: 目标可以还不存在(比如要创建的子目录), 但它的解析结果必须落在沙箱内。
    rp="$(realpath -m "$p" 2>/dev/null)" || why="realpath 失败"
  fi
  if [[ -z "$why" ]]; then
    case "$rp" in
      /) why="目标是根目录";;
      /root|/home|/usr|/etc|/var|/opt|/boot) why="目标是系统目录 $rp";;
    esac
  fi
  # 仓库本体、仓库父目录、CI 工作区一律不许当目标 —— 这正是那次事故打中的地方。
  if [[ -z "$why" ]]; then
    local repo; repo="$(realpath -m "${E2E_ROOT:-/nonexistent}" 2>/dev/null)"
    local parent; parent="$(dirname "$repo")"
    local ws; ws="$(realpath -m "${GITHUB_WORKSPACE:-/nonexistent}" 2>/dev/null)"
    [[ "$rp" == "$repo" || "$rp" == "$repo"/* ]] && why="目标在源码仓库内: $rp"
    [[ -z "$why" && "$rp" == "$parent" ]] && why="目标是仓库父目录: $rp"
    [[ -z "$why" && -n "$ws" && "$ws" != /nonexistent && ( "$rp" == "$ws" || "$rp" == "$ws"/* ) ]] \
      && why="目标在 GITHUB_WORKSPACE 内: $rp"
  fi
  # 必须落在**已验证**的一次性根内, 且该根的 marker 与本轮 nonce 相符。
  if [[ -z "$why" ]]; then
    [[ -n "$E2E_SANDBOX" ]] || why="沙箱未初始化(e2e_sandbox_init 没跑)"
  fi
  if [[ -z "$why" ]]; then
    [[ "$rp" == "$E2E_SANDBOX" || "$rp" == "$E2E_SANDBOX"/* ]] || why="目标在沙箱之外: $rp"
  fi
  if [[ -z "$why" ]]; then
    local m="$E2E_SANDBOX/.e2e-disposable"
    [[ -f "$m" ]] || why="沙箱 marker 不存在"
    [[ -z "$why" && "$(cut -d' ' -f1 "$m" 2>/dev/null)" == "$E2E_NONCE" ]] || why="${why:-marker nonce 不匹配}"
  fi
  [[ -z "$why" ]] && return 0
  echo "[FAIL] 拒绝对 $p 执行破坏性操作: $why" >&2
  return 1
}

# 唯一允许的递归删除入口 —— 判据只有这一份, 各脚本不得自己抄一遍。
e2e_rm_rf(){
  local p
  for p in "$@"; do
    e2e_guard_path "$p" || return 1
    rm -rf -- "$p" || return 1
  done
  return 0
}

# 退出钩子沿用下面既有的 e2e_add_exit_hook(注册函数名、幂等、保持原退出码), 不另起一套。

# ── 留现场开关 ──────────────────────────────────────────────────────────────
# 用例红了的时候, 最想看的恰恰是它刚建的那堆临时物。清理做得越干净, 排查越没东西可看,
# 所以给一个明确的口子: PDG_KEEP_TMP=1(或任意非空非 0 值)时一个都不清, 并把路径打出来。
# 默认清 —— "默认留着, 想清再说"那种设计就是 /tmp 里堆一天几十个目录的由来。
e2e_keep_tmp(){ [[ -n "${PDG_KEEP_TMP:-}" && "${PDG_KEEP_TMP}" != "0" ]]; }

# 撤掉**指向本轮 $E2E_TMP** 的桩命令。只认里面真的写着本轮路径的那些, 别人的桩不碰。
#
# 为什么必须在删沙箱之前做: 容器模式下多个脚本顺序跑, /usr/local/bin 是共用的。前一个脚本
# 退出时把自己的沙箱删了, 桩却还留在 PATH 上 —— 下一个脚本进场 e2e_reset_box 第一句就是
# `systemctl disable --now …`, 调到的正是那个旧桩, 而它头一件事是 `mkdir -p "$D"`,
# 于是刚删掉的目录又被建回来。实测: e2e-serial-hermetic 跑完 3 支, /tmp 里剩下前两支的
# 沙箱根, 每个里面孤零零一个 tmp/e2e-svc。
e2e_stub_uninstall(){
  [[ -n "$E2E_TMP" ]] || return 0
  local f
  for f in /usr/local/bin/systemctl /usr/local/bin/nft; do
    [[ -f "$f" ]] && grep -qF -- "$E2E_TMP" "$f" 2>/dev/null && rm -f "$f"
  done
  # 影子桩同样在退出时主动清 —— "反正下一支进场会清"是不成立的: serial 的**最后一支**
  # 后面没有下一支, 桩就留在容器里跑到下一个 job。
  e2e_purge_shadow_stub ip python3 py3-real || true
  return 0
}

# 收尾: 只删自己建的一次性根, 且要再过一遍 realpath + marker + nonce —— 中途被换掉的话
# 这一步会拒绝, 而不是照删。
e2e_sandbox_cleanup(){
  [[ -n "$E2E_SANDBOX" ]] || return 0
  if e2e_keep_tmp; then
    echo "[PDG_KEEP_TMP] 保留沙箱: $E2E_SANDBOX" >&2
    return 0
  fi
  e2e_stub_uninstall
  e2e_rm_rf "$E2E_SANDBOX" 2>/dev/null || true
}

# ── 本轮的临时物 ────────────────────────────────────────────────────────────
# 各脚本的中间文件(命令输出、桩的状态目录、假 nft 规则集…)以前一律写死 /tmp/e2e-* 之类:
#   · 跑完没人清 —— 一天下来 /tmp 里堆一批;
#   · 写死路径 = 同时跑的两个脚本共用同一份状态, 互相踩(桩的 svcstate 尤其致命)。
# 现在统一落进本轮自己的 $E2E_TMP, 随一次性根一起消失。TMPDIR 也指过去, 于是脚本里的
# `mktemp` 和子进程(python 的 tempfile)不必逐个改也会落在里面。
#
# **不按前缀扫 /tmp 删**: 并发跑测试时那删的是别人正在用的沙箱, 症状还是"另一支测试莫名
# 其妙红了"。只清本轮登记的这一个根, 是唯一安全的依据。
E2E_TMP=""

e2e_tmp_init(){
  [[ -n "$E2E_TMP" && -d "$E2E_TMP" ]] && return 0            # 幂等
  if [[ -n "$E2E_SANDBOX" ]]; then
    E2E_TMP="$E2E_SANDBOX/tmp"                                # 随一次性根一起被清
  else
    # 没走 e2e_enter 的脚本(如 e2e-rescue-10b.sh)也要能用, 那就自己建自己清。
    E2E_TMP="$(mktemp -d "${TMPDIR:-/tmp}/e2e-tmp.XXXXXX")" || return 1
    e2e_add_exit_hook e2e_dw_reap
    e2e_add_exit_hook e2e_tmp_cleanup
  fi
  mkdir -p "$E2E_TMP" || return 1
  export E2E_TMP
  export TMPDIR="$E2E_TMP"
  return 0
}

e2e_tmp_cleanup(){
  [[ -n "$E2E_TMP" ]] || return 0
  if e2e_keep_tmp; then
    echo "[PDG_KEEP_TMP] 保留临时目录: $E2E_TMP" >&2
    return 0
  fi
  rm -rf -- "$E2E_TMP"
  return 0
}

# 重入 namespace: 外层建 overlay 目录并 unshare, 内层挂载
e2e_enter(){
  # 已经身处一次性隔离环境且是 root(CI 的容器 job) → 直接跑, 不必再自建 namespace。
  # GitHub runner(ubuntu-24.04)用 AppArmor 禁掉了非特权用户命名空间, unshare -rm 不可用,
  # 所以 CI 走容器这条路; 本地开发机则走 namespace, 两边跑的是同一份测试主体。
  if [[ "${PDG_E2E_ISOLATED:-}" == 1 && "$(id -u)" == 0 ]]; then
    # 容器是一次性的, 但**同一个容器里顺序跑多个脚本**时它并不是一次性的: 前一个脚本留下的
    # /usr/local/bin/sing-box 会让下一个脚本的装机路径判成"机器上已有第三方 sing-box"而中止。
    # 进场先把现场清干净 —— 每个 E2E 都必须自带完整前提, 不许指望上一个脚本留下的状态。
    # 容器由 CI 一次性创建, 但"一次性"这件事必须由本进程自己证明: 建一个带本轮 nonce 的
    # 一次性根并记下来, 之后所有破坏性操作都要落在它之内(见 e2e_guard_path)。
    e2e_sandbox_init "${E2E_DISPOSABLE:-/tmp/e2e-box.$$}" || exit 1
    e2e_add_exit_hook e2e_dw_reap        # 最先注册: 真进程回收要先于沙箱拆除
    e2e_add_exit_hook e2e_sandbox_cleanup
    e2e_tmp_init || exit 1                 # e2e_reset_box 已经要用 $E2E_TMP, 必须先于它
    e2e_reset_box
    _e2e_git_safe
    return 0
  fi
  if [[ "${PDG_E2E_INNER:-}" == 1 ]]; then
    e2e_sandbox_init "${E2E_OVL:-/tmp/e2e-inner.$$}" || exit 1
    e2e_tmp_init || exit 1
    mount -t overlay overlay -o "lowerdir=/etc,upperdir=$E2E_OVL/eu,workdir=$E2E_OVL/ew" /etc \
      || { echo "[SKIP] overlay /etc 挂不上"; exit 0; }
    mount -t overlay overlay -o "lowerdir=/usr/local/bin,upperdir=$E2E_OVL/bu,workdir=$E2E_OVL/bw" /usr/local/bin
    mount -t overlay overlay -o "lowerdir=/opt,upperdir=$E2E_OVL/ou,workdir=$E2E_OVL/ow" /opt
    mount -t tmpfs tmpfs /run 2>/dev/null || true            # pdg 的 flock 落在 /run(宿主归真 root)
    # 快照目录在 /var/lib/privdns-gateway; 宿主 /var/lib 归真 root, 不覆盖就建不了快照,
    # 而"快照失败即中止更新"是有意设计 → 不覆盖的话整条 update 路径根本走不到。
    mount -t overlay overlay -o "lowerdir=/var/lib,upperdir=$E2E_OVL/vu,workdir=$E2E_OVL/vw" /var/lib \
      2>/dev/null || mount -t tmpfs tmpfs /var/lib 2>/dev/null || true
    mkdir -p /var/lib/privdns-gateway 2>/dev/null || true
    _e2e_git_safe
    return 0
  fi
  unshare -rm true 2>/dev/null || e2e_skip "本环境不支持 unshare -rm(需用户+挂载命名空间)"
  E2E_OVL="$(mktemp -d)"
  e2e_sandbox_init "$E2E_OVL" || exit 1
  # 宿主 /etc 里归真 root 的路径在 userns 里映射成 nobody, 改不动 → 先在 upperdir 里建好(归本人)
  mkdir -p "$E2E_OVL"/{eu,ew,bu,bw,ou,ow,vu,vw}
  mkdir -p "$E2E_OVL"/eu/{mosdns/rules,sing-box,mihomo,privdns-gateway,systemd/system,systemd/journald.conf.d}
  : > "$E2E_OVL"/eu/nftables.conf
  local rc=0
  PDG_E2E_INNER=1 E2E_OVL="$E2E_OVL" E2E_ROOT="$E2E_ROOT" \
    unshare -rm bash "$0" "$@" || rc=$?
  # overlay 的 workdir 归 namespace 内的 root, 外层删不掉 → 再进一次 namespace 清理。
  # 内层的 $E2E_TMP 就在这个根里面, 所以这一句同时是它的清理; 留现场时两个一起留。
  if e2e_keep_tmp; then
    echo "[PDG_KEEP_TMP] 保留沙箱: $E2E_OVL(临时物在 $E2E_OVL/tmp)" >&2
  else
    unshare -rm bash -c 'rm -rf "$1"' _ "$E2E_OVL" 2>/dev/null || rm -rf "$E2E_OVL" 2>/dev/null
  fi
  exit "$rc"
}

# ── 打桩: 沙盒里没有 systemd / netlink ──────────────────────────────────────
# 配置事务的硬门探针落点(本地 DNS 应答 + 内核 redir 端口)。沙箱里 mosdns/mihomo 是桩,
# 真端口上没人听, 而事务的基线门要求"本次要动的组件操作前是好的" —— 那条判据**不该为了测试
# 而关掉**, 所以这里起真的 socket 顶上, 并把探针落点告诉事务核心(判据本身一行没改)。
# 端口动态选取: 多个 E2E 在同一台机器上先后跑, 写死端口会互相占用。
# ── 退出清理 hook(最小实现) ──────────────────────────────────────────────────
# 各 E2E 脚本自己也要注册清理(e2e-install.sh 的 restore_resolv 就是)。如果谁都直接
# `trap ... EXIT`, 后设置的会把前面的顶掉。这里只做够用的那一点: 注册**已定义的函数名**,
# 由统一的 EXIT/INT/TERM/HUP 处理器逐个尽力执行, 且保持原退出码。
E2E_EXIT_HOOKS=""
E2E_HOOKS_RUNNING=""

e2e_add_exit_hook(){
  local fn="$1"
  declare -F "$fn" >/dev/null || { echo "[!] e2e_add_exit_hook: 没有这个函数: $fn" >&2; return 1; }
  case " $E2E_EXIT_HOOKS " in *" $fn "*) return 0;; esac      # 幂等
  E2E_EXIT_HOOKS="${E2E_EXIT_HOOKS:+$E2E_EXIT_HOOKS }$fn"
  trap 'e2e_run_exit_hooks $?' EXIT
  trap 'e2e_run_exit_hooks 130; exit 130' INT
  trap 'e2e_run_exit_hooks 143; exit 143' TERM
  trap 'e2e_run_exit_hooks 129; exit 129' HUP
  return 0
}

e2e_run_exit_hooks(){
  local rc="${1:-0}" fn
  [[ -n "$E2E_HOOKS_RUNNING" ]] && return "$rc"               # 不递归
  E2E_HOOKS_RUNNING=1
  for fn in $E2E_EXIT_HOOKS; do
    declare -F "$fn" >/dev/null && { "$fn" || true; }          # 清理失败不掩盖原始失败
  done
  return "$rc"
}

# ── 负控用的字节码缓存隔离 ──────────────────────────────────────────────────
# 负控要在同一秒内"把源码改坏 → 跑 → 恢复 → 再跑"。CPython 默认的 __pycache__ 用**秒级
# 时间戳 + 文件长度**判定源码是否变过: 同一秒内改成等长内容, 判据完全命中旧记录, 于是跑的
# 是上一版字节码 —— 负控"通过"了, 而它验的其实是没被改过的旧代码。真踩过一次: 恢复源码后
# 测试仍然失败, 因为读的是负控那一版的 .pyc。
#
# 解法不是"记得手动清缓存", 而是让每次负控子进程都用**本实例独有且为空**的缓存目录:
#   e2e_pycache_isolate      建目录 + 导出 PYTHONPYCACHEPREFIX + 注册退出清理(只删这一个目录)
#   e2e_pycache_reset        清空它(每跑一次负控调一次, 保证"空")
E2E_PYCACHE_DIR=""

e2e_pycache_isolate(){
  [[ -n "$E2E_PYCACHE_DIR" ]] && return 0                  # 幂等
  E2E_PYCACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/e2e-pycache.XXXXXX")" || return 1
  export PYTHONPYCACHEPREFIX="$E2E_PYCACHE_DIR"
  e2e_add_exit_hook e2e_pycache_cleanup
  return 0
}

e2e_pycache_reset(){
  [[ -n "$E2E_PYCACHE_DIR" && -d "$E2E_PYCACHE_DIR" ]] || return 0
  # 只删本实例这一个目录的内容, 再原样建回来 —— 不碰仓库里的 __pycache__, 不用宽泛 find
  rm -rf -- "$E2E_PYCACHE_DIR"
  mkdir -p -- "$E2E_PYCACHE_DIR"
}

e2e_pycache_cleanup(){
  [[ -n "$E2E_PYCACHE_DIR" ]] && rm -rf -- "$E2E_PYCACHE_DIR"
  E2E_PYCACHE_DIR=""
  unset PYTHONPYCACHEPREFIX
  return 0
}

# ── 事务硬门探针的生命周期 ──────────────────────────────────────────────────
# 旧实现 `setsid python3 /tmp/e2e-tx-probe.py … &` 既不记 PID 也不清理: 每个 E2E 都留一个
# PPID=1 的孤儿(e2e-install.sh 里多次 e2e_stub_system 就留多个), 它们还持有已删除的 overlay
# 文件 —— 跑几轮就把磁盘占满, 只能人工 kill 才能继续。
E2E_TX_PROBE_PID=""
E2E_TX_PROBE_SCRIPT=""
E2E_TX_PROBE_PORTS=""

# 这个 PID 现在还是"本实例的探针"吗(PID 复用后别误杀别的进程)
_e2e_probe_is_mine(){
  local pid="$1" cl
  [[ -n "$pid" && -n "$E2E_TX_PROBE_SCRIPT" && -r "/proc/$pid/cmdline" ]] || return 1
  cl="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)"
  [[ "$cl" == *"$E2E_TX_PROBE_SCRIPT"* && "$cl" == *"$E2E_TX_PROBE_PORTS"* ]]
}

# ── 「本次操作新增了哪个目录」──────────────────────────────────────────────────
# 事务目录名是 `%Y%m%dT%H%M%S.mmmZ-<uuid4 前 8 位>`, 快照目录是 `%Y%m%d-%H%M%S` —— 两者
# 都可能在同一时刻出现多笔, 所以**不能**按名字排序去猜"最新的那个": 上一个小节留下的与本次
# 产生的落在同一时刻时, 谁排在后面纯看运气。
#
# 这不是假设出来的风险。e2e-hijack-mode-tx.sh 因此间歇性红了一个多星期(约 6%, 最早可追到
# 2026-08-02): 断言读到的是上一小节留下的 ABORTED, 而本次那笔其实是 ROLLBACK_FAILED ——
# 状态读的是别人的, 而且看起来像产品出了随机故障。
#
# 改成记差集: 被测命令调用前后各取一次目录集合, 新增的那一笔才是本次要断言的对象。
# 顺带把"一次操作只应产生一笔"变成硬门 —— 0 笔或多笔都判红, 而不是默默挑一个。
# 逻辑只此一份: 三支 e2e(hijack-mode-tx / cli-ops / snapshot-meta)共用它, 不各抄一遍。
_e2e_dirlist(){ find "$1" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort; }
e2e_dirset_mark(){ _E2E_DIRSET_ROOT="$1"; _E2E_DIRSET_BEFORE="$(_e2e_dirlist "$1")"; }
e2e_dirset_created(){          # $1=场景名; 打印本次新增的那一个目录, 恰好 1 个才返回 0
  local nm="$1" now new n
  now="$(_e2e_dirlist "$_E2E_DIRSET_ROOT")"
  new="$(comm -13 <(printf '%s\n' "$_E2E_DIRSET_BEFORE") <(printf '%s\n' "$now"))"
  n="$(grep -c . <<<"$new")"
  if [[ "$n" == 1 ]]; then printf '%s\n' "$new"; return 0; fi
  if [[ "$n" == 0 ]]; then bad "$nm: 本次操作没有新增目录(应恰好 1 个)"; return 1; fi
  bad "$nm: 本次操作新增了 $n 个目录(应恰好 1 个): $(xargs -r -n1 basename <<<"$new" | tr '\n' ' ')"
  return 1
}

# ── nft 桩: 全仓唯一实现 ─────────────────────────────────────────────────────
# 以前 e2e 里的 nft 桩是 `echo …; exit 0` —— 对 `nft -j list table inet pdg` 什么都不返回,
# 而 nftlive 读的正是那个。它按设计 fail-closed(读不到内核 = 不知道现在放行了什么, 绝不
# 当成没问题), 于是更新后自检判红、整次 update 回滚: 测出来的是桩的病, 而排查时最顺手的
# "修法"恰恰是最坏的 —— 把 fail-closed 降成 WARN。所以桩得做真。
#
#   -f FILE            装载: 把内容记成当前"内核状态"
#   list …             文本查询: 回放状态(去掉注释 —— 真 nft 不会把配置注释吐回来)
#   -j list table F T  JSON 查询: 由**当前状态**转换而来, 见 tests/nftjson.py
#                      表不在就非零退出, 绝不返回一个"看着健康"的空壳
#   -c                 只校验, 不改状态
#
# 为什么提成函数: e2e-custom-nft / e2e-install-nft / e2e-platform-switch 过去各带一份
# **私有的简化桩**, 三份全都没有 `-j` 分支 —— 被测路径一旦走到 nftlive, 桩就静默返回空,
# 正是上面这段拼命要避免的"看着健康的空壳", 而且它不会报错, 只会让断言读到一个空表。
# 转换逻辑只此一份(nftjson.py), 桩本身也只此一份。
# 固定写 /usr/local/bin/nft —— 三处调用点都是这个路径。不留"写到哪"的参数: 桩的位置
# 一旦可变, 就会出现"装了两份桩、生效的是另一份"这种极难查的现场。
e2e_write_nft_stub(){
  local out=/usr/local/bin/nft
  cp "$E2E_ROOT/tests/nftjson.py" /usr/local/bin/pdg-nftjson.py 2>/dev/null || true
  { printf '#!/bin/sh\nSTATE=%s/e2e-nft-ruleset\nCALLS=%s/e2e-calls.log\n' "$E2E_TMP" "$E2E_TMP"
    cat <<'S'
echo "nft $*" >> "$CALLS"
if [ "$1" = "-j" ]; then
  # -j list table <family> <name>
  fam="$4"; tab="$5"
  [ -s "$STATE" ] || { echo "Error: No such file or directory" >&2; exit 1; }
  exec python3 /usr/local/bin/pdg-nftjson.py "${fam:-inet}" "${tab:-pdg}" < "$STATE"
fi
case "$1" in
  -c) exit 0 ;;
  -f) [ -f "$2" ] && cat "$2" > "$STATE"; exit 0 ;;
  list) sed -e 's/#.*$//' "$STATE" 2>/dev/null | grep -v '^[[:space:]]*$'; exit 0 ;;
  delete) : > "$STATE"; exit 0 ;;
esac
exit 0
S
  } > "$out"
  chmod 755 "$out"
  : > "$E2E_TMP/e2e-nft-ruleset"
}

e2e_tx_probe_stop(){
  local pid="$E2E_TX_PROBE_PID" n=0
  if [[ -n "$pid" ]] && _e2e_probe_is_mine "$pid"; then
    kill -TERM "$pid" 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null && [[ "$n" -lt 30 ]]; do sleep 0.1; n=$((n+1)); done
    if kill -0 "$pid" 2>/dev/null && _e2e_probe_is_mine "$pid"; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
  fi
  # 不管上面走没走到, 都要 wait 回收(它是本 shell 的子进程; 已退出/已回收时 wait 直接返回)
  [[ -n "$pid" ]] && { wait "$pid" 2>/dev/null || true; }
  [[ -n "$E2E_TX_PROBE_SCRIPT" ]] && rm -f "$E2E_TX_PROBE_SCRIPT"
  [[ -n "$E2E_TX_PROBE_PORTS" ]] && rm -f "$E2E_TX_PROBE_PORTS"
  E2E_TX_PROBE_PID=""; E2E_TX_PROBE_SCRIPT=""; E2E_TX_PROBE_PORTS=""
  return 0
}

e2e_tx_probes(){
  e2e_tx_probe_stop                       # 同一脚本里重复初始化: 先收掉上一个, 不累计
  e2e_add_exit_hook e2e_tx_probe_stop     # 正常/失败/信号退出都会清
  local ps pf
  # 临时文件跟随 TMPDIR: 并发 E2E 各自一份, 用例也能把它们圈进自己的目录里精确计数
  local tdir="${TMPDIR:-/tmp}"
  ps="$(mktemp "$tdir/e2e-tx-probe.XXXXXX.py")" || return 1
  pf="$(mktemp "$tdir/e2e-tx-probe.XXXXXX.ports")" || { rm -f "$ps"; return 1; }
  E2E_TX_PROBE_SCRIPT="$ps"; E2E_TX_PROBE_PORTS="$pf"
  : > "$pf"
  # 脚本先落盘再起 —— `python3 - <<EOF &` 拿不到 stdin(会被脱开), 探针根本跑不起来。
  # 不再 setsid: 探针只有一个进程, 留在本 shell 的进程组里才能被 wait 回收。
  cat > "$ps" <<'PY'
import os, socket, sys, threading
u = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); u.bind(("127.0.0.1", 0))
t = socket.socket(); t.bind(("127.0.0.1", 0)); t.listen(16)
d = socket.socket(); d.bind(("127.0.0.1", 0)); d.listen(16)      # DoT(853)替身
# 端口文件**原子写**: 父脚本靠"非空且三个合法端口"判就绪, 半行内容会让它误判
tmp = sys.argv[1] + ".tmp"
with open(tmp, "w") as f:
    f.write("%d %d %d\n" % (u.getsockname()[1], t.getsockname()[1], d.getsockname()[1]))
    f.flush(); os.fsync(f.fileno())
os.replace(tmp, sys.argv[1])
threading.Thread(target=lambda: [d.accept()[0].close() for _ in iter(int, 1)],
                 daemon=True).start()
def dns():
    while True:
        try:
            data, a = u.recvfrom(512); u.sendto(data[:2] + b"\x81\x83" + data[4:12], a)
        except OSError:
            return
threading.Thread(target=dns, daemon=True).start()
while True:
    try:
        c, _ = t.accept(); c.close()
    except OSError:
        break
PY
  python3 "$ps" "$pf" >/dev/null 2>&1 &
  E2E_TX_PROBE_PID=$!
  local n=0 ports=""
  while [[ "$n" -lt 40 ]]; do
    if [[ -s "$pf" ]]; then
      ports="$(cat "$pf")"
      # 三个十进制端口才算就绪(挡住"文件已建、内容没写完"的中间态)
      [[ "$ports" =~ ^[0-9]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+$ ]] && break
      ports=""
    fi
    kill -0 "$E2E_TX_PROBE_PID" 2>/dev/null || break         # 探针自己死了, 不白等
    sleep 0.1; n=$((n+1))
  done
  if [[ -z "$ports" ]]; then
    e2e_tx_probe_stop                     # 超时/启动失败: 停 + wait + 删临时文件, 不留残骸
    return 1
  fi
  # shellcheck disable=SC2086
  set -- $ports
  export PDG_TX_DNS_PROBE="127.0.0.1:$1"
  export PDG_TX_REDIR_PORT="$2"
  export PDG_TX_DOT_PORT="$3"
  return 0
}

e2e_stub_system(){
  e2e_tmp_init || return 1
  mkdir -p "$E2E_TMP/e2e-svc"
  e2e_tx_probes || echo "[!] 事务硬门探针没起来, 相关用例会如实失败"
  # 真机上做变更时 mosdns/mihomo 本来就在跑; 沙箱的假 systemd 默认全 inactive, 会让事务的
  # 基线门(操作前组件必须是好的)正确地拒掉一切普通变更。这里把它们置为 active, 让沙箱与
  # 真机同形态 —— 判据没动, 只是把"现场"补齐。
  printf 1 > "$E2E_TMP/e2e-svc/mosdns.ac"; printf 1 > "$E2E_TMP/e2e-svc/mihomo.ac"
  # 有状态的假 systemd: 记录每个 unit 的 active/enabled。切核纪律(旧核必须真的 inactive
  # 且 disabled)只有靠状态机才验得出来 —— 无脑回 active 的桩会把 activate 判成失败。
  #
  # 路径由**生成的头两行**注入: 桩正文用 <<'S'(不展开)才不会被里面成堆的 $1/$@ 咬到,
  # 所以 $E2E_TMP 只能这样带进去。写死 /tmp/e2e-svc 是老样子, 那让并发跑的两个脚本共用
  # 同一份 svcstate, 而且跑完谁也不清。
  { printf '#!/bin/sh\nD=%s/e2e-svc\nCALLS=%s/e2e-calls.log\n' "$E2E_TMP" "$E2E_TMP"
    cat <<'S'
mkdir -p "$D"
echo "systemctl $*" >> "$CALLS"
verb="$1"; shift
now=0; [ "$1" = "--now" ] && { now=1; shift; }

# ── pdg-dotwitness 专用: 只有这一个 unit 起**真的生产进程** ─────────────────
# 为什么非这么做不可: 6.2B 的状态机装完 witness 会轮询 127.0.0.1:5399 有没有真在听,
# 听不到就判"四件套没闭合"并精确回滚。那条判据是 P0 隔离门与 doctor 分级的地基, 绝不
# 能为了迁就假 systemd 去放宽。所以反过来 —— 让桩在这一个 unit 上说真话。
# 其它 unit 的行为逐字不变; 不做通用的"声明端口就模拟监听"框架。
_dw_is(){ case "$1" in pdg-dotwitness|pdg-dotwitness.service) return 0;; *) return 1;; esac; }
_dw_stop(){
  [ -f "/run/pdg-e2e-dw.pid" ] || return 0
  p=$(cat "/run/pdg-e2e-dw.pid" 2>/dev/null)
  [ -n "$p" ] && kill "$p" 2>/dev/null
  i=0; while [ $i -lt 40 ] && kill -0 "$p" 2>/dev/null; do i=$((i+1)); sleep 0.05; done
  kill -0 "$p" 2>/dev/null && kill -9 "$p" 2>/dev/null
  rm -f "/run/pdg-e2e-dw.pid"
  return 0
}
_dw_start(){
  _dw_stop
  # 缺件一律 fail-closed, 不谎报成功
  [ -f /opt/pdg-bot/dotwitness.py ] || return 1
  [ -f /etc/privdns-gateway/dotwitness.env ] || return 1
  ns=$(sed -n 's/^PDG_DOTWITNESS_SUFFIX=//p' /etc/privdns-gateway/dotwitness.env | tail -1)
  [ -n "$ns" ] || return 1
  mkdir -p /run/pdg-dotwitness && chmod 700 /run/pdg-dotwitness || return 1
  echo /run/pdg-dotwitness > "/run/pdg-e2e-dw.rundir"      # 登记, 退出钩子按这个清
  # setsid + 关掉继承的 fd 9: migrate_dotwitness 是在 pdg __migrate 内部跑的, 而 pdg
  # 用 exec 9>LOCK + flock 持全局锁。子进程继承 fd 9 后, witness 常驻不退 = 锁一直被
  # 握着, 同一支脚本里后续每个 pdg 调用都撞"已有 pdg 操作在运行"。真 systemd 没这
  # 问题 —— 服务由 PID 1 拉起, 不是 pdg 的子进程。这里必须显式还原那个前提。
  RUNTIME_DIRECTORY=/run/pdg-dotwitness PDG_DOTWITNESS_SUFFIX="$ns" \
    setsid /usr/bin/python3 /opt/pdg-bot/dotwitness.py >>"/run/pdg-e2e-dw.log" 2>&1 9>&- <&- &
  echo $! > "/run/pdg-e2e-dw.pid"
  # 等它真的绑上再返回 —— 不 sleep 定额, 按事实判定
  i=0
  while [ $i -lt 60 ]; do
    ss -lun 2>/dev/null | grep -q '127.0.0.1:5399' && return 0
    kill -0 "$(cat "/run/pdg-e2e-dw.pid" 2>/dev/null)" 2>/dev/null || { rm -f "/run/pdg-e2e-dw.pid"; return 1; }
    i=$((i+1)); sleep 0.05
  done
  return 1
}
_dw_alive(){ [ -f "/run/pdg-e2e-dw.pid" ] && kill -0 "$(cat "/run/pdg-e2e-dw.pid" 2>/dev/null)" 2>/dev/null; }

case "$verb" in
  daemon-reload|reset-failed|preset|mask|unmask) exit 0;;
  enable)  for u in "$@"; do echo 1 > "$D/${u}.en"
             # .fail 标记 = 这个 unit "起得来但立刻崩" → 起完仍是 inactive
             if [ "$now" = 1 ]; then
               if [ -f "$D/${u}.fail" ]; then echo 0 > "$D/${u}.ac"
               elif _dw_is "$u"; then _dw_start && echo 1 > "$D/${u}.ac" || echo 0 > "$D/${u}.ac"
               else echo 1 > "$D/${u}.ac"; fi
             fi
           done; exit 0;;
  disable) for u in "$@"; do echo 0 > "$D/${u}.en"
             if [ "$now" = 1 ]; then echo 0 > "$D/${u}.ac"; _dw_is "$u" && _dw_stop; fi
           done; exit 0;;
  start|restart) for u in "$@"; do
                   if [ -f "$D/${u}.fail" ]; then echo 0 > "$D/${u}.ac"
                   elif _dw_is "$u"; then _dw_start && echo 1 > "$D/${u}.ac" || echo 0 > "$D/${u}.ac"
                   else echo 1 > "$D/${u}.ac"; fi
                 done; exit 0;;
  stop)    for u in "$@"; do echo 0 > "$D/${u}.ac"; _dw_is "$u" && _dw_stop; done; exit 0;;
  is-active)
      u="$1"; v=$(cat "$D/${u}.ac" 2>/dev/null)
      # 没记录过的: 有 unit 文件就当它在跑(模拟装好即运行), 否则 inactive
      [ -z "$v" ] && { [ -f "/etc/systemd/system/${u}.service" ] && v=1 || v=0; }
      # witness 起的是真进程: 它自己崩了就不能再说 active(真 systemd 也不会)
      if _dw_is "$u" && [ "$v" = 1 ] && ! _dw_alive; then v=0; echo 0 > "$D/${u}.ac"; fi
      [ "$v" = 1 ] && { echo active; exit 0; }; echo inactive; exit 3;;
  is-enabled)
      u="$1"; v=$(cat "$D/${u}.en" 2>/dev/null)
      [ -z "$v" ] && { [ -f "/etc/systemd/system/${u}.service" ] && v=1 || v=0; }
      [ "$v" = 1 ] && { echo enabled; exit 0; }; echo disabled; exit 1;;
  show)
      # show [-p PROP]... [--value] UNIT
      #
      # 原来这里只认单个 -p、只答得出 ActiveState, 其余一律 `echo 0`。timer 判据要读
      # SubState 与两个 NextElapse, 于是它们全成了 "0" —— doctor 按 fail-closed 判红,
      # 整次 update 回滚。测出来的是桩的病, 而排查时最顺手的"修法"(把判据放宽)恰恰最坏。
      # 所以桩要做真: **状态从当前 unit 状态派生**, 绝不无条件回答 active/waiting/finite,
      # 否则 timer 死角那组测试会变成恒绿。
      #
      # 属性输出顺序**有意与命令行 -p 顺序不同**(按名字排序): 真 systemd 就是按自己的
      # 规范顺序打印的, 谁回去按位取值立刻错位 —— 这个坑在真机上栽过一次。
      u=""; props=""; want_value=0; nextp=0
      for a in "$@"; do
        if [ "$nextp" = 1 ]; then props="$props $a"; nextp=0; continue; fi
        case "$a" in
          -p) nextp=1;;
          --value) want_value=1;;
          -*) ;;
          *) u="$a";;
        esac
      done
      [ -n "$props" ] || props=" ActiveState"
      _st(){ v=$(cat "$D/${u}.ac" 2>/dev/null)
             [ -z "$v" ] && { [ -f "/etc/systemd/system/${u}" ] || [ -f "/etc/systemd/system/${u}.service" ] && v=1 || v=0; }
             echo "$v"; }
      _val(){
        case "$1" in
          ActiveState)
            [ -f "$D/${u}.failed" ] && { echo failed; return; }
            [ "$(_st)" = 1 ] && echo active || echo inactive;;
          SubState)
            # timer 的子状态从 .sub 记录取; 没记过就按 active 与否给默认值。
            # elapsed = 已触发过但排不出下一次(死角); waiting = 正常等待; running = 正在触发。
            v=$(cat "$D/${u}.sub" 2>/dev/null)
            if [ -n "$v" ]; then echo "$v"
            elif [ -f "$D/${u}.failed" ]; then echo failed
            elif [ "$(_st)" = 1 ]; then case "$u" in *.timer) echo waiting;; *) echo running;; esac
            else echo dead; fi;;
          NextElapseUSecMonotonic)
            # 只有 **active 且非 elapsed/failed 的 timer** 才有有限的下一次。
            case "$u" in
              *.timer)
                sub=$(_val SubState)
                if [ "$(_st)" = 1 ] && [ "$sub" != elapsed ] && [ "$sub" != failed ]; then
                  cat "$D/${u}.next" 2>/dev/null || echo "1w 2d 3h 4min 5s"
                else echo infinity; fi;;
              *) echo infinity;;
            esac;;
          NextElapseUSecRealtime)
            cat "$D/${u}.nextreal" 2>/dev/null || echo "";;
          UnitFileState)
            v=$(cat "$D/${u}.en" 2>/dev/null)
            [ -z "$v" ] && { [ -f "/etc/systemd/system/${u}" ] || [ -f "/etc/systemd/system/${u}.service" ] && v=1 || v=0; }
            [ "$v" = 1 ] && echo enabled || echo disabled;;
          LoadState) echo loaded;;
          Result)    [ -f "$D/${u}.failed" ] && echo failed || echo success;;
          InvocationID) cat "$D/${u}.inv" 2>/dev/null || echo "";;
          MainPID)   [ "$(_st)" = 1 ] && { cat "$D/${u}.pid" 2>/dev/null || echo 1234; } || echo 0;;
          NRestarts) cat "$D/${u}.nr" 2>/dev/null || echo 0;;
          Triggers)  case "$u" in *.timer) echo "${u%.timer}.service";; *) echo "";; esac;;
          LastTriggerUSec) cat "$D/${u}.last" 2>/dev/null || echo "";;
          *)         echo 0;;
        esac
      }
      # 按名字排序输出 —— 有意不跟随 -p 的顺序
      for k in $(for x in $props; do echo "$x"; done | sort); do
        if [ "$want_value" = 1 ]; then _val "$k"; else echo "$k=$(_val "$k")"; fi
      done
      exit 0;;
esac
exit 0
S
  } > /usr/local/bin/systemctl
  e2e_write_nft_stub
  chmod 755 /usr/local/bin/systemctl
  : > "$E2E_TMP/e2e-calls.log"
}

# 把某 unit 置为"当前不在跑"(供故障注入)。注意: 之后任何 restart 都会把它拉回 active,
# 要模拟"启动后立刻崩溃"请用 e2e_svc_crash。
e2e_svc_fail(){ mkdir -p "$E2E_TMP/e2e-svc"; echo 0 > "$E2E_TMP/e2e-svc/$1.ac"; }

# "起得来但立刻崩": restart 返回 0, 但服务随即变回 inactive —— 真实现场里最常见的失败形态,
# 也正是"只看 systemctl 返回值"这种写法看不出来的那种。
e2e_svc_crash(){ mkdir -p "$E2E_TMP/e2e-svc"; : > "$E2E_TMP/e2e-svc/$1.fail"; echo 0 > "$E2E_TMP/e2e-svc/$1.ac"; }
e2e_svc_heal(){ rm -f "$E2E_TMP/e2e-svc/$1.fail"; echo 1 > "$E2E_TMP/e2e-svc/$1.ac"; }

# PATH 上那个 mihomo 是不是**真内核**: 正反两份配置都要判对。串行跑时它很可能是上一个脚本
# 留下的桩(`-t` 恒 0), 拿它当内核用, "配置不合法就不许重启"这类用例会静默失效。
e2e_mihomo_is_real(){
  command -v mihomo >/dev/null 2>&1 || return 1
  local d rc_good rc_bad; d="$(mktemp -d)" || return 1
  printf '{"log-level":"silent","mixed-port":17899,"proxies":[],"rules":["MATCH,DIRECT"]}\n' > "$d/good.yaml"
  printf '{"proxies":[{"name":"x","type":"definitely-not-a-real-protocol","server":"1.1.1.1","port":1}],"rules":["MATCH,DIRECT"]}\n' > "$d/bad.yaml"
  mihomo -t -d "$d" -f "$d/good.yaml" >/dev/null 2>&1; rc_good=$?
  mihomo -t -d "$d" -f "$d/bad.yaml"  >/dev/null 2>&1; rc_bad=$?
  rm -rf "$d"
  [[ "$rc_good" == 0 && "$rc_bad" != 0 ]]
}

# 取真内核二进制(钉死版本); 拿不到回非 0, 调用方据此跳过
e2e_fetch_mihomo(){
  e2e_mihomo_is_real && return 0
  rm -f /usr/local/bin/mihomo 2>/dev/null || true      # 桩要换成真的
  # shellcheck source=/dev/null
  . "$E2E_ROOT/lib/versions.sh"
  curl -fsSL --retry 2 -m 120 \
    "https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VER}/mihomo-linux-amd64-${MIHOMO_VER}.gz" \
    -o "$E2E_TMP/m.gz" 2>/dev/null || return 1
  gunzip -c "$E2E_TMP/m.gz" > /usr/local/bin/mihomo 2>/dev/null || return 1
  chmod 755 /usr/local/bin/mihomo
}
e2e_fetch_mosdns(){
  command -v mosdns >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  . "$E2E_ROOT/lib/versions.sh"
  curl -fsSL --retry 2 -m 120 \
    "https://github.com/IrineSistiana/mosdns/releases/download/${MOSDNS_VER}/mosdns-linux-amd64.zip" \
    -o "$E2E_TMP/mos.zip" 2>/dev/null || return 1
  (cd "$E2E_TMP" && unzip -qo mos.zip mosdns) 2>/dev/null || return 1
  install -m755 "$E2E_TMP/mosdns" /usr/local/bin/mosdns 2>/dev/null || return 1
}

# ── 造现场 ──────────────────────────────────────────────────────────────────
E2E_SIP=203.0.113.1
E2E_CIDR=127.0.0.0/8

# 装好 bot 模块 + 仓库 + pdg 脚本
# 把 /opt/pdg-bot 清回"只有部署模块"的状态, 但**保住用户数据**。
#
# 三支跨版本 E2E 原本都写 `rm -rf /opt/pdg-bot; mkdir -p /opt/pdg-bot` —— 它们想做的是
# "把部署模块换成某个旧版本的那一份", 却把同住一个目录的用户数据(PDG_USER_DATA 里的
# dot-domain / rulesets.json)一并带走。机器于是落到"模块在、用户数据没了"这种真机永远
# 不会出现的形态: 真机上那些文件由 install.sh 写、由 pdg update 逐字节保全(成功与失败
# 回滚两条路径都实测过, 见 e2e-update-preserve-userdata.sh)。
# 后果是 6.2B 的 migrate_dotwitness 按契约 fail-closed("拼进配置的值不能靠猜"), 整次
# 更新回滚 —— 红的是夹具而不是产品。
#
# 保留清单从 lib/preserve.sh 的 PDG_USER_DATA 读, 不在任何一支测试里写死文件名。
e2e_reset_botdir(){
  # shellcheck source=lib/preserve.sh
  source "$E2E_ROOT/lib/preserve.sh" || return 1
  local keep p
  keep="$(mktemp -d "${TMPDIR:-/tmp}/e2e-ud.XXXXXX")" || return 1
  while read -r p; do
    [[ "$p" == opt/pdg-bot/* && -e "/$p" ]] || continue
    mkdir -p "$keep/$(dirname "$p")" && cp -a "/$p" "$keep/$p"
  done < <(pdg_user_data)
  rm -rf /opt/pdg-bot && mkdir -p /opt/pdg-bot || { rm -rf "$keep"; return 1; }
  [[ -d "$keep/opt/pdg-bot" ]] && cp -a "$keep/opt/pdg-bot/." /opt/pdg-bot/
  rm -rf "$keep"
  return 0
}

e2e_seed_install(){
  mkdir -p /opt/pdg-bot /etc/mosdns/rules /etc/privdns-gateway
  cp -a "$E2E_ROOT" /opt/privdns-gateway
  install -m755 "$E2E_ROOT/deploy/bot/pdg.sh" /usr/local/bin/pdg
  local f; for f in "$E2E_ROOT"/deploy/bot/*.py; do install -m755 "$f" /opt/pdg-bot/; done
  install -m755 "$E2E_ROOT/deploy/bot/pdg-bot.py" /opt/pdg-bot/bot.py
  # install.sh 从第一版公开装机脚本(62443ad)起就写这个文件, 它是 DoT 域名的唯一真源。
  # 夹具既然模拟"已装好的机器", 就得把它一起造出来 —— 少了它, 6.2B 的
  # migrate_dotwitness 会以"域名缺失"返回 1, 把整条 __migrate 打红。
  echo dot.e2e.test > /opt/pdg-bot/dot-domain
  printf 'PDG_BOT_TOKEN=x\nPDG_BOT_ALLOWED=1\n' > /etc/privdns-gateway/bot.env
}

# 渲染 mosdns 配置 + 规则文件。$1=劫持模式(all|gfw)
e2e_seed_mosdns(){
  local mode="${1:-all}" f
  for f in geosite_cn geosite_apple custom_direct custom_hijack ruleset_hijack unlock mitm_hijack \
           geosite_gfw 'geosite_geolocation-!cn'; do : > "/etc/mosdns/rules/$f.txt"; done
  printf 'domain:baidu.com\n' > /etc/mosdns/rules/geosite_cn.txt
  printf 'domain:blocked.test\n' > /etc/mosdns/rules/geosite_gfw.txt
  sed -e "s|__SERVER_IP__|$E2E_SIP|g" -e "s|__INTERNAL_CIDR__|$E2E_CIDR|g" \
      -e 's|__CERT_DIR__|/etc/mosdns/certs|g' -e 's|__SSH_PORT__|22|g' -e 's|__SSH_MATCH__||g' \
      -e 's|__MOSDNS_CACHE__|1024|g' -e 's|__HIJACK_SET_FILE__|geosite_geolocation-!cn.txt|g' \
      "$E2E_ROOT/deploy/mosdns/config.yaml" > /etc/mosdns/config.yaml
  # shellcheck source=/dev/null
  . "$E2E_ROOT/lib/mosdns.sh"
  local setf; [[ "$mode" == gfw ]] && setf=geosite_gfw.txt || setf='geosite_geolocation-!cn.txt'
  _mosdns_hijack_shape "$mode" /etc/mosdns/config.yaml "$setf" >/dev/null
  printf 'PDG_LOWMEM=0\nPDG_HIJACK_MODE=%s\nPDG_INTERNAL_CIDR=%s\n' \
    "$mode" "$E2E_CIDR" > /etc/privdns-gateway/profile.env
  # DoT 证书: 真机装完一定有(install.sh 签发或生成自签), mosdns 的 dot_server 插件初始化要读它。
  # 沙盒缺它 → 任何"拿真 mosdns 校验候选配置"的事务都会失败, 那是夹具不够真实, 不是产品问题。
  if [[ ! -s /etc/mosdns/certs/fullchain.pem ]] && command -v openssl >/dev/null 2>&1; then
    install -d -m700 /etc/mosdns/certs
    openssl req -x509 -newkey rsa:2048 -nodes -keyout /etc/mosdns/certs/privkey.pem \
      -out /etc/mosdns/certs/fullchain.pem -days 3650 -subj "/CN=e2e.example" >/dev/null 2>&1 || true
    chmod 644 /etc/mosdns/certs/fullchain.pem 2>/dev/null || true
    chmod 600 /etc/mosdns/certs/privkey.pem 2>/dev/null || true
  fi
}

# 渲染真实防火墙配置(switch-core 要从中提取 SSH 端口)。$1=内核(singbox|mihomo)
# v1.6.0: 只剩 mihomo 一套模板($1 保留但已无意义, 调用方不必改)。
e2e_seed_nft(){
  # 救援端口取正式常量, 不在这里写字面量 —— 写死一个数字, 常量一改夹具就造出一台
  # 端口对不上的"机器", 而这正是最难查的那类夹具失真。
  local _rp; _rp="$(python3 "$E2E_ROOT/deploy/bot/rescue_const.py" --port 2>/dev/null)"
  if [[ -z "$_rp" ]]; then
    echo "e2e_seed_nft: 读不到救援端口常量, 无法完整渲染防火墙模板" >&2; return 1
  fi
  sed -e "s|__SSH_PORT__|22|g" -e "s|__SSH_MATCH__||g" -e "s|__INTERNAL_CIDR__|$E2E_CIDR|g" -e "s|__RESCUE_PORT__|$_rp|g" \
      "$E2E_ROOT/deploy/firewall/nftables-mihomo.conf" > /etc/nftables.conf
  # fail-closed: 真机装完不会留下未替换的占位符, 沙箱也不许。漏一个就当场失败 ——
  # 上一次漏的是 __RESCUE_PORT__, 后果是六个升级类 E2E 同时红而现象指向别处。
  # 只报 token 名, 不回显渲染后的配置内容。
  local _left
  _left="$(grep -oE '__[A-Z][A-Z0-9_]*__' /etc/nftables.conf | sort -u | tr '\n' ' ')"
  if [[ -n "${_left// /}" ]]; then
    echo "e2e_seed_nft: 模板未完整渲染, 残留占位符: $_left" >&2; return 1
  fi
  # 真机上装完会 `nft -f` 应用一次, 内核里于是有这份规则。桩的"内核状态"同步过去,
  # 否则磁盘有、内核空, doctor 会如实判"读不到内核规则"——那是夹具不像真的。
  cp /etc/nftables.conf "$E2E_TMP/e2e-nft-ruleset" 2>/dev/null || true
}

e2e_seed_singbox_model(){
  sed -e "s|__SERVER_IP__|$E2E_SIP|g" -e "s|__INTERNAL_CIDR__|$E2E_CIDR|g" -e 's|__SSH_PORT__|22|g' -e 's|__SSH_MATCH__||g' \
      "$E2E_ROOT/deploy/singbox/config.json.tmpl" > /etc/sing-box/config.json
}

# 自签占位证书(装机时 PDG_SKIP_CERT 也是这么做的)。没有它 doctor 的证书项必 fail,
# 而 update 的校验门见 fail 就回滚 —— 整条更新路径根本走不完。
e2e_seed_cert(){
  command -v openssl >/dev/null 2>&1 || return 1
  mkdir -p /etc/mosdns/certs
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -keyout /etc/mosdns/certs/privkey.pem -out /etc/mosdns/certs/fullchain.pem \
    -subj "/CN=dot.e2e.test" >/dev/null 2>&1 || return 1
  chmod 600 /etc/mosdns/certs/privkey.pem
  echo dot.e2e.test > /opt/pdg-bot/dot-domain
}

# 起真 mosdns 在 127.0.0.1:15353(上游指向死端口, 保证快速失败且不外连)
e2e_mosdns_start(){
  e2e_tmp_init || return 1
  local cfg="$E2E_TMP/e2e-mos.yaml"
  sed -e 's#0.0.0.0:53#127.0.0.1:15353#g' \
      -e 's#^\([[:space:]]*\)args: {.*1\.1\.1\.1.*}#\1args: { concurrent: 1, upstreams: [ {addr: "udp://127.0.0.1:15999"} ] }#' \
      -e 's#^\([[:space:]]*\)args: {.*223\.5\.5\.5.*}#\1args: { concurrent: 1, upstreams: [ {addr: "udp://127.0.0.1:15999"} ] }#' \
      -e 's#^\([[:space:]]*\)args: {.*22\.22\.22\.22.*}#\1args: { concurrent: 1, upstreams: [ {addr: "udp://127.0.0.1:15999"} ] }#' \
      -e '/- tag: dot_server/,$d' /etc/mosdns/config.yaml > "$cfg"
  mosdns start -c "$cfg" -d "$E2E_TMP" >"$E2E_TMP/e2e-mos.log" 2>&1 &
  echo $! > "$E2E_TMP/e2e-mos.pid"
  local _i; for _i in $(seq 1 50); do
    dig +short +time=1 +tries=1 @127.0.0.1 -p 15353 probe.ready A >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 0
}
e2e_mosdns_stop(){ [[ -f "$E2E_TMP/e2e-mos.pid" ]] && kill "$(cat "$E2E_TMP/e2e-mos.pid")" 2>/dev/null; rm -f "$E2E_TMP/e2e-mos.pid"; sleep 0.2; }
e2e_q(){ dig +short +time=2 +tries=1 @127.0.0.1 -p 15353 "$1" A 2>/dev/null | head -1; }
