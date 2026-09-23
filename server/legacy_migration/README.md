# 旧库引导迁移脚本执行契约

本目录只用于 `YTDQ_2023` 离线一致性快照到新库的首次引导导入或可丢弃演练。它不是切流后的增量同步器，也不是普通运维入口。权威模块清单、对账和生产门禁见 [迁移总索引](../../docs/数据迁移/README.md)。

`migrate.sh` 的当前 schema 集合由 `verify_candidate.py` 从受审 Git 提交的正式 Flyway 资源逐文件计算，再与发布 checksum manifest 和目标 `flyway_schema_history` 三方精确比较；不再另存固定 head/count。导入映射协议由 `mapping-version.txt` 单独版本化。缺文件、额外版本、checksum 不符、未跟踪或未提交源码全部拒绝。旧 `bootstrap-v10-v426` 只是历史运行身份，不再是当前导入目标。

目录兼容或合成测试不会自动授权目标库。真实源导出、目标首导与业务切换分别需要可核验的批准和证据；现役 PostgreSQL 的前向升级不使用此脚本，也不重导旧业务。任何目标未授权的破坏性历史迁移（包括 V425）不得借首次导入越过；目标 schema 必须事先由该环境批准的正式 migrator 建立。

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
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

`--bootstrap-all` 只允许由正式 Flyway 建好的空业务新库或可丢弃演练库。入口核对目标库名、集群身份和首导批准，并用当前业务表分类逐表检查无业务事实；不会调用业务清空函数。不得在已经切流、含新业务写入或无法完整恢复的数据库运行。

所有导入模块、23 项结构对账、逐单据模块源/目标行数对账与成功回执在一个 PostgreSQL 事务提交。loader SQL 自身不提交，事务由协调器唯一拥有（单模块也由调用器包事务）。`compose_bootstrap.py` 用词法守卫拒绝额外顶层事务或跨连接命令，不改写 SQL 字符串/注释/dollar body，模块间清理本连接临时表；FK、审计和业务触发器一直启用。后段失败会回滚整个业务导入，独立保留 FAILED run 和输入摘要；确认是本单事务协议失败且业务仍空后可以重试。旧协议、未知数据或已存在业务的目标拒绝重建，须恢复到受审空库，不会自动删库。

相同 manifest、受审提交、mapping 和目标身份已成功时，返回原 SUCCESS 回执，不再次删除或导入，也不把原回执说成新的业务验收。钱流及采购/委外收货依赖同批真实来源证明，只允许完整 `--bootstrap-all`；旧 `--finance`、`--purchase`、`--subcontract` 单模块入口在写库前拒绝。其余单模块目标仍限隔离诊断，其 `reconciliation_status=NOT_RUN` 不构成完整切换证据。同一数据库的 claim 与业务执行均由数据库 advisory 锁保护；新事务持锁重验自己的 RUNNING 身份和空业务状态，跨 helper 容器也不能竞争重建。并发拒绝只清理本进程拥有的锁和随机密钥暂存文件。

`--shelf-labels` 是唯一不读老库导出的目标：货架库位（库行-层-位，如 A31-3-1）只存在于仓库现场挂牌，老库 `B_Goods.StockPlace` 是无关历史残值。仓库部门按挂牌人工整理 `data/shelf_labels.csv`（格式见 `migrate_shelf_labels.sql` 头部与 `data/shelf_labels.example.csv`），脚本现算 sha256 登记审计后回填 `goods.stock_place`；依赖 `--goods-data` 已迁，幂等可重跑，不进 `--bootstrap-all`。

## 受审输入与自动对账

可发布的全量导出必须来自停写后恢复的离线备份，并在一个 SQL Server `Serializable` 只读事务中完成全部查询。执行 `export_legacy.ps1 All` 前必须通过私有环境提供：

- `LEGACY_SOURCE_AUTHORITY_ID`：CMDB 中的非秘密源身份；
- `LEGACY_SOURCE_BACKUP_SHA256`：受审离线备份摘要；
- `LEGACY_SOURCE_SNAPSHOT_AS_OF_UTC`：该备份真实业务截止时点，格式 `YYYY-MM-DDTHH:mm:ssZ`；不是导出或导入时间；
- `LEGACY_EXPORT_APPROVAL_REFERENCE`：批准的导出窗口引用。

导入会再次要求独立提供与 manifest 完全相同的 `LEGACY_SOURCE_AUTHORITY_ID`、`LEGACY_SOURCE_BACKUP_SHA256`、`LEGACY_EXPORT_APPROVAL_REFERENCE`，不能只因 JSON 中填写了批准字符串就执行。另需：

- `UTEN_LEGACY_TARGET_DB_EXPECTED_NAME`：批准目标的精确库名，必须与 `PG_DB` 及实际连接一致；
- `UTEN_LEGACY_TARGET_SYSTEM_IDENTIFIER`：预先核验的 PostgreSQL 集群 system identifier；
- `UTEN_LEGACY_TARGET_APPROVAL_REFERENCE`：本目标首次导入批准引用；
- `UTEN_FLYWAY_CHECKSUM_MANIFEST`：同一受审候选/发布制品导出的正式完整清单路径。

导出器、协调器、校验/装配/对账 Python、`mapping-version.txt`、全部 `migrate_*.sql` 和 Flyway 目录必须属于同一个无 scoped dirty 的受审 Git 提交。formatVersion 4 manifest 不保存 server、database、连接串或凭据，只保存源 authority、备份摘要、批准引用、UTC 时间、提交、导出器/sidecar 摘要以及每个 CSV 的行数、字节数和 SHA-256。导入时提交或任一字节漂移都会在数据库连接和写入前失败。

全量导入完成后，`migrate_reconciliation.sql` 固定写入 23 项自动结构对账，包括核心 CSV 行数、完整消费清单、四个系统分类根、货品 UUID 关系、客户默认结算 UUID、客户铺底合法性、销售订单财务兼容事实、显式仓库/车间映射、活动 BOM、reject 和历史 FK anchor 统计。全部判定在提交前执行；失败则事务回滚并使 run 失败，诊断日志保留失败原因，成功运行保留 23 项结构记录和 `reconciliation_summary.moduleRowChecks`。自动结构对账通过仍不代表可切流；金额、数量、来源谱系、编号冲突、审计覆盖、恢复演练和业务/财务签字必须另行完成。

V630(2026-09-20)退役了 V443 的客户货款类别标签：首导不再按 `B_PStyle` 的 `system_role` 回填 `sales_payment_type`，结构对账也没有「未决标签」项(导入映射协议随之升为 `bootstrap-v12`)；客户条款只剩 `default_settlement_method_id`(由 `B_PStyle` 经 `settlement_matches` 唯一匹配，缺失/歧义仍进 `client_default_settlement_migration_issues`)。`B_Client.Credit` 保留 legacy 快照，并在铺底尚未人工维护时精确写入 `credit_floor`；未设置按 0。10,653 张历史销售订单的 `Deposit` 非零数为 0，定金仍以已审预收事实为准。

历史出货不得批量伪造财审或风险事件。已进入 `PICKING/PICKED/SHIPPED` 的历史事实保留 `finance_gate_version=0`；仍处于活动 `PENDING_PICK` 且能证明尚未开始作业的旧草稿必须升级为版本 1、保持未审，再由财务人工放行。`LEGACY_PENDING` 是只读迁移异常，不得再走旧审核、财审、仓库推进或原位升级；须保留原草稿，并从当前已财务确认订单来源逐行重建版本 1 两审任务。无法证明的行进入异常清单并阻断切换。新流放行/撤回同事务追加 `sales_shipment_finance_release_events` 风险快照；历史不回填。财审只通知仓库，不立 AR；仓库最终确认 `SHIPPED` 的上海业务日才建立完整正式 AR 并起算到期日。

销售 AR 对账必须把正式应收与客户预收分层：未转销 `CUSTOMER_PREPAYMENT` 负余额不得净掉正式 AR 未收；只有已审预收转销才冲减目标 AR。铺底只在客户汇总展示，`超出铺底额=正式 AR 未收-铺底额` 保留负数，不参与核销。这 23 项结构对账不能替代这组金额/来源人工对账或后续自动守卫。

V442 候选在采购、仓库、销售、委外和生产物理单据导入后运行
migrate_measurement_profiles.sql。它只消费已审核目标 UUID 事实：正重量模式形成
PROVISIONAL 建议；旧 Weight 没有单位，不得自动 CONFIRMED。异常进入
legacy_measurement_exceptions。画像必须绑定同一 formatVersion 4 manifest 的备份摘要、
批准引用和 Git commit；原来明确为空且尚无导入映射的生产日报、委外询价/申请及银行单 CSV 必须仍为空；非空来源在写库前拒绝，必须先补受审映射，不能静默丢弃。当前未绑定的本地 CSV 只允许运行
profile_measurement_evidence.py 做聚合诊断。

来源辅助文件也必须被消费并核验：`b_pstyle.csv` 与受审结算 UUID 字典逐项核对，不按名称猜测新增业务角色；`b_worker_columns.csv` 保留源字段结构证据，不作为员工业务数据；`m_bank.csv` 在交付非空映射前必须为空。

主档按源 CSV 的精确 legacy 主键集合对账，历史缺档占位必须有实际业务 CSV 的行/字段引用证据。孤儿 BOM 保留逐行排除原因，满足源数=有效导入+明确排除；不能进入现役 BOM。仅 StockGoods 留存的余额也按仓/货/实际色或无色保留，不会因缺少出入库明细丢行或合并颜色；源数量、金额、重量不改写。源 B_Goods.StockPlace 残值不写入库位主档。

受验采购/委外收货通过 V627 恢复旧历史 `consideration_required=false` 口径，保持原 header/item 来源、金额与单位证据，不造对价分段、库存或 AP。P Total 是原币；E STotal 是本币成本。只有原单明确正汇率才转换商业原币到本币；E 成本只有基准币且原率 1 才能等值为原币，否则未知维度保持 NULL。所有源单位/汇率 NULL/0 不填 1、不借当前货品默认单位。原 header Total 的真实 0 不能被明细成本合计替换；源头/明细只读，详见采购/委外迁移文档当前覆盖说明。

## 历史资金与期初余额

V626 的受验导入函数一次写入历史资金原单、实际原明细、原账户流水和不可变来源证明。旧 `M_Get` 缺少足以证明现代业务分类的核销关系时保留 `LEGACY_UNCLASSIFIED`，不能因为明细为空就猜成预收；`M_AllCheck` 保留 `LEGACY_SNAPSHOT`。原单不允许普通修改、审批、红冲或再次生成总账。既有 legacy 原单也不能作为新预收转销资金源。

`M_In/M_Out` 的原额、原已结、原余额仍是旧账事实；当前余额可以由新的合法收付款继续结算。来源仅在方向、已核实来源族、真实 BillID、单号和当事人共同得到唯一候选时绑定 UUID；缺失或多候选保留 `LEGACY_OPENING` 和原因，不按单号前缀选择第一张。全部本批迁入往来以 `LEGACY_UNVERIFIED` 保留其历史余额分类，唯一来源 UUID 仍可核验；负余额不会变成可用预收、贷项或退款来源。本币 Total 不能冒充未知原币金额；只在基准币且源汇率明确为 1 时证明对应原币数值。

钱流模块导入收付款类别(科目)之后, `migrate_finance.sql` 末尾调用 `fn_finance_report_line_bindings_seed_defaults()`(ADR-112 / V686): 按原报表代码里的科目名单, 为总账附表/经营损益表还没有任何绑定的行补默认取数科目(只绑费用类末级科目, 同一张表里已归别行的科目不补, 人工/折旧行不猜), 幂等。新库上线因此不会整张附表都显示「未配置科目」; 之后由财务在总账报表「附表取数设置」里调整。

`sourceSnapshotAsOfUtc` 是与离线备份一起批准的真实业务截止时点。历史累计已结数没有逐笔付款日期，不能把它当成导入当天或原发票当天的新付款。供应商月结只重建截止业务日之后的完整月份：例如原额 25、历史已付 8、期初余额 17，新付款 3 后期末 14，本期实际付款只有 3。跨越截止日的整月、迁入前月份、缺失截止证据或原币未核实的行均拒绝冻结并给出核验提示；不能用当前余额倒推旧月走势。业务日固定按 Asia/Shanghai，精确月界也遵守此规则。

## 人事与秘密

- 所有导入 psql 使用 `-X`，客户端仅输出 SQLSTATE、不输出 COPY 原行或错误 SQL 上下文。最终 deferred 检查会另外输出经过标识符白名单过滤的 constraint/function 名称，便于定位守恒规则；原异常 MESSAGE/DETAIL/CONTEXT 不打印、不存表。导入连接通过固定 `PGOPTIONS` 会话级关闭语句/参数/错误内容日志并固定 UTF-8，不修改集群配置；账号必须已经具备设置这些参数的权限，否则在读取密钥/导入 CSV 前拒绝，脚本不会自行授权或提权。失败运行保留 exit_code、输入摘要及安全模块阶段信息，真实切换还需独立业务验收。
- HR SQL 不再使用 `session_replication_role=replica` 绕过 V282/V287 保护；缺失证件号或主手机号保持 `NULL`，不得加密空串或伪造 HMAC/last4。V287 要求主身份密文为空时对应派生值也为空。
- `prepare_hr_keys.py` 优先使用进程环境，未提供的值才读取不入库的 `server/.env`；文件解析与项目实际 dotenv-java 3.0 行规则一致，不展开反斜杠、不执行 shell、拒绝重复密钥定义。版本未提供时使用应用相同默认值 `1`，显式版本原样保留。本地与容器都用 `mktemp` 创建本次独占随机文件并立即设为 `0600`；私有初始化文件采用显式转义 SQL 文字和不显示结果的 `\gset`，保持引号、反斜杠、Unicode、真实换行及字面 `\n` 的不同字节。命令只传文件路径，退出 trap 清理两侧文件。禁止把密钥写进命令行、日志、CSV、Git 或本文档。

PostgreSQL 16 的迁移账号无需成为超级用户。受控入口先只读检查四项参数的 SET 能力与真实集群身份读取权限，再连接并验证实际日志设置；第一条能力查询不含密钥或业务数据。经 DBA 核验后，可以只向专用迁移角色授予：

```sql
GRANT SET ON PARAMETER log_min_messages, log_min_error_statement,
    log_statement, log_parameter_max_length TO uten_migrator;
GRANT EXECUTE ON FUNCTION pg_catalog.pg_control_system() TO uten_migrator;
```

`log_parameter_max_length_on_error` 与 `client_encoding` 是普通会话参数，不需要额外提权。该操作不得授予应用角色 `uten`，也不要求添加 `pg_monitor`、owner 成员资格或超级用户。脚本本身不运行以上授权语句；正式执行前使用 `PG_USER=uten_migrator` 验证完整入口。仅数据库函数在非超级账号下可调用，不能替代这项真实 psql 启动参数验收，也不能为跑通而去掉日志保护。
- `import_product_lists.py` 不提供数据库默认密码，必须通过私有环境显式提供 `UTEN_DB_PASSWORD`；host/user/database 的开发默认值不构成生产授权。
- 正常入职/补开账号仍要求真实证件号与主手机号并走正式服务；扩展-only legacy 行不能登录，也不能借迁移 capability 进入在线路径。

## PostgreSQL 前向升级演练

本目录的 SQL Server 首次导入与既有 PostgreSQL 的 Flyway 前向升级是两条不同链路。`V238ToCurrentSyntheticMigrationPostgresTest` 从历史 schema 建合成非空库，再升级到从正式资源自动发现的当前目录；`LegacyBootstrapSchemaCompatibilityPostgresTest` 只证明 SQL 结构兼容和部分主档关系；`LegacyBootstrapCoordinatorPostgresTest` 在独立测试容器运行真实 Shell、Docker CLI、CSV COPY、来源/目标门禁、非空多模块导入与重放/失败回滚。合成来源与批准均明确标为测试数据，不代表真实旧库已经导入或通过业务对账。

公司数据只能在独立、可丢弃且可恢复的克隆上运行 `CurrentHeadNonEmptyCloneRehearsalTest`。除 `UTEN_RUN_REHEARSAL_DB_TESTS=true` 外，执行者必须通过私有环境显式提供：

- `UTEN_REHEARSAL_DB_URL`、`UTEN_REHEARSAL_DB_USER`、`UTEN_REHEARSAL_DB_PASSWORD`；
- `UTEN_REHEARSAL_DB_EXPECTED_NAME`（必须精确匹配且名称包含 `rehearsal`）、`UTEN_REHEARSAL_DB_EXPECTED_START_VERSION`；
- `UTEN_REHEARSAL_DB_SYSTEM_IDENTIFIER`、`UTEN_REHEARSAL_BACKUP_SHA256`、`UTEN_REHEARSAL_APPROVAL_REFERENCE`；
- `UTEN_REHEARSAL_IDENTIFIER_CONFLICT_SHA256`、`UTEN_REHEARSAL_CLIENT_SETTLEMENT_ISSUE_SHA256`，分别绑定 V279 编号冲突和 V285 客户结算问题的受审规范化证据。

该测试固定 `cleanDisabled=true`，拒绝普通 `uten_imp` 库名，先核对起点、集群身份和完整 Flyway history，再升级并验证行数允许清单、用户身份、权限范围、收付款合计、库存合计、系统分类根、PII 派生约束以及当前迁移审计合同。没有上述带外证据时保持跳过；不得为了“跑绿”伪造摘要或把目标库改名后直接执行。

## 发布边界

已应用 Flyway 迁移不可修改、改名或 `repair` 掩盖 checksum；修复只能新增更高版本。V282/V284/V286/V287 需要停写、排空旧实例、单版本迁移与前向修复/一致备份恢复，不能让旧 JAR 与新密文/约束滚动并存。

生产执行仍需单独批准目标、维护窗口、备份恢复、冲突清单、历史对账和多岗位 UAT。本 README 和脚本均不授予目标服务器、生产密钥或生产数据库写入权限。
