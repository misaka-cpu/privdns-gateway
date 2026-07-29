#!/usr/bin/env python3
"""把一份当前形态的 mosdns 配置退回 v1.7.0 形态(摘掉明确代理的域名集/序列/判断)。

E2E 夹具用: 造一台"还没修过的 v1.7.0 机器"。摘不干净就报错 —— 夹具没造对而用例照跑,
验的是别的东西。"""
import re
import sys

f = sys.argv[1]
s = open(f, encoding="utf-8").read()
s = re.sub(r"  # 明确代理集:[\s\S]*?(?=  - tag: ecs_china\n)", "", s)
s = re.sub(r"  # 明确代理域名的劫持序列[\s\S]*?(?=  - tag: internal_sequence\n)", "", s)
s = re.sub(r"      # 用户点名指到出口的域名[\s\S]*?exec: goto explicit_proxy_seq\n", "", s)
if "explicit_proxy" in s:
    sys.exit("没退回到 v1.7.0 形态: 仍残留 explicit_proxy")
open(f, "w", encoding="utf-8").write(s)
