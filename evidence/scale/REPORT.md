# D3 大规模输出预验记录

当前记录是独立工作树的**预验**，不是最终统一 SHA 验收签署。基线与输入源码为 `c4b84f5465de1e6fcb4617a847f523383d07da64`，分支 `uimp/feedback-scale-verify-20261110`，目录 `D:/Projects/uten_imp_worktrees/feedback-scale-verify-20261110`。原 `feedback-audit-20261110/audit` 只读；未触碰运行后端的 `target/classes`、`target-dev` 或 Root `runtime-maven-prepare-1/classes`。

## 已完成的独立物理文件

`PhysicalXlsxScale.java` 是在新位置复制、核查输出路径后的原 `ExtraAudit.large` 对照。它调用实际公共成表器，生成 **1,048,600** 行真实 XLSX，再以 SAX 逐行重读两个物理工作表，严格核对 `R0` 至 `R1048599`。此合成成表试验不冒称百万行业务数据库或浏览器链。

| 事实 | 结果 |
|---|---|
| 实际 XLSX | `physical-prep-1/artifacts/physical-1048600.xlsx` |
| 物理行 / 续表 | 1,048,600 数据行，2 张工作表，最终 R1048599 |
| 文件字节 | 8,530,989 |
| SHA-256 | `93501b872ba463024344b063d5f78b7dd2a4880cb0c27cc23beb9a9af4da1fb8` |
| 成表 / 重读 | 9,169 ms / 1,617 ms（本次机器观测，非固定门槛） |
| 取消 | 已写一页后真实抛取消，未发布半成品，`uten-table-sync-*` 临时目录残留 0 |
| 退出 | 0，详见 `physical-prep-1/physical.log`、`receipt.json`、编译/运行参数文件 |

## 十万行真实 PostgreSQL 业务源

`CompleteExportScalePostgresTest#hundredThousandAuthoritativeRowsMatchIndependentSqlOrderAndExactAmounts` 已 1/1 通过，0 失败、错误、跳过。空 PG 正常迁移至 V897，在该版开启全部货品触发器时有界造 100,000 条真实货品，继续完整升级至 V1131，然后使用实际 `MasterReportExportSource` 读取。

| 阶段 | 实际结果 |
|---|---|
| 初次迁移 | 60,709 ms，正常到 V897 |
| 真库造数 | 173,963 ms，每批 250 行，价格明确为可无损存入 NUMERIC(18,4) 的 1.2345 |
| 既有数据升级 | 33,575 ms，正常到 V1131，无禁用货品触发器 |
| 独立 SQL | COUNT=100000；MIN=MAX=1.2345；SUM=123450.0000 |
| 实际源读取 | 100,000 个严格有序唯一编号，1,000 批，每行精确价格 1.2345，总额 123450.0000 |
| 内存边界 | Hibernate 峰值受管实体 102，最终 source payload 不留全表 |
| 读取时长 | 13,221 ms，包含每行断言，未混入造数或迁移时间 |

这是 PostgreSQL + 实际服务 + 合成受权 `AuthUser` 上下文证据，不是普通账号登录网页证据。该阶段与上方百万行成表分别判定，不拼成同一业务源或同一浏览器闭环。原始命令与日志在 `prep-1/logs/maven.log`；中途真实 SQL 监测 `seed-monitor-1.txt` 记录 78,500 行、当时版本 14 个货品触发器全部开启、活跃 INSERT 无锁等待。

## 真实 50,001 个唯一选中 ID

`MasterDirectoryExportPostgresTest` 两个指定用例已 2/2 通过，0 失败、错误、跳过。1626 模具套数反序及精确文本对照保留。大范围用例在真库创建 50,002 条符合筛选的模具，独立 SQL COUNT=50002，明确选中其中 50,001 个唯一 ID；逐编号断言排序，未选中的另一条不在结果中。

| 阶段 | 实际结果 |
|---|---|
| 真库造数 | 150,467 ms，每批至多 1000 行、单 UUID 数组参数；全部模具触发器开启 |
| 实际源读取 | 29,125 ms；严格有序的 50,001 行，排除匹配但未选的 1 行 |
| SQL 边界 | 503 条 JDBC statement，最大 prepared parameter index 58 |
| 缺失 | 替换一个选中 UUID 为不存在的 ID 后拒绝生成文件 |
| 中断 | 实际页 sink 抛出取消；操作失败，选择 Scope 清理，未扩大为全量 |
| 输出凭据 | `D3_REAL_SELECTION selected=50001 matching=50002 excluded=1 ordered=50001 cancellation=preserved missing=rejected` |

原始日志 `prep-1/logs/maven.log` 与 `prep-1/reports-scale/` 保留，Maven 总计 3/3、exit 0。此处仍是 public Source + 真实 PostgreSQL 验证，不能据此宣称普通账号真实页面或 50,001 行下载文件已验。

## 补充生命周期对照

`ExportSelectionBudgetTest` 3/3、`ExportRowSelectionTest` 12/12、`MasterExportSelectionAspectTest` 1/1 和四个具名 `ReportExportQueuePostgresTest` 4/4，合计 **20/20** 通过、0 失败/错误/跳过，Maven exit 0。覆盖同类门槛、去重、缺失、精确选择、取消清理、不可变任务、回滚、稳定快照及实际文件下载时撤权。队列撤权测试使用真实 PostgreSQL 和实际 worker/文件/controller，但 principal restorer 为受控测试替身；不等同普通账号真实 HTTP 登录撤权。

这些结果由原 `c4b84f546` 编译产物产生。为使大选中范围也有实际文件证据，测试随后追加逐精确套数断言、实际成表与 SAX 逐行重读，并提供 `uten.export.evidence.directory` 可选保存目录；新增断言不回写旧证据。

## 新增实际文件反例与谓词诊断

`selected-prep-2` 源 `d83f9ee41` 的增强试验保留为真实失败：50,002 模具正常造数 149,880 ms，50,001 行 source 顺序/精确套数通过但耗时 42,970 ms；随后真实公共 `XlsxExportService.buildSource` 触发原有事务截止时间（`TransactionTimedOutException`），未生成可交付文件。Maven 1 错误、exit 1，完整日志/XML 保留。没有延长事务超时。先前 source 对照通过不能掩盖这个文件闭环失败。

PG 实际活动 SQL 是 `$7 @> array[m1_0.id]`，COUNT 和首读分别消耗约 15 s、22 s，无锁等待。原试验 PG 正常回收后，在另一独立 PostgreSQL 16 容器创建 50,002 行算子对照表；两种谓词对照使用完全相同的 50,001 个固定 UUID、相同 owner/筛选/排序、单 UUID 数组参数。这是算子诊断，未冒充真模具业务表或普通账号权限验收。

| 同一集合对照 | `uuid[] @> ARRAY[id]` | `id = ANY(uuid[])` |
|---|---:|---:|
| 真 EXPLAIN ANALYZE COUNT 执行 | 10,420.792 ms | 10.437 ms |
| 完整有序逐行读取 | 14,504 ms | 232 ms |
| 行数 / 未选排除 | 50,001 / 1 | 50,001 / 1 |
| 另一 owner / 不匹配筛选 | 0 / 0 | 0 / 0 |
| 精确数量总额 | 1250031250.125 | 1250031250.125 |
| 有序 code + 精确 qty SHA-256 | `6bad399401808217be8606d42ec42d570f666b7b9593a86a4eab61ace1909f19` | 同左 |

原件 `predicate-probe-1/*-count-plan.json` 含完整计划、actual rows/loops/buffers；`logs/probe.log` 记录每项断言。生产唯一入口抽为 `MasterSelectionPredicate`，大集合用 Hibernate SQL expression 的标量 `= ANY`，小集合仍沿用原 IN；权限/原筛选、RR 快照、稳定排序、缺失检查、取消和请求空间预算均保留。该补丁与更严格的独立 SQL 有序摘要测试已编译，真实服务/文件复验待下一轮。

最终统一候选冻结后，以 `rerun.ps1 -WorkspaceRoot <统一候选> -RunName <新唯一目录> -Kind final-unified -ExpectedRevision <冻结SHA>` 在新的编译/TMP/日志/数据库重跑；脚本拒绝源变化与重复输出目录。物理成表以 `run-physical.ps1 -WorkspaceRoot <同一候选> -ClassesDirectory <该轮独立build/classes> -Attempt <新唯一目录> -Kind final-unified -ExpectedRevision <冻结SHA>` 重跑。

## 指纹与边界

Git 源文件按 Git blob 原始字节 SHA-256；下载、日志、XML 和其他原件按实际文件字节 SHA-256，不进行换行配平。物理大文件保留在本地 `artifacts`，清单记录精确路径、字节、哈希；不把二进制纳 Git 作为唯一取回方式。

没有合并 main、推送、公司数据库、部署或正式包行为。Win7 真机、公司原单、私有旧 Excel、完整正式 CI 不在此预验记录内。
