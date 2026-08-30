# 旧库引导迁移脚本执行契约

本目录只用于 `YTDQ_2023` 离线一致性快照到新库的首次引导导入或可丢弃演练。它不是切流后的增量同步器，也不是普通运维入口。权威模块清单、对账和生产门禁见 [迁移总索引](../../docs/数据迁移/README.md)。

> 当前源码边界（2026-08-29）：Flyway 全局目录最高 V426，共 388 个迁移文件、388 个唯一版本且无重号。V420 是已授权的 BUY 需求 exact/公共安全补库分账，V421 是库存台账金额与货品成本完整性，V422 前向修正安全 action 单位快照和 allocation 反向门禁，V424 审计日志降噪（通知 4 表与系统管道/幂等指令表退出触发器覆盖），V425 审计日志全新开始（清空并重置自增 ID），V426 强化零料直接自制执行段的物料分析逐行谱系。离线 bootstrap 在任何写库前必须消费与当前候选 exact-set 一致的 388 行 checksum manifest，并把 `bootstrap-v10-v426` 写入迁移运行记录。V426 不授权跨越或执行尚未获准的破坏性 V425；若某环境未独立批准 V425，迁移必须在 V424 停止，V426 也保持 NO-GO。V409–V415/V418 的生产质量事实、V419 在线到货命令以及 V420–V422 的在线修复语义均不由离线脚本伪造或回填。脚本存在、空库回放或本地演练都不表示公司目标库已应用 V239–V426，目标库仍以自身 `flyway_schema_history` 为准。

## 不变量

1. 在线关系只认新库 UUID。`legacy_id`、旧单号、编号、名称和人员文本只用于受控导入、对账或历史只读；不得把本目录的映射逻辑复制进普通 API。
2. 历史单号和主档编号原样保留。V279 只登记占用、成员和冲突证据；历史重复/格式异常不静默改码，新身份不得复用归一后的完整标识或前缀。
3. 货品、模具、客户和供应商的分类前缀由目标分类规则决定。旧库重导恢复同一 `legacy_id` 身份；复制/新建/import 新身份必须走统一分配器，不能由 SQL 自行 `max+1`。
4. 采购、仓库、销售、委外和生产脚本缺失货品锚统一使用 `LEGACY-G-<legacy_id>`，并标记 `auto_created` 历史 stub；这些行只维持历史外键，不得进入在线选择器、活动 BOM 或 MRP。
5. 金额、数量、汇率和余额保持精确 `NUMERIC`，不逐列加密。已列明员工 PII 使用既有版本化 pgcrypto/HMAC 路径；KMS/HSM/Vault、卷/云盘加密和备份加密属于独立生产控制，当前没有因执行本目录脚本而自动部署。

## 执行方式

`migrate.sh` 每次只接受一个目标，并要求 `--confirm-destructive` 或精确环境确认 `UTEN_CONFIRM_DESTRUCTIVE_MIGRATION=RESET_<数据库名>`。无参数、未知参数或重复目标均拒绝执行。可用目标以脚本 `--help` 输出为准，例如：

```bash
bash server/legacy_migration/migrate.sh --help
bash server/legacy_migration/migrate.sh --goods --confirm-destructive
bash server/legacy_migration/migrate.sh --purchase --confirm-destructive
```

`--bootstrap-all` 会按 UUID 依赖顺序重建多个目标模块，只允许空白新库或可丢弃演练库。不得在已经切流、含新业务写入或无法完整恢复的数据库运行。单模块目标用于诊断和受控演练，其成功记录保持 `reconciliation_status=NOT_RUN`，不得作为切换证据。

`--shelf-labels` 是唯一不读老库导出的目标：货架库位（库行-层-位，如 A31-3-1）只存在于仓库现场挂牌，老库 `B_Goods.StockPlace` 是无关历史残值。仓库部门按挂牌人工整理 `data/shelf_labels.csv`（格式见 `migrate_shelf_labels.sql` 头部与 `data/shelf_labels.example.csv`），脚本现算 sha256 登记审计后回填 `goods.stock_place`；依赖 `--goods-data` 已迁，幂等可重跑，不进 `--bootstrap-all`。

## 受审输入与自动对账

可发布的全量导出必须来自停写后恢复的离线备份，并在一个 SQL Server `Serializable` 只读事务中完成全部查询。执行 `export_legacy.ps1 All` 前必须通过私有环境提供：

- `LEGACY_SOURCE_AUTHORITY_ID`：CMDB 中的非秘密源身份；
- `LEGACY_SOURCE_BACKUP_SHA256`：受审离线备份摘要；
- `LEGACY_EXPORT_APPROVAL_REFERENCE`：批准的导出窗口引用。

导出器、`migrate.sh`、全部 `migrate_*.sql` 和 Flyway 目录必须属于同一个无 scoped dirty 的受审 Git 提交。formatVersion 3 manifest 不保存 server、database、连接串或凭据，只保存源 authority、备份摘要、批准引用、UTC 时间、提交、导出器/sidecar 摘要以及每个 CSV 的行数、字节数和 SHA-256。导入时提交或任一字节漂移都会在数据库连接和写入前失败。

全量导入完成后，`migrate_reconciliation.sql` 固定写入 20 项自动结构对账，包括核心 CSV 行数、完整消费清单、四个系统分类根、货品 UUID 关系、客户默认结算 UUID、显式仓库/车间映射、活动 BOM、reject 和历史 FK anchor 统计。任一强制项失败都会保留失败项并使 run 失败。自动结构对账通过仍不代表可切流；金额、数量、来源谱系、编号冲突、审计覆盖、恢复演练和业务/财务签字必须另行完成。

## 人事与秘密

- HR SQL 不再使用 `session_replication_role=replica` 绕过 V282/V287 保护；缺失证件号或主手机号保持 `NULL`，不得加密空串或伪造 HMAC/last4。V287 要求主身份密文为空时对应派生值也为空。
- `migrate.sh` 从不入库的 `server/.env` 读取 PGP/HMAC key，只用 `mktemp` 创建随机临时文件并立即设为 `0600`；复制到容器后同样设为 `0600`，退出 trap 清理两侧文件。禁止把密钥写进命令行、日志、CSV、Git 或本文档。
- `import_product_lists.py` 不提供数据库默认密码，必须通过私有环境显式提供 `UTEN_DB_PASSWORD`；host/user/database 的开发默认值不构成生产授权。
- 正常入职/补开账号仍要求真实证件号与主手机号并走正式服务；扩展-only legacy 行不能登录，也不能借迁移 capability 进入在线路径。

## PostgreSQL 前向升级演练

本目录的 SQL Server 离线 bootstrap 与既有 PostgreSQL 的 Flyway 前向升级是两条不同链路，不能混用。自动测试 `V238ToCurrentSyntheticMigrationPostgresTest` 从最后一份公司目标库只读基线 V238 构造非空库并升级到当前 V426/388，用于发现空库回放看不到的结构、种子和约束问题；它不包含公司历史业务数据。

公司数据只能在独立、可丢弃且可恢复的克隆上运行 `CurrentHeadNonEmptyCloneRehearsalTest`。除 `UTEN_RUN_REHEARSAL_DB_TESTS=true` 外，执行者必须通过私有环境显式提供：

- `UTEN_REHEARSAL_DB_URL`、`UTEN_REHEARSAL_DB_USER`、`UTEN_REHEARSAL_DB_PASSWORD`；
- `UTEN_REHEARSAL_DB_EXPECTED_NAME`（必须精确匹配且名称包含 `rehearsal`）、`UTEN_REHEARSAL_DB_EXPECTED_START_VERSION`；
- `UTEN_REHEARSAL_DB_SYSTEM_IDENTIFIER`、`UTEN_REHEARSAL_BACKUP_SHA256`、`UTEN_REHEARSAL_APPROVAL_REFERENCE`；
- `UTEN_REHEARSAL_IDENTIFIER_CONFLICT_SHA256`、`UTEN_REHEARSAL_CLIENT_SETTLEMENT_ISSUE_SHA256`，分别绑定 V279 编号冲突和 V285 客户结算问题的受审规范化证据。

该测试固定 `cleanDisabled=true`，拒绝普通 `uten_imp` 库名，先核对起点、集群身份和完整 Flyway history，再升级并验证行数允许清单、用户身份、权限范围、收付款合计、库存合计、系统分类根、PII 派生约束以及当前迁移审计合同。没有上述带外证据时保持跳过；不得为了“跑绿”伪造摘要或把目标库改名后直接执行。

## 发布边界

已应用 Flyway 迁移不可修改、改名或 `repair` 掩盖 checksum；修复只能新增更高版本。V282/V284/V286/V287 需要停写、排空旧实例、单版本迁移与前向修复/一致备份恢复，不能让旧 JAR 与新密文/约束滚动并存。

生产执行仍需单独批准目标、维护窗口、备份恢复、冲突清单、历史对账和多岗位 UAT。本 README 和脚本均不授予目标服务器、生产密钥或生产数据库写入权限。
