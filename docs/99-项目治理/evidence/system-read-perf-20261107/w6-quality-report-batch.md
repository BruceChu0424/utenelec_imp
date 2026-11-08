# W6（P6 品质批量通过）实现与预算 2026-11-08

## 1. 基线处境（本机当日状态，先如实记录）

`IqcDecideReportBatchPostgresTest#twentyReceiptBatchCompletesWithinDeadlineBudget`（20×5=100 行）在本机当日状态
（Docker Desktop on Windows、Defender 实时扫描、多次容器全量迁移后的 I/O 状态）**两轮都无法在 40s 服务端命令截止内完成**，
decide-report 409「本次操作处理时间过长已自动取消，没有生效，请稍后再重试」：

| 运行 | 条件 | [decide-report] elapsedMs | JDBC 段 | 语句数 |
|---|---|---|---:|---:|
| 第 1 轮 | track_functions=all 全局 | 409（截止取消） | 37,860ms | 3,939 |
| 第 2 轮 | 无跟踪 | 409（截止取消） | 38,102ms | 4,362 |

2026-10-13 基线 11.2s 是当日机器状态（历史参考值）。track_functions=all 本身是全局税（每函数调用计数），
第一轮的 3,939 条语句里每条都付了这个税；第二轮无跟踪仍 38s——本机当日每语句均摊 ~8.7ms（正常热态 1-2ms），
主因是 Defender 扫描 + 容器冷态。**结论：本机当日无法复现 11.2s 绝对值，W6 验收改为同机同状态的前后对照
（语句数下降 + 功能全绿 + 小场景计时），绝对预算断言（<30s/<35s）留 CI。**

## 2. 已实现（随本文件提交）

- **B 三轮→两轮**：`FulfillmentMutationLocks.acquireNestedWithoutRecheck(discovery)` 新入口——已持联合预锁的
  嵌套取锁跳过 `recheckPrefixCoverage`（它会把联合发现整图重跑一遍）；诊断开关(verify-nested-footprint)照旧
  重跑嵌套发现核对覆盖，测试安全网不撤。`ProcurementMutationLocks.inspectionHeld(...)` 适配；`decideReport`
  的逐单 `lockInspectionRows(…, heldPrefix=true)` 用之，其后既有的 `unionGuard.verifyUnchanged()` 严格相等
  复核（重读同一份发现逐行比较）覆盖了被跳过的检查且更强。发现轮次：初始 1 + 嵌套复核 1 + 严格复核 1 → 初始 + 严格 = 2。
- **A 精确唤醒**：`MaterialAnalysisSupplyWakeupService.candidateQuery(dimensionSql, exact)` 加 exact 形态。
  报告路径 `afterQualityReportCompleted` 改走 `exactReceiptTargets` 三臂：
  ① `preplan_analysis_stock_exact_pegs.source_receipt_type/source_receipt_id` 直指本报告收货单 →
  `beneficiary_analysis_id`（索引 idx_preplan_exact_peg_receipt）；
  ② 收货明细→订货明细（request_item_id / application_item_id）= `preplan_supply_action_allocations.external_item_id` → `analysis_id`；
  ③ 保留 `ownsQualifiedAt`（v_preplan_stock_entitlement_beneficiary_balance / FORMALIZE 权益），
  **删除 `fn_warehouse_same_main` 泛化臂**。单张回调（afterPurchaseReceiptApproved/afterSubcontractReceiptApproved）
  维持 `resolvedReceiptTargets` 泛化两臂不动；红冲/完工入库/`inspectionStockInTargets`（先入库后检批次）另路不动。
  状态过滤（ACTIVE/PARTIALLY_PLANNED 或 COMPLETED 未履约完）三臂统一经 `eligible` CTE。
- **对照测试**（`exactWakeupRefreshesOnlyFactDependentAnalyses`）：T1 铺 12 张共享分析夹具（同仓×同货品的
  OTHER preview 兄弟分析，只有维度泛化关联）；断言 ① 夹具分析（真有供给分配）刷新恰好 1 次；
  ② 兄弟分析未被刷新（version|fingerprint 不变）；③ 反射调真实 wakeup 服务的 `resolvedReceiptTargets` vs
  `exactReceiptTargets` 直接对拍：精确 ⊆ 泛化、夹具分析 ∈ 精确、兄弟 ∈ 泛化 ∧ ∉ 精确；
  ④ 回滚事务里逐个兄弟 `refreshLocked`，断言 version/fingerprint 与投影行 md5 均不变——证明泛化多出的目标
  在本报告事实下刷新为无操作，「新旧目标集合持久化的分析行完全一致」。
- **E 结案去重**：`ProcurementOrderClosurePolicy` 重写——闭包计算搬进 `closure` CTE（判定表达式与原
  correlated 形式逐字一致），UPDATE 加 `is_closed IS DISTINCT FROM closure.is_closed` 值变化守卫（无值变化
  不再空写：行版本、审计触发器、锁都不空转）；新增 `recalculateReceipts(em,type,Collection<UUID>)` 多收货单
  一次 DISTINCT 订单集合。`decideReport` 把逐单收尾里的结案重算延迟到报告末尾（`deferredClosureReceipts`
  收集→按类型分桶各一次去重重算）；单张/单明细路径保持即时重算（带值守卫），且**无入库批次时跳过**
  （`preStocked.isEmpty() && autoStockIn.batches().isEmpty()`——结案只读上架量/退货/判定损耗，这些输入
  本次结论没动过）。已核对：报告事务中途（供应推进、分析唤醒、逐单执行）无任何 is_closed 读者
  （ProductionPurchase/SubcontractSupplyTransitionService 无引用）。
- **F 语句合并**：`executeBatch` 非重放路径重构为「内存裁决→批量写」：
  - `computeBatchedDisposition`：与逐条 `applyDisposition` 相同的状态门/余量校验/切片数学，同一行先后
    PASS/FAIL 的累计量仍在内存按事件顺序推进；
  - 行更新一条多行 `UPDATE ... FROM (VALUES...)`（守卫 `status IN ('PENDING','PARTIAL')` + 条数核对，
    与逐行「恰好一行」等价）；
  - 事件落账 `ProcurementInspectionEvents.appendAll` 一条多行 INSERT（列与单条同构，行序=事件顺序，
    occurred_at 顺序保持——pass_release_value 依赖）；
  - 出站事件 `BusinessEventPublisher.publishOnceBatch`（新端口默认实现=逐条；`BusinessOutboxPublisher`
    覆盖为一条多行 `INSERT ... ON CONFLICT(dedupe_key) DO NOTHING RETURNING`，冲突键一次取齐按
    publishOnce 同一恒等式核对，异体同句 409）。逐条路径（单张/重放/结案标记）不变。
- **C 部分**：`fn_imported_business_document(text,uuid)` / `fn_imported_business_document_row(text,jsonb)`
  声明 `COST 100000`（V1119）——只影响计划选择，写路径语义权威不变。「同事务内存证明复用」定论：W1(V1115)
  后 `ProcurementReceiptOriginPolicy.requireNative` 每次调用只剩一条登记表谓词查询（单条索引查），
  报告事务内每收货单 2-3 次 ≈ 每单 2-3 条小语句；再加事务级 memo 的复杂度不值得（同 R4 定论口径）。
- **H 上限+遮罩**：decideReport 加明细总行数上限 200（20×5=100 预算形状留一倍余量）；前端
  `QualityBatchSubmission.phase`（iqc/fqc 两段）+ 两页遮罩按阶段报文案（「正在提交检验报告」/「正在批量通过
  自制产成品」），disposal 页补 onProgress 让遮罩随阶段刷新。

## 3. D 定论：不做跨收货单合并（前提已被 2026-10-10 批量化覆盖 + 时序风险）

- 「资金冻结与品质价值转移从每单一批扩为整份报告一批」：现报告路径**每收货单已经是一次**
  `freezeQualityEvents(ids, events)` + `qualityRecordedBatch(events)`（executeBatch 内，2026-10-10 随
  decide-report 做掉），不是逐行。再跨单合并需把冻结/记账推迟到全部收货单处理完，但每单的
  `completeReceiptDisposition→confirmPreStockedReleases→confirmOne`（V446 库级价值守卫链）依赖**本单**
  冻结已发生——跨单延迟会破坏 freeze→stockin 时序，风险与收益（每报告省 ~38 对小语句）不成比例。
- 「先入库后检的 store 整批命令边界」：自动转正批次模型按收货单建批
  （`procurement_iqc_stock_in_batches.receipt_id`、批次 100 行上限、`normalize(type, receiptId, ...)`），
  跨收货单一批需批次模型/守卫触发器（V307 亦按收货单验证）联动改造，属库存域结构变更，不在本轮授权内。

## 4. 预算重测与遍历数（2026-11-08 实测，同机同日前后对照）

| 场景 20×5 | 改前（W6 前，本机当日） | 改后（W6 后，本机当日） |
|---|---|---|
| decide-report 命令 | **40s 命令截止取消（409）**，JDBC 段 38,102ms / 4,362 语句 | **9,813ms 完成（200）**，JDBC 段 8,021ms / 3,727 语句 / 1,867 次调用 |
| `fn_imported_business_document(_row)(_internal)` 调用 | — | ~~originWalks=0~~ **作废**：该次运行没开函数跟踪，`pg_stat_user_functions` 恒不计数，0 是假零（见下「更正：遍历计数口径」） |

### 更正：遍历计数口径（2026-11-08 04:24 复核）

初版写的「originWalks=0，整个 20×5 命令零权威图遍历」不成立：计时运行按规定不开
`track_functions`（全局税），而集群级 `pg_stat_user_functions` 只在开跟踪时计数，打印的差值恒为 0。
开跟踪实测一份 2×2 报告（`trackedSmallReportCountsWritePathAuthoritativeCalls`，319 语句）：
`fn_imported_business_document_row` 入口 **2 次**、递归 `_internal` 遍历步 **33 次**。来源是 V1115
写路径守卫 `fn_guard_imported_business_document_archive`：原生单据的运行时写入仍调权威函数，
登记表未命中即下钻递归遍历——这正是「写路径保留权威函数」的设计口径，不是回归。W1 达成的是
**读路径**零遍历（登记表谓词 + P1 增长守卫证明）。随测试修正：计时用例未开跟踪时打印
`n/a(track_functions off)`；统计读取改为等 11s 无变化（空闲后端最长 10s 才刷出函数统计）；
开跟踪用例断言计数必须 >0（防假零）并按每行 20 步封顶作遍历预算。20×5 规模未在开跟踪下复测
（跟踪税会把计时推向 40s 截止）。

- 语句数同机对照 −14.5%（4,362→3,727）；elapsed 的 38s→9.8s 除语句合并外还含本机 I/O 状态回暖
  （改前连基线都无法完成，改后在同一机器完整通过且远低于 40s 截止）。绝对值与 2026-10-13 的 11.2s
  基线不可直接比（机器不同状态），CI 复跑为准；预算断言（<30s）在本机已满足。
- 功能子集 10/10 绿（mixed 原子提交/同体重放、冲突整批回滚按单号报错、只读 403、共享订货单、
  旧版逐单回放、先入库后检语义、失败回滚、部分入库分析一次刷新、购买失败投影零遍历）+
  对照测试 `exactWakeupRefreshesOnlyFactDependentAnalyses` 绿。
- 对照测试三次返工的教训（记档）：① decide 每明细展开 PASS+FAIL 两条事件，批量行 UPDATE 的
  VALUES 必须按明细取**末条**累计值（同 id 多行只更新一次且取值任意）；② preview 不落快照行，
  兄弟夹具必须先经正规命令（saveRoutes 空决策）物化，否则「首次刷新」必不是无操作；
  ③ refreshLocked 的 version 是无条件 +1（bumpFingerprint 设计），无操作判据=**指纹不变+业务投影行
  （去 updated_at/updated_by）不变**；④ refreshLocked 不是独立命令入口（嵌套锁要求外层先持全分析
  预锁），测试驱动重算须走 saveRoutes 一类正规入口；MockMvc 请求会保存/恢复 SecurityContext，
  模板内要重挂登录。

### 补录：最终验证批（同夜复测）

| 测试 | 结果 | 数据 |
|---|---|---|
| `AggregateMaterialOrderEndToEndTest#twentyMaterialLinesCompleteWithinDeadlineBudget` | 绿 | elapsedMs=7,240（10s 断言内；V1119 迁移+回归无恙） |
| `ImportedDocumentRegistryGrowthPostgresTest`（W7 新建 P1 增长守卫） | 绿 | 历史 1 万/10 万/100 万注入下 p50=2.5/2.9/**2.1ms**——曲线平，登记表无顺序扫描节点 |
| `DataLifecycleRegistryContractTest` | 绿 | 5/5（V1119 登记合同成立） |
| `preStockedTwentyReceiptBatchAlsoCompletesWithinDeadlineBudget` | 该批红→**安静复测绿** | 该批 elapsedMs=42,621（`<35_000` 不过），运行期与并行会话主树 `mvn test`（真库容器）全程重叠；同代码安静复测 26,583ms 绿，见下方 A/B。语句 14,200、jdbcCalls 10,680（打印的 originWalks=0 为未开跟踪的假零，见 §4 更正）；断言未改 |

### 更正：preStocked 同机 A/B（2026-11-08 02:37–02:52）

上表 preStocked 行初版把 42.6s 归因于「~8.7ms/语句机器态」与「2026-10-13 CI 同形状 ~19s」，两处均不成立：
该批实测 JDBC 36,708ms / 14,200 语句 ≈ **2.6ms/语句**（8.7ms 是 §1 普通 20×5 改前冷态的值，14,200×8.7ms≈124s
对不上 42.6s）；仓库记录里 2026-10-13 该形状是 **37,881ms 超 35,000ms 门禁**
（`2026-10-13-前端行为与徽章全平台审查.md`「本地合并收口」节），ADR-090 首测 29.7s，没有 ~19s 的记录。
改前「语句数与遍历数证明非本批回归」也缺改前语句数。以下用同机 A/B 补齐：两份临时 detached 工作树
（改前 `deaae5bff` / 改后 `0957ff6f0`，各自 `target-perf`，不碰共享工作树），先后各跑一次（计时段开始前核对本机无其他 JVM）。

| preStocked 20×5（同一测试方法） | 语句 | jdbcCalls | JDBC 段 | commit 段(2 次) | elapsedMs | `<35s` |
|---|---:|---:|---:|---:|---:|---|
| 改前 `deaae5bff`（安静） | 14,741 | 11,221 | 23,612ms | 1,626ms | 27,292 | 绿 |
| 改后 `0957ff6f0`（安静，紧接其后） | **14,200** | 10,680 | 22,897ms | 1,670ms | **26,583** | **绿** |
| 改后（上方最终验证批，与并行会话 mvn 重叠） | 14,200 | 10,680 | 36,708ms | 2,494ms | 42,621 | 红 |

- 本批对先入库后检形状：语句 −541（−3.7%）、调用 −541、耗时 −0.7s；功能断言（20 单/100 行/1 次分析刷新/
  实物+资金+价值事实/原键重放零刷新且事实不变）改后两轮都过（那次红只差方法末尾的计时断言）。
- 42.6s 那次与安静复测语句数完全相同，多出的时间全在每语句与提交的数据库响应（JDBC 2.6 vs 1.6ms/语句，
  commit 2,494 vs 1,670ms）——是并行负载，不是代码回归。
- 改后安静复测同时验证了提交版 V1119（批后只加长 legacy 行 `term_note` 文本）：Flyway 迁到 v1119 成功，
  `DataLifecycleRegistryContractTest` 5/5 绿。
- 余量：26.6s 距 35s 断言 8.4s、距 40s 命令截止 13.4s；重路径仍是逐收货单先入库后检的入库确认链
  （W6-D 定论未动部分），绝对值以 CI 为准。

## 5. 坑（本会话）

- `mvn test` 运行期间绝不可并行编译；**TaskStop 杀后台 mvn 在 Windows 留 mvn+surefire 僵尸**，僵尸会继续
  跑并清 target-perf/test-classes（后续运行「No tests matching pattern」假失败）——按命令行认领
  （classworlds=MAVEN / surefire 临时 jar）后 Stop-Process 逐个杀，再删 test-classes+maven-status。
- track_functions=all 经 hikari options 下发是**全局税**：3939 语句的报告从 ~11s 拖到 ~38s，撞 40s 命令截止。
  计时基线绝不能带跟踪；遍历计数用小场景另测。
- 本机当日（Defender+容器冷态）每语句 ~8.7ms，是热态的 4-8 倍——绝对计时数字只做同机前后对照。
- 计时测试红了先查同时段有没有别的 JVM/容器（`tasklist | grep java` + 命令行认领）：preStocked 42.6s 那次
  与并行会话主树 `mvn test` 全程重叠，同代码安静复测 26.6s。机器态归因要拿本次实测的每语句毫秒与
  提交毫秒对照，不沿用别的场景的均摊值；改前/改后语句数用临时 detached 工作树同机 A/B 取证。
