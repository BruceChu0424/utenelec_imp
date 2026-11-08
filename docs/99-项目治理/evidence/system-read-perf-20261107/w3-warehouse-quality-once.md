# W3（P2.3 仓库/品质任务中心一次候选 + P3 徽章每源时限）实测 2026-11-07

环境：5434 容器公司数据副本 `uten_perf_w2`（V1117）；公司服务器 `uten_imp`（V1111）全部探针 `BEGIN READ ONLY` + 超时，未写任何库。真库测试经 Testcontainers 迁移基线（同套件内含新旧语句对拍）。

## 1. 徽章每来源语句时限（P3，先期完成）

见本目录先行证据与 `WorkbenchBadgeService.readIsolated` 实现：每来源保存点内 `set_config('statement_timeout', min(调用方,5s), true)`，释放前写回；超时来源进既有 stale 机制。真库测试 `WorkbenchBadgeSourceFailureTest`（200ms 上限 + ACCESS EXCLUSIVE 锁等待来源）。

## 2. 仓库入库/出库任务中心：metadata+rows+total 一条语句（原各跑 2 次 base CTE 链）

- 形态沿用 `FulfillmentWorkbenchPageRead`：`page_source`（谓词后候选）→ `page_rows`（窗口行号 + LIMIT/OFFSET）+ `page_summary`（精确 total）+ `metadata_totals`（TOTAL/STATUS/BILL 三桶，各保持自身筛选排除口径）；行首（`page_position=:offset+1`）或空页合成行携带 metadata JSON（`page_metadata_buckets`）。
  - 入库 `WarehouseInboundTaskCenterSql.page`：`inbound_snapshot AS MATERIALIZED (inbound_rows)` 一次求值供页/计数/分面共享；**identity 查询不物化**（行谓词继续下推进 UNION 分支，避免为单行查全量物化）。
  - 出库 `WarehouseOutboundTaskCenterSql.Plan.pageSql`：`physical_rows AS MATERIALIZED` 变体（`pageBase`）；原 `cte`（可下推）保留给 identity/facets/候选单引用语句。生产工单 LATERAL 只在页行求值（默认序不参与时不在窗口求值），`productionOrderNo` 排序时窗口先取工单列。
  - 品质待检 `QualityPendingQueueService`：IQC/FQC_SHEET/FQC 三源 `candidates/labeled/eligible` 本就 MATERIALIZED，metadata 语句与 page 语句合成一条（此前每页 2 次三源求值）；metadata 三值（状态分面/来源分面/来源计数）与行同帧返回。
- 钳制语义保持：页号超末页时（首页空行 + total>0）按原语义补发末页语句取回末页行（罕见路径），交互页常规路径恒 1 条语句。`WarehouseInboundTaskCenterQueryPostgresTest` 第 647 行钉住 page=99→2 钳制，全绿。
- 服务重写：`WarehouseTaskPageMetadata.fromJson`（合并语句 JSON 桶 → 同一 record）；出库 map() 位置列契约用 `PAGE_TOTAL_COLUMN/PAGE_METADATA_COLUMN` 常量钉住。
- 删除死代码：入库 `metadata()`/`facets()`、出库 `metadataSql()`（合并后无调用方）；`rows()/count()`/`rowsSql()/countSql()/facetsSql()/billNoFacetsSql()` 保留为测试与单引用入口的真实语句形态 oracle。

### 对拍与计时（副本库 `uten_perf_w2`，全候选精确口径，单语句并列执行）

| 方向/视图 | 旧交互页（metadata+rows 两条） | 新合并页 | 对拍 |
|---|---:|---:|---|
| 出库 ACTIVE | 1.856 + 1.987 = 3.84 s | **1.179 s** | 空集一致（TOTAL=0） |
| 出库 HISTORY | 0.788 + 0.806 = 1.59 s | **0.977 s** | 空集一致 |
| 入库 ACTIVE | 9.402 + 14.066 = 23.47 s | **17.99 s** | 空集一致（ACTIVE 口径下导入收货全为历史态） |
| 入库 HISTORY | 9.108 + 16.011 = 25.12 s | **17.41 s** | **total 77,926 ↔ 77,926；metadata 504 桶 ↔ 504 桶逐值一致；首页 30 行行序逐行一致** |

副本库剩余成本是**导入收货行分支自身形状**（36,827 采购 + 41,099 委外收货行逐行 LATERAL：待入库事件/退回案/进度富化），非共享次数问题——见 §4 生产实测，V1115 后生产库该分支仅 20 张原生单，整条退化为毫秒级。W7 EXPLAIN 守卫将把该分支形状钉进监控。

## 3. UNION 分支 fn 一次求值 + fn_is_production_linked_stock_document 快路径定论

- 入库 `stockDocuments()`：`production_facts` LATERAL（`fn_is_production_linked_stock_document` ×5 处 → 1 次、`fn_is_production_material_return_request` ×3 处 → 1 次）；`expectations()`：`selected_warehouse_id` LATERAL（`fn_procurement_item_inbound_warehouse_id` ×3 处 → 1 次）。
- 出库 `stock()`：`production_facts` LATERAL 以 `CASE WHEN d.doc_type='DRAW'` 短路（OTHER/FINISHED 分支行零函数调用），`linked/draw_requested/draw_pending` 各 1 次（原 2-3 处重复调用）。
- **快路径定论（实测）**：`fn_is_production_linked_stock_document`（V164）三条 EXISTS 全部索引支撑（`uq_production_planning_package_owned_document(document_type,document_id)`、`uq_pdl_active_draw(draw_id)`、`idx_sdi_doc(doc_id)`）——存储等价快路径已存在，无需改函数体。公司库原生 DRAW 247 张三函数各一次逐张实测 187ms（idx_sd_legacy 直取原生行）；W1 后仓库读路径只扫原生行，逐行 LATERAL 一次求值已把每行调用压到最低。此前 2.9s/次的观测是**导入 DRAW 36,448 张混扫**（旧版无 V1115 谓词时），不在现行读路径。函数保留为权威，无形状变更、无迁移。
- 记不做的部分：不改写函数、不加快路径列（与偏差 3 同口径：EXPLAIN 复核后无收益不建）。

## 4. WarehouseQualityResultService.typeCounts 部分索引：经 EXPLAIN 不建

公司库实测（2026-11-07 只读）：`receipt_scope` 活动集 = 原生收货单 20 张（purchase 10 + subcontract 10），全部经 `purchase_receipts_legacy_id_key`/`subcontract_receipts_legacy_id_key` 唯一索引 Index Scan 直取（`legacy_id IS NULL` 即索引条件），11 缓冲区、0.037ms。`(status, created_at)` 部分索引不改变任何用户可感知时延，且过不了 `SchemaIndexHygieneContractTest` 必要性论证——同 W2-5 口径记为不建。副本库同查询 0 行原生单，5.8ms。

## 5. 测试

- 单元：`WarehouseInboundTaskCenterQueryServiceTest` 7/7（新增 page 语句形状断言：快照单次引用、identity 不物化、无 metadata 变体不含分面）；`WarehouseOutboundTaskCenterQueryServiceTest` 17/17（合并语句 mock 重写：一页一语句、空页 metadata 保留、无 metadata 导出页、LATERAL CASE 短路形状钉住）；`WarehouseTaskCenterExportServiceTest` 6/6。
- 真库：`WarehouseInboundTaskCenterQueryPostgresTest` 25/25；`WarehouseOutboundTaskCenterSqlPostgresTest` 14/14（新增合并页 vs 旧 rows/total 对拍 + 超末页合成行断言）；`WarehouseOutboundTaskCenterMigratedSchemaPostgresTest` 5/5；`WarehouseTaskPageMetadataPostgresTest` 2/2（重写为合并页等价 + 源求值次数探针：旧 2 语句=2 次候选，合并=1 次，10 万行注入曲线进 `LoadingGrowthEvidence`）；`QualityPendingQueuePostgresTest` 2/2；合计 54/54。
