# W5（P5 物料批量下单）基线与侦察 2026-11-07（进行中，未改码）

## 1. 基线（本会话实测）

- `AggregateMaterialOrderEndToEndTest`（Testcontainers 全链）现状：**33/33 全绿，538.2s**（均 ≈16s/测，含 Spring 上下文与 FullChain 夹具搭建）。
- 尚无「20 行物料端到端」预算测试——计划 R7 要求先测当前值再定预算：需要新夹具（一个分析下 20 个独立物料行，`insertGoods`+BOM+已审订单+MRP 导入，参照 `selectAllThreeProducts...` 的 GroupInput 构造与 `createWithChild`/多成品循环夹具形态）。
- 2026-10-13 历史参照：preview 0.34s / submit 1.66-7.64s、30 组 14.5s→4.5s。

## 2. 代码侦察（本轮已核实，续做直接用）

- `submit` 主循环（AggregateMaterialOrderWriteService.java:101-294）：幂等重放→`guard.verifyUnchanged`→**锁内完整重算 preview**（projectIssuePreviewBase + previews.resolve，:122-125）→逐组循环内 `refreshLocked`+`detailInternal` 每组 2-4 次（:229/:244/:252/:267/:274/:277/:282）。
- **已有两级合批**：`submitExternalCohort`（外部单据批量：一次 preview、一次 createBatches、末尾一次 refreshLocked）与 `submitIndependentManufacturing`（自制合批：两次 refreshLocked + 逐 plan em.flush/clear）。`independentExternalPrefix`/`independentManufacturing` 是独立判定。
- **R1 放宽点**：`independentManufacturing`(:442-479) 目前对以下情况整体回退逐组：任一行存在**可认领** makePublicSupplyRefs/sharedFutureSupplyRefs（哪怕该组本身 skipClaims/retainedMakeResponsibility 不会认领——顺序路径的认领判定在 :259-262，合批路径完全没有认领逻辑，所以保守拒绝）、priorityMakeSupplement/borrowedIn/borrowedOut>0、owner 为 AGGREGATE_MAKE、safetyQty>0、availableOnly。放宽方向=把「存在可认领供给」改为「该组实际会认领才拒绝」（复用顺序路径的 originalFlow/retainedMakeResponsibility/skipClaims 判定），子树不相交证明（祖先游走）保留。
- R2：`previews.resolve` 同分析锁内可加 (analysisId,version,fingerprint,request) 短缓存，保留指纹比对与 (id,xmin) 复核。
- R3：preview 纯读段（projectIssuePreviewBase+resolve）可移到 `lockAnalysisWithClaimableShared` 之前一次；reconciler try-lock 跳过被 submit 锁定的计划（与 W6 G 同项）。
- R4：W1 守卫单遍历已落地；审计 digest 扩展（V830 先例扩大到投影维护 UPDATE）待做。
- R5：前端同层并行（material_analysis_aggregate_submission.dart 依赖分轮）。
- R6：同一次 submit 内 SOURCE/EXACT 闭包命令级缓存（:831-880/891-957/1094-1130 递归子树 SQL）。
- 预算验收：数量/来源/认领/别名逐值对拍零差异；`independentManufacturingCohortStillReservesSharedScarceMaterialSequentially`（稀缺料顺序保留）与 `aSecondPlanFailureRollsBack...`（整批回滚）是 R1 的重要护栏。

## 3. 已知锁事实（W5/W6 共用，来自调研与记忆）

ProductionReadinessReconciler 已是 REQUIRES_NEW + lock_timeout 500ms + statement 5s/读 2s，撞锁自己放弃；放大来自 submit 被 reconciler 先持有的 production_plans FOR UPDATE 行锁挡住→FulfillmentSourceConflictRetryInterceptor 整笔重跑 ≤5 次。FulfillmentMutationLocks 也是行锁。
