# W7（P7 收尾：增长守卫、读视图合同、JIT 口径更正）实测与定论 2026-11-08

环境：5434 容器公司数据副本 `uten_perf_w2`（V1117，7,552 张导入计划全部登记、0 个执行段）与
`uten_perf_probe_dev`（V1117，34 段）；公司服务器 `uten_imp`（V1111，103 段 / 7,570 计划）只读探针
`BEGIN READ ONLY` + `statement_timeout 60s` + `lock_timeout 2s`，结束 ROLLBACK，未写任何库。
真库测试经 Testcontainers（迁移基线克隆 / 一次性容器），未推送、未部署。

## 1. JIT 口径更正（推翻 W2 记下的「剩余热点」）

应用连接初始化固定 `SET jit = ${uten.database.jit-enabled:false}`（`application.yml:40-41`，
`CloudDataSourceConfig:73` 同策略，准则 07 性能自适应有记载）；生产 `/etc/uten-imp/*.env` 与全部
systemd drop-in 均无 `UTEN_DB_JIT` 覆盖——**应用连接恒关 JIT**。W2 §1 计时写明「公司库只读 EXPLAIN
ANALYZE，JIT 同开」：psql 会话默认 `jit=on`，而根视图/段视图这类大视图的计划代价远超
`jit_above_cost`(100000) 与 inline/optimize 阈值(500000)，JIT 编译数百个表达式本身就要数秒。

公司库只读复测（同一会话、同一数据，先开后关）：

| 查询 | 开 JIT（W2 的测法） | 关 JIT（应用实际） |
|---|---:|---:|
| 段视图全投影 + 排序页（LIMIT 100） | 1,746 ms | **85 ms**（复测 84） |
| 根视图整读（302 根，V1094 形态——公司库未上 V1117） | 7,254 ms | **404 ms**（复测 402） |
| 根视图 count（徽章口径） | 1,788 ms | **90 ms** |

- W2 记下的「段视图整投影 1.70 s/页」「根视图整读 3.8 s / count 2.15 s」主要是 JIT 编译读数；
  应用路径分别约 85 ms / 0.4 s / 90 ms。P2.2「三段 <1s」按应用口径已满足；productionExecution
  徽章来源约 90 ms，不再是「徽章合计 <2s」的阻断项。W2 证据保留原始数字，以本节为准。
- 教训：凡用 psql/EXPLAIN 给应用读路径计时，先 `SET jit = off` 对齐应用连接；守卫测试同样关 JIT。

## 2. 进行中根列表谓词下推实验（V1120 草案，验证后不采用）

- 现象：`CURRENT_ROOT_PREDICATE` 是 `CASE … NOT EXISTS(登记表)`，含子查询的条件不会被下推进视图
  `roots` 的 UNION ALL，导入历史根要先经逐根 LATERAL 汇总才被剔除（全量可见用户的默认列表、
  单号表头筛选、徽章都走它）。
- 草案：视图末尾追加 `imported_root`（历史计划分支按登记表主键左连求得，分析根恒 FALSE），
  调用方改为列谓词 `NOT root.imported_root`。副本库事务内演练：5 个锚点各命中 1 次；新旧谓词在
  全部根上逐行对称差 **0**；计划里历史分支变成登记表 Hash Anti Join，输出 0 行。
- 关 JIT 对比（`uten_perf_w2`，7,470 导入根）：旧谓词 **29.6 ms** → 新谓词 **10–14 ms**；开 JIT 时的
  3,209 → 2,646 ms 差额几乎全是编译开销。
- 定论：每条省约 18 ms（列表一次加载 3 条语句，约 50 ms），收益不足以再加一个视图迁移（本分支
  迁移号段合并时本就要整体顺延，见 §6）。草案已删除、未提交；历史根的逐根成本由 §3 守卫钉住斜率。

## 3. P2.2 增长守卫 `ProductionExecutionWorkbenchGrowthPostgresTest`

当前迁移结构（V1094 根视图 + V1117 共享段扫描，计划/明细/子计划链接/登记表带真实约束与索引），
原生根 5 个（2 分析 + 3 计划，其一带执行段），注入公司库同形历史计划（全部登记、无执行段、每 25 张
留 1 张未完结）；与应用一致 `SET LOCAL jit = off`。

| 导入历史计划 | 其中未完结 | 徽章 p50 | 默认列表 p50 | 全量根 p50 | 明细探查次数 |
|---:|---:|---:|---:|---:|---:|
| 1,000 | 40 | 7.6 ms | 7.6 ms | 7.5 ms | 43 |
| 10,000 | 400 | 42.3 ms | 40.2 ms | 33.9 ms | 403 |
| 30,000 | 1,200 | 102.7 ms | 110.4 ms | 102.5 ms | 1,203 |

- 断言：徽章 = 默认列表 = 5（导入历史不进「进行中」）；全量根 = 5 + 未完结历史；已完结历史计划在
  计划状态条件处短路，「计划还有未完成明细」探查次数 ≤ 原生计划 + 未完结历史；探查走计划索引，
  不出现 `production_plan_items` 顺序扫描。耗时三次采样只落证据。
- 夹具历史计划带制单人（最坏形状）。公司库导入计划 `maker_id` 为空，徽章口径在 owner 谓词处即被
  剪掉（副本库徽章 0 行）；默认列表无 owner 谓词，按上表斜率约 3.4 µs/导入根，公司库 7,470 根约
  25 ms，下一轮导入翻倍也只多约 25 ms。

## 4. P1.6 读视图合同 `ImportedDocumentReadViewContractPostgresTest`

完整迁移链之后，public 下全部视图与物化视图的定义都不得内联导入单据的权威遍历入口
（`fn_imported_business_document` / `_row` / `_row_internal`）；履约任务中心视图
`v_procurement_decomposition_tasks` 另做 VERBOSE 计划核对。比单条 EXPLAIN 更严：覆盖全部视图、
不受计划器选择影响。副本库现状：唯一调用该函数族的视图 `v_imported_business_document_guard_tables`
只调 `_roots`（IMMUTABLE 根清单），不是遍历。1/1 绿（67 s，含迁移基线）。

## 5. 同夜其余收尾

- 遍历计数假零更正（`63b2f69bb`）：W6 记的「originWalks=0」来自未开 `track_functions` 的运行；开跟踪
  实测 2×2 报告写路径守卫入口 2 次、递归遍历步 33 次，属「写路径保留权威函数」口径（w6 §4 更正）。
- 财务分类弹窗 `_completeReferences` 保留理由补记进 w4b 保留清单（三份读取同一代次退休）。

## 6. 迁移号撞号（合并前必须处理）

本分支 V1115–V1119（`imported_document_registry` / `procurement_order_closed_at_task_window` /
`execution_workbench_roots_shared_segment_scan` / `fulfillment_workbench_read_revisions` /
`system_read_perf_wave_w6c_w7`）与当前本地 main（`5a1ea982e`）的 V1115–V1119
（`execution_workbench_actual_top_level_products` / `production_overproduction_request_optional_reason` /
`production_daily_report_local_weight_basis` / `preplan_receipt_priority` /
`subcontract_material_shortage_choices`）同号不同文件；另有在途工作树已用到 V1124
（`subcontract-material-shortage-20261107`、`warehouse-physical-stock-20261107`）。合并时须把本分支五个
迁移整体顺延到 main 当时最高号之后，并同步：迁移内自引用注释（V1116/V1117/V1119 头注）、按文件名
读取迁移的测试（`ProductionExecutionWorkbenchRootsSharedScanPostgresTest`、
`ProductionExecutionWorkbenchGrowthPostgresTest` 读 V1094/V1117，`DataLifecycleRegistryContractTest` 读
V1119）、`docs/数据迁移/README.md` 头注、`ForwardMigrationSequenceContractTest` 连续性，以及 W1
回填（约 190 万行、6–9 分钟）的维护窗口安排。本轮按授权不合并、不推送。
