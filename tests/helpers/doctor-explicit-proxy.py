#!/usr/bin/env python3
"""断言 `pdg doctor --json` 里「明确代理优先级」那一项的等级(并在 warn 时要求点名未迁移)。

用法: doctor-explicit-proxy.py <doctor.json> <ok|warn|fail>"""
import json
import sys

want = sys.argv[2]
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:                      # 读不出来就是不通过, 不能静默当成通过
    sys.exit("读不了 doctor 输出: %s" % e)
hit = [x for x in d if x.get("check") == "明确代理优先级"]
if not hit:
    sys.exit("doctor 里没有「明确代理优先级」这一项")
if hit[0].get("level") != want:
    sys.exit("等级是 %s, 期望 %s: %s" % (hit[0].get("level"), want, hit[0].get("detail", "")[:120]))
if want == "warn" and "未迁移" not in hit[0].get("detail", ""):
    sys.exit("warn 了但没点名未迁移: %s" % hit[0].get("detail", "")[:120])
