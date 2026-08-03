#!/usr/bin/env bash
# 6.1C 负控: 每条都先把某处改坏, 确认"改坏器真的命中了", 再看对应测试是否转红。
# 恢复用逐字节备份 + sha256 核对, 不用任何 destructive git 命令。
cd /home/codex/privdns-gateway || exit 1
B="${PDG_NC_OUT:-$(mktemp -d)}"
rm -rf "$B"; mkdir -p "$B"
cp deploy/bot/pdg-bot.py "$B/"; cp deploy/bot/linkstat.py "$B/"; cp deploy/bot/linksess.py "$B/"
sha256sum deploy/bot/pdg-bot.py deploy/bot/linkstat.py deploy/bot/linksess.py > "$B/sha.txt"
export PDG_TEST_STRICT=1
PASS=0; FAIL=0

restore(){ cp "$B/pdg-bot.py" deploy/bot/pdg-bot.py
           cp "$B/linkstat.py" deploy/bot/linkstat.py
           cp "$B/linksess.py" deploy/bot/linksess.py; }

# nc <编号> <说明> <改坏的python代码> <该转红的测试>
nc(){
  local n="$1" desc="$2" breaker="$3" test="$4"
  if ! python3 -c "$breaker"; then
    echo "[NC$n ✗] 改坏器没命中: $desc"; FAIL=$((FAIL+1)); restore; return
  fi
  if timeout 900 python3 "$test" >"$B/nc$n.log" 2>&1; then
    echo "[NC$n ✗] 改坏了却仍然全绿 —— 判据是空的: $desc"; FAIL=$((FAIL+1))
  else
    echo "[NC$n ✓] $desc → $(grep -cE '^\[FAIL' "$B/nc$n.log") 条转红"
    PASS=$((PASS+1))
  fi
  restore
}

P=deploy/bot/pdg-bot.py
rd() { echo "import io;p='$P';s=io.open(p,encoding='utf-8').read()"; }

nc 1 "绕过授权后建会话(鉴权移到 handle_cb 之后)" \
"$(rd); o='if q[\"from\"][\"id\"] in ALLOWED:\n                        handle_cb('; \
n='if True:\n                        handle_cb('; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 2 "把 token 写进消息正文" \
"$(rd); o='edit(chat, mid, \"%s\\\\n\\\\n%s\\\\n\\\\n%s\" % (LINK_INTRO, LINK_START_HINT, LINK_WAITING), kb)'; \
n='edit(chat, mid, \"%s\\\\n\\\\n%s\\\\n\\\\n%s\\\\n%s\" % (LINK_INTRO, LINK_START_HINT, LINK_WAITING, payload[\"step1_url\"]), kb)'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 3 "不关闭链接预览" \
"$(rd); o='\"reply_markup\": kb or MENU, \"disable_web_page_preview\": True}'; \
assert s.count(o)>=1, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,'\"reply_markup\": kb or MENU}'))" \
tests/test-link-bot.py

# 改坏器必须**语法合法**: 第一版写成 kb_with_url(未定义), 测试是崩掉的 —— 那证明的是
# "代码会崩", 不是"判据有牙齿"。0 条转红就是这个信号。
nc 4 "出结果后仍保留 URL 按钮" \
"$(rd); o='        edit(chat, mid, txt, LINK_DONE_KB if done else LINK_BACK); return'; \
n='        _leak = {\"inline_keyboard\": [[{\"text\": \"x\", \"url\": \"http://a:81/probe?t=leaked\"}]]}\n        edit(chat, mid, txt, _leak if done else LINK_BACK); return'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 5 "把 HTTP 成功写成 SIM/APN 正常" \
"$(rd); o='\"这只证明 HTTP 测试请求到达网关，不代表 DoT、SIM/APN 或整体联网正常。\")'; \
n='\"SIM/APN 正常。\")'; assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-copy-boundary.py

nc 6 "把来源段内写成 DoT 正常" \
"$(rd); o='LINK_INSIDE = (\"✅ 网关已收到本次 HTTP 测试请求。\\\\n\"'; \
n='LINK_INSIDE = (\"✅ DoT 正常。\\\\n\"'; assert o in s, 'anchor'; \
io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-copy-boundary.py

nc 7 "删掉会话过期检查" \
"import io;p='deploy/bot/linksess.py';s=io.open(p,encoding='utf-8').read(); \
o='    expired = _expired(rec, now)'; n='    expired = False'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 8 "后台任务异常后不释放占用" \
"$(rd); o='    finally:\n        with _linktest_lock:\n            _linktest_waiters.pop(chat, None)'; \
n='    finally:\n        pass'; assert o in s, 'anchor'; \
io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 9 "Bot 里复制一套 token 生成" \
"$(rd); o='    okk, payload = linksess.start_session()'; \
n='    import secrets\n    _t = secrets.token_urlsafe(32)\n    okk, payload = linksess.start_session()'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 10 "第 6.5 层改成 PASS" \
"import io;p='deploy/bot/linkstat.py';s=io.open(p,encoding='utf-8').read(); \
o='6.5, \"L6_DOT_METRICS_UNAVAILABLE\", NOT_OBSERVED'; n='6.5, \"L6_DOT_METRICS_UNAVAILABLE\", PASS'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 11 "probe81 不可用仍发测试链接" \
"$(rd); o='    if blockers:'; n='    if False:'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 12 "重复点击创建多个会话" \
"$(rd); o='    if busy_until > time.time():'; n='    if False:'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

# 锚点里不放 \n: 经 bash 单引号 → python 字符串两层转义后对不上, 改坏器不命中 ——
# 那样"负控"什么也证明不了(第一版就是这么废掉的)。
nc 13 "把「普通 DNS 与代理不受影响」加回 STATE_UNWRITABLE 文案" \
"$(rd); o='\"请运行 sudo pdg doctor 检查网关状态。\")'; \
n='\"请运行 sudo pdg doctor 检查网关状态。普通的 DNS 与代理不受影响。\")'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

nc 14 "把 /run 路径塞回 STATE_UNWRITABLE 文案" \
"$(rd); o='                   \"请运行 sudo pdg doctor 检查网关状态。\")'; \
n='                   \"请检查 /run 是否可写。\")'; \
assert o in s, 'anchor'; io.open(p,'w',encoding='utf-8').write(s.replace(o,n,1))" \
tests/test-link-bot.py

echo "────────────────"
echo "负控 通过 $PASS, 失败 $FAIL"
echo "── 还原核对 ──"; sha256sum -c "$B/sha.txt"
