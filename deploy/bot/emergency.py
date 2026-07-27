#!/usr/bin/env python3
"""紧急默认出口(T6)—— **只改 route.final**, 一笔事务。

它解决的是这么一个处境: 当前默认出口挂了, 手机上什么都打不开, 而 Bot 也连不上(它自己就走
那条链路)。这时候用户需要一个能在救援页上按一下、把"其余流量"换到另一个还活着的出口的开关。

刻意划死的边界:
  · **只改 route.final**。已有的分流规则、优先级、规则集一个字都不动 —— 所以这**不是**
    "全局强制单出口": 命中高优先级规则的流量仍然各走各的出口。页面上必须把这句话写出来,
    否则用户会以为按下去就等于全部走这一个出口, 在排障时得出完全错误的结论。
  · model、派生的 mihomo_cfg、rescue_state **在同一笔 pdgtx 事务里**。状态文件绝不在事务外
    单独写 —— 那样一旦渲染或落盘失败, 盘上就会留下一个"说自己启用了"的状态, 而配置根本没变。
  · 候选出口只能来自**当前模型里真实存在**的出口枚举(与 bot 同一套判据), HTTP 传什么进来都
    要重新枚举核对一遍。

状态机(rescue-state.json):
  · 首次启用: 记下 route.final **原本有没有**以及原值, 然后改成所选出口;
  · 已启用再换一个: 只更新 emergency_final, **原值保持第一次那份** —— 否则连切两次之后
    "恢复"就把用户送回上一个紧急出口, 而不是他自己原来的配置;
  · 恢复: 当前 route.final 必须仍等于记录的 emergency_final; 不等就是有人(Bot/CLI/配置恢复/
    完整恢复)在这期间改过 —— 标 stale 并**拒绝**, 绝不拿旧记录覆盖用户后来的修改。
"""
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, "/opt/pdg-bot")

import mihomorender  # noqa: E402

SCHEMA_VERSION = 1
STATE_TARGET = "rescue_state"
MODEL_TARGET = "model"
MIHOMO_TARGET = "mihomo_cfg"


def _tx():
    """事务核心。拿不到就什么都别做 —— 紧急出口是**写操作**, 没有事务就没有回滚保证。"""
    import pdgtx
    return pdgtx


def _sha_of(obj):
    """对象 → 稳定摘要(键排序)。用来记"启用那一刻 route 长什么样"。"""
    import hashlib
    return hashlib.sha256(
        json.dumps(obj, ensure_ascii=False, sort_keys=True).encode("utf-8")).hexdigest()


def blank_state():
    # 刻意**没有** enable_txid: txid 要到 stage 之后才定, 想写进状态就得再改一次状态文件,
    # 与"三个目标一笔事务"冲突。留一个恒为空的字段只会让人以为"没记录" —— 追溯以 pdgtx 的
    # 审计为准(那里有 txid)。旧状态文件里带着这个键也不要紧: 下面按本表的键逐个取, 多出来的
    # 一律忽略。
    return {"schema_version": SCHEMA_VERSION, "active": False, "original_present": False,
            "original_final": "", "emergency_final": "", "enabled_at": 0,
            "route_digest": "", "last_state": "inactive"}


def parse_state(raw):
    """读状态。**坏了就当没有**(fail-closed 到"未启用"), 绝不据一份读不懂的状态去改配置。"""
    if not raw:
        return blank_state()
    try:
        st = json.loads(raw.decode("utf-8") if isinstance(raw, bytes) else raw)
    except Exception:  # noqa: BLE001
        return blank_state()
    if not isinstance(st, dict) or st.get("schema_version") != SCHEMA_VERSION:
        return blank_state()
    out = blank_state()
    for k in out:
        if k in st:
            out[k] = st[k]
    out["active"] = bool(out.get("active"))
    return out


def state_bytes(st):
    return json.dumps(st, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8")


def candidates(model):
    """可选的紧急出口: 当前模型里真实存在的出口。与 bot 的判据同源。"""
    return mihomorender.exit_tags(model)


def current_final(model):
    route = (model or {}).get("route") or {}
    return route.get("final") if "final" in route else None


def status(model, raw_state):
    """页面要显示的一切。**纯读**, 不写任何文件(GET 请求不许有副作用)。

    stale 的判据: 记录说自己启用着, 但当前 route.final 已经不是记录里的紧急出口了 —— 说明
    这期间有别的入口改过配置。这时候一键恢复必须拒绝, 否则会把用户后来的修改覆盖掉。"""
    st = parse_state(raw_state)
    cur = current_final(model)
    out = {"active": bool(st["active"]), "stale": False, "current_final": cur,
           "original_present": bool(st["original_present"]),
           "original_final": st["original_final"], "emergency_final": st["emergency_final"],
           "enabled_at": st["enabled_at"], "candidates": candidates(model),
           "original_available": True}
    if st["active"]:
        out["stale"] = (cur != st["emergency_final"])
        # 原出口可能在紧急期间被删了 —— 那就恢复不回去, 页面要说清楚而不是等按下去才报错
        if st["original_present"]:
            out["original_available"] = st["original_final"] in out["candidates"]
    out["last_state"] = "stale" if out["stale"] else ("active" if st["active"] else "inactive")
    return out


def _derive_mihomo(paths):
    return mihomorender.deriver_from_paths(**paths)


def _commit(op, mutate, paths, trigger_source, audit_extra):
    """启用与恢复共用的事务骨架: 读 model + 读状态 → 算候选 → 三个目标一起 stage → 提交。

    三者同事务是硬要求: 状态文件单独写的话, 渲染失败/落盘失败/观察期失败之后, 盘上会留下一个
    "说自己启用了"的状态而配置没变 —— 之后的一键恢复就会照着这份幻觉去改用户的配置。"""
    tx = _tx()
    out = {"ok": False, "op": op, "state": "", "txid": "", "error": "", "changed": []}
    t = tx.Tx(source="rescue", op=op, mode="normal")
    out["txid"] = t.txid
    try:
        model_raw, model_sha = t.read_for_update(MODEL_TARGET)
        if not model_raw:
            out["error"] = "读不到数据模型, 未改动任何文件"
            t.abort_unstarted(out["error"])
            return out
        model = json.loads(model_raw.decode("utf-8"))
        state_raw, state_sha = t.read_for_update(STATE_TARGET)
        st = parse_state(state_raw)
        new_model, new_state, err = mutate(model, st)
        if err:
            out["error"] = err
            t.abort_unstarted(err)
            return out
        t.audit_extra = dict(audit_extra or {})
        t.audit_extra.update({"trigger_source": trigger_source,
                              "original_present": bool(st["original_present"]),
                              "original_tag": st["original_final"] or "(无)",
                              "emergency_tag": (new_state["emergency_final"]
                                                or st["emergency_final"] or "(无)")})
        if op == "emergency_default_restore":
            # 还原成了什么: 有原值就点名, 原本就没有 route.final 就明确记 absent ——
            # 两者在事后排障时是完全不同的结论。
            if st["original_present"]:
                t.audit_extra["restored_tag"] = st["original_final"]
            else:
                t.audit_extra["restored_absent"] = True
        else:
            t.audit_extra["original_present"] = bool(new_state["original_present"])
            t.audit_extra["original_tag"] = new_state["original_final"] or "(无)"
        t.stage(MODEL_TARGET, json.dumps(new_model, ensure_ascii=False,
                                         indent=2).encode("utf-8"), expect=model_sha)
        t.stage(STATE_TARGET, state_bytes(new_state), expect=state_sha)
        t.derive(MIHOMO_TARGET, _derive_mihomo(paths))
        out["changed"] = [MODEL_TARGET, MIHOMO_TARGET, STATE_TARGET]
        # 服务动作由**变化的目标**推导 —— rescue_state 自己不牵动任何服务, 真正要重启内核的
        # 是 model/mihomo_cfg。不固定重启 mosdns: 分流规则一个字没动, DNS 侧没有理由重来。
        for a in tx.actions_for_targets([MODEL_TARGET, MIHOMO_TARGET, STATE_TARGET]):
            t.service(a)
        res = t.commit()
    except tx.TxBusy:
        out["error"] = "已有配置操作正在执行, 本次未做任何改动"
        out["busy"] = True
        return out
    except tx.TxRefused as e:
        out["error"] = tx.redact(str(e))
        out["state"] = "REFUSED"
        return out
    except tx.TxError as e:
        out["error"] = tx.redact(str(e))
        return out
    finally:
        t.abort_unstarted()
    out["state"] = res.get("state", "")
    out["ok"] = out["state"] == tx.COMMITTED
    out["executed_actions"] = list(t.meta.get("executed_actions", []))
    if res.get("error"):
        out["error"] = tx.redact(str(res["error"]))
    return out


def enable(tag, *, paths, trigger_source="rescue"):
    """把 route.final 换成 tag。已启用同一个 tag 时幂等(不重启、不动状态时间)。"""
    def mutate(model, st):
        if tag not in candidates(model):
            return None, None, "出口 %s 不在当前模型里, 拒绝设置" % mihomorender._safe_ident(tag)
        cur = current_final(model)
        if st["active"] and st["emergency_final"] == tag and cur == tag:
            return None, None, "__NOCHANGE__"
        if st["active"] and cur != st["emergency_final"]:
            # 期间被别人改过: 再次启用时必须以**当前值**作为新的原值, 否则恢复会回到一个
            # 早就不成立的旧配置。
            base_present, base_final = ("final" in (model.get("route") or {})), cur
        elif st["active"]:
            # 连续切换: 原值保持第一次那份 —— 否则连切两次之后"恢复"会把用户送回上一个
            # 紧急出口, 而不是他自己原来的配置。
            base_present, base_final = st["original_present"], st["original_final"]
        else:
            base_present, base_final = ("final" in (model.get("route") or {})), cur
        new_model = json.loads(json.dumps(model))
        new_model.setdefault("route", {})["final"] = tag
        new_state = blank_state()
        new_state.update({
            "active": True, "original_present": bool(base_present),
            "original_final": base_final or "", "emergency_final": tag,
            "enabled_at": st["enabled_at"] if (st["active"] and st["enabled_at"])
            else int(time.time()),
            "route_digest": _sha_of(model.get("route") or {})[:16],
            "last_state": "active"})
        return new_model, new_state, ""

    res = _commit("emergency_default_enable", mutate, paths, trigger_source,
                  {"event": "emergency_default_enable"})
    if res.get("error") == "__NOCHANGE__":
        return {"ok": True, "op": "emergency_default_enable", "state": "NO_CHANGE",
                "txid": "", "error": "", "changed": [], "executed_actions": [],
                "note": "已经是这个紧急出口, 未做任何改动"}
    return res


def restore(*, paths, trigger_source="rescue"):
    """把 route.final 精确还原成启用前的样子(原本没有这个键就删掉它)。"""
    def mutate(model, st):
        if not st["active"]:
            return None, None, "紧急默认出口未启用, 没有可恢复的原值"
        cur = current_final(model)
        if cur != st["emergency_final"]:
            # stale: 期间有别的入口改过 route.final。拿旧记录覆盖过去就是把用户后来的修改
            # 抹掉 —— 宁可拒绝, 让他自己决定。
            return None, None, ("当前默认出口已不是紧急出口(记录=%s, 当前=%s), "
                                "状态已过期, 拒绝覆盖后来的修改" % (
                                    mihomorender._safe_ident(st["emergency_final"]),
                                    mihomorender._safe_ident(cur)))
        if st["original_present"] and st["original_final"] not in candidates(model):
            return None, None, ("原默认出口 %s 已不存在, 无法恢复; 状态保留, "
                                "请先把它加回来或手动指定" % mihomorender._safe_ident(
                                    st["original_final"]))
        new_model = json.loads(json.dumps(model))
        route = new_model.setdefault("route", {})
        if st["original_present"]:
            route["final"] = st["original_final"]
        else:
            route.pop("final", None)          # 原本就没有这个键 → 删掉, **不写 null**
        new_state = blank_state()
        new_state["last_state"] = "inactive"
        return new_model, new_state, ""

    return _commit("emergency_default_restore", mutate, paths, trigger_source,
                   {"event": "emergency_default_restore"})
