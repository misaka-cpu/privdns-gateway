# shellcheck shell=bash
# ══ DNS 去广告(可选, 默认关闭)═══════════════════════════════════════════════
ADB_STATE_DIR="/var/lib/privdns-gateway/adblock"
ADB_USER_ALLOW="/etc/mosdns/rules/adblock_allow.txt"
ADB_USER_BLOCK="/etc/mosdns/rules/adblock_block.txt"
ADB_SOURCES="/etc/privdns-gateway/adblock-sources.txt"   # 用户配置的第三方源; 是用户数据, 进快照
ADB_MARK_PL=">>> pdg-adblock managed block (plugins)"
ADB_MARK_SQ=">>> pdg-adblock managed block (internal_sequence)"

# profile.env 里的启用意图(读不到 = 空 = 未启用)
_adblock_intent(){ sed -n 's/^[[:space:]]*PDG_ADBLOCK_ENABLED=//p' "$PROFILE_ENV" 2>/dev/null | tail -1; }

# _adblock_read_state → enabled | disabled | unknown  (窄的**只读**三态读取器)
#
# 为什么不直接改 _adblock_intent: enable / disable / apply / 迁移都依赖它现有的语义,
# 动它等于把行为面扩到那些写路径上去。这一个只服务"显示状态"这一件事。
#
# 三态不是形式主义。线上 profile.env 是 0600 root:root, 同一台**已启用**的机器上:
#     root   → 已启用(第三方表 214982 条 / 自定义 0 条)
#     nobody → 未启用
# 一个**权限问题**在屏幕上长得和"这台机器没开去广告"一模一样 —— 而后者会让人去点"启用"。
#
# 最后一次赋值不是 0/1 时报 unknown, 不退回更早的合法值: 有人往启用位里写了看不懂的东西,
# 说"未启用"是在替他下结论, 而我们并不知道他要什么。
_adblock_read_state(){
  local raw last
  [[ -e "$PROFILE_ENV" ]] || { printf 'unknown'; return 0; }
  # 先确认**读得出来**。sed 非零就是打不开(权限 / 路径是目录 / IO 错误)—— 那不是"没启用",
  # 而是"不知道"。以前这一步的 2>/dev/null 把两者一起吞了。
  if ! raw="$(sed -n 's/^[[:space:]]*PDG_ADBLOCK_ENABLED=[[:space:]]*//p' "$PROFILE_ENV" 2>/dev/null)"; then
    printf 'unknown'; return 0
  fi
  # 键一次都没出现 = 从没开过。与"值读不出来"分开: 上一步已经证明文件可读。
  if ! grep -q '^[[:space:]]*PDG_ADBLOCK_ENABLED=' "$PROFILE_ENV" 2>/dev/null; then
    printf 'disabled'; return 0
  fi
  last="$(printf '%s\n' "$raw" | tail -1)"
  # profile.env 是 shell 片段: 值可能带引号, 后面也可能跟行内注释。
  last="${last%%[[:space:]]*}"
  last="${last%\"}"; last="${last#\"}"; last="${last%\'}"; last="${last#\'}"
  case "$last" in
    1) printf 'enabled';;
    0) printf 'disabled';;
    *) printf 'unknown';;
  esac
}

# 规则文件**读得出来吗**。`-r` 只看权限位, 真正的判据是能不能打开 —— 路径是目录、
# IO 错误、ACL 都只在打开那一步现形。
# 为什么要单立一条: 缺文件与"0 条"是两件不同的事。0 条是一个具体事实(表在, 里面没东西);
# 文件不在是另一回事(mosdns 会 FATAL 退出)。显示成同一句话, 现场就没法区分。
_adb_rules_readable(){
  local f="${1:-}"
  [[ -f "$f" ]] || return 1
  { : < "$f"; } 2>/dev/null || return 1
  return 0
}

# 四个 domain_set 文件必须常驻(空文件可以)。缺一个 mosdns 直接 FATAL 退出 —— 这是
# "规则文件为空是可接受的降级, 规则文件缺失是致命的"那条老规矩。
_adblock_ensure_files(){
  install -d -m755 "$ADB_STATE_DIR" 2>/dev/null || return 1
  local f
  for f in "$ADB_STATE_DIR/infra_allow.txt" "$ADB_STATE_DIR/effective_block.txt" \
           "$ADB_STATE_DIR/effective_list.txt"; do
    [[ -e "$f" ]] || : > "$f"; chmod 644 "$f" 2>/dev/null
  done
  for f in "$ADB_USER_ALLOW" "$ADB_USER_BLOCK"; do
    [[ -e "$f" ]] || : > "$f"
    # 与同目录其它规则文件同权限(custom_hijack.txt 等)
    chmod 644 "$f" 2>/dev/null; chown root:root "$f" 2>/dev/null || true
  done
}

# 基础设施白名单: 从**权威本机状态**枚举, 不手写一份会过期的名单。
# 枚举不到的那一类**不猜、也不用宽泛后缀放行整个公共域** —— 缺哪一类如实记进 .note,
# doctor 据此判 WARN + 无结论。
_adblock_gen_infra(){
  _adblock_ensure_files || return 1
  local tmp note; tmp="$(mktemp)" || return 1; note=""
  # ① 本机 DoT 域名(唯一真源)
  local dom; dom="$(tr -d '[:space:]' < /opt/pdg-bot/dot-domain 2>/dev/null)"
  if [[ -n "$dom" ]]; then printf 'domain:%s\n' "$dom" >> "$tmp"; else note="$note dot"; fi
  # ② 内网面板域名(面板表是真源)
  if [[ -s /etc/privdns-gateway/lan-panels.json ]]; then
    python3 -c 'import json,sys
try: d=json.load(open("/etc/privdns-gateway/lan-panels.json"))
except Exception: sys.exit(0)
for p in d.get("panels",[]):
    h=p.get("host")
    if h: print("domain:%s"%h.strip().lower().rstrip("."))' >> "$tmp" 2>/dev/null
  fi
  # ③ WLOC / MITM 接管域名(mitm_hijack.txt 是真源)
  if [[ -s /etc/mosdns/rules/mitm_hijack.txt ]]; then
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//' /etc/mosdns/rules/mitm_hijack.txt \
      | grep -vE '^$|^#' | sed 's|^domain:||; s|^full:||' | sed 's|^|domain:|' >> "$tmp"
  fi
  # ④ 更新源(从仓库 remote 取主机名, 不写死)
  local rurl rhost
  rurl="$(git -C "${REPO_DIR:-/opt/privdns-gateway}" remote get-url origin 2>/dev/null)"
  rhost="$(sed -E 's|^[a-z]+://||; s|^[^@]*@||; s|[:/].*$||' <<<"$rurl")"
  if [[ -n "$rhost" ]]; then printf 'domain:%s\n' "$rhost" >> "$tmp"; else note="$note update-src"; fi
  # ⑤ 证书/ACME: 已签发的域名 + acme 目录服务器主机名
  local d2
  for d2 in /etc/letsencrypt/live/*/; do
    [[ -d "$d2" ]] || continue
    printf 'domain:%s\n' "$(basename "$d2")" >> "$tmp"
  done
  local acme_host=""
  if [[ -s /opt/pdg-acme/account.conf ]]; then
    acme_host="$(grep -oE 'https://[a-zA-Z0-9.-]+' /opt/pdg-acme/account.conf 2>/dev/null | head -1 | sed 's|https://||')"
  fi
  if [[ -z "$acme_host" ]]; then
    acme_host="$(grep -rhoE 'https://[a-zA-Z0-9.-]*acme[a-zA-Z0-9.-]*' /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -1 | sed 's|https://||')"
  fi
  if [[ -n "$acme_host" ]]; then printf 'domain:%s\n' "$acme_host" >> "$tmp"; else note="$note acme"; fi
  # ⑥ DNS 服务商 API: 交给 adblock.py 的 infra_closure 判定 —— 那里有受支持 provider 的
  #    显式表, 外加与安装的 dnsapi 脚本做交叉核对。**枚举不到就不写**, 也不猜:
  #    猜一个 api.<provider>.com 等于放行一整个公共域。
  #    (早先这里读的是 /opt/pdg-acme/account.conf 里的 dns_ 字样 —— 位置就是错的:
  #     本项目以 `--home <家>/data` 调 acme.sh, provider 记在每域名的 Le_Webroot 里。)
  local _mod _cl
  if _mod="$(_pdg_module adblock.py)"; then
    _cl="$(python3 -c 'import json,sys,importlib.util
spec=importlib.util.spec_from_file_location("a", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.infra_closure(sys.argv[2], sys.argv[3]), ensure_ascii=False))' "$_mod" "$ACME_HOME" "$ADB_USER_ALLOW" 2>/dev/null)"
    if [[ -n "$_cl" ]]; then
      python3 -c 'import json,sys
d=json.loads(sys.argv[1])
for h in d.get("hosts") or []: print("domain:%s" % h)' "$_cl" >> "$tmp" 2>/dev/null
      printf '%s' "$_cl" > "$ADB_STATE_DIR/infra.closure.json"
      python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("complete") else 1)' "$_cl" \
        || note="$note dns-api"
    else
      note="$note dns-api"
    fi
  else
    note="$note dns-api"
  fi

  LC_ALL=C sort -u "$tmp" -o "$tmp"
  install -m644 "$tmp" "$ADB_STATE_DIR/infra_allow.txt" || { rm -f "$tmp"; return 1; }
  printf '%s\n' "${note# }" > "$ADB_STATE_DIR/infra.note"
  rm -f "$tmp"
  return 0
}

# 编译产物 → 重启 mosdns → 校验。失败要把编译产物退回去。
_adblock_apply(){
  local want="$1" mod bak_b bak_l
  mod="$(_pdg_module adblock.py)" || { c_y "❌ 找不到 adblock.py"; return 1; }
  bak_b="$(mktemp)"; bak_l="$(mktemp)"
  cp -a "$ADB_STATE_DIR/effective_block.txt" "$bak_b" 2>/dev/null
  cp -a "$ADB_STATE_DIR/effective_list.txt"  "$bak_l" 2>/dev/null
  # 把 stderr 留下来: 编译被拒是有具体理由的(比如用户 block 文件超了上限), 丢进 /dev/null
  # 的话用户拿到的是一次没有原因的失败, 而这条失败恰恰是他自己能修的。
  local _cerr; _cerr="$(python3 "$mod" compile "$want" "$ADB_STATE_DIR" 2>&1 >/dev/null)" || {
    c_y "❌ 编译规则失败(现网未改动)"
    [[ -n "$_cerr" ]] && c_y "   原因: $(head -1 <<<"$_cerr")"
    rm -f "$bak_b" "$bak_l"; return 1
  }
  systemctl restart mosdns 2>/dev/null; sleep 1
  if ! systemctl is-active --quiet mosdns; then
    c_y "❌ mosdns 重启失败 → 退回上一份编译产物。"
    cp -a "$bak_b" "$ADB_STATE_DIR/effective_block.txt" 2>/dev/null
    cp -a "$bak_l" "$ADB_STATE_DIR/effective_list.txt" 2>/dev/null
    systemctl restart mosdns 2>/dev/null
    rm -f "$bak_b" "$bak_l"; return 1
  fi
  rm -f "$bak_b" "$bak_l"
  return 0
}

# 数一份规则文件里的**有效条数**(空行与 `#` 注释不算)。
#
# 单独抽出来是因为原地那种写法同时踩了两个坑, 而且互相盖住:
#
#   grep -vce '^$|^#' FILE 2>/dev/null || echo 0
#
#   ① `grep -c` 无匹配时**既打印 0、又返回退出码 1** —— 于是 `|| echo 0` 再追加一个 0,
#      输出变成 "0\n0", status 那一行就断成两截。**只在某类规则为 0 条时出现**, 而那
#      正是绝大多数机器的默认状态, 所以它一直没被发现。
#   ② `-e` 是**基本正则**, 里面的 `|` 不是"或"而是字面竖线 —— 那个模式从来没排除过注释
#      和空行。3 条规则会被数成 5 条。
#
# 两个坑叠在一起还互相掩护: ① 让人以为是显示问题, ② 让人以为数字本来就该那么大。
_adb_count_rules(){
  local f="${1:-}" n
  [[ -f "$f" ]] || { printf '0'; return 0; }
  # LC_ALL=C 只加在**这一次调用**上, 不 export: 规则文件的内容契约是纯 ASCII
  # (adblock.py 的 _DOMAIN_RE 只放行 [a-z0-9_-] 与点), 而 UTF-8 locale 下 grep 要为每个
  # 字节做多字节解码, 二十多万行的表上这笔开销是白花的。语义不变 —— 这个模式里没有任何
  # 依赖 locale 的字符类语义(见 tests/test-adblock-count-locale.sh 的双 locale 对拍)。
  # 不做计数缓存、不改文件格式、不拿 meta.json 里的数字冒充磁盘真实条数: 那三样都会让
  # "现在盘上到底有多少条"这个问题失去唯一答案。
  n="$(LC_ALL=C grep -vcE '^[[:space:]]*(#|$)' "$f" 2>/dev/null)"
  printf '%s' "${n:-0}"
}

# 主状态页那一行。**未启用时也要输出** —— 只在启用时才显示的话, 一台"以为开着其实没开"
# 的机器在主状态页上看不出任何区别, 而那正是最需要它说话的情形。
#
# 报的是**表的大小**, 不是命中次数。本项目没有命中统计(四条实现路径都调查过并否决,
# 见 HANDOFF), 措辞不许造出一个看着像命中数的数字。
_adblock_status_line(){
  local st lst usr
  st="$(_adblock_read_state)"
  case "$st" in
    disabled) printf '未启用'; return 0;;
    unknown)  printf '状态未知(启用位读不到: 文件缺失或不可读)—— 请运行 sudo pdg doctor'; return 0;;
  esac
  # 启用位是开着的, 但表读不出来 —— 这里**不能**掉回 0 条: 那会把"证据缺失"说成一个事实。
  if ! _adb_rules_readable "$ADB_STATE_DIR/effective_list.txt" \
     || ! _adb_rules_readable "$ADB_USER_BLOCK"; then
    printf '已启用, 但规则文件缺失或不可读; 请运行 sudo pdg doctor'
    return 0
  fi
  lst="$(_adb_count_rules "$ADB_STATE_DIR/effective_list.txt")"
  usr="$(_adb_count_rules "$ADB_USER_BLOCK")"
  printf '已启用(第三方表 %s 条 / 自定义 %s 条)' "$lst" "$usr"
}

_adblock_status(){
  local state count updated
  # 与 status-line 走**同一个**读取器。两处各读各的话, 迟早会一个说开着一个说关着,
  # 而用户看到哪一个取决于他敲了哪条命令。
  state="$(_adblock_read_state)"
  # 路径经 **argv** 传进去, 不再插进 Python 字符串字面量。
  # 今天 ADB_STATE_DIR 是固定常量, 插值不可利用 —— 但那正是"变量一旦可变就变成注入"的
  # 形状, 而这个文件里其它地方都已经走 argv 了, 留一处例外只会让下一个人照抄。
  count="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1] + "/meta.json")).get("count",0))
except Exception: print(0)' "$ADB_STATE_DIR" 2>/dev/null)"
  updated="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1] + "/meta.json")).get("updated","(无)"))
except Exception: print("(无)")' "$ADB_STATE_DIR" 2>/dev/null)"
  case "$state" in
    enabled)  echo "  启用意图: 已启用";;
    disabled) echo "  启用意图: 未启用";;
    *)        c_y "  启用意图: 状态未知(启用位读不到: 文件缺失或不可读)—— 请运行 sudo pdg doctor";;
  esac
  echo "  第三方表: $count 条, 更新于 $updated"
  echo "  用户 allow: $(_adb_count_rules "$ADB_USER_ALLOW") 条   用户 block: $(_adb_count_rules "$ADB_USER_BLOCK") 条"
  echo "  生效中的表: block $(_adb_count_rules "$ADB_STATE_DIR/effective_block.txt") 条 / list $(_adb_count_rules "$ADB_STATE_DIR/effective_list.txt") 条"
  local note; note="$(cat "$ADB_STATE_DIR/infra.note" 2>/dev/null)"
  [[ -n "$note" ]] && c_y "  ⚠️ 基础设施白名单有枚举不到的类别(不猜, 也不放行整个公共域): $note"
  # 点名 provider 类型 —— 但只出**插件名**, 不出 token / 账号 / zone。
  # **自己现算一次**, 不依赖 enable 时落下的缓存: status 是只读命令, 用户完全可能在
  # 从没成功启用过的机器上先看一眼状态, 那时缓存根本不存在, 而"provider 是什么"恰恰
  # 是他最需要知道的一行。现算不写盘。
  local cj mod2; cj=""
  if mod2="$(_pdg_module adblock.py)"; then
    cj="$(python3 -c 'import json,sys,importlib.util
spec=importlib.util.spec_from_file_location("a", sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(json.dumps(m.infra_closure(sys.argv[2], sys.argv[3]), ensure_ascii=False))' "$mod2" "$ACME_HOME" "$ADB_USER_ALLOW" 2>/dev/null)"
  fi
  [[ -n "$cj" ]] || cj="$(cat "$ADB_STATE_DIR/infra.closure.json" 2>/dev/null)"
  if [[ -n "$cj" ]]; then
    python3 -c 'import json,sys
d=json.loads(sys.argv[1]); p=d.get("provider")
if p is None: print("  ACME DNS provider: 未配置(无需保护其 API 域名)")
elif d.get("complete"): print("  ACME DNS provider: %s —— API 域名已纳入保护(%s)" % (p, ", ".join(d.get("hosts") or [])))
else: print("  ACME DNS provider: %s —— **无法枚举其 API 域名, 保护列表不完整**" % p)' "$cj" 2>/dev/null
  fi
  return 0
}

cmd_adblock(){
  local sub="${1:-status}"; shift 2>/dev/null || true
  case "$sub" in
    # status 是**只读**命令: 缺文件按空集报告, 不许先建再读。原来这里挂着
    # `_adblock_ensure_files` —— 看一眼状态就在磁盘上留下三个空文件, 于是"这台机器用没用过
    # 去广告"这个问题被工具自己搅浑了(doctor 的 ADBLOCK_STATE_DIR 判据正是看它存不存在)。
    status|"") _adblock_status;;
    enable)
      need_root adblock; _lock; _adblock_ensure_files || return 1
      _adblock_gen_infra || { c_y "❌ 基础设施白名单生成失败 —— 不启用(宁可不拦, 也不能误杀自己的域名)。"; return 1; }
      # **基础设施闭包门(fail-closed)。**已经配了 ACME DNS provider, 却枚举不出它的 API
      # 域名时, 拒绝启用 —— 不是 WARN 之后照样开。那个域名一旦落进第三方广告表, 证书续期
      # 会**静默失败**: 不是某个网站打不开那种一眼可见的故障, 而是几十天后所有面板同时
      # 证书过期, 全程零告警(同 v1.10.14 修的"续期是哑的", 只是触发源换了)。
      # 没配 provider 是正常情形, 照常继续 —— "枚举不到"与"没有"必须分开。
      local _cj _cok=1 _cprov="" _cdet=""
      _cj="$(cat "$ADB_STATE_DIR/infra.closure.json" 2>/dev/null)"
      if [[ -n "$_cj" ]]; then
        python3 -c 'import json,sys; sys.exit(0 if json.loads(sys.argv[1]).get("complete") else 1)' "$_cj" || _cok=0
        _cprov="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("provider") or "")' "$_cj" 2>/dev/null)"
        _cdet="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("detail") or "")' "$_cj" 2>/dev/null)"
      fi
      if [[ "$_cok" != 1 ]]; then
        c_y "❌ 基础设施保护列表不完整 —— **去广告没有被启用**。"
        c_y "   provider: ${_cprov:-未知}"
        c_y "   $_cdet"
        c_y "   为什么拦住: 拦不住的话, 这个 provider 的 API 域名可能被第三方广告表挡掉,"
        c_y "   证书续期会从此静默失败 —— 几十天后所有面板同时证书过期, 期间没有任何告警。"
        c_y "   证书与现有 DNS 服务**未被改动**; 用户 allow/block 与已下载的表也未被改动。"
        c_y "   可以怎么做: 改用受支持的 DNS provider、或不用 DNS-01 这条证书路径、或等待本产品支持它。"
        c_y "   注意: 自己往 allow 里加一条**不算**产品已经认全了该 provider 的 API 域名。"
        return 1
      fi
      # 必须先有可用的表: 没有候选也没有 LKG 就启用, 等于开了个空壳
      if [[ ! -s "$ADB_STATE_DIR/list.lkg" && ! -s "$ADB_USER_BLOCK" ]]; then
        c_y "❌ 既没有第三方表(先跑 pdg adblock update), 也没有用户 block 规则 —— 保持关闭。"
        return 1
      fi
      _adblock_apply 1 || { c_y "❌ 启用失败, 保持关闭状态。"; _adblock_apply 0 >/dev/null 2>&1; return 1; }
      _profile_set PDG_ADBLOCK_ENABLED 1 || { c_y "⚠️ profile.env 写入失败, 启用意图未持久化。"; return 1; }
      c_g "✅ DNS 去广告已启用。"; _adblock_status;;
    disable)
      need_root adblock; _lock; _adblock_ensure_files || return 1
      _adblock_apply 0 || return 1
      _profile_set PDG_ADBLOCK_ENABLED 0 || c_y "⚠️ profile.env 写入失败。"
      c_g "✅ DNS 去广告已停用(用户规则与已下载的表都保留, 随时可以再 enable)。";;
    update)
      need_root adblock; _lock; _adblock_ensure_files || return 1
      local mod out; mod="$(_pdg_module adblock.py)" || return 1
      out="$(python3 "$mod" update "$ADB_STATE_DIR" "$ADB_SOURCES" 2>&1)"
      if grep -q '"ok": *true' <<<"$out"; then
        c_g "✅ 规则表已更新。"
        [[ "$(_adblock_intent)" == 1 ]] && { _adblock_apply 1 || return 1; }
        _adblock_status
      else
        c_y "⚠️ 更新失败, **继续使用上一份可用的表**(不会切成空表):"
        sed 's/^/    /' <<<"$out" | head -3
        return 1
      fi;;
    status-line)
      # 主状态页那一行的**唯一**来源。Bot 也调它 —— 两处各拼一份措辞, 迟早有一处把
      # "表的大小"说成"命中次数", 而本项目没有命中统计(见 HANDOFF)。
      _adblock_status_line; echo
      return 0;;
    rule-add-many)
      # 批量加阻断规则。**一笔事务**: 一次锁、一次改源、一次编译、一次重启。
      # 不做成"在 Bot 里循环调 N 次 rule-add": 那只是把 N 次 mosdns 重启从用户手里搬进代码,
      # 一次都没少, 而且中间任何一次撞上 `pdg update` 就卡住。
      #
      # 域名走 **stdin**(一行一个), 不走 argv —— 条数由用户决定, argv 有长度上限, 超限的
      # 表现是 E2BIG, 一个跟域名毫无关系的报错。
      need_root adblock
      local mod _bulk_out _bulk_rc=0 _changed=0
      mod="$(_pdg_module adblock.py)" || { echo '{"result":"apply_failed_rolled_back","changed":0}'; return 1; }
      # 与单条那支同一把全局锁, 同样先非阻塞试一次 —— 抢不到就吐 ADBLOCK_BUSY 走人,
      # 一个字节都还没动过, 不能说成"失败并回滚"。
      exec 9>"$LOCK" 2>/dev/null || { echo '{"result":"ADBLOCK_BUSY","changed":0}'; return 1; }
      if ! flock -n 9; then
        echo '{"result":"ADBLOCK_BUSY","changed":0}'; return 1
      fi
      PDG_LOCKED=1
      _adblock_ensure_files || { echo '{"result":"apply_failed_rolled_back","changed":0}'; return 1; }
      local _src_bak; _src_bak="$(mktemp)" || return 1
      cp -a "$ADB_USER_BLOCK" "$_src_bak" 2>/dev/null || : > "$_src_bak"
      _bulk_out="$(python3 "$mod" rule-add-many "$ADB_USER_BLOCK")" || _bulk_rc=$?
      _changed="$(printf '%s' "$_bulk_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("changed",0))
except Exception: print(0)')"
      # 一条都没变 → 没什么要编译的, 更没必要重启。直接把逐条回执交出去。
      if [[ "${_changed:-0}" == 0 ]]; then
        rm -f "$_src_bak"
        printf '%s\n' "$_bulk_out"
        return "$_bulk_rc"
      fi
      if [[ "$(_adblock_intent)" != 1 ]]; then
        rm -f "$_src_bak"
        printf '%s\n' "$_bulk_out"
        c_y "  规则已保存, 但去广告当前未启用, 因此尚未生效。" >&2
        return "$_bulk_rc"
      fi
      # 启用态: 与单条那支同样的产物前像 + 编译 + 产物真变才重启 + 失败整份回滚。
      local _eb="$ADB_STATE_DIR/effective_block.txt" _el="$ADB_STATE_DIR/effective_list.txt"
      local _eb_bak _el_bak _eb0 _el0 _cerr3
      _eb_bak="$(mktemp)"; _el_bak="$(mktemp)"
      cp -a "$_eb" "$_eb_bak" 2>/dev/null || : > "$_eb_bak"
      cp -a "$_el" "$_el_bak" 2>/dev/null || : > "$_el_bak"
      _eb0="$(sha256sum "$_eb" 2>/dev/null | cut -d' ' -f1)"
      _el0="$(sha256sum "$_el" 2>/dev/null | cut -d' ' -f1)"
      _bulk_rollback(){
        cp -a "$_src_bak" "$ADB_USER_BLOCK" 2>/dev/null
        cp -a "$_eb_bak" "$_eb" 2>/dev/null
        cp -a "$_el_bak" "$_el" 2>/dev/null
        rm -f "$_src_bak" "$_eb_bak" "$_el_bak"
      }
      if ! _cerr3="$(python3 "$mod" compile 1 "$ADB_STATE_DIR" "$ADB_USER_BLOCK" 2>&1 >/dev/null)"; then
        _bulk_rollback
        c_y "  ❌ 编译失败 —— 已回滚, 规则未生效。" >&2
        [[ -n "$_cerr3" ]] && c_y "     原因: $(head -1 <<<"$_cerr3")" >&2
        echo '{"result":"apply_failed_rolled_back","changed":0}'; return 1
      fi
      local _eb1 _el1
      _eb1="$(sha256sum "$_eb" 2>/dev/null | cut -d' ' -f1)"
      _el1="$(sha256sum "$_el" 2>/dev/null | cut -d' ' -f1)"
      if [[ "$_eb0" != "$_eb1" || "$_el0" != "$_el1" ]]; then
        systemctl restart mosdns 2>/dev/null; sleep 1
        if ! systemctl is-active --quiet mosdns; then
          _bulk_rollback; systemctl restart mosdns 2>/dev/null
          c_y "  ❌ mosdns 起不来 —— 已回滚, 规则未生效。" >&2
          echo '{"result":"apply_failed_rolled_back","changed":0}'; return 1
        fi
      fi
      rm -f "$_src_bak" "$_eb_bak" "$_el_bak"
      printf '%s\n' "$_bulk_out"
      return "$_bulk_rc" ;;

    rule-add|rule-del)
      # Telegram Bot 的可信入口。Bot **不许自己写规则文件**, 也不许解析这里的中文文案 ——
      # 这条分支最后一定吐一份闭集 JSON, 字段含义见 test-adblock-rule-cli.sh:
      #   result ∈ invalid_input|blocklist_full|already_exists|not_found|saved_inactive
      #            |applied|apply_failed_rolled_back|rollback_incomplete
      #   change ∈ added|removed|none
      need_root adblock
      # cmd_adblock 开头已经 shift 过: 这里 $1 是域名, 动作在 $sub 里。
      local _act="${sub#rule-}" _dom="${1:-}"
      _adb_emit(){ printf '{"result":"%s","change":"%s","restarted":%s,"overridden_by_allow":%s}\n' \
                     "$1" "$2" "${3:-false}" "${4:-false}"; }
      if [[ $# -ne 1 ]]; then
        echo "需要恰好一个域名参数。" >&2
        _adb_emit invalid_input none; return 2
      fi
      # 取的是**全局**那把锁 —— 与 enable/disable/update/`pdg update` 同一把, 互斥。
      # 但这条分支要给机器结果, 不能让 _lock 忙时那句 `exit 1` 把 JSON 吞掉: Bot 拿不到
      # 结果就只能兜底成 apply_failed_rolled_back, 而那是在说"改了又回滚了" —— 与事实不符。
      # 所以先**非阻塞地自己试一次**: 抢不到就吐 ADBLOCK_BUSY 走人, 一个字节都还没动过。
      # 抢到了就把 fd 留着(PDG_LOCKED=1), 后面的 _lock 调用会认这把锁, 不会二次抢。
      if ! { exec 9>"$LOCK"; } 2>/dev/null || ! flock -n 9; then
        _adb_emit ADBLOCK_BUSY none; return 1
      fi
      PDG_LOCKED=1
      _adblock_ensure_files || { _adb_emit apply_failed_rolled_back none; return 1; }
      local mod; mod="$(_pdg_module adblock.py)" || { _adb_emit apply_failed_rolled_back none; return 1; }

      # ① 校验 + 改源。校验与规范化**只有 adblock.py 一份**(validate_domain), shell 不另造。
      local _src_bak _out _change _norm
      _src_bak="$(mktemp)" || { _adb_emit apply_failed_rolled_back none; return 1; }
      cp -a "$ADB_USER_BLOCK" "$_src_bak" 2>/dev/null || : > "$_src_bak"
      local _prc=0
      _out="$(python3 "$mod" "rule-$_act" "$_dom" "$ADB_USER_BLOCK" 2>/dev/null)" || _prc=$?
      if [[ "$_prc" == 2 ]]; then
        # 只有"域名非法"是 2。其它非零是**写不进去**, 不能冒充成用户输入的错。
        rm -f "$_src_bak"; _adb_emit invalid_input none; return 2
      fi
      if [[ "$_prc" == 4 ]]; then
        # 用户 block 文件满了。**一个字节都没动过** —— 既不是"域名不合法"(用户会去改一个
        # 完全合法的域名, 改多少次都没用), 也不是"应用失败已回滚"(那是在说改了又撤回)。
        c_y "  ❌ $(printf '%s' "$_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("why",""))
except Exception: print("用户规则文件已达上限")')"
        rm -f "$_src_bak"; _adb_emit blocklist_full none; return 4
      fi
      if [[ "$_prc" != 0 ]]; then
        c_y "  ❌ 写用户规则失败 —— 未改动任何生效产物。"
        rm -f "$_src_bak"; _adb_emit apply_failed_rolled_back none; return 1
      fi
      _change="$(printf '%s' "$_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("change",""))
except Exception: print("")')"
      _norm="$(printf '%s' "$_out" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("normalized",""))
except Exception: print("")')"

      # ② 没变就到此为止: 不编译、不重启 —— 幂等操作的重启次数必须是 0。
      if [[ "$_change" == none ]]; then
        rm -f "$_src_bak"
        if [[ "$_act" == add ]]; then _adb_emit already_exists none; else _adb_emit not_found none; fi
        return 0
      fi

      # 用户 allow 压过 block(见受管块里的合取): 加了也不会真拦, 必须说清楚, 不能冒充已生效。
      local _ovr=false
      if [[ "$_act" == add ]] && python3 -c 'import sys
canon = "domain:" + sys.argv[1]
try:
    with open(sys.argv[2], encoding="utf-8") as f:
        hit = any(l.strip() in (canon, sys.argv[1]) for l in f)
except OSError:
    hit = False
sys.exit(0 if hit else 1)' "$_norm" "$ADB_USER_ALLOW"; then
        _ovr=true
      fi

      # ③ 停用态: 只改源。不编译、不重启、不碰 LKG、不动启用位。
      if [[ "$(_adblock_intent)" != 1 ]]; then
        rm -f "$_src_bak"
        c_y "  规则已保存, 但去广告当前未启用, 因此尚未生效。"
        _adb_emit saved_inactive "$_change" false "$_ovr"
        return 0
      fi

      # ④ 启用态: 存产物前像 → 用**现有** LKG/白名单/用户规则重编译(不联网) → 产物真变才重启。
      local _eb="$ADB_STATE_DIR/effective_block.txt" _el="$ADB_STATE_DIR/effective_list.txt"
      local _eb_bak _el_bak _eb0 _el0
      _eb_bak="$(mktemp)"; _el_bak="$(mktemp)"
      cp -a "$_eb" "$_eb_bak" 2>/dev/null || : > "$_eb_bak"
      cp -a "$_el" "$_el_bak" 2>/dev/null || : > "$_el_bak"
      _eb0="$(sha256sum "$_eb" 2>/dev/null | cut -d' ' -f1)"
      _el0="$(sha256sum "$_el" 2>/dev/null | cut -d' ' -f1)"
      _adb_rollback(){
        local _bad=0
        cp -a "$_src_bak" "$ADB_USER_BLOCK" 2>/dev/null || _bad=1
        cp -a "$_eb_bak" "$_eb" 2>/dev/null || _bad=1
        cp -a "$_el_bak" "$_el" 2>/dev/null || _bad=1
        rm -f "$_src_bak" "$_eb_bak" "$_el_bak"
        return "$_bad"
      }
      local _cerr2
      if ! _cerr2="$(python3 "$mod" compile 1 "$ADB_STATE_DIR" "$ADB_USER_BLOCK" 2>&1 >/dev/null)"; then
        c_y "  ❌ 编译失败 —— 已回滚, 规则未生效。"
        [[ -n "$_cerr2" ]] && c_y "     原因: $(head -1 <<<"$_cerr2")"
        if _adb_rollback; then _adb_emit apply_failed_rolled_back "$_change"
        else _adb_emit rollback_incomplete "$_change"; fi
        return 1
      fi
      local _eb1 _el1 _restarted=false
      _eb1="$(sha256sum "$_eb" 2>/dev/null | cut -d' ' -f1)"
      _el1="$(sha256sum "$_el" 2>/dev/null | cut -d' ' -f1)"
      if [[ "$_eb0" != "$_eb1" || "$_el0" != "$_el1" ]]; then
        systemctl restart mosdns 2>/dev/null; sleep 1
        if ! systemctl is-active --quiet mosdns; then
          c_y "  ❌ mosdns 起不来 —— 已回滚, 规则未生效。"
          if _adb_rollback; then
            systemctl restart mosdns 2>/dev/null
            _adb_emit apply_failed_rolled_back "$_change"
          else
            c_y "  ⚠️ 回滚未能完整完成 —— 需要人工核对用户规则与编译产物。"
            _adb_emit rollback_incomplete "$_change"
          fi
          return 1
        fi
        _restarted=true
      fi
      rm -f "$_src_bak" "$_eb_bak" "$_el_bak"
      _adb_emit applied "$_change" "$_restarted" "$_ovr"
      return 0;;
    source)
      # 第三方源可配。存在 $ADB_SOURCES(一行一个 URL, 允许 # 注释); 文件缺失或为空就沿用
      # adblock.py 里的内置默认 —— 老机器升上来行为一个字节不变。
      # 白名单跟着**配置过的源**走(见 adblock.py allowed_fetch_hosts): 没 add 过的主机照样
      # 连不上, 而零重定向 / 非公网拒绝 / DNS-连接绑定 / TLS 校验那几道一条都没松。
      local _sub="${1:-list}" _url="${2:-}" mod
      mod="$(_pdg_module adblock.py)" || return 1
      case "$_sub" in
        list)
          # `--json` 给机器看(Telegram Bot 走这条): Bot **认字段不认措辞** —— 让它去解析
          # 下面那段中文, 措辞一改 Bot 就瞎了。人看的那份保持原样, 一个字没动。
          if [[ "$_url" == "--json" ]]; then
            python3 "$mod" list-sources "$ADB_SOURCES" 2>/dev/null || {
              echo '{"sources":[],"defaults":[]}'; return 1; }
            return 0
          fi
          python3 "$mod" list-sources "$ADB_SOURCES" 2>/dev/null | python3 -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit("读不到源列表")
cur=d.get("sources") or []; dft=d.get("defaults") or []
using_default = cur == dft
print("  当前生效的第三方源%s:" % ("(内置默认, 未自定义)" if using_default else ""))
for u in cur: print("    " + u)
if not using_default:
    print("  内置默认(reset 可回到这里):")
    for u in dft: print("    " + u)'
          ;;
        add)
          need_root adblock
          [[ -n "$_url" ]] || { c_y "❌ 需要一个 URL。"; return 2; }
          # 当场校验, 不拖到 update —— 那时用户已经把它记进配置里了。
          local _cw
          if ! _cw="$(python3 "$mod" check-source "$_url" 2>/dev/null)"; then
            c_y "❌ 这个 URL 不能作为规则源: $(printf '%s' "$_cw" | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("why",""))
except Exception: print("")')"
            c_y "   只接受 https、默认 443 端口、主机名是合法域名(不能是 IP 字面量)。"
            return 2
          fi
          _lock
          mkdir -p "$(dirname "$ADB_SOURCES")" || return 1
          if [[ -f "$ADB_SOURCES" ]] && grep -qxF "$_url" "$ADB_SOURCES"; then
            c_g "  已存在, 未改动。"; return 0          # 幂等
          fi
          local _t; _t="$(mktemp)" || return 1
          [[ -f "$ADB_SOURCES" ]] && cat "$ADB_SOURCES" > "$_t"
          printf '%s\n' "$_url" >> "$_t"
          install -m644 "$_t" "$ADB_SOURCES" || { rm -f "$_t"; c_y "❌ 写入失败, 未改动。"; return 1; }
          rm -f "$_t"
          c_g "  ✅ 已添加。下次 pdg adblock update 生效。"
          ;;
        del)
          need_root adblock
          [[ -n "$_url" ]] || { c_y "❌ 需要一个 URL。"; return 2; }
          [[ -f "$ADB_SOURCES" ]] && grep -qxF "$_url" "$ADB_SOURCES" \
            || { c_y "❌ 这个源不在列表里, 未改动。"; return 1; }
          _lock
          local _t; _t="$(mktemp)" || return 1
          grep -vxF "$_url" "$ADB_SOURCES" > "$_t"
          install -m644 "$_t" "$ADB_SOURCES" || { rm -f "$_t"; c_y "❌ 写入失败, 未改动。"; return 1; }
          rm -f "$_t"
          c_g "  ✅ 已删除。"
          ;;
        reset)
          need_root adblock
          _lock
          : > "$ADB_SOURCES" 2>/dev/null || { c_y "❌ 清空失败。"; return 1; }
          c_g "  ✅ 已回到内置默认源。"
          ;;
        *)
          echo "用法: pdg adblock source <list [--json]|add <URL>|del <URL>|reset>"; return 1;;
      esac
      ;;
    check)
      # **恰好一个参数。**多给一个多半是引号没打对(`check "a b"` 写成了 `check a b`),
      # 那时按第一个参数回答等于对着一个用户没打算问的东西给出确定结论。
      if [[ $# -ne 1 || -z "${1:-}" ]]; then
        echo "用法: pdg adblock check <域名>   (恰好一个参数)"; return 1
      fi
      local d="$1"
      local mod; mod="$(_pdg_module adblock.py)" || return 1
      # 先过输入契约。**管道会吞掉退出码**, 所以这里先落到变量再判 —— 原实现正是把
      # `python3 … | python3 …` 的成败丢掉了, 于是非法输入也一路走到"是否阻断"。
      local raw rc=0
      raw="$(python3 "$mod" check "$d" "$ADB_STATE_DIR" "$(dirname "$ADB_USER_ALLOW")" 2>/dev/null)" || rc=$?
      if [[ "$rc" != 0 ]]; then
        # 不回显原始输入 —— 它可能含 shell 标点或换行, 复述一遍等于把危险内容又抄进
        # 日志与用户的排障截图。只说是哪一类不合法。
        c_y "❌ 域名格式无效: $(python3 -c 'import json,sys
try: print(json.loads(sys.argv[1]).get("why","(未说明)"))
except Exception: print("(未说明)")' "$raw" 2>/dev/null)"
        c_y "   只接受一个 ASCII 域名(可带一个末尾点)。未做任何判定。"
        return 2
      fi
      python3 -c 'import json,sys
r=json.loads(sys.argv[1])
print("  域名      : %s" % sys.argv[2])
print("  是否阻断  : %s" % ("是" if r.get("blocked") else "否"))
print("  命中层级  : %s" % (r.get("layer") or "无命中"))
print("  命中规则  : %s" % (r.get("rule") or "-"))' "$raw" "$d"
      local meta; meta="$(cat "$ADB_STATE_DIR/meta.json" 2>/dev/null)"
      echo "  表版本    : $(python3 -c 'import json,sys
try: d=json.loads(sys.argv[1] or "{}"); print("%s 条, 更新于 %s, 来源 %s" % (d.get("count","?"), d.get("updated","?"), d.get("source","?")))
except Exception: print("(读不到元数据)")' "$meta" 2>/dev/null)"
      echo "  使用 LKG  : $([[ -s "$ADB_STATE_DIR/list.lkg" ]] && echo 是 || echo 否)";;
    *)
      echo "用法: pdg adblock <status|status-line|enable|disable|update|check <域名>|source <list|add|del|reset>|rule-add <域名>|rule-del <域名>>";;
  esac
}

# 受管块迁移: 老机器的 mosdns 配置里没有这两段(pdg update 从不用模板重渲那个文件)。
# 锚点缺失或重复一律 fail-closed —— 半安装的受管块比没装更难查。
migrate_adblock(){
  local mos=/etc/mosdns/config.yaml
  [[ -f "$mos" ]] || return 0                     # 没装 mosdns 的机器不归这条管
  # 形态判定全是只读的, 放在任何写入之前 —— 判定要跳过时, 这台机器上一个字节都不该被动过。
  local n_pl n_sq
  n_pl="$(grep -c "$ADB_MARK_PL" "$mos" 2>/dev/null)"; n_sq="$(grep -c "$ADB_MARK_SQ" "$mos" 2>/dev/null)"
  if [[ "$n_pl" -gt 1 || "$n_sq" -gt 1 ]]; then
    c_y "  ❌ mosdns 配置里 pdg-adblock 受管块出现多次(plugins=$n_pl sequence=$n_sq) —— 不自动修改, 请人工核对。"
    return 1
  fi
  if [[ "$n_pl" != "$n_sq" ]]; then
    c_y "  ❌ 受管块只装了一半(plugins=$n_pl sequence=$n_sq) —— 半安装比没装更糟, 不自动修补。"
    return 1
  fi
  if [[ "$n_pl" == 1 && "$n_sq" == 1 ]]; then
    # 已经装好: 不改配置, 但仍要把 domain_set 的输入文件补齐 —— 受管块在场而文件被删掉的话
    # mosdns 起不来, 这是每次更新都该做的自愈, 不能因为"无事可做"就跳过。
    _adblock_ensure_files || { c_y "  ❌ 受管块在场, 但去广告规则文件建不出来 —— mosdns 可能起不来。"; return 1; }
    return 0
  fi
  # 前置依赖: 受管块对外只引用一个 tag —— `$explicit_proxy`(由 migrate_mosdns_explicit_proxy 装)。
  # 调用顺序已经把它排在前面, 但那一支是 `|| true`, 允许自己跳过(pdgtx 卡在待收尾 / 配置形态
  # 不认识)。所以这里不能假设它成功, 必须自己确认 tag 真的定义了。不在就**跳过**而不是报错:
  # 插一个引用不存在插件的块会让 mosdns 起不来 → 整次更新回滚 → 这台机器再也升不上去。
  # 跳过是可恢复的: 等 explicit_proxy 到位, 下一次 pdg update 会把受管块补上。
  # 判据用 `- tag: explicit_proxy` 的**定义**(锚到行尾, 免得匹配上 explicit_proxy_seq),
  # 而不是它有没有被引用 —— 让引用合法的是定义, 不是用法。
  # 位置也是判据的一部分: 它必须排在**所有写入之前**, 包括建规则文件那一步。
  if ! grep -qE '^ *- tag: explicit_proxy$' "$mos"; then
    c_y "  [去广告] 这台的 mosdns 还没有 explicit_proxy 明确代理层 —— 本次跳过受管块安装"
    c_y "           (去广告功能暂不可用; 等明确代理层到位后, 下一次 pdg update 会自动补上)。"
    return 0
  fi
  local tmpl="$REPO_DIR/deploy/mosdns/config.yaml"
  [[ -f "$tmpl" ]] || { c_y "  ❌ 部署源缺 mosdns 模板, 不改现网。"; return 1; }
  local work; work="$(mktemp -d)" || return 1
  if ! python3 - "$mos" "$tmpl" "$work/candidate.yaml" <<'PYEOF'
import re, sys
live, tmpl, out = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(tmpl, encoding="utf-8").read()
cur = open(live, encoding="utf-8").read()
def block(text, kind):
    m = re.search(r"( *# >>> pdg-adblock managed block \(%s\).*?# <<< pdg-adblock managed block \(%s\)\n)"
                  % (kind, kind), text, re.S)
    return m.group(1) if m else None
pl, sq = block(t, "plugins"), block(t, "internal_sequence")
if not pl or not sq:
    sys.exit("模板里找不到受管块")
# plugins: 插在 force_hijack_seq 定义之前; sequence: 插在 $lazy_cache 之前
# 锚点必须是**结构**, 不是注释文案。上一版拿 `  # MITM 接管域名的劫持序列` 当 plugins 锚点 ——
# 那行只在仓库模板里(2026-07-20 的 ce9b72d 才加进去), 没有任何迁移会把它写进现网配置。于是
# 只有"那之后全新装机、由模板渲染出配置"的机器才有它; 存量机器的配置是老模板加一串迁移堆出来
# 的, 一律没有 —— 线上 jp(v1.10.16)实测就缺这一行, 整次更新因此回滚, 老机器全都升不上来。
# 换成 `  - tag: force_hijack_seq` 这个**定义行**: 它是被迁移真正写出来的结构, 不随注释文案变。
# (仓库自己早写过这条: tests/helpers/strip-explicit-proxy.py —— "不拿注释文案当锚点"。)
anc_pl = "  - tag: force_hijack_seq\n"
anc_sq = "      - exec: $lazy_cache\n"
if anc_pl not in cur or anc_sq not in cur:
    sys.exit("现网配置里找不到插入锚点(这台的 mosdns 配置形态不认识)")
cur = cur.replace(anc_pl, pl + anc_pl, 1)
cur = cur.replace(anc_sq, sq + anc_sq, 1)
open(out, "w", encoding="utf-8").write(cur)
PYEOF
  then
    c_y "  ❌ 去广告受管块候选生成失败, 现网未改动。"; rm -rf "$work"; return 1
  fi
  # 规则文件在**候选生成成功之后**才建: 候选都生成不出来时这台机器什么都没被改, 状态目录也
  # 不该凭空出现 —— 线上那次失败就在 /var/lib 下留了三个 0 字节文件, 而 doctor 的"从来没用过
  # 这个功能"判据正是看这个目录存不存在。但必须赶在落盘之前建好: 受管块一旦生效, mosdns 缺任何
  # 一个 domain_set 文件都会 FATAL。
  _adblock_ensure_files || { c_y "  ❌ 去广告规则文件建不出来, 不动 mosdns 配置。"; rm -rf "$work"; return 1; }
  # 候选的正确性靠**落盘后真的重启一次**来判 —— 与 pdg.sh 里其它改 mosdns 配置的地方
  # 同一口径(见 cache 调整那两处): 先备份, 再落盘, 起不来就整份还原。
  # 不在这里跑 `mosdns start` 做预检: 它是常驻进程, 用"超时没退出"当合法证据是假判据,
  # 而真正的失败(端口占用/权限)在预检里也复现不出来。
  local bak; bak="$mos.pre-adblock.$(date +%s)"
  cp -a "$mos" "$bak" || { rm -rf "$work"; return 1; }
  install -m644 "$work/candidate.yaml" "$mos" || { rm -rf "$work"; return 1; }
  systemctl restart mosdns 2>/dev/null; sleep 1
  if ! systemctl is-active --quiet mosdns; then
    c_y "  ❌ 装上去广告受管块后 mosdns 起不来 → 已还原。"
    cp -a "$bak" "$mos"; systemctl restart mosdns 2>/dev/null
    rm -rf "$work"; return 1
  fi
  rm -f "$bak"; rm -rf "$work"
  c_g "  [去广告] mosdns 受管块已装好(默认关闭, 解析行为不变)。"
  return 0
}
