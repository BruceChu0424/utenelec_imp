# W3 第一部分（P3 徽章每来源语句时限）实测 2026-11-07

## 实现

`WorkbenchBadgeService.readIsolated`：每个来源在既有 JDBC 保存点内先执行一次「读原值 + 收紧」（`current_setting('statement_timeout')` 先物化，再 `set_config(..., true)` 设为 `min(调用方时限, 5s)`；调用方时限为 0（不限）或更宽时取 5s，更严则原样保留），读完在**释放保存点之前**写回原值。

- 失败/超时路径：`ROLLBACK TO SAVEPOINT` 一并撤销收紧（事务级设置随子事务回滚），来源记入 `failed` → 入口进既有 `staleEntries`（前端保留上次数），不改口径、不连累其它来源。
- 成功路径：`RELEASE SAVEPOINT` 会把事务级设置一直留到事务结束，所以先写回原值再释放；写回失败时保存点仍在，照常回滚。
- 时限是**每条语句**上限（PostgreSQL `statement_timeout` 语义）；徽章来源绝大多数是单条 COUNT。不加缓存（复核文档已否决）。

## 验收口径修订

主文档 §P3「注入 >5s 来源、汇总仍 <2s」与 5s 上限自相矛盾：慢来源要等到时限才被取消，汇总耗时 ≈ 时限 + 其余来源。现行验收：慢来源在其时限处取消并进 stale，其余入口照常给出数，调用方时限原样恢复。

## 测试

- `WorkbenchBadgeSourceFailureTest.slowSourceIsCancelledIntoStaleWhileLaterSourcesAndTheCallerTimeoutAreKept`（真库，容器）：来源上限调为 200ms；被另一连接持 ACCESS EXCLUSIVE 锁的表上的查询阻塞 → 200ms 取消、只有该来源/入口进 stale，其后来源读到的时限是 `200ms`、给出正确计数，汇总 <2s；调用方 `SET LOCAL statement_timeout TO '7s'` 在汇总后仍是 `7s`；调用方更严（150ms）时来源看到 `150ms` 且不被放宽。
- 既有 mock 夹具（`WorkbenchBadgeSourceFailureTest` 其余 4 例、`WorkbenchBadgeBrowsingAudienceTest`、`WorkbenchBadgeReadTransactionTest`、`WarehouseDirectionBadgeContractTest`）经 `BadgeStatementBudgetStubs` 接受限时/写回两次往返，原断言（stale 只标自己、恢复日志、事务隔离级别、仓库方向口径）全部不变：5+1+3+4 全绿。
