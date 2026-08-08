#!/usr/bin/env bash
# .153 那个 P0(动态用户读不到 profile.env)的负控。
# 每条先确认**改坏器真的命中锚点**, 再看对应测试是否转红 —— 改坏器没命中的"负控"什么也
# 证明不了(6.1C 那轮踩过两次: 未定义变量让测试崩掉、锚点里带 \n 转义对不上)。
# 恢复用逐字节备份 + sha256 核对, 不用任何 destructive git 命令。
cd /home/codex/privdns-gateway || exit 1
B="${PDG_NC_OUT:-$(mktemp -d)}"
mkdir -p "$B"
cp deploy/bot/linksess.py deploy/bot/pdg-bot.py "$B/"
cp tests/linksess_profile_uid_probe.py "$B/"
sha256sum deploy/bot/linksess.py deploy/bot/pdg-bot.py tests/linksess_profile_uid_probe.py > "$B/sha.txt"
export PDG_TEST_STRICT=1
PASS=0; FAIL=0
restore(){ cp "$B/linksess.py" deploy/bot/linksess.py
           cp "$B/pdg-bot.py" deploy/bot/pdg-bot.py
           cp "$B/linksess_profile_uid_probe.py" tests/linksess_profile_uid_probe.py; }

nc(){
  local n="$1" desc="$2" breaker="$3" test="$4"
  if ! python3 -c "$breaker"; then
    echo "[NC$n ✗] 改坏器没命中: $desc"; FAIL=$((FAIL+1)); restore; return
  fi
  if timeout 900 python3 "$test" >"$B/nc$n.log" 2>&1; then
    echo "[NC$n ✗] 改坏了却仍全绿 —— 判据是空的: $desc"; FAIL=$((FAIL+1))
  else
    echo "[NC$n ✓] $desc → $(grep -cE '^\[FAIL' "$B/nc$n.log") 条转红"
    PASS=$((PASS+1))
  fi
  restore
}

L="deploy/bot/linksess.py"
rl(){ echo "import io;p='$L';s=io.open(p,encoding='utf-8').read()"; }
UID_T=tests/test-link-profile-uid.py

nc 1 "probe81 路径恢复读 profile.env" \
"$(rl); o='inside_internal_cidr(client_ip, rec.get(\"internal_cidr\"))'; \
n='inside_internal_cidr(client_ip, _profile(\"PDG_INTERNAL_CIDR\"))'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 2 "start_session 不写 CIDR 快照" \
"$(rl); o='\"internal_cidr\": internal_cidr,'; n='\"internal_cidr\": None,'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

# 默认值要**能过校验器**才会产生坏行为: 0.0.0.0/0 会被 cidrgen 拦掉, 改坏器等于没改。
nc 3 "缺 CIDR 时默认成项目示例网段" \
"$(rl); o='    if not raw:'; n='    raw = raw or \"172.22.0.0/16\"\n    if False:'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 4 "consume 改用当前 profile 而不是会话快照" \
"$(rl); o='rec.get(\"internal_cidr\")),'; n='_profile(\"PDG_INTERNAL_CIDR\")),'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 5 "把 profile.env 全文写进状态" \
"$(rl); o='        \"internal_cidr\": internal_cidr,'; \
n='        \"internal_cidr\": internal_cidr,\n        \"profile_dump\": open(os.environ.get(\"PDG_PROFILE_ENV\", PROFILE_ENV)).read(),'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 6 "把敏感项(SECRET_SENTINEL 所在键)写进状态" \
"$(rl); o='        \"internal_cidr\": internal_cidr,'; \
n='        \"internal_cidr\": internal_cidr,\n        \"leak\": _profile(\"PDG_RESCUE_TOKEN\"),'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 7 "保存完整 peer IP" \
"$(rl); o='\"ipv4_16\": ipv4_16(client_ip),'; n='\"ipv4_16\": client_ip,'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

# 边界其实是**目录**挡住的(/etc/privdns-gateway 0700 root), 只放宽文件 mode 动态用户照样
# 进不去 —— 第一版只改文件, 于是"负控"什么都没证明。要真拆掉边界得连目录一起放宽。
nc 8 "放宽 profile.env 与其目录权限(边界消失, 测试必须抓住)" \
"import io;p='tests/linksess_profile_uid_probe.py';s=io.open(p,encoding='utf-8').read(); \
o='    os.chmod(profile, 0o600)               # 与真机一致: root 独占'; \
n='    os.chmod(profile, 0o644); os.chmod(etc, 0o755)'; assert o in s,'anchor'; \
io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 9 "去掉真实 setuid(退化成同一个 uid)" \
"import io;p='tests/linksess_profile_uid_probe.py';s=io.open(p,encoding='utf-8').read(); \
o='        os.setuid(uid)                      # 真的换身份, 不是 seteuid 也不是桩'; \
n='        pass'; assert o in s,'anchor'; \
io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 10 "schema 不匹配仍继续读取" \
"$(rl); o='rec.get(\"schema_version\") != SCHEMA_VERSION'; n='False'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 11 "Bot 里单独复制一套 CIDR 解析" \
"import io;p='deploy/bot/pdg-bot.py';s=io.open(p,encoding='utf-8').read(); \
o='    okk, payload = linksess.start_session()'; \
n='    import ipaddress\n    _mycidr = ipaddress.ip_network(\"172.22.0.0/16\", strict=False)\n    okk, payload = linksess.start_session()'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" tests/test-link-bot.py

nc 12 "状态写入失败后仍返回 URL" \
"$(rl); o='    if not write_state(rec):\n        return False, {\"error\": \"会话状态写不下去(%s 不可写?)\" % _runtime_dir(),'; \
n='    if False:\n        return False, {\"error\": \"会话状态写不下去(%s 不可写?)\" % _runtime_dir(),'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" tests/test-link-bot.py

nc 13 "动态用户交接失败却报告成功(不 chown 给目录属主)" \
"$(rl); o='        if uid is not None and os.geteuid() == 0 and uid != 0:'; \
n='        if False:'; assert o in s,'anchor'; \
io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$UID_T"

nc 14 "改 TTL 掩盖问题" \
"$(rl); o='TTL_SECS = 300'; n='TTL_SECS = 86400'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" tests/test-link-session.py

# runner 自检: 人为塞一条无效负控, 证明脚本真的会返回非零。
# 以前脚本最后一句是 sha256sum -c, 退出码就是它的 —— 有 NC ✗ 也照样 rc=0,
# 于是"负控失效"这件事在 CI 里完全看不见。
if [[ "${PDG_NC_SELFTEST:-}" == 1 ]]; then
  echo "[SELFTEST] 人为记一条无效负控"; FAIL=$((FAIL+1))
fi

echo "────────────────"
echo "负控 通过 $PASS, 失败 $FAIL"
echo "── 还原核对 ──"
RC=0
sha256sum -c "$B/sha.txt" || { echo "[FAIL] 还原核对不通过"; RC=1; }
[[ "$FAIL" -eq 0 ]] || { echo "[FAIL] 有 $FAIL 条负控无效(改坏了却没转红, 或改坏器空转)"; RC=1; }
[[ "$PASS" -gt 0 ]] || { echo "[FAIL] 零条有效负控"; RC=1; }
exit "$RC"
