#!/usr/bin/env python3
"""PrivDNS Gateway 自检 —— 只读, 一条命令跑全部检查。
  pdg doctor          人类可读
  pdg doctor --json   JSON 输出
  pdg doctor --deep   追加慢速端到端检查(DoT 握手 / :81 探测 / DNS 解析 / clash_api)
退出码: 有 fail → 1, 否则 0。"""
import sys, json
sys.path.insert(0, "/opt/pdg-bot")
import checks  # noqa: E402

def main():
    deep = "--deep" in sys.argv
    funcs = checks.ALL + (checks.DEEP if deep else [])
    results = checks.run(funcs)
    if "--json" in sys.argv:
        print(json.dumps([{"level": l, "check": lb, "detail": d} for l, lb, d in results],
                         ensure_ascii=False, indent=2))
    else:
        icon = {"ok": "🟢", "warn": "🟡", "fail": "🔴", "info": "ℹ️"}
        print("===== PrivDNS Gateway 自检" + (" (--deep)" if deep else "") + " =====")
        for l, lb, d in results:
            print(f"  {icon.get(l, '?')} {lb}: {d}")
        nf = sum(1 for l, _, _ in results if l == "fail")
        nw = sum(1 for l, _, _ in results if l == "warn")
        verdict = "🔴 有问题需处理" if nf else ("🟡 有警告" if nw else "🟢 全部正常")
        print(f"\n{verdict}  ({nf} 失败 / {nw} 警告)")
    return 1 if any(l == "fail" for l, _, _ in results) else 0

if __name__ == "__main__":
    sys.exit(main())
