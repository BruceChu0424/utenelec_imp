# W5（P5 物料批量下单）基线、R1/R3 实现与续做侦察 2026-11-08

## 1. 预算（R7，已建测试）

`AggregateMaterialOrderEndToEndTest#twentyMaterialLinesCompleteWithinDeadlineBudget`：1 个 MAKE 父件 + 20 个独立 BUY 物料全选下达（父件子树与全部叶子相交 → 叶子走依赖路径），断言 21 批、1 计划、BUY 合计 400、幂等重放。

| 阶段 | elapsedMs（Testcontainers 全链） |
|---|---:|
| 基线（R1/R3 前） | 4,299 |
| R1 后 | 3,665 |
| R1+R3 后（34/34 全绿） | 3,882（同机波动 ±300ms） |

预算断言收紧为 **10s**（撞锁重跑场景余量）；「≤3s」目标留待 R5（前端同层并行）与 R6（命令级子树缓存）逼近。参考：2026-10-13 历史中位 submit 1.66-7.64s。

## 2. 已实现（随本文件提交）

- **R1 扩合批**：`independentManufacturing` 新增 `requestSkipClaims` 参数；「存在可认领供给即整体回退」改为「该组实际会认领才回退」——判定复用顺序路径口径 `!input.skipClaims(request.skipClaims()) && !retainedMakeResponsibility(group, view)`；子树相交/借料/safety/availableOnly/nested-make 守卫全部保留。`retainedMakeResponsibility` 从 submit 内联抽取为 static 助手（顺序路径同引用，口径单一来源）。护栏 `independentManufacturingCohort...Sequentially`、`aSecondPlanFailureRollsBack...`、全量 34 场景绿。
- **R3 锁窗口压缩**：submit 的 admission preview（projectIssuePreviewBase + issuePreviewView + resolve）移到 `lockAnalysisWithClaimableShared` **之前**计算；锁后三重校验（header version、tree fingerprint、`commands.sharedClaimableFingerprint` 认领共享足迹指纹）任一漂移即回退锁内重算——绝不陈旧接受。新入口：`MaterialAnalysisService.headerSnapshot`（免锁头快照）、`MaterialAnalysisCommandService.sharedClaimableFingerprint`（只读足迹指纹）。
- **R3b / W6-G reconciler try-lock**：`ProductionReadinessReconciler` 每候选先 `SELECT ... FOR UPDATE NOWAIT` 探测计划行——正被 submit 持有立即跳过本轮（原 500ms 等待），reconciler 自身不再排队、不放大 submit 的锁等待窗口；游标轮次兜底。
- **R4 定论：已由现状覆盖**。分析投影表审计本就是 V830 窄函数（`fn_audit_route_columns`，3 列）+ 列 WHEN 门（items 表 5 列）——refreshLocked 的投影维护 UPDATE 不触发整行审计；写侧剩余守卫成本已由 W1 单遍历消除。无需新迁移。

## 3. 未做（续做从这里开始）

- **R2 preview 短缓存**：`previews.resolve` 是纯内存（对传入 view 计算），submit 内逐组请求形态各异，跨请求缓存命中面小且需 (id,xmin) 复核面；待预算逼近 3s 时再评估是否值得。
- **R5 前端同层并行**：`material_analysis_aggregate_submission.dart:44-319` 依赖分轮 while——同层车间+委外批并行发（409 竞争重试已有保护）。
- **R6 命令级子树缓存**：同一次 submit 内 SOURCE/EXACT 闭包（WriteService :831-880/891-957/1094-1130 递归子树 SQL）组间增量合并。

## 4. W6-A 精确唤醒侦察（schema 已核实，续做直接写）

现泛化路径：`resolvedReceiptTargets`（按 仓×货品×颜色 维度）→ `candidateQuery`（`fn_warehouse_same_main` OR `ownsQualifiedAt` 两分支）→ 唤醒全部同主仓活跃分析逐个 `refreshLocked`。

精确目标集合（报告路径 `afterQualityReportCompleted`）三臂，schema 锚点全部已核实：
1. **精确 peg**：`preplan_analysis_stock_exact_pegs.source_receipt_type/source_receipt_id` 直指本报告收货单 → `beneficiary_analysis_id`（表列已含收货单引用，无需 join 反推）。
2. **供给动作分配**：receipt_items（purchase/subcontract 均有 `order_item_id`）→ `preplan_supply_action_allocations.external_item_id` = 订单明细 → `analysis_id`。
3. **同池已拥有**：保留 `ownsQualifiedAt` 分支（分析在收货实际仓×货品×颜色上已有合格供给余额/FORMALIZE 权益），**只删 `fn_warehouse_same_main` 泛化分支**。

验收：计划要求「新旧目标集合下持久化的分析行完全一致」对照测试（泛化集合刷新为无操作是前提，用 T1 的 10-30 个共享分析夹具铺开）。`candidateQuery` 加 exact 形态参数，其余调用方（到货通知等）维持现状。`inspectionStockInTargets`（先入库后检批次）另路不动。

## 5. 其余 W6 锚点（照主文档 P6）

- B 三轮→两轮：decideReport 联合发现 ③a 嵌套 recheckPrefixCoverage + ④ verifyUnchanged（`FulfillmentLockState` prefixRechecked/prefixVerified 双状态位）；「已持有联合前缀」重载跳过嵌套 recheck（严格相等复核更强）。
- F 语句合并：每单待检行 `UPDATE ... FROM (VALUES ...)`、事件多行 INSERT 一条（保持 occurred_at 顺序）、outbox 多行 INSERT+RETURNING。
- E 结案去重、D 整批边界（资金冻结/品质价值转移整报告一批）、C 守卫降本（W1 已消大头+同事务内存证明复用）、H 报告总行数上限（重测后定 100-200）+ 分阶段遮罩文案。
- 预算：`IqcDecideReportBatchPostgresTest` twentyReceipt/preStocked（[decide-report] elapsedMs；基线 2026-10-13=11.2s），`track_functions='all'` 记 `fn_imported_business_document_row_internal` 调用数。

## 6. 坑（本会话踩过）

- **mvn test 运行期间绝不可同时改代码再编译**——test-classes 竞争产生 NoClassDefFoundError/TypeNotPresent 假失败（5 例，重跑全绿）。源码 Edit（不跑 mvn）安全。
- 测试打印 elapsed 只在 stdout，grep 过滤会缓冲到进程结束才出——用 TaskOutput 等待而非轮询日志。
