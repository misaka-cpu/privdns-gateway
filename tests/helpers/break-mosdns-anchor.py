#!/usr/bin/env python3
"""拆掉迁移赖以定位的锚点(force_hijack 域名集与它那道判断)= "高度自定义、无法安全识别"。

用来验 fail-closed: 迁移必须拒绝, 现网配置一个字节都不许动。"""
import re
import sys

f = sys.argv[1]
s = open(f, encoding="utf-8").read()
s = re.sub(r"  - tag: force_hijack\n    type: domain_set\n    args: \{[^\n]*\n", "", s)
s = re.sub(r"      # MITM 接管域名[^\n]*\n      - matches: qname \$force_hijack\n"
           r"        exec: goto force_hijack_seq\n", "", s)
if "tag: force_hijack\n" in s:
    sys.exit("锚点没拆掉, 构造失败")
open(f, "w", encoding="utf-8").write(s)
