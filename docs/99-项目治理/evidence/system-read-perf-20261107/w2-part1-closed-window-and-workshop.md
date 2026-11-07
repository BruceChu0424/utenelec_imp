# W2 第一部分（P2 履约/车间先筛）本机副本库实测 2026-11-07

环境：5434 容器公司数据副本克隆 `uten_perf_w1_scratch`（V946 + V1115）。V1116 在事务内应用后测量，结束 ROLLBACK；未写任何库。车间相关改动以真库测试证明等价。

## 1. V1116 履约关单窗口 `closed_at`

| 项 | 改前（updated_at 窗口） | 改后（closed_at 窗口） |
|---|---|---|
| `v_procurement_decomposition_tasks` 原始行数 | 26,381 | 830 |
| 采购原生任务计数（同语句两次） | 324.9 / 317.8 ms | 31.0 / 24.4 ms |
| 原生各部门×各状态计数对称差 | — | **0** |
| 离开原始视图的行 | — | 25,551 行，**全部为已登记导入单据** |
| 已关已审采购单逐行 `reserves_source`（10,139 张，W2 前置测量） | 551–625 ms | 门控后不再全表求值 |

切换规则：`closed_at` 只在 `is_closed` 变为 true 时由触发器写入 `now()`；迁移时原生且 `updated_at` 落在 31 天内的已关单沿用 `updated_at`（31 天覆盖任意会话时区），导入单据保持 NULL 退出窗口；调用方不能把关单时刻改回窗口内。视图改写以锚点校验原地改写（与 V923 相同模式），并断言不再引用 `updated_at` 窗口。

## 2. 车间部门树授权谓词

`ProductionWorkshopAssignmentScope.predicate` 由"每个任务行一棵 `WITH RECURSIVE workshop_tree`"改为"每条语句一次：员工主/兼职/所管（未删除）部门向上取父链的车间集合"的无关联子查询。

- 等价性：`ProductionWorkshopAssignmentScopePostgresTest` 以原递归写法为参照，覆盖已删除部门子树、已删除中间节点、兼职/主管/责任人、离职/已删除员工、NULL 车间与 NULL 责任人、未绑定员工，逐行逐员工一致且结果从不为 NULL。
- `NativeReadScopeVersionPostgresTest`（12 个，含按该谓词求员工可见车间）全绿。

## 3. 「等待物料」两阶段档位窗口

默认档位排序（无关键词、无显式列排序）时，数据查询先按 `segment_status, plan_end_date, plan_no, segment_no, segment_id` 取前 3×(offset+size) 个候选，再只对窗口内行求物料/齐套档位并排序分页；计数查询仍按完整谓词。带关键词或显式排序时保持原单阶段查询。

- `ProductionWorkshopPreparationFilterPostgresTest` 6/6、`ProductionExecutionWorkbenchQueryPostgresTest` 25/25 通过。
- 待补：钉住"页内档位单调不减、档内按存储键"的专用测试，以及公司副本三段（PREPARING / IN_PROGRESS / REPORT_INSPECTION）改前改后计时（需把克隆库 `uten_perf_w2` 迁到 V1116 后测量）。

## 4. 其余验证

`FulfillmentWorkbenchTaskAudiencePostgresTest` 6/6、`LegacyMigrationSafetyContractTest` 12/12、`MigratedProjectionImportedPolicyPostgresTest` 2/2 在含 V1116 的完整迁移上通过。尚未运行：`IqcTriggerProfileEndToEndTest`（关单路径新增 `closed_at` 触发器，可能触及触发器预算）及采购/委外结案端到端测试。
