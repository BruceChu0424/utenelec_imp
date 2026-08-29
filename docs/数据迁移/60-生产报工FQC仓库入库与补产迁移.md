# 60 - 生产报工、FQC、仓库入库、失败补产与拒收重交迁移（V409–V415/V418）

> 日期：2026-08-28  
> 生产迁移范围：核心 V409–V415；后置拒收重交 V418  
> 当前全局源码头：V419/381；以[迁移总索引](README.md)顶部、`MigrationRehearsalSupport` 与最终冻结 manifest 的 exact-set 为准  
> 决策依据：[ADR-046](../99-决策记录-ADR/ADR-046-生产领料仓库点收报工归属与未来计件边界.md)、[ADR-054](../99-决策记录-ADR/ADR-054-生产报工质量放行与合格入库.md)  
> 状态：共享源码与本地 PostgreSQL 候选；目标非空库迁移、真实岗位 UAT、恢复和发布未完成，生产 **NO-GO**

> 最终本地证据：完整 Maven 2,511 项 0 failure/0 error（338 skipped）、完整 Flutter 1,137/1,137；专项组合契约 73/73、PostgreSQL 15/15、Flutter 聚焦 26/26。环境门禁跳过项由专项数据库运行补齐，但这些结果仍不是目标库或现场 UAT。

## 一、结论和权威数量

这组迁移把三种容易混淆的数量彻底分开：

- `reported_qty / fqty`：车间已经申报并获批的完工数量，是生产事实，不是合格库存。
- `passed_qty`：品质决定中允许进入成品入库待办的合格数量，是放行资格，不是库存。
- `accepted_qty / iqty`：仓库对 `FINISHED_IN` 实际点收并过账的数量，才是库存和生产完成率的权威。

因此计划数量 10,000、仓库累计实收 1,000 时，完成率为 10%。齐套 100%、报工 100% 或 FQC PASS 100% 都不能提前把生产完成率写成 100%。

## 二、版本职责

| 版本 | 数据库职责 | 对存量数据的影响 |
|---|---|---|
| V409 | 为 `production_daily_reports` 增加单调 `row_version`；新增 append-only `production_daily_report_commands`，以操作者、幂等键和请求哈希绑定唯一日报 | 既有日报版本为 0；不改数量、状态或库存 |
| V410 | 新增 FQC 检验、决定事件、放行命令和 PASS 分配四张账；数据库守住决定投影、命令总量和 PASS 容量 | 明确不回填历史 FQC，不把既有入库或 `iqty` 猜成 PASS |
| V411 | 在写唯一索引前检查活动 `plan_draw_links` 是否重复；一张物理 DRAW 只能有一个活动生产计划归属 | 发现歧义即阻断迁移，不自动删除、合并或猜归属 |
| V412 | 新增来源报工红冲对应的 FQC cancellation 事件；决定和放行分配保留为 append-only 历史；有活动成品入库时禁止取消 | 不补造历史 cancellation；只扩展检验状态约束 |
| V413 | 前向替换 V410 的延迟总量校验函数，用显式别名和 `v_*` 局部变量消除 PL/pgSQL 同名歧义 | 只替换函数体，不改表和业务数据；V410 字节保持不变 |
| V414 | 用显式 `production_fqc_legacy_exemptions` 取代“没有检验就当 legacy”；新增 REWORK/SCRAP/REJECT 恢复授权、分配、取消、贡献调整及补产分析链接 | 一次性登记迁移时所有无 inspection 的既有日报行；该登记不是 PASS，也不能由运行时新增 |
| V415 | 为 SCRAP/REJECT 建立独立补产物料周期、BOM 冻结需求、缺口、DRAW、实发 READY、反向和取消账；REWORK 仍直接走恢复授权 | 新列对既有需求保持 NULL；不伪造需求、库存、预留、DRAW 或实发事实 |
| V418 | 放宽 REJECTED confirmation 为可选 residual，并以前向函数强化同计划、同日报、全量零实收重交谱系 | 不回填或猜测历史拒收；历史无 residual 行继续合法，新在线写入必须有同源 residual |

V409–V415 与 V418 已经进入共享迁移序列。后续修正必须使用最终冻结时全局最高版本之后的未占用新版本；禁止修改、重命名、删除或复用这些版本，也禁止改写任何其它已应用迁移。

## 三、审计与不可变登记

新增业务表均安装 `fn_audit()` 触发器，并登记在 `AuditTriggerCoverageMigrationContractTest`：

| 版本 | 新增且要求审计覆盖的表 |
|---|---|
| V409 | `production_daily_report_commands` |
| V410 | `production_fqc_inspections`、`production_fqc_decision_events`、`production_fqc_release_commands`、`production_fqc_release_allocations` |
| V412 | `production_fqc_cancellation_events` |
| V414 | `production_fqc_legacy_exemptions`、`production_fqc_recovery_authorizations`、`production_fqc_recovery_cancellation_events`、`production_fqc_recovery_allocation_events`、`production_fqc_contribution_adjustments`、`production_fqc_replenishment_tasks`、`production_fqc_replenishment_analysis_links` |
| V415 | `production_fqc_replenishment_cycles`、`production_fqc_replenishment_attempts`、`production_fqc_replenishment_supply_gaps`、`production_fqc_replenishment_draw_links`、`production_fqc_replenishment_ready_events`、`production_fqc_replenishment_ready_reversals`、`production_fqc_replenishment_cycle_cancellations` |

V411 和 V413 不新建业务表，因此没有新的审计表登记；它们分别通过唯一索引/迁移阻断和函数前向修复守住已有事实。

## 四、目标非空库迁移前盘点

以下查询只能先在只读目标身份和可恢复副本执行。不要为了让结果为零而直接改目标数据。

### 4.1 确认真实 Flyway 起点

```sql
SELECT installed_rank, version, description, script, checksum, success
FROM flyway_schema_history
ORDER BY installed_rank;

SELECT max(version::int) FILTER (WHERE success AND version ~ '^[0-9]+$') AS head,
       count(*) FILTER (WHERE success AND version IS NOT NULL) AS versioned_count,
       count(*) FILTER (WHERE NOT success) AS failed_count
FROM flyway_schema_history;
```

每一行已应用的 `version/script/checksum` 都必须与同一受保护发布 lineage 的 manifest 完全一致。失败行、未知版本、重复版本、checksum 不同或源码缺失一律 **NO-GO**；禁止 `flyway repair` 或手工修改 history。

### 4.2 V411 的 DRAW 歧义预检

```sql
SELECT plan_id, draw_id, count(*)
FROM plan_draw_links
WHERE is_deleted = FALSE
GROUP BY plan_id, draw_id
HAVING count(*) > 1;

SELECT draw_id, count(DISTINCT plan_id)
FROM plan_draw_links
WHERE is_deleted = FALSE
GROUP BY draw_id
HAVING count(DISTINCT plan_id) > 1;
```

两项都必须为零。存在结果时应形成业务对账清单，由计划和仓库确认真实归属后通过独立、受审的数据处置完成；V411 不会替业务人员猜测。

### 4.3 V414 legacy cutover 预览

目标头低于 V410 时，所有既有日报行都没有 FQC 表事实，V414 会把它们登记为 pre-cutover exemption：

```sql
SELECT count(*) AS eventual_legacy_exemptions
FROM production_daily_report_items;
```

若目标曾停留在 V410–V413 并开放写入，则必须先在副本核对哪些日报行缺 inspection：

```sql
SELECT item.report_id, item.id AS report_item_id, report.bill_no, report.status
FROM production_daily_report_items item
JOIN production_daily_reports report ON report.id = item.report_id
LEFT JOIN production_fqc_inspections inspection
  ON inspection.source_report_item_id = item.id
WHERE inspection.id IS NULL
ORDER BY report.created_at, item.id;
```

这类环境不能盲目把所有缺失行都解释成历史兼容：必须区分真正的 V410 前事实与 V410 部署后漏登记缺陷。V414 的运行时没有新增 exemption 的入口，迁移完成后 absence 会失败关闭。

### 4.4 备份与业务基线

迁移窗口前至少冻结并保存：

- 数据库名、`system_identifier`、timeline、目标当前 head 和完整 history。
- 可恢复备份及 SHA-256，并真实恢复到隔离副本。
- 生产计划、执行段、日报行、`fqty/iqty`、活动 DRAW、成品入库单/行、库存余额和流水的行数及数量汇总。
- V414 exemption 预期行数、V411 歧义结果、FQC 相关对象是否已存在。
- 当前审计触发器矩阵和被禁用的非内部触发器数量。

## 五、迁移后验收

### 5.1 全局头与唯一版本

生产专项核心截止 V415，拒收重交前向修复为 V418；完整候选的全局 head/count 当前为 V419/381，并必须与迁移总索引、`MigrationRehearsalSupport` 和 checksum manifest 三方 exact-set 一致。迁移成功后执行：

```sql
SELECT max(version::int) FILTER (WHERE success AND version ~ '^[0-9]+$') AS head,
       count(*) FILTER (WHERE success AND version IS NOT NULL) AS versioned_count,
       count(*) FILTER (WHERE NOT success) AS failed_count
FROM flyway_schema_history;
```

`head/versioned_count` 必须等于最终冻结值，`failed_count` 必须为 0。不要在并行迁移尚未稳定时把阶段数字写成永久合同。

若发布时目录继续新增迁移，应以冻结 manifest 和 `MigrationRehearsalSupport` 的同一 exact-set 为准，不可只手工改本文数字。

### 5.2 审计触发器

```sql
SELECT table_row.relname AS table_name, count(*) AS audit_trigger_count
FROM pg_trigger trigger_row
JOIN pg_class table_row ON table_row.oid = trigger_row.tgrelid
JOIN pg_proc trigger_function ON trigger_function.oid = trigger_row.tgfoid
WHERE NOT trigger_row.tgisinternal
  AND trigger_function.proname = 'fn_audit'
  AND table_row.relname LIKE 'production_fqc_%'
GROUP BY table_row.relname
ORDER BY table_row.relname;
```

上表列出的每张 FQC 表应恰有一个有效 AFTER ROW I/U/D 审计触发器；不能用“有一个名字像 audit 的触发器”替代函数、时机、级别和事件校验。

### 5.3 FQC 决定和放行守恒

```sql
SELECT inspection.id, inspection.reported_qty,
       inspection.passed_qty, inspection.failed_qty,
       coalesce(sum(event.pass_qty), 0) AS event_pass,
       coalesce(sum(event.fail_qty), 0) AS event_fail
FROM production_fqc_inspections inspection
LEFT JOIN production_fqc_decision_events event
  ON event.inspection_id = inspection.id
GROUP BY inspection.id
HAVING inspection.passed_qty <> coalesce(sum(event.pass_qty), 0)
    OR inspection.failed_qty <> coalesce(sum(event.fail_qty), 0);

SELECT command.id, command.requested_qty,
       coalesce(sum(allocation.qty), 0) AS allocated_qty
FROM production_fqc_release_commands command
LEFT JOIN production_fqc_release_allocations allocation
  ON allocation.release_command_id = command.id
GROUP BY command.id
HAVING command.requested_qty <> coalesce(sum(allocation.qty), 0);

SELECT decision.id, decision.pass_qty,
       coalesce(sum(allocation.qty), 0) AS released_qty
FROM production_fqc_decision_events decision
LEFT JOIN production_fqc_release_allocations allocation
  ON allocation.decision_event_id = decision.id
GROUP BY decision.id
HAVING coalesce(sum(allocation.qty), 0) > decision.pass_qty;
```

三项结果都应为空。CANCELLED 只取消当前资格，不删除决定或放行历史，因此不能通过删除历史行把查询“修绿”。

### 5.4 legacy、恢复和物料闭环

```sql
SELECT exemption.source_report_item_id
FROM production_fqc_legacy_exemptions exemption
JOIN production_fqc_inspections inspection
  ON inspection.source_report_item_id = exemption.source_report_item_id;

SELECT authorization.id, authorization.disposition_code
FROM production_fqc_recovery_authorizations authorization
LEFT JOIN production_fqc_recovery_cancellation_events cancellation
  ON cancellation.authorization_id = authorization.id
WHERE cancellation.id IS NULL
  AND authorization.disposition_code IN ('SCRAP', 'REJECT')
  AND NOT fn_fqc_replenishment_material_ready(authorization.id);
```

第一项必须为空。第二项是尚未取得完整 BOM 需求履约并真实 DRAW 发料的开放补产授权，它们可以存在，但必须保持不可报工；只有 READY 事实成立后才允许新的恢复报工分配。

## 六、自动化证据

静态迁移合同至少包括：

- `ProductionFqcQualityReleaseMigrationContractTest`（V410）
- `ProductionPlanDrawActiveUniquenessMigrationContractTest`（V411）
- `ProductionFqcSourceReversalMigrationContractTest`（V412）
- `ProductionFqcReleaseFunctionRepairContractTest`（V413）
- `ProductionFqcRecoveryAndLegacyCutoverMigrationContractTest`（V414）
- `ProductionFqcReplenishmentMaterialMigrationContractTest`（V415）
- `ProductionFinishedInboundRejectedResidualMigrationContractTest`（V418）
- `AuditTriggerCoverageMigrationContractTest`
- `LegacyMigrationSafetyContractTest`

真实 PostgreSQL 候选至少包括：

- `ProductionFqcEmptyDatabaseMigrationPostgresTest`：空库迁移和 FQC/恢复结构守卫。
- `ProductionFqcReplenishmentMaterialPostgresTest`：V415 SCRAP/REJECT 物料闭环。
- `ProductionDailyReportCommandPostgresTest`：V409 命令幂等和并发。
- `ProductionFinishedInWarehouseConfirmationPostgresTest`：V338 点收兼容与 V418 `REJECTED + residual` 同源重交谱系；本轮 8/8。
- `ProductionFqcEmptyDatabaseMigrationPostgresTest`：空库真实应用 381 个迁移至 V419；本轮 2/2。
- `FullChainEndToEndTest#exactExecutionSegment_partialInboundCanShipWhileSegmentContinuesThenCloses`：计划 10、首收 1 显示 10%，余量与第二批闭环。
- `V238ToCurrentSyntheticMigrationPostgresTest`：合成非空基线升级到当前头。
- `CurrentHeadNonEmptyCloneRehearsalTest`：只允许在显式绑定数据库身份、备份摘要、批准引用的可恢复克隆执行，永不对普通开发库或目标主库自动运行。

空库、合成非空和本地真实链通过仍不等于公司目标库历史对账、真实权限/岗位 UAT、恢复演练或发布签字通过。

## 七、发布、失败和回滚边界

1. 从同一受保护 commit/tag 生成应用 JAR、migration-only JAR、与最终全局迁移数一致的 checksum manifest 和发布签名；exact-set 必须一致。
2. 停写并排空旧实例，在已验证备份恢复出的副本先执行最终冻结的全链迁移、JPA validate 和本页对账。
3. 正式窗口只运行同一签名 migration-only 候选；入口在迁移、history、结构、数量、审计和 readiness 全部通过前保持关闭。
4. 失败时保留原始日志与 history，只能新增更高版本前向修复，或恢复到迁移前已经演练且与旧版本完全一致的备份。
5. 禁止 `flyway repair`、手工改 checksum/history、修改任何已应用迁移、删除约束/触发器、用旧 JAR 覆盖新 schema，或把 exemption/通知/页面状态伪造成 FQC 与库存事实。

离线 legacy bootstrap 的 head、数量、mapping version、安全合同和说明必须在全局迁移头稳定后一起重新冻结；常量一致本身不代表已生成受保护 manifest，也不代表目标副本 bootstrap、对账或恢复完成。这些证据缺一项，发布仍为 **NO-GO**。
