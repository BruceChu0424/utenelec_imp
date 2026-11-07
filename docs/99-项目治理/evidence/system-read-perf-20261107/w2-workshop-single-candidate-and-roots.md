# W2（P2 履约/车间候选收口 + V1117 根视图单趟化）实测 2026-11-07

环境：5434 容器；公司数据副本克隆 `uten_perf_w2`（V946 副本经分支 Flyway 全链 184 个迁移正式迁到 V1117，含 V1115 登记表回填，总 719 s）；开发备份克隆 `uten_perf_probe_dev`（V1111，34 段/3 分析）；公司服务器 `uten_imp`（V1111）全部探针 `BEGIN READ ONLY` + 超时，未写任何库。

## 1. V1117 根视图单趟化（8 次段视图展开 → 1 次 MATERIALIZED CTE）

- 实现按 V923/V1116 的锚点校验 + `pg_get_viewdef` 原地改写：`workbench_segment_facts AS MATERIALIZED (SELECT <rollup 用到的 27 列> FROM v_production_execution_workbench_segments shared_segment)` 供 8 个聚合共享；锚点断言「段视图引用=8、7 处 `FROM ... task`、rollup 派生表形状唯一、未重写过」，防重复执行与未知形状。
- 等价性对拍（探针库 + 公司库，均事务内）：
  - `uten_perf_probe_dev`：改写前后根行 EXCEPT ALL 对称差 = 0；
  - 公司库 `uten_imp`（只读，同一语句内新旧定义并列执行）：**302 ↔ 302 行、对称差 0**；改写前后 `pg_get_viewdef` md5 与本机一致（bac19f28…），证明公司库可原地应用同一改写；
  - 真库等价测试 `ProductionExecutionWorkbenchRootsSharedScanPostgresTest`：混合 ANALYSIS/PLAN 根（含 >3 预览、CANCELLED/REVERSED 段、多单位/多色、无段数量回退），V1094 定义与 V1117 定义全列逐值一致；重复执行 V1117 被锚点拒绝。
- 计时（公司库只读 EXPLAIN ANALYZE，JIT 同开）：

| 查询 | 改前（V1094 形态） | 改后（V1117） |
|---|---:|---:|
| 根视图整读（302 根，实际用户链路 list/group） | 7201 ms | **3773 ms** |
| 根视图 count（inProgressRootCount 徽章） | 1788 ms | 2151 ms |

count 小幅回退的原因：MATERIALIZED CTE 固定求值全投影（含 rollup 需要的 `reportable` 等逐行函数），而旧内联形态在 count-only 查询里可裁剪未用列。整读收益（−3.4 s）远大于 count 回退（+0.36 s）；count 属徽章来源，已由 W3 每来源 5 s 上限兜底。副本库 `uten_perf_w2` 上根视图整读 4.07 s / count 3.85 s：段=0 时单趟化无差异，剩余成本是 7,470 个历史计划根的逐根 demand/action/plan LATERAL（超出 W2 范围，见 §4）。

## 2. 车间任务页一次候选（count/data 4 条 SQL → 2 条）

`readSegmentPage` 改为一条语句：`segment_candidates AS MATERIALIZED (谓词过滤的段视图)` 一次求值，`page_segments`（窗口行号 + LIMIT/OFFSET）与 `candidate_total` 都从候选派生；页行再挂既有物料/齐套富化 LATERAL。空页（页码超末页）才单独补一条 count 收回末页（原钳制语义）。

- 逐行函数一次求值：`fn_split_batch_empty_issued` / `fn_actual_supplement_material_ready` / `fn_material_discovery_pending` 挪进 readiness LATERAL，投影内 5/4/4 处引用全部改读 readiness 列（每行每函数 1 次）；档位 CASE 排序键保持短路口径（WAITING 行不调函数）。
- **全局次序修复（对拍发现的缺陷）**：W2 第一部分的有界窗口（存储序前 3×(offset+size) 候选求档位）与「完整读取逐页拼接」合同冲突——候选 > 3 页时后页会重复窗口行、漏掉排在窗口外的档位 0 行，`loadCompletePagedResult` 的身份去重会以 SNAPSHOT_CHANGED 拒绝整次读取。本次改为：排序键对**全部候选**精确求值（两处 ORDER BY：page_segments 窗口行号 + 外层 page_position），跨页拼接恒等于全局 (档位, 存储键) 次序；有界窗口及其 `SEGMENT_STORAGE_CANDIDATES`/`candidateLimit` 参数整体移除。
- facets 两条合一：无候选分页上下文时 `workshopTaskFacets` 用同一 `facet_candidates AS MATERIALIZED` 一次段视图求值出 sourcePlan/segment 两组桶（各 500 桶上限、值/计数/排序与原两条一致）；候选分页上下文仍走原样单查询。一次页面加载的段视图求值次数 4 → 2。
- 语句数合同更新：`materialEntryFlagsUseActualLedgerBalancesInOneScopedBatch` 语句数 4 → 3（count 并入页语句）。
- 新测试 `preparingOrderIsOneGlobalReadinessOrderAcrossEveryPageAndExportBatch`：14 段夹具（12 个 READY 里 9/10/11 为档位 0、按存储序排在 3×2 窗口之外），钉死：8 页拼接 = 全局次序且无重无漏；单页 100 行同序；超末页钳制到末页；`workshopTaskExportBatch` 500 行批次同序；facets 桶值正确。

## 3. 车间任务导出批次上限修复（对拍发现的存量缺陷）

导出走 `ReportQueryKit.paginateAll`（500 行/批、批不满即判「不完整」），但底层 `workshopTasks` 单页上限 100——第一批 100<500 触发 `Export source is incomplete`。新增 `workshopTaskExportBatch`（同一谓词/排序/可见范围，单批上限 500），导出服务改走它；交互页保持 100。2026-11-06 移除行数上限后任何 >100 行的车间任务导出都会失败，本批修复。

## 4. 计时与复核结论

| 项 | 值 |
|---|---|
| `uten_perf_w2`(V1117) 履约待处理 PURCHASE 原生 count（冷/热） | 61 / 28 ms |
| `uten_perf_w2` 履约待处理 SUBCONTRACT 原生 count | 13.5 ms |
| `uten_perf_w2` 进行中状态子集（徽章口径） | 24 / 22 ms |
| 公司库段视图 count（103 段） | 2.1 ms |
| 公司库段视图整投影 + 排序页（LIMIT 100） | 1.70 s |
| 公司库活动采购单（status=1 AND NOT is_closed AND termination_case_id IS NULL） | Seq Scan 152 行，1.0 ms |

- **W2-5 活动单部分索引：不加**。V1116 后活动单谓词在公司库是 152 行、1.0 ms 的顺序扫描（无逐行函数、无排序热点）；部分索引不改变用户可感知时延，且须过 SchemaIndexHygieneContractTest 的必要性论证。复核结论：不需要。
- **W2-6 FulfillmentWorkbenchPageRead 状态先筛：不做**。`metadata_groups` 按全部候选统计各状态计数（分段徽章口径），`statusFilter` 压进 candidates 会让分段计数变成「已筛选子集的分布」，口径变化；候选视图本身已 MATERIALIZED 单次求值，先筛不减少段视图求值次数。记为不做。
- 段视图整投影固定成本（公司库 1.70 s / 页）是剩余热点：逐行 `reportable`/物料保管函数与 lateral 聚合，属视图自身形状，超出本轮「候选收口」范围；W7 的 EXPLAIN 增长守卫将其钉进监控。

## 5. 测试

- `ProductionExecutionWorkbenchQueryPostgresTest` 26/26（含新跨页次序测试与语句数 3 合同）；
- `ProductionExecutionWorkbenchRootsSharedScanPostgresTest` 1/1（V1094↔V1117 全列对拍 + 锚点防重）；
- `ProductionWorkshopTaskExportServiceTest` 5/5（导出走 500 批次且交互入口不再被导出调用）；
- `IqcTriggerProfileEndToEndTest`（V1116 新触发器下预算内）1/1；采购/委外结案 E2E 68/68；`AuditTriggerCoveragePostgresTest` 11/11、`AuditTriggerCoverageMigrationContractTest` 17/17；
- `CurrentWorkbenchOriginPostgresTest` 2/2、`ProductionWorkbenchStockCoverageEndToEndTest` 2/2、`TaskReadScopesEndToEndTest` 1/1、`ProductionWorkshopAssignmentScopePostgresTest` 1/1、`ProductionWorkbenchSourceFulfillmentPostgresTest` 16/16、`LegacyMigrationSafetyContractTest` 12/12（README V1117/1056 标记核对）。
