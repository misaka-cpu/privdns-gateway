#!/usr/bin/env python3
"""在事务目录里造一笔**指定状态**的事务, 用来验"什么样的未完成事务该挡住迁移"。

用法: seed-stale-tx.py <tx根目录> <PREPARING|APPLYING|OBSERVING…> [几天前]

为什么要造: 两台线上机器上都躺着几笔"开了但从没应用过"的 PREPARING(定时 geosite 更新留下的)。
它们不挡任何写入 —— pdgtx 自己也不把它们算进 NEEDS_RECOVERY —— 但 `pending` 会把它们打印出来。
迁移若拿"输出非空"当判据, 就会在**恰恰最需要修的那些机器上**静默跳过。
"""
import json
import os
import sys
import time

root, state = sys.argv[1], sys.argv[2]
days = float(sys.argv[3]) if len(sys.argv) > 3 else 3.0
txid = "%s-seeded%s" % (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()), state[:4].lower())
d = os.path.join(root, txid)
os.makedirs(d, exist_ok=True)
meta = {"schema_version": 1, "txid": txid, "source": "test", "op": "seeded_" + state.lower(),
        "mode": "normal", "state": state, "started_at": time.time() - days * 86400,
        "ended_at": None, "targets": [], "services": [], "validations": [], "baseline": {},
        "observed": {}, "warnings": [], "error": "", "error_class": "",
        "rollback_complete": None, "diff": [], "staged": []}
with open(os.path.join(d, "meta.json"), "w", encoding="utf-8") as f:
    json.dump(meta, f, ensure_ascii=False)
print(txid)
