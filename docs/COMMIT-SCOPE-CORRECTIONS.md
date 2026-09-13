# 提交说明与实际文件范围不符 —— 事实更正

分支 `fix/retire-wloc`。下面这几笔提交的**说明写窄了**: 它们实际改动的文件范围比说明里讲的
更大。**树是对的, 每一处改动本身也是有意为之并且验过的; 错的是提交信息的边界。**

按本轮约定, 这些提交**不改写**(不 amend / rebase / squash / reset) —— 历史照留, 事实写在这里。
以后 `git log --stat` 与这份说明一起看。

成因是同一个: `git rm` 或前一步 `git add` 已经把改动暂存了, 而后面那次 `git commit` 没有
重新核对暂存区就带走了它们。补救是**提交前逐文件核对 `git diff --cached --name-only`** ——
从 `cadf5c9` 起已经这么做了。

---

## `9a9755a` — test(wloc): pin the retirement, not just the absence of code

说明写的是"两支新判据"。**实际还包含**:

| 实际含有 | 说明里没提 |
|---|---|
| 删除 `deploy/bot/mitm_server.py`(171 行) | ✅ 漏了 |
| 删除 `deploy/bot/mitm_wloc.py`(596 行) | ✅ 漏了 |
| 删除 10 支只测 WLOC 的测试(`test-mitm-ca*.py`、`test-mitm-server.py`、`test-mitm-wloc*.py`、`test-wloc-copy.py`、`test-wloc-hotswitch.py`、`test-wloc-hotreload.py`、`e2e-wloc.sh`) | ✅ 漏了 |

那两个产品模块的删除**应当属于** `96a005e`(特性笔), 10 支测试的删除应当属于 `fec51ff`
(测试与文档处置笔)。

## `fec51ff` — chore(wloc): retire WLOC tests, CI entries and docs

**实际还包含** `lib/units.sh`、`lib/modules.sh`、`lib/preserve.sh` 三个文件的产品改动
(删掉 `pdg_unit_pdg_mitm`、把两个模块移进 `PDG_LEGACY_MODULES`、把 `mitm_hijack.txt` 移出
重装保留清单)。它们**应当属于** `96a005e`。

## `7396d9e` — fix(lock): prove the inherited lock instead of trusting a claim

说明只讲了继承锁。**实际 `deploy/bot/iosstate.py` 里还包含**另外两组改动:

- **用户设置沿用**(对应 `276462a` 的 §7 判据): `_blank()` 增加 `retired_inputs`、
  `_migrate_1_to_2` 把退役那一版的输入带过来、`effective_ssids` 增加回退链、
  `_check_meta_object` 增加 `retired_inputs` 的契约校验;
- **迁移前的产物校验与原子边界**(对应 `276462a` 的 §8 判据): `_migrate_schema_locked` 在动
  任何东西之前逐份验产物、缺失与损坏分开处置、写后复核挪进 `_Txn` 的可恢复边界内。

这三组改动本身都由 `1146acb` / `276462a` 两支判据先转红后转绿, 一处都不是顺手带进来的 ——
只是它们被塞进了同一笔提交, 而那笔的说明只讲了其中一组。
