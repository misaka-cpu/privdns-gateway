#!/usr/bin/env bash
# probe81 迁移 fail-closed 的负控。每条先确认改坏器命中锚点, 再看对应测试是否转红。
# "0 条转红"= 测试崩了, 不是通过 —— 那种负控什么也证明不了(本轮之前踩过)。
# 恢复用逐字节备份 + sha256 核对, 不用任何 destructive git 命令。
cd /home/codex/privdns-gateway || exit 1
B="${PDG_NC_OUT:-$(mktemp -d)}"; mkdir -p "$B"
cp deploy/bot/pdg.sh "$B/"; cp tests/test-probe81-migrate-failclosed.py "$B/"
sha256sum deploy/bot/pdg.sh tests/test-probe81-migrate-failclosed.py > "$B/sha.txt"
export PDG_TEST_STRICT=1
PASS=0; FAIL=0
restore(){ cp "$B/pdg.sh" deploy/bot/pdg.sh
           cp "$B/test-probe81-migrate-failclosed.py" tests/test-probe81-migrate-failclosed.py; }

nc(){
  local n="$1" desc="$2" breaker="$3" test="$4"
  if ! python3 -c "$breaker"; then
    echo "[NC$n ✗] 改坏器没命中: $desc"; FAIL=$((FAIL+1)); restore; return
  fi
  local red
  if timeout 900 python3 "$test" >"$B/nc$n.log" 2>&1; then
    echo "[NC$n ✗] 改坏了却仍全绿 —— 判据是空的: $desc"; FAIL=$((FAIL+1))
  else
    red=$(grep -cE '^\[FAIL' "$B/nc$n.log")
    if [ "$red" = "0" ]; then
      echo "[NC$n ✗] 测试是崩掉的(0 条转红), 不算负控: $desc"; FAIL=$((FAIL+1))
    else
      echo "[NC$n ✓] $desc → $red 条转红"; PASS=$((PASS+1))
    fi
  fi
  restore
}

P=deploy/bot/pdg.sh
rp(){ echo "import io;p='$P';s=io.open(p,encoding='utf-8').read()"; }
T=tests/test-probe81-migrate-failclosed.py

nc 1 "恢复 [[ -f template ]] || return 0" \
"$(rp); o='  if [[ ! -f \"\$tmpl\" ]]; then'; n='  [[ -f \"\$tmpl\" ]] || return 0\n  if false; then'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 2 "只打印错误但仍返回 0" \
"$(rp); o='     切到目标版本再重跑迁移。\"\n    return 1'; n='     切到目标版本再重跑迁移。\"\n    return 0'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 3 "run_all_migrations 吞掉非零" \
"$(rp); o='  migrate_probe81_public || rc=1'; n='  migrate_probe81_public || true'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 4 "cmd_update 吞掉 __migrate 的非零" \
"$(rp); o='  if ! bash /usr/local/bin/pdg __migrate; then'; n='  if false; then'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 5 "unit 已存在时就绕过模板缺失" \
"$(rp); o='  if [[ ! -f \"\$tmpl\" ]]; then'; \
n='  if [[ ! -f \"\$tmpl\" ]] && [[ ! -f /etc/systemd/system/pdg-probe81.service ]]; then'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 6 "检查模板之前先动 unit" \
"$(rp); o='  local tmpl=\"\$REPO_DIR/deploy/bot/pdg-probe81.service\"'; \
n='  local tmpl=\"\$REPO_DIR/deploy/bot/pdg-probe81.service\"\n  : > /etc/systemd/system/pdg-probe81.service'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 7 "缺模板仍执行 daemon-reload" \
"$(rp); o='    c_y \"  ❌ 当前部署源缺少 pdg-probe81 unit 模板(\$tmpl)。\"'; \
n='    systemctl daemon-reload 2>/dev/null\n    c_y \"  ❌ 当前部署源缺少 pdg-probe81 unit 模板(\$tmpl)。\"'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 8 "install 失败后不返回非零(留半安装)" \
"$(rp); o='      c_y \"  ❌ 写入 pdg-probe81.service 失败(保留原状)。\"; return 1; }'; \
n='      c_y \"  ❌ 写入失败\"; return 0; }'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 9 "平台切换里跳过公共迁移" \
"$(rp); o='  if ! migrate_probe81_public; then\n    echo \"❌ pdg-probe81 公共件迁移失败(详见上方), 平台切换回退\"'; \
n='  if false; then\n    echo \"❌ pdg-probe81 公共件迁移失败(详见上方), 平台切换回退\"'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

nc 10 "故障注入没命中却判绿(把夹具的 install 桩改成永不失败)" \
"import io;p='tests/test-probe81-migrate-failclosed.py';s=io.open(p,encoding='utf-8').read(); \
o='+ (\"exit 1\\\\n\" if fail_install else'; n='+ (\"\" if fail_install else'; \
assert o in s,'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" "$T"

echo "────────────────"
echo "负控 通过 $PASS, 失败 $FAIL"
echo "── 还原核对 ──"; sha256sum -c "$B/sha.txt"
