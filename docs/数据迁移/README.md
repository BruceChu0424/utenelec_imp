# 老库数据迁移 · 总索引
> **当前共享源码候选（2026-08-29）**：目录最高 V424，共 386 个迁移文件、386 个唯一版本且无重号。
> V424 审计日志降噪与中文化：通知 4 表（`notices`/`notice_user_states`/`notice_acknowledgments`/
> `notice_blessings`）、业务/附件事件发件箱、账户月度流水汇总与 4 张幂等指令表退出审计触发器覆盖，
> 系统自动行为不再写审计日志；人工操作仍由 HTTP 请求覆盖行与业务表触发器完整留痕，详见
> [迁移说明 62](62-V424审计日志降噪与中文化.md)。
> V423 下线货品「生产 BOM 策略」（删除 `goods.production_bom_policy`）与计划级 BOM 例外放行
> （删除 `production_plans.bom_override_reason/by`），重写执行段 ZERO_MATERIAL 证据触发器并退役
> `production_material_analysis:bom_override`、`production_plan:forward_rd` 两个权限点，
> 见 [ADR-057](../99-决策记录-ADR/ADR-057-下线生产BOM策略与计划级例外放行.md)。
> V420 建立 BUY 生产需求 exact 与公共安全库存补库的分账结构/只读投影；第二采购明细写命令已经
> 业务显式授权且仅限员工在数量框确认后执行，SUBCONTRACT/MAKE 保持 NO-GO，见
> [ADR-056](../99-决策记录-ADR/ADR-056-计划前生产需求与公共安全库存补库分账.md)。
> V421 把即时库存金额权威切换到 `stock_balances.amount_local`，历史负/越界成本先写审计再修复，
> 并增加应用与数据库双门禁，见 [ADR-055](../99-决策记录-ADR/ADR-055-即时库存台账金额与货品成本完整性.md)。
> V422 前向冻结安全 action 单位快照并阻止公共 safety item 进入 demand allocation。当前开发库
> 已成功应用 V420；V421 曾因生成列显式写入失败并完整回滚，修正后已在 V420 备份恢复克隆演练通过；
> V422 已通过空库和核心分账 PostgreSQL 测试；当前开发库随后成功应用 V421/V422、JPA 校验和
> liveness/readiness 均通过。该本机证据不能外推为公司目标库已升级。
> 完整备份、checksum、测试与七个物料分账对账见
> [2026-08-29 治理验收报告](../99-项目治理/2026-08-29-物料分析安全库存分账与库存成本治理验收.md)。
> V407 为新收款增加 `settlement_authority_version=1`：AR 原币结算毛额、本位币毛额、真实账户币种/入账、
> 扣除或另付费用、`fee_bearer=NONE/COMPANY` 承担方、公司直收/外贸代理结汇、`BASE_PER_SETTLEMENT` 汇率方向、来源/生效时间、银行入账时间、
> 银行/代理单号、合作外贸公司 UUID/名称快照和创建幂等键分别冻结。V1 明细 `writeOff=0`；历史 V0
> 有费收款不猜测、不自动升级。V408 将 `finance_reconciliations` 收口为全局 append-only 原币流水，新增
> `posting_seq/entry_kind/reversal_of_id/account_currency_id/amount_local`，红冲追加镜像 `REVERSAL`，并用
> `v_account_balance_integrity` 暴露缓存/流水差异。完整月份由可重建 `account_flow_monthly_summaries` 汇总，起始月仍从原始账本取尾段，`v_account_flow_monthly_integrity` 逐月核对。完整口径见
> [ADR-053](../99-决策记录-ADR/ADR-053-多币种收款毛额净额与追加式账户流水.md)。
> V1 `RECEIPT` 总账凭证同样不可删除；红冲在当前业务月追加关联 `RECEIPT_REV`，
> `v_receipt_expected_gl_entries` 用冻结科目/金额拒绝“平衡但公式错”的原凭证，`v_receipt_gl_integrity` 暴露缺凭证、错金额、缺反向或不镜像异常；deferred `receipt_flow_terminal_guard` 拒绝收款终态单头缺真实账户流水。收款已移出可删除的期间重建集合。
> V407 另以固定 UUID 创建收款银行手续费、收款汇兑损益和应收控制叶子，只为仍未映射的
> `BANK_FEE_EXPENSE/FX_GAIN_LOSS/AR_CONTROL` 补 `style_id`，不覆盖任何既有已复核 UUID 映射。
> 精确前向文件顺序是 `V407__finance_receipt_settlement_authority.sql`、
> `V408__append_only_account_flow_and_integrity.sql`、`V416__finance_migration_exception_queues.sql`、
> `V417__finance_payment_command_idempotency.sql`；已经执行的 V407/V408 不得修改，只能继续新增前向迁移。
> V416 新增 V0 收款/GL 和旧账户流水异常队列，且要求新 V1 外部证据、金额公式、maker-checker 以及新流水
> 来源 UUID/启用账户币种/本位币快照。V417 为付款创建保存 maker 范围幂等键和请求哈希，编辑要求
> `expectedVersion`；同键异内容或陈旧版本均返回冲突。
> V400 只对 `legacy_id IS NOT NULL AND currency_id IS NULL` 的旧账户按既有规则桥接：
> `OFFSHORE` → 唯一使用中、未删除的 `currencies.legacy_id=3` 美金 UUID，其它 legacy 账户 →
> 唯一使用中、未删除的 `currencies.legacy_id=1` 人民币 UUID；显式 UUID、在线/手工账户不推断，
> 缺失/多匹配或桥接后活动账户仍非法均 SQLSTATE `23514` 回滚。本地只读实测 27 行（26+1）不是目标库
> 事实。美金币种参考汇率 0 不影响账户原币余额、流水或余额核对；美元账户记美元，人民币账户记人民币，
> 不同币种不直接相加。外币非零余额调整另由财务显式提供本位币 `localDelta`，不读取币种主档参考汇率。
> V401 以 `local_amount_basis` 区分人民币同值、财务显式外币本位币金额和零差额；既有 V400 行保留旧依据
> 仅供历史重放，新批次不得继续使用参考率路径。
> V402 用数据库 INSERT 守卫禁止新写 `LEGACY_REFERENCE_RATE`；V403 将本位币身份绑定到唯一币种 UUID
> 的 `is_base_currency` 标记，并校验新余额行 basis。币种编号、名称和参考汇率不再参与本位币身份判断。
> V404 强制每条新调账明细的币种 UUID 等于账户当前币种 UUID，并共享锁定两者；V405 进一步禁止普通
> 更新改变本位币主键 UUID。V406 为 `notice_user_states` 前向增加可空
> `popup_acknowledged_at`，把关键事件居中弹窗的手动关闭与已读/待办完成分开；不猜测或回填历史用户
> 是否看过弹窗。本机 Flyway 已执行的 V400–V408 字节必须保持不可变；后续修正只允许用 V416/V417 或更高前向版本，不能回改旧文件。
> 目标库备份、可恢复非空副本、前后对账未完成，
> 禁止改迁移/checksum 或 `flyway repair`，生产继续 **NO-GO**。
> 财务增量证据：付款 PostgreSQL 在 V417/379 为 5/5；50 年账本/异常守卫在当前 V419/381 为 6/6，均 skipped=0。25 万条
> EXPLAIN 使用月汇总与原流水 Index Only Scan、无原流水 Seq Scan，Execution Time 1.059 ms、Java/JDBC
> 墙钟 20 ms，三类规模样本差异/异常均为 0。财务后端定向 74/74、Flutter 29/29、完整 analyze 0 issue；
> 并发编辑停止后，当前稳定工作树完整 Maven 2,511 项为 0 failure/0 error、338 skipped；完整 Flutter 1,137/1,137。本轮 V418/V419 组合契约 73/73、PostgreSQL 15/15、Flutter 聚焦 26/26 和定向 analyze 也通过。尚未形成受保护签名 lineage，目标库/UAT 仍 **NO-GO**。详见 [迁移说明 61](61-V417财务迁移异常队列付款幂等与50年账本证据.md)。
> V409–V415 完成日报命令并发去重、FQC 决定/放行守恒、仓库点收门禁、失败数量恢复授权及 SCRAP/REJECT 补产物料闭环；V418 令整单零实收保留 REJECTED 事实并生成全量同源 residual 重交单。采购/委外每次 IQC PASS 现按累计合格差量推进正式供给，同单其它待检行不阻塞；V419 到货登记同键同体回放、同键异体冲突。所有证据均不能外推为目标库已迁移。
> **离线 bootstrap 冻结状态**：`server/legacy_migration/migrate.sh`、安全合同和说明已同步到 V424/386 与 `bootstrap-v9-v424`。这只表示源码校验常量一致；尚未生成并核验受保护 lineage 的 386 行 checksum manifest，也未在目标可恢复副本执行 bootstrap/对账/恢复，因此目标库和发布仍为 **NO-GO**。
> 账户页面“全部使用中账户目标填 0”只是余额核对输入预设，保留期初、累计、流水和总账历史，禁用账户不参与。
> 真正清业务历史的 `server/ops/reset_business_data.sql` 仅用于可丢弃本地/测试库：CLEAR 完成后以
> `ops:reset_business_data` 审计身份把所有账户五个金额字段，以及客户/供应商期初往来、货品 legacy
> 期初库存、`min_qty` 安全库存、20 项成本金额/费率和结算类别期初金额同事务归零，随后再记录
> PRESERVE 计数基线并分别做全零断言。货品安全库存/成本的 NULL 也改为字面 `0`；客户/供应商/货品
> `version` 与 `updated_at` 随真实变化推进，审计共用一次 request ID。货品 UUID/编号/名称/分类/单位/BOM、
> `max_qty` 与业务售价 `price/a_price/price2` 不变。不得从页面调用，
> 也不得用于公司目标库或生产。
>
> **2026-08-29 V423 本机开发库完整零基线重置（第四次执行，当前状态）**：第三次清理后，同一
> Windows Terminal 再次运行 `mvn spring-boot:run`，形成 225 行 CLEAR 数据（48 张表非空）、8 个应用
> 连接和 7 行库存余额（数量 `70,005`、台账金额 `17,001`；流水/预留各 8 行）；账户和主档零基线仍为 0。
> 已关闭本次 cmd/Maven/Spring Boot 链并保留终端窗口。清理前备份
> `server/backups/uten_imp_pre_full_reset_v423_20260829_133230_4f555c79.dump` 为 8,550,382 字节，
> SHA-256 `F808BE5D6AD989E7F3FB35CFD7EE45385A4EB1B998DF0B7B57451D510A62433C`，`pg_restore -l`
> 5,756 项；完整恢复库与源库的 283 张父表/69,093 行、V423/385、基础资料、人事、用户、账户、货品/BOM、
> 库存及六张物化视图指纹完全一致。第四次清理 request ID
> `40a50ee1-7851-47c6-8ac4-8c2c03676b8c` 已提交：191 张 CLEAR 表、库存、账户、期初、安全库存/成本和
> 六张视图均为 0；主档原已全零，因此 UPDATE 与新增审计均为 0。全部 92 张 PRESERVE 表行数
> （`92 / 68,868`）及基础资料、人事、权限、审计、Flyway、编号治理指纹与恢复库一致。临时恢复库和
> 容器副本已删除，主机备份保留；所有 Uten 后端及 8080 保持关闭。该记录是当前本机最终状态。
>
> **2026-08-29 V423 本机开发库完整零基线重置（第三次执行，历史记录）**：第二次清理后，用户
> Windows Terminal 中的 `mvn spring-boot:run` 启动链再次运行，形成 115 行 CLEAR 业务数据（20 张表
> 非空）及 9 个数据库应用连接；库存、账户和主档零基线字段仍为 0。已只关闭该 cmd/Maven/Spring Boot
> 链并保留终端窗口，确认项目 Java、8080 和数据库应用连接均为 0。清理前备份
> `server/backups/uten_imp_pre_full_reset_v423_20260829_115358_a8d4c184.dump` 为 8,070,112 字节，
> SHA-256 `6A59CC0E7255A63A607EB11BB24A627E2461665C5FEBE0B10DEA4324858D8F0F`，`pg_restore -l`
> 5,756 项；完整恢复库与源库的 283 张父表/64,780 行、V423/385 Flyway、基础资料、人事、用户、账户、
> 货品/BOM、库存及六张物化视图指纹完全一致。第三次清理 request ID
> `59ce5947-5def-4af6-afd5-867aea93a176` 已提交：191 张 CLEAR 表、库存、账户、期初、安全库存/成本和
> 六张视图均为 0；保留主档原已全零，因此 UPDATE 与新增审计均为 0。全部 92 张 PRESERVE 表行数
> （`92 / 64,665`）及基础资料、人事、权限、审计、Flyway、编号治理指纹与恢复库完全一致。临时恢复库和
> 容器副本已删除，主机备份保留；所有 Uten 后端及 8080 保持关闭。该记录是当时状态。
>
> **2026-08-29 V423 本机开发库完整零基线重置（第二次执行，历史记录）**：上一轮之后后端被重新启动并
> 应用 V423，随后又产生 195 行业务数据（191 张 CLEAR 表中 32 张非空）；库存余额/流水/预留各 7 行，
> 数量 `80,005`、台账金额 `10,301`，账户五金额及货品安全库存/成本仍为 0。停写后其它客户端、阻断
> Outbox 和非人事附件 owner 均为 0。新备份
> `server/backups/uten_imp_pre_full_reset_v423_20260829_111039_6f67d45b.dump` 为 7,950,006 字节，
> SHA-256 `549A01051329F471B6F029A7874476CD7F3859F088943E5142011304A61468CF`，`pg_restore -l`
> 5,756 项；完整恢复库与源库的 283 张父表/63,527 行计数、V423/385 Flyway、货品/BOM、人事、用户、
> 账户、库存和六张物化视图指纹完全一致。V423 不新增永久表，脚本/合同同步为 V423 后聚焦测试 5/5
> 通过。第二次清理 request ID `efa1295f-29dc-45e8-a1e0-157f09370e0f` 已提交，191 张 CLEAR 表、库存、
> 账户、期初、安全库存/成本和六张物化视图均为 0；因五类保留主档原本已是零，本次 UPDATE/新增审计
> 均为 0。外部对账确认全部 92 张 PRESERVE 表行数（`92 / 63,332`）及 Flyway、基础资料、人事、权限、
> 审计、编号治理指纹与恢复库完全一致。临时恢复库和容器副本已删除，主机备份保留；Uten Java/Maven
> 后端和 8080 监听均保持关闭。该记录是当时状态，不代表公司目标库或生产已清理。
>
> **2026-08-29 V422 本机开发库完整零基线重置（已执行，仅本地 `uten_imp`）**：执行前数据库 identity
> 为 `7665531896769187878`，Flyway `V422 / 384` 且失败行 0；后端停写后其它客户端、待处理/失败 Outbox、
> 非人事附件 owner 均为 0。191 张 CLEAR 表中 35 张有数据、合计 203 行；库存余额/流水/预留各 7 行，
> 数量 `91,005`、台账金额 `25,202`；27 个账户五项金额原已为 0。清理前备份
> `server/backups/uten_imp_pre_full_reset_v422_20260829_042315_86d9a6ef.dump` 为 7,479,990 字节，
> SHA-256 `47E2BB40BBE32B129F7A15AA9D27BFE5A10E12D7134B6D17AC7D8620AB8CE287`，`pg_restore -l`
> 5,758 项；完整恢复到随机临时库后，283 张父表/59,168 行计数指纹、384 条 Flyway、序列、六张物化视图
> 及货品/BOM/人事/账号/仓库关键指纹与源库完全一致。受控事务以 request ID
> `8a161aba-cc25-4b1d-8e11-5368a47bf44b` 提交：191 张 CLEAR 表、库存数量/重量/金额、账户五金额、
> 客户/供应商/结算类别期初、货品期初/`min_qty`/20 项成本和六张物化视图全部为 0；137 个货品、202 条
> BOM 保留。货品真实变化 131 行，`version +131`、审计 `+131`，actor 全为
> `ops:reset_business_data`，同一非空 request ID。外部对账确认除新增审计外 91 张 PRESERVE 表行数、
> 基础资料稳定字段及旧 30,033 条审计指纹与恢复库一致。临时恢复库和容器 `/tmp` 副本已删除，主机备份
> 保留；后端以 V422/JPA 成功重启，liveness/readiness 均为 `UP`。该证据不代表公司目标库或生产已清理。
>
> **V399 阶段冻结证据（2026-08-26）**：空库 Testcontainers PostgreSQL 16.15 已从 V1 应用
> 361 个迁移到 V399。V393–V397 收紧普通销售默认
> 客户/销售范围，新增单客户只读共享、客户访问 CAS/事件、人员数据交接、离职并发责任守卫、全
> `public` 审计 sweep 和 employee→user 固定锁序。V398 进一步移除部门/角色层的广泛
> `client:assign`，统一 data scope owner 任职代际、单客户 grantee 与附件上传 current-user 守卫；新增带
> source/default-target 代际的 offboarding event、handover 双端代际、requested/effective scope 数据库
> 约束、employment history append-only 和全域责任恢复守卫。V399 为 `users` 增加独立 JPA 写入 CAS。
> 当前本地证据：`FullChainEndToEndTest` 61/61、`DataHandoverPostgresTest` 10/10；Surefire
> 538 suites / 2283 tests / 0 failures / 0 errors / 2 skipped，Failsafe packaging 1 suite / 2 tests /
> 0 failures，合计 2285 test cases；Flutter 定向 40/40、全量 1007/1007、analyze 0 issues、Web release exit 0。
> 详见 [迁移说明 59](59-客户访问与人员数据交接.md) 与
> [ADR-050](../99-决策记录-ADR/ADR-050-客户访问与人员数据交接分层.md)。这些仍是本地源码候选，
> 公司目标库迁移、历史对账、真实账号 UAT、恢复和部署均未执行；这组数字不覆盖 V400–V405，生产仍为 **NO-GO**。
> **历史全目录复扫（2026-08-22，V375 时点）**：当时共享工作树目录最高 V375，共 337 个迁移文件、337 个唯一版本、无重号；下方“V329 当前头”段是页面权限子项目完成时的阶段快照，不再代表全目录头。生产相关新增 V337（MAKE exact entitlement 随 child ownership 交接）与 V338（生产 FINISHED_IN 仓库逐行实收、整单拒收、余量草稿与专用红冲）；V339–V375 为并行委外/供应商结算与审计候选，不改变 V337/V338 生产语义。V338 混合零/正实收只软删零源行并保留全量余量，整单零才 `REJECTED`；已点收单专用红冲 append-only 记录反向并重建 accepted slice replacement。生产仓库动作使用 inventory→plan/package/segment→document 锁序，权限与 `SUB_WH` 组织范围求交，当前无员工到具体仓库分配主档。V337/V338 均未部署目标库、未完成非空升级、仓库/车间岗位 UAT、恢复和签名发布，生产继续 **NO-GO**。见 [ADR-046](../99-决策记录-ADR/ADR-046-生产领料仓库点收报工归属与未来计件边界.md)与[治理收口报告](../99-项目治理/2026-08-22-生产领料仓库点收报工归属与未来计件治理收口.md)。
>
> **页面权限阶段快照（2026-08-22，V329 时点）**：当时目录最高 V329，共 309 个迁移文件、309 个唯一版本、无重号。V307–V314 是跨分析让料/权益守恒及审计链；V315–V325 是页面权限委派、来源隔离、代际与历史显式任职候选；V326 前向停用并永久禁止 V323 显式任职及其委派重新启用，同时增加中央覆盖 CAS、直属部门分页、姓名/工号 trigram 和负责人索引；V327 用中性 inactive tombstone 保留全局页取消覆盖后的单调版本；V328 以数据库 `permission_surfaces` + `permission_surface_permissions` 作为 85 个页面 surface 的唯一目录，登记十类动作、新增 204 个按钮级/端点级权限码，并用 207 条旧→新映射保真迁移四类旧授权来源；V329 增加当前员工 `full_name/code/id` 跨部门稳定分页部分覆盖索引并包含 `department_id/position_id`，不修改任何权限或负责人数据。V315–V328 旧字节不得改写。现行页面范围只认 `departments.manager_id`：普通负责人根覆盖未删除子树，总经办 `GM` 直属在册负责人覆盖公司；空部门筛选搜索全部授权范围，选中部门后取子树交集。上述仍是共享源码候选，目标非空库、公司 live history、V328 四类授权前后对账、历史 UNKNOWN 对账、真实负责人/对象范围 UAT、目标规模搜索/分页性能、恢复与发布均 **NO-GO**；当前全目录头只认本页顶部 V423/385。
> V328 后补的 16 个生产码中，11 个为已有真实页面按钮和服务端门禁的 active/assignable 动作，覆盖执行分段、计划包与材料结清；另 5 个仅兼容历史端点，固定 `active=false/assignable=false` 且无 UI。生产细分已完成，不再是待授权决策。
> 主数据再增加 `department:move` / `department:manager_assign`，两码均属 `org.department` surface，并已分别接入 Flutter 父级位置与负责人字段门禁；员工与附件、生产执行、主数据三组拆分均已完成并通过全量候选验收。
> `rd_task:create` / `rd_task:assign` 因本轮无合法 UI 固定 `active=false/assignable=false` 并移出 Flutter 候选，只保留端点、旧授权映射和审计证据。附件对账两码只在中央目录，不挂 business surface；历史授权保真保留，但禁止新增授权和负责人转授。
> 附件对账不是“严格 superAdmin-only”有效权限规则：既有历史非超管授权不得被文档抹除，后续处置须走显式对账与前向治理。
> 最终本地候选验收：Maven 2058 项、0 failure/0 error（283 skip）；PostgreSQL 16-alpine 空库迁到 309 个版本，页面范围/代际 4/4、surface 目录 4/4，覆盖跨根/选中子树分页、总经办公司范围、V324 ABA 与 V329 无 Sort 索引计划；Flutter 848/848；全量 analyze 0 error/0 warning，仅保留 6 条既有 info。业务方已确认通用/生产源码默认开启，可通过 `UTEN_MANAGER_PERMISSION_DELEGATION_ENABLED=false` 紧急回退。公司目标库、历史授权对账、现场 UAT、目标规模性能、恢复与发布签字未完成前继续 **NO-GO**。
> V328 兼容真实 V327 中缺少源码侧历史码 `production:view` 的数据形态：`production.plan` 与 `production.hub` 不再依赖该 tombstone；若 V328 的完整性门禁失败，PostgreSQL 会回滚本次迁移的结构、数据与 history 写入，必须修正候选并重新验证，禁止用 `flyway repair` 掩盖失败。
>
> **客户预收当前目录头（2026-08-23）**：共享工作树迁移目录现为 V389，共 351 个版本化 SQL、
> 351 个唯一版本且无重号。V379–V387 建立客户预收、普通收款逐订单 FIFO、预收转销、双币来源容量、
> 活动订单与取消守卫；V388/V389 把 sales_orders.deposit 固定为不可改的 legacy 快照，新单只能零或空。
> 正式 AR 仍只在 SHIPPED 形成。退款、历史多订单收款人工来源对账、目标非空库迁移、多岗位 UAT、
> 恢复与签名发布未完成，生产继续 **NO-GO**。本段覆盖下方 V375/V329/V306/V289 等阶段目录数字，
> 但不把源码候选写成目标库已升级。详见
> [ADR-048](../99-决策记录-ADR/ADR-048-客户预收与销售订单资金事实分层.md)。


> **2026-08-28 V419 本机开发库零基线重置（再次执行）**：执行前 33 张业务表合计 220 行，
> `stock_balances/stock_movements/stock_reservations` 各 7 行；账户五项金额及四类遗留期初字段仍为 0，
> 目标库无其它客户端连接。备份 `server/backups/uten_imp_pre_full_reset_v419_20260828184827Z.dump`
> 大小 7,082,798 字节，SHA-256 为 `BAD49ECD80AA2CFC97609B9F38FFFDF7A37B2EF6FD82C5076C431F2ADA8619D6`；
> 完整恢复后源库/恢复库的 283 张实体表、381 条 Flyway 和全部零基线字段指纹一致。单事务提交后
> 191 张 CLEAR 表和库存三表均为 0，账户及遗留期初继续为 0；92 张 PRESERVE 表逐表计数指纹不变，
> 六张物化视图、禁用非内部触发器和其它连接均为 0。临时恢复库与容器 `/tmp` 副本已删除，主机备份
> 保留。该记录只适用于本机可丢弃开发库，不代表空数据库或任何内测/生产验收。
>
> **2026-08-28 V419 本机开发库零基线重置**：迁移头为 V419/381，live catalog 共 283 张父表，
> 重置策略前向更新为 `CLEAR 191` / `PRESERVE 92`。V407–V419 新增的账户流水月汇总、日报命令账、
> 19 张 FQC 检验/放行/恢复/补产业务表和仓库到货登记命令账共 22 张全部明确 CLEAR；未知表、幽灵表和
> PRESERVE→CLEAR 外键均为 0。执行前 191 张 CLEAR 表合计 166 行，库存余额/流水/预留为 1/2/2 行；
> 账户五项金额及四类遗留期初字段已为 0。备份
> `server/backups/uten_imp_pre_full_reset_v419_20260828164020Z.dump` 大小 6,730,772 字节，SHA-256 为
> `11EEA9EED6C90A24A179A25FBD956EEB586925603AAA93F627F33BD2437F7309`。恢复库与源库的 283 张实体表、
> 381 条 Flyway、分区和零基线字段指纹一致；恢复库重建物化视图后证明源库旧
> `subcontract_monthly_mv` 少 1 行属于可重建派生视图陈旧，不是基础数据缺失。单事务提交后 191 张
> CLEAR 表、库存、账户和遗留期初均为 0，六张物化视图统一为 0，92 张 PRESERVE 表指纹不变。
> V407–V419 迁移异常/FQC 完整性视图均为 0；27 个账户的缓存余额、流水余额、差异和活动流水异常均为 0。
> 临时恢复库与容器 `/tmp` 副本已删除，主机备份保留；应用保持停止。该证据只适用于本机可丢弃开发库，
> 不代表空数据库或内测/目标库/生产验收。
>
> **2026-08-28 V406 本机开发库零基线重置（幂等复核执行）**：执行前 169 张 CLEAR 表、库存三表、
> 27 个账户五项金额及客户/供应商/货品/结算类别遗留期初字段均已为 0，目标库无其它客户端连接。
> `server/backups/uten_imp_pre_idempotent_reset_v406_20260828141323Z.dump` 大小 5,920,352 字节，
> SHA-256 为 `C223258A4C1EC24BFAF6C36988657C487A844E86E8BB4DC92D6E7BC406B7DB97`；完整恢复后源库与
> 恢复库的 261 张表、368 条 Flyway 和全部零基线字段指纹一致。幂等单事务执行中五组保留主档 UPDATE
> 均为 0 行，重新完成 CLEAR `RESTART IDENTITY`、六张物化视图刷新和全部断言；执行前后 169 张
> CLEAR 表及 92 张 PRESERVE 表指纹分别完全一致。临时恢复库与容器 `/tmp` 副本已删除，主机备份保留。
> 该记录只证明本机可丢弃开发库的零基线复核，不代表空数据库或任何内测/生产验收。
>
> **2026-08-28 V406 本机开发库零基线重置（再次执行）**：live catalog 继续为 261 张父表，
> `CLEAR 169` / `PRESERVE 92`、未知表和 PRESERVE→CLEAR 外键均为 0。执行前 48 张业务表合计 103 行，
> `stock_balances/stock_movements/stock_reservations` 分别为 1/2/2 行；27 个账户五项金额及客户/供应商期初
> 往来、货品 legacy 期初库存、结算类别期初金额已经为 0。备份
> `server/backups/uten_imp_pre_full_reset_v406_20260828092607Z.dump` 大小 5,939,221 字节，SHA-256 为
> `493FED636F459D555ED761AE5989175F3F494A8D24489187A0749434D5795B72`；完整恢复后源库/恢复库的
> 261 张表、368 条 Flyway、父表/分区、六张物化视图和全部零基线字段指纹一致。单事务提交后 169 张
> CLEAR 表和库存三表均为 0，账户及四类遗留期初字段继续为 0；91 张非审计 PRESERVE 表逐表计数指纹
> 不变，因所有保留主档目标字段原本已为零，本次未新增 `ops:reset_business_data` 主档 UPDATE 审计。
> 临时恢复库与容器 `/tmp` 副本已删除，主机备份保留；该证据只适用于本机可丢弃开发库。
>
> **2026-08-27 V406 本机开发库零基线重置（业务、库存、账户金额及遗留期初）**：执行库为 V406/368；
> live catalog 验证 261 张父表与 `CLEAR 169` / `PRESERVE 92` 策略完全一致，未知表和
> PRESERVE→CLEAR 外键均为 0。执行前 46 张业务表合计 102 行，27 个账户中 5 个存在非零金额，260 个
> 客户中 134 个存在非零 `init_total/init_total2`；供应商期初应付、货品 legacy 期初库存和结算类别期初金额
> 已为 0。库存事实为 `stock_balances` 1 行、`stock_movements` 2 行、`stock_reservations` 2 行。备份
> `server/backups/uten_imp_pre_full_reset_v406_20260828031801Z.dump` 大小 5,697,999 字节，SHA-256 为
> `0E1724320263A66A93267C3FB0C4622A918D6612FAE9374ACCE5BE53A8690E87`；完整恢复到唯一临时库后，
> 261 张表、368 条 Flyway、父表/分区、六张物化视图及账户五项金额逐账户指纹与源库一致。受控单事务
> 先将 169 张 CLEAR 表、库存和 27 个账户五项金额归零，再用扩展后的 V406 脚本把客户/供应商期初往来、
> 货品 legacy 期初库存和结算类别期初金额归零。最终四类遗留期初非零数均为 0；`audit_log` 新增 5 条账户
> 和 134 条客户 `ops:reset_business_data` UPDATE 记录，均证明非金额/非期初主档字段未改。除审计增量外，
> 其余 91 张 PRESERVE 表逐表计数指纹不变。临时恢复库与容器 `/tmp` 副本已删除，主机备份保留。
> 这里的“零基线”不删除账户/货品/客户/员工主档、币种、信用额度、铺底额、余额警戒线、权限、审计、
> Flyway、编号流水或全局标识占用，不等于新建空数据库，也不得外推为内测、目标库或生产验收。
>

> **2026-08-27 V405 本机开发库业务重置（第三次执行；备份时间为 2026-08-28 UTC）**：执行库继续为
> V405/367，清理脚本与 261 张真实父表一致，分类为 `CLEAR 169` / `PRESERVE 92`，catalog 漂移和
> PRESERVE→CLEAR 外键均为 0。执行前停止会重连数据库的 ERP Java PID 31300，确认目标库其它客户端、
> 业务 Outbox 阻断、附件对象 Outbox、上传会话和非人事附件 owner 均为 0。本次备份
> `server/backups/uten_imp_pre_reset_v405_20260828010125Z.dump` 大小 5,493,113 字节，SHA-256 为
> `940AB4A3EE702718CACE48EAB8EA41D4A56EF47C9CBC72218749101FBB1B7E0C`；完整恢复到唯一临时库后，
> 源库与恢复库的 261 张表、367 条 Flyway、父表/分区及六张物化视图指纹一致。单事务清理前 CLEAR
> 合计 66 行，提交后 169 张 CLEAR 表全部为 0；92 张 PRESERVE 表合计 44,681 行且逐表计数指纹不变；
> 六张物化视图、禁用的非内部触发器和目标库其它客户端连接均为 0。临时恢复库与容器 `/tmp` 副本已
> 删除，主机备份保留。该证据只适用于本机可丢弃开发库，不代表内测、公司目标库或生产验收。
>
> **2026-08-27 V405 本机开发库业务重置（再次执行，仅本地 `uten_imp`）**：执行库为 V405/367，
> `server/ops/reset_business_data.sql` 与真实 catalog 一致，将 261 张 public 非分区普通表/分区父表精确
> 分类为 `CLEAR 169` / `PRESERVE 92`，无未分类表、幽灵表或 PRESERVE→CLEAR 外键。执行前没有 Java/
> 其它客户端连接，业务 Outbox 阻断、附件对象 Outbox、上传会话和非人事附件 owner 均为 0；数据库名、
> 主库状态和 `system_identifier` 三闸复核一致。本次备份
> `server/backups/uten_imp_pre_reset_v405_20260827182027Z.dump` 大小 5,327,135 字节，SHA-256 为
> `53369B0EBDE139345E2B52BEAA65D9A181BE2313DC1C66EB970E5A931A0BA7A2`；归档完整恢复到唯一临时库，
> 源库与恢复库的 261 张表逐表行数、367 条 Flyway、父表/分区及六张物化视图指纹一致。单事务提交前
> CLEAR 合计 78 行，提交后 169 张 CLEAR 表全部为 0；92 张 PRESERVE 表合计 42,810 行且逐表计数
> 指纹不变；六张物化视图、禁用的非内部触发器和其它客户端连接均为 0。验证后删除临时恢复库及容器
> `/tmp` 备份副本，主机备份保留。该证据只证明本机可丢弃开发库本次重复清理与恢复演练，不代表公司
> 目标库、内测服务器或生产已清理/验收；目标库与生产仍禁止使用本脚本。
>
> **2026-08-26 V399 本机开发库业务重置（已执行，仅本地 `uten_imp`）**：目录头与执行库均为
> V399/361；`server/ops/reset_business_data.sql` 将 259 张 public 非分区普通表/分区父表逐张分类为
> `CLEAR 167` / `PRESERVE 92`。V330–V379 新增的委外损耗、供应商结算/索赔、客户预收抵销与收款来源
> 分配等 14 张业务事务表明确 CLEAR；V393–V398 新增的单客户只读授权、客户访问追加式事件、人员交接
> 批次/scope 与离职事件等 5 张权限/人事治理表明确 PRESERVE。分区子表不单列，随父表处理。
> 执行前停止本地 Java 应用，确认其它客户端、业务 Outbox、附件对象 Outbox、上传会话和非人事附件 owner
> 均为 0；数据库名、主库状态和 `system_identifier` 三闸复核一致。备份
> `server/backups/uten_imp_pre_reset_v399_20260827032141Z.dump` 大小 5,020,662 字节，SHA-256 为
> `EFA271804594A9447F4A1C84BE065C992A5C6F041ABC86F1A97B9A1B07058132`；不是只做 `pg_restore -l`，还完整
> 恢复到唯一临时库并比较 259 张表逐表行数指纹、Flyway、父表/分区和六张物化视图，源库与恢复库一致，
> 验证后删除临时库及容器 `/tmp` 副本，主机备份保留。单事务清理前 CLEAR 合计 70 行，提交后 167 张
> CLEAR 表全部为 0；92 张 PRESERVE 表合计 39,780 行且逐表计数指纹前后一致；六张物化视图为 0，
> Flyway 仍为 361/V399，禁用的非内部触发器为 0。应用为保护零业务基线保持停止，未自动重启。
> 该证据只证明本机可丢弃开发库本次清理与恢复演练，不代表公司目标库、内测服务器或生产已清理/验收；
> 目标库与生产仍禁止使用本脚本。
>
> **本地库业务数据清空记录（2026-08-19，仅本地 uten_imp，不影响任何目标库）**：应业主要求再次将本地
> 开发库重置为"只有基础资料、零业务单据"的干净起点。本次起该操作已固化为可复用脚本
> **`server/ops/reset_business_data.sql`**（配合 `-v ON_ERROR_STOP=1 -v confirm=CLEAR_BUSINESS` 执行；
> 脚本头部有完整范围说明与安全机制），共清空 147 张业务表：销售/采购/库存/生产/委外/财务全链单据、
> 工资批次与工资条、公告/建议/访客/官网询盘、审计日志、任务认领、附件索引、货品导入批次、老库迁移
> 运行记录，并将 `doc_number_sequences` / `business_document_sequences` 单据编号流水清零（新单据从头
> 编号）；6 张月度统计物化视图同步刷新归零。**保留**：人事（员工/合同/薪酬/任职历史/部门/岗位）、
> 全部主档（货品/BOM/客户/供应商/模具/分类/颜色/单位/币种/仓库/结算与付款方式/科目/账户）、主档与
> 业务编码预留（`master_code_*` / `business_identifier_*`，避免新单据撞号）、用户/角色/权限/系统设置。
> 本次改用单事务 `TRUNCATE … RESTART IDENTITY CASCADE`（已验证无任何保留表外键指向业务表，CASCADE
> 不越界；TRUNCATE 不触发行级触发器，无需 2026-08-17 的 DISABLE TRIGGER 流程），提交前逐表断言业务表
> 为零、22 张关键保留表行数不变，否则整体回滚。执行前备份：
> `server/backups/pre_clear_business_20260819_231931.dump`。仅适用于可丢弃的本地/测试库，不得用于
> 目标库或生产。

> **2026-08-22 V328 业务重置脚本前向加固（历史源码候选，当时尚未执行）**：2026-08-19
> 的“147 张”是当次历史记录，不能继续作为当前目录事实。当时脚本改由
> `ResetBusinessDataScriptContractTest` 解析唯一表策略：235 张 public 非分区普通表/
> 分区父表必须恰好分类为 `CLEAR 148` 或 `PRESERVE 87`；V304 的委外备料计划两表及
> V307/V309 的 exact peg、跨分析让料、entitlement 三表均显式 CLEAR，不再依赖级联静默
> 扩大范围。脚本以 `confirm + expected_database + expected_system_identifier` 三闸确认，
> 要求应用/定时任务/Outbox worker 已停止、无其它客户端连接、Outbox 无待处理或失败事件；
> CLEAR 逐表归零、PRESERVE 逐表计数不变及六张物化视图归零都在唯一事务提交前验证。
> 安全审计、人事附件、附件对账、货品导入和老库迁移证据、个人资料变更记录、
> `doc_number_sequences` / `business_document_sequences` 均保留，维持治理证据和
> 全局编号单调性；外键绑定具体生产计划的 `production_product_no_sequences` 随计划清空。
> 存在非人事附件
> owner 时脚本拒绝执行，必须先走对象删除/对账流程，禁止只删元数据制造孤儿文件。
> 这只是本地源码与脚本候选，不代表已清库、已恢复演练、已部署或完成多账号 UAT。
>
> **本地开发库重置记录（2026-08-17，仅本地 uten_imp，不影响任何目标库）**：应业主要求将本地开发库
> 业务面清空为全新测试起点——出入库单据/库存流水/余额（即时库存归零）、采购四单、委外八单、销售五单、
> 生产计划/日报/物料分析、收付款/应收应付/总账凭证、到货预期/IQC 待检/到货异常、预留与调整申请、
> 集成事件队列合计删除 300 行，并刷新 `stock_monthly_mv` / `finance_ar_ap_mv`。主档（货品/客户/供应商/
> 仓库/颜色/单位/币种/分类/模具/BOM/账户资料）、人事、权限、通知、单据编号占用与 `audit_log` 全部保留。
> 三张 `ENABLE ALWAYS` append-only 事件表（IQC/审批/出货事件等）在单事务内受控 DISABLE TRIGGER→DELETE→
> ENABLE 后复位，完成后全库无残留禁用触发器。此操作仅适用于可丢弃开发库，不得用于目标库或生产。
> 同日新增 V296（仓储部收货权限补齐，已经 Flyway 应用于本地库，见
> [54 §V296](54-部门默认权限矩阵.md)）与 `--shelf-labels` 迁移目标（货架库位人工 CSV，种子 28 行已收录，
> 见 [17 §十二](17-仓库管理-新库与迁移.md)）；`migrate.sh` 的 `EXPECTED_FLYWAY_*` 冻结常量仍为 270/289，
> 待下次交付冻结随 checksum 清单统一重算。

> **全局业务标识增量（V279，2026-08-14 源码候选）**：V279 登记 37 个文档命名空间及 `VISITOR_ACCOUNT=V`，新文档号为 `PREFIXYYYYMMDDNNNNNN`。固定文档/系统/主档前缀与四类分类显式 `code_prefix` 共用全局精确 token 终身保留；文档号、系统号与主档编号的归一完整值也全局终身占用。旧库/已有号码原样保留，历史重复和无法解析格式只追加登记成员/冲突证据，不静默改号。只有可恢复副本 dry-run、冲突报告签收、并发/跨日验证、备份恢复演练和岗位 UAT 全部通过后才能写目标库。具体命名空间、五类字段边界和回滚约束见 [ADR-036](../99-决策记录-ADR/ADR-036-全局业务标识与单据号命名空间.md)。V279 的编号不意味它是并发工作树的最新迁移；目录最高版本和文件数只在交付冻结后重算。

> **当前共享工作树迁移状态（2026-08-14）**：目录最高 V289，共 270 个迁移文件、270 个唯一版本且无重复。V256–V264 属当前业务增量，V265/V267 是收付款类别/账户 UUID 引用守卫，V266 与 V268–V271 继续补充总账、生产、采购和销售的 UUID/历史快照，V272 新增未分类主档的系统分类根，V273–V278 是随后加入的关系、编号和财务过账治理候选，V279 是本次全局业务标识注册，V280/V281 是人员删除与附件授权/元数据治理，V282 才是员工 7 项扩展 PII 的局部加密候选，V283 修正生产关联采购/委外订单在财务审批时的一次性货品快照锁定守卫，V284 保护个人信息变更敏感 old/new 快照并定向清理历史审计副本，V285 收紧客户默认结算方式 UUID，V286 允许尚未登记证件号/主手机号的 bootstrap/legacy 员工保存仅含实际扩展密文的 `employee_sensitive` 行，V287 拒绝无证件号/主手机号密文却残留对应 HMAC/last4 派生值。V288 创建 `production_material_analysis_borrows` 及端点约束；V289 收紧新行 ACTIVE/零生效量、禁 DELETE、REVOKED 后不可变、核心 payload/时间戳守卫、终态端点/维度一致性，并刷新 fail-closed 全 `public` 审计覆盖。源码候选已接通 create/revoke 持久化、同事务双趟生效计算和 Flutter UI；专项 PostgreSQL 6/6、后端行为/合同 35/35、Flutter 聚焦 45/45 且 analyze 0 issue。这仍不代表受保护版本、公司目标库或生产已迁移；公司目标库保留既有 V238 只读证据，真实角色权限负测、岗位/实物 UAT、恢复和签名发布仍为 **NO-GO**。
>
> **当前源码候选验证（V289/270，2026-08-15）**：启用 `UTEN_RUN_DB_TESTS=true` 的最终后端 `mvn clean verify` 生成 401 份 Surefire 报告、执行 1,714 项测试，0 failure / 0 error、2 项按门控跳过；Failsafe 双 JAR 打包门禁 2/2 通过。真实公司克隆演练因缺少带外数据库身份、备份摘要和批准引用而必须跳过；checksum exporter 默认拒绝写文件，但已另行显式执行 1/1 通过。PostgreSQL 16.14 隔离库已从空库应用全部 270 个唯一迁移到 V289，自动 V238→V289 非空演练通过；本地 PostgreSQL 16.4 又实际验证主 Boot JAR 从 V276/257 应用 13 条到 V289/270并健康返回 200，独立 migrator JAR 分别从空库执行 270 条、从 V276 执行 13 条，均先 validate、退出码 0且不回显凭据。双 JAR 的迁移集合与 270 行 Flyway checksum 清单一致。Flutter/Dart 已通过 734 个文件格式门禁、全量 analyze 0 issue、729/729 测试、4/4 Web 更新测试、729 个固定字体资产检查及同源无 CDN 的 Web release 构建；真实构建副本也通过 `stamp-web` 终态验证。部署链五组 Python 门禁共 909 项，0 failure / 0 error、5 项按真实 disposable-host 环境门控跳过；100 个部署 Python 文件、52 个 shell 脚本、隔离 systemd 合并图和官方模板合同均通过。本机真实 Docker 链已从受审源码包构建 15 个锁定分发包，生成并核验 lock、SHA-256 清单、SBOM 与证明，随后在断网双容器中完成 root-owned venv 安装校验及普通用户只读测试；updater 405 项通过，11 项仅按 root/真实主机条件门控跳过。正式 wheelhouse 仍必须由受保护 CI 或已验收构建机从冻结提交重新生成。以上均只是未提交工作树的本地源码候选证据，不代表真实公司克隆、公司目标库、签名发布或服务器安装已经完成，也不替代目标库预检、冲突与历史数据报告、金额/数量/来源对账、备份恢复演练及真实岗位 UAT。
> **历史冻结验证（V287/268，已被当前 V289/270 目录头取代）**：加入 V288/V289 前的旧数字只对应当时冻结字节，不得冒充当前候选结果或目标环境证据。

> **非空升级演练边界**：`V238ToCurrentSyntheticMigrationPostgresTest` 自动从公司目标库最后一份只读版本基线构造非空 V238，再应用 V239–V289 并核对迁移数、业务表保留、用户身份、权限范围、收付款/库存合计、系统分类根、编号冲突、客户结算、PII 和现货借用审计合同。真实公司数据只允许在独立可恢复克隆上由 `CurrentHeadNonEmptyCloneRehearsalTest` 执行，并须显式绑定数据库名、PostgreSQL `system_identifier`、实际起点、备份 SHA-256、批准引用及两类规范化问题清单 SHA-256；该测试永不启用 Flyway `clean`。自动演练通过不等于公司克隆已演练，缺少带外证据时必须保持跳过。
>
> **V282/V284/V286/V287 加密迁移与单版本切换**：V282 用 PostgreSQL 全局 advisory lock 串行化启动 runner 与两份受审 HR 导入；runner 以 100-id 小批逐员工锁住主行/sensitive 行，既有密文先解密对账、空目标才条件写。V286 只移除 `employee_sensitive.id_card_enc/phone_enc` 的数据库 `NOT NULL`，使 runner 可在锁内为尚未登记证件号/主手机号的 bootstrap/legacy 员工创建仅含实际存在扩展密文的行；V287 进一步要求主身份密文为空时相应 HMAC/last4 派生值也为空。二者都不合成身份值，也不放宽正常入职或补开账号校验。缺失行创建或重载失败、密文冲突、派生孤儿、失去所有权或最终旧明文残留非零仍失败关闭；完全没有旧扩展 PII 的员工无需被伪造一行。数据库拒绝无专用 backfill/legacy-import capability 的 7 个旧明文列写入，readiness 在 runner 完成前保持拒绝流量。V284 的 `profile_change_requests.value_encoding` 区分 `PLAIN`、`PGCRYPTO_V1`、`LEGACY_UNKNOWN`；敏感 INSERT/UPDATE 除领域密文外还必须有精确事务级 codec capability，旧实例/旧 JAR 无法审批新密文行。历史行逐行验证/加密，带版本密文按 keyring 选 key；无版本旧 pgcrypto 只试当前 key、不猜历史 key，失败保留原值并中止。迁移定向清除两种 profile-change target type 的 old/new/`review_comment` 审计副本。发布必须停写、排空全部旧实例后单版本切换，禁止滚动并存及旧 JAR 回滚；失败仅允许前向修复或恢复与旧版本完全一致的隔离验证备份。目标库仍须验证 7 列旧明文与 `LEGACY_UNKNOWN` 均为零、需要迁移扩展 PII 的员工均有可解密目标行、无主身份的扩展-only 行没有派生孤儿且不能开通账号、审计敏感键为零、旧 key 可读和完整审批回归。
>
> **收付款类别引用守卫（V265/V267）**：类别层级/状态维护与费用、收入、收款其它费用、报销、账户、总账和资产子账引用共用 `PAYMENT_STYLE_HIERARCHY` 事务锁；数据库 BEFORE trigger 在加锁后按用途校验存在性、大类、启用状态和叶子节点。V267 将账户映射升级为 `accounts.style_id` UUID 真源并接入同一守卫；旧库财务导入只在单次事务使用受限兼容模式，并在提交前核对全部实际导入映射。详见 [26 §3.2](26-钱流管理-新库与迁移.md)与 [ADR-035](../99-决策记录-ADR/ADR-035-收付款类别分类页与财务引用一致性.md)。
>
> **UUID 关系与主档编号后置治理（V257–V278）**：V257–V263 冻结销售、采购、仓库、委外明细的货品编号/名称快照；V264–V271 把报价转换、销售来源、总账来源、报工生成单、采购人员/部门等在线关系收敛到 UUID，单号/姓名/旧整数只作历史快照或受控导入影子；V272/V275 为各主档“未分类”根建立受保护 UUID 注册身份；V273 将 `B_PStyle` 与独立 `RecStyle` 分别迁入 `settlement_methods`、`finance_payment_methods`，不接 `payment_styles`；V274 明确仓库旧 `WorkID` 是操作员影子，当前车间只写部门 UUID；V275 补生产日报来源、库存调整命令 UUID 关系；V276 为业务主档编号建立同域终身保留；V277 收紧账户会计科目与类别关联账户 UUID；V278 建立 7 个固定系统过账角色到 `payment_styles.id` 的持久化映射。普通在线新建/编辑和总账过账不按编号、名称、路径或 `legacy_id` 反查生成关系。详见 [ADR-034](../99-决策记录-ADR/ADR-034-分类驱动业务编号与UUID关联.md)。这些仍是源码候选，目标库迁移、冲突预览、历史对账和多岗位 UAT 未完成。
>
> **货品选择与 Excel 导入 UUID 边界**：`GoodsListItem` 直接返回颜色/单位 UUID，销售、采购、仓库、委外和生产新建单据直接透传，不再由 legacy 值二次换算。Excel `detect` 返回绑定操作者、文件 SHA-256、主档指纹和逐行 UUID/new-token 的五分钟一次性 `planId`；服务重启、过期、重复提交或文件/操作者/主档漂移时必须重新检测，`commit` 不按名称重新选“第一条”。
> V253–V255 都与生产默认车间无关，生产的未来默认车间建议仍以 V192 `production_goods_workshop_preferences` 为唯一事实源。开发原库 `uten_imp`
> 实测保持 V244/installed_rank 225，既有一次性隔离克隆已真实迁移到 V250/installed_rank 231；“233 个迁移到 V252”是更早时点的历史证据，当前候选目录事实与本地验证以顶部 V289/270 记录为准，
> 仍不能据此宣称 V239–V289 已在公司目标环境验收。公司目标库仍保留 V238 既有只读证据。生产备份、V239–V289 正式迁移、全表及金额/数量/来源谱系
> 对账尚未执行。统一证据和待办见
> [2026-08-09 本地云端部署与生产就绪清单](../99-项目治理/2026-08-09-本地云端部署与生产就绪清单.md)。

> **货品批量导入审计增量（2026-08-11）**：V251 新增 `goods_import_batches` 与 `goods_import_creations`，分别保存导入/撤销状态和本批新建实体来源；两者都是解释、限定和追溯撤销的业务事实。V252 在不修改已应用 V251 的前提下重跑 fail-closed 全表审计覆盖，为缺失表补建唯一有效的 `trg_audit%` AFTER ROW I/U/D 触发器并复核全库契约。V252 只保护迁移后的新变化，不补造历史审计；公司目标库应用、`pg_trigger` 矩阵和导入/撤销岗位 UAT 未完成前不得视为生产放行。

> **官网询盘增量（2026-08-11）**：V253 新增 `website_inquiries`、本表自己的审计触发器及 `webinquiry:view/manage` 权限。它不增加 `goods.default_workshop_department_id`，也不改变 V192 车间建议学习规则；后续生产结构修正必须使用 V254 或更高版本，禁止复用 V253。详见 [57-官网询盘汇入](57-官网询盘汇入.md)。

> **官网询盘审计覆盖修正（2026-08-12）**：V254 以新的不可变迁移重跑完整 fail-closed audit sweep，并把 V253 的 `website_inquiries` 纳入合同测试；没有修改 V253，也不补造历史审计。目标库触发器矩阵、历史询盘事实和岗位 UAT 未验收前仍为生产 **NO-GO**。

> **附件生命周期与审计覆盖（2026-08-12）**：尚未发布、未应用的 V255 将既有附件标记为 `LEGACY_UNVERIFIED`，增加隔离上传会话、扫描后提升、对象删除 Outbox、孤儿对账及审批权限；三个新表先安装唯一审计 trigger，再执行全库 fail-closed sweep。该迁移不会把历史对象冒充为已扫描；权威库副本演练、真实恶意文件扫描、双 Bucket/CORS/RAM、容量与恢复 UAT 完成前仍为生产 **NO-GO**。

> **生产物料分析重构增量（2026-08-10）**：现行序列为 **V234/V237/V239 与 V247–V250**。V234 新增计划前需求、全树物料快照、供应动作、命令幂等和计划分批链接；V237 刷新新增公开业务表未来写入的审计覆盖且不补历史；V239 允许节点剩余 `required_qty` 在全量 plan-link claim 后合法归零，修复整批生成终态被旧 `> 0` 约束拒绝的问题；V247 冻结阶段/包装边及 start/finish/ship 三个 ready 字段，其中当前 ship 等于 finish 的参考投影而不是独立硬门槛；V248 冻结非线性精确执行需求，V249 显式区分 DEMANDED/ZERO_MATERIAL，V250 保护外部化申请/订货来源谱系。详见 [56-生产计划前需求与物料分析重构](56-生产计划前需求与物料分析重构.md)和本文 V247–V250 节。隔离 PostgreSQL 和真实 HTTP 证据不等于目标库迁移、历史对账或真实岗位/实物 UAT，生产写链路仍为 **NO-GO**。

> **销售待收/应收/分批收款增量（2026-08-08）**：V236 增加 AR 收款拆分、行级汇率/冲销/余额快照和销售订单来源；V237 刷新审计覆盖；V238 在不改变已部署 V236 checksum 的前提下保守撤回不能证明安全的历史原币合成，并补启用的手续费/汇兑损益科目。详见 [20-销售管理](20-销售管理-新库与迁移.md) §十二、[26-钱流管理](26-钱流管理-新库与迁移.md) §十四与 [ADR-030](../99-决策记录-ADR/ADR-030-销售待收计划与正式应收分层.md)。目标库历史分类对账、回滚演练和财务 UAT 未完成前生产仍为 **NO-GO**。
>
> **附件对象存储边界（2026-08-12）**：V240–V244 建立附件元数据、对象完整性与固定版本读取基础；V255 再增加隔离上传、扫描、提升、删除和对账状态机。OSS 模式必须使用不同的私有 staging/final Bucket：staging 强制 Versioning Off 与禁止覆盖，final 强制 Versioning Enabled 并固定 `versionId`；上传授权绑定用户、业务单据、key、类型和大小，下载和删除每次重新授权。目标 Bucket、CORS、RAM、AV、容量/告警、压测与恢复均未真实验收，上传开关继续关闭。
>
> **附件生产发布门禁**：V255 默认把旧行置为 `LEGACY_UNVERIFIED`，只有 `CLEAN` 可列出/下载；不得仅回填 `storage_version` 就绕过扫描。源码已有 PostPolicy 大小前置门禁、staging→扫描→final、删除 Outbox、pending 配额和孤儿对账，但真实 AV、双 Bucket/CORS/RAM、恶意样本、告警、容量、压测、断网/掉电及恢复演练仍未完成，继续 **NO-GO**。
>
> 云端架构是**本地唯一写主库 + 异步物理热备**，链路断开时公司继续写、远程整体 503，不存在双边写入后的自动合并。部署与真实故障矩阵见 [cloud Runbook](../../deploy/cloud/README-cloud.md) 和 [ADR-031](../99-决策记录-ADR/ADR-031-本地云端单主库部署架构.md)。当前真实目标库、阿里云 ECS/VPN/OSS、PITR 与故障切换尚未验收，不能表述为“填 `.env` 即可上线”，生产保持 **NO-GO**。

<!-- PRODUCTION-PLANNING-V195-CURRENT -->
> **历史记录：生产计划迁移增量（2026-08-02）**：以下 V190/V191–V195 状态只说明当时的迁移设计，
> 不代表 2026-08-10 当前版本或目标库事实。V191 预排草案、V192 车间建议、V193 审计覆盖刷新、V194 MAKE 供给生命周期/三态人工放行/生产组织层级守卫，以及 V195 在 V194 后再次刷新审计覆盖，均为当时候选迁移，详见 [52-生产预排审核下达与车间建议](52-生产预排审核下达与车间建议.md)。新数据处置为 `READY`、`AUTO_WAIT`、`DEFERRED`；`release-defer` 只允许 DEFERRED 单向人工放行并立即重做齐套。车间、班组、负责人和日期由应用层与 V194 数据库守卫共同校验。V191–V195 全部禁止历史业务回填：不重算旧 BOM/计划、不补造计划包/子计划/供给分摊、不从旧单猜车间或延期状态；V193/V195 只保护迁移后的未来写入，不补历史审计。当前目标库/源码边界以本页顶部 2026-08-10 状态为准。

> 本文件夹是「老库 `YTDQ_2023` → 新库」数据迁移的**执行中心**。
> 看本 README 就懂：每个模块迁什么、代码在哪、怎么一键迁移、怎么加新模块。
> 现行融合策略是“按模块幂等迁移、对账、统一切换写入口、老模块只读”，见
> [ADR-017](../99-决策记录-ADR/ADR-017-模块化单体与异步旁路.md) 和
> [老系统融合总策略](../06-老系统融合/00-融合总策略.md)。

---

## 🔐 目标库迁移 authority 与停点

当前源码候选目录是 V423/385，但这个数字本身不能授权目标库升级。公司目标库迁移前必须依次完成：

1. **冻结同一发布 lineage**：从受保护、签名 commit 和签名 annotated tag 生成主 JAR、migration-only JAR、
   Flyway checksum manifest 与 Release 签名；三者的 385 个 `version/script/checksum/source SHA-256` exact-set
   必须一致。GitHub/签名 authority 见
   [配置执行清单](../../deploy/release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)。
2. **先建立目标身份**：按
   [目标服务器带外清单](../../deploy/target-host-oob-authority.zh-CN.md)完成 H01–H12 后，首次会话只读采集
   PostgreSQL `system_identifier`、timeline、监听进程、数据库名和全部 `flyway_schema_history`；旧截图、旧 JAR
   或历史 V238 记录不能替代 live history。
3. **核对已应用字节不可变**：live history 中每个已应用 version/script/checksum 必须与冻结源码完全一致；任一
   mismatch、失败行、重复版本、未来版本或未知 repeatable 立即 **NO-GO**。禁止 `flyway repair`、手工改 history、
   修改/重命名已应用 SQL 或用旧 JAR 回滚覆盖。
4. **先在可恢复副本演练**：对目标库经验证备份恢复出的独立副本执行 V238→签名目标，保存备份 SHA-256、
   恢复耗时、system identifier、迁移前后行数/金额/数量/状态/来源、触发器/约束和 PII 对账。合成非空测试、
   开发原库 V244 和一次性 V250 克隆都不能替代真实公司副本演练。
5. **正式窗口单版本切换**：停写、排空旧实例、留存可恢复备份并取得数据库维护锁后，只运行同一签名候选的
   migration-only JAR；应用运行账号不持 DDL 权限。迁移、live history exact-set、JPA validate、readiness 和业务
   对账全部通过前，ERP/Nginx 入口保持关闭，禁止新旧 JAR 滚动并存。
6. **失败只前向或恢复**：失败时保留证据并保持入口关闭，只能新增更高版本的前向修复，或恢复与旧版本完全
   一致且已演练的备份；不得删约束、禁触发器、伪造回填或继续带病启动。

上述步骤是 Flyway schema 升级；下面的 legacy bootstrap 是另一条首次离线业务数据导入链。两者必须分别有
manifest、批准、对账和 terminal receipt，不能用“Flyway 成功”替代老库数据迁移，也不能用 `bootstrap-all`
替代 V1→V423 的 schema history。当前 legacy bootstrap 源码校验已同步 V423/385，但目标 manifest、可恢复副本 bootstrap、业务对账和恢复演练仍未执行，不能把“常量一致”冒充迁移完成。

## 🚨 执行边界：只有首次离线 bootstrap，不存在运行时增量迁移

当前能力分为正式离线链和本地开发样例，二者不能混称“一键迁移”：

| 入口 | 覆盖范围 | 证据边界 | 可用于切流后追平 |
|---|---|---|---|
| `server/legacy_migration/migrate.sh --bootstrap-all` | 主档及采购、库存、销售、委外、生产、钱流等首次导入 | 源码校验已同步 V423/385 与 `bootstrap-v9-v423`；受保护 385 行 manifest、目标副本实跑、对账和恢复尚未完成 | **不可以** |
| `/api/admin/dev/legacy-category-seed/*` | 四棵 classpath 分类样例 | 仅 `dev` profile 的页面/分类树调试 | **不可以** |

运行中 ERP 不包含 SQL Server 驱动或老库 DataSource，也没有 `/api/admin/legacy-migration/all`。
Shell 会拒绝无目标、未知目标和多目标调用，并要求破坏性确认。它保持 FK、审计触发器和 UUID
注册身份有效，以 FK 顺序 `DELETE`/重建；禁止 `TRUNCATE`、`CASCADE` 和禁用约束。

单模块命令只用于隔离演练或故障定位：

```bash
bash server/legacy_migration/migrate.sh --stock-docs --confirm-destructive
bash server/legacy_migration/migrate.sh --subcontract --confirm-destructive
```

完整引导只允许在可清空的新库/演练库执行：

```bash
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

> **禁止**把 dev 分类样例当生产迁移，禁止把破坏性 Shell 脚本用于已切流模块，禁止用多目标命令。
> 当前仅首次全量 bootstrap 具备受审输入绑定和自动结构对账；增量、dry-run、统一 quarantine 与可重复回滚尚未交付，不能把首次引导脚本冒充持续迁移体系。
> 销售是顺序依赖的典型：`--sales` 只导入单据并保留 `seller_legacy_id`，HR 员工
> `legacy_id` 可用后还必须执行单独的 `--sales-owner` 回填。推荐只用 `--bootstrap-all` 的内置顺序；
> 不得把“销售表有数据”误判为 owner 归属已经完成。

> **⚠️ 数据坑（已修，迁其他含地址/备注的表时复用）**：老库 varchar 字段（地址、收货地址、备注）
> 可能含管道符 `|`。`export_legacy.ps1` 的 `Export-Query` 已做 RFC4180 引号转义（字段含
> 分隔符/引号/换行则 `"..."` 包裹、内部 `"`→`""`），配合 COPY `FORMAT csv` 正确还原。
> 不转义会 `missing data for column X`（客户主档首跑即踩）。

---

## 📦 模块清单

> 表中每个 `migrate.sh` 目标均是脚本真实支持的单目标 flag；实际执行必须再传 `--confirm-destructive`
> （或数据库名绑定的 `UTEN_CONFIRM_DESTRUCTIVE_MIGRATION`）。各目标必须分开调用，只有显式
> `--bootstrap-all` 会按内置依赖顺序执行全量引导。

| 模块 | 状态 | 老库来源 | 新库表 | 迁移代码 | 文档 |
|---|---|---|---|---|---|
| **货品分类** | ✅ 已实现 | `SystemItem` (ItemclassID=1) | `material_categories` | `migrate.sh --goods` | [02-老库溯源](02-货品分类-老库溯源.md) · [03-新库与迁移](03-货品分类-新库与迁移.md) |
| **货品主档** | ✅ 已实现 | `B_Goods`（35750 条，全 78 字段，image 留空） | `goods` | `migrate.sh --goods-data` | （字段映射见 V32__goods.sql） |
| **货品组装（BOM）+ 成本预算** | ⛔ 待业务处置拒绝行 | `B_BomItem`（218,820 行；正确孤儿 20,798）/ 成本列随主档 | `goods_bom_items`（有效源迁移 198,022；另有新系统手工行） | `migrate.sh --goods-bom --confirm-destructive` | [31-组装BOM与成本预算](31-货品组装BOM与成本预算.md)；V181 隔离 81 条误接占位边，计数守恒不等于零数据丢失 |
| **即时库存** | ✅ 已实现 | `View_IOStockGoods` 口径：`StockGoods.FactQTY/FactWeight` + `B_Goods.Paper/CTotal` + `View_ProductMore`（F_PlanItem） | `stock_balances`（**V80 增 weight**；余额含重量 1,288 行） | `migrate.sh --stock-docs`（重跑即补重量） | [32-即时库存](32-即时库存.md) |
| **模具分类** | ✅ 已实现 | `SystemItem` (ItemclassID=18，65 个扁平业务根) | `mould_categories`（V272 候选目标 66 根：65 业务根 + 1 系统“未分类”根） | `migrate.sh --mould` | [04-老库溯源](04-模具资料-老库溯源.md) · [05-新库与迁移](05-模具资料-新库与迁移.md) |
| **模具主档** | ✅ 已实现 | `B_Mould`（1605 条，12 字段；19 条源分类悬空） | `moulds`（V272 候选目标：系统根 19、`category_id NULL` 0） | `migrate.sh --mould-data` | （字段映射见 V34__mould.sql） |
| **颜色** | ✅ 已实现 | `B_Color`（151 条，**实测扁平**非树；`B_Goods.MColorID` 引用） | `colors` | `migrate.sh --color-data` | [10-老库溯源](10-颜色资料-老库溯源.md) · [11-新库与迁移](11-颜色资料-新库与迁移.md) |
| **基本单位** | ✅ 已实现 | `B_Unit`（66 条，扁平，与 B_Color 同构；`B_Goods.UnitID` 引用） | `units` | `migrate.sh --unit-data` | [12-老库溯源](12-基本单位-老库溯源.md) · [13-新库与迁移](13-基本单位-新库与迁移.md) |
| 模具 | ✅ 见上 | — | — | — | （已拆为「模具分类 + 模具主档」两行） |
| 员工 | ✅ 正式名录 141 人已录入（2026-08-05）；转正日期已按入职日期回填（V210/ADR-021）；老库 stub 融合键约定保留 | `B_Worker` + 《职工信息表.xls》 | `employees` / `employee_sensitive` / `positions` / `employment_history` | `build_hr_roster.py` → `migrate.sh --hr-cleanup --hr-roster --confirm-destructive`；老库 stub：`--hr-workers` | [34-人事老库迁移](34-人事老库迁移.md) · [53-人事正式名录迁移](53-人事正式名录迁移.md) · [55-转正日期回填与员工车辆联系方式](55-转正日期回填与员工车辆联系方式.md) |
| **客户分类** | ✅ 已实现 | `SystemItem` (ItemclassID=2，10 个业务根/40 个业务节点/最大 level 2) | `client_categories`（V272 候选目标 11 根/41 节点，含系统“未分类”根） | `migrate.sh --client` | [06-老库溯源](06-客户资料-老库溯源.md) · [07-新库与迁移](07-客户资料-新库与迁移.md) |
| **客户主档** | ✅ 已实现 | `B_Client`（260 条，34 字段；6 条未分组） | `clients`（V272 候选目标：系统根 6、`category_id NULL` 0；官网/财务后续兜底同根） | `migrate.sh --client-data` | （字段映射见 V36__client.sql） |
| **供应商分类** | ✅ 已实现 | `SystemItem` (ItemclassID=3，15 个扁平业务根) | `supplier_categories`（V272 候选目标 16 根，含系统“未分类”根） | `migrate.sh --supplier` | [08-老库溯源](08-供应商资料-老库溯源.md) · [09-新库与迁移](09-供应商资料-新库与迁移.md) |
| **供应商主档** | ✅ 已实现 | `B_Provider`（386 条，29 字段，源端全有业务分类） | `suppliers`（V272 候选令 `category_id NULL` 为 0；财务占位绑定系统根） | `migrate.sh --supplier-data` | （字段映射见 V38__supplier.sql） |
| **币种 / 仓库** | ✅ 已实现 | `B_Currency`(3) / `B_Storage`(6) | `currencies` / `warehouses` | `migrate.sh --currency-data` / `--warehouse-data` | [15-采购 §三](15-采购模块-新库与迁移.md)（归基础资料） |
| **采购管理** | ✅ 已实现（单位歧义行待治理） | `P_Application`/`P_Order`/`P_In`/`P_Withdraw`（主+明，十几万行） | `purchase_requests/orders/receipts/returns(+_items)` + V65 报表列 + V168 历史单位安全规范化 | `migrate.sh --purchase`（`migrate_purchase.sql`） | [14-老库溯源](14-采购模块-老库溯源.md) · [15-新库与迁移](15-采购模块-新库与迁移.md)（**9 报表 + V65 迁移补全 + V168 单位治理**） |
| **库存（流水+余额）+ 仓库报表** | ✅ 已实现 | `StockGoods`(45万) + 9 类 `O_*` 单据 | `stock_movements` / `stock_balances` / `stock_documents(+_items)` | `migrate.sh --stock-docs`（含人员 *_legacy_id + B_Worker stub + 末尾刷 MV） | [16-老库溯源](16-仓库管理-老库溯源.md) · [17-新库与迁移](17-仓库管理-新库与迁移.md) · [50-盘点修正与历史处理](50-仓库盘点修正与历史单据处理.md) · **14 张仓库报表**（V67：7 单据 × 明细/汇总，`/api/stock/reports/{docType}/{detail|summary}`，明细已含「库位号」列） |
| **货架库位（目视化清单）** | 🟡 源码候选；挂牌数据待仓库整理（迁移 SQL 已在开发库实弹演练：成功/幂等/拒绝三路径全过） | **无老库源**（现场挂牌；老库 `B_Goods.StockPlace` 为无关残值，`StockLabel`/`StockSLabel` 为数量快照非库位，均不迁） | `goods.stock_place`（V32 已有列） | 人工整理 `data/shelf_labels.csv` → `migrate.sh --shelf-labels`（不进 bootstrap-all；同键与跨键重复货品均显式拒绝） | [17 §十二](17-仓库管理-新库与迁移.md) · [货架目视化清单页](../03-页面/货架目视化清单页.md) |
| **销售管理** | 🟡 单据导入已实现；V187–V189 与 V220 已包含在公司目标库 V238，历史对账、对象授权和岗位 UAT 待最终验收 | `S_Order`(10653)/`S_Out`(12124)/`S_OtherOut`(1558)/`S_Withdraw`(221)（在用）+`S_Quote`(0) | `sales_orders/shipments/other_shipments/returns(+_items)` + V187 发运/仓库字段 + V188 仓库事件 + V189 退货质量冻结 + V220 客户处置 | `--sales` 导单；员工迁入后 `--sales-owner` 回填（完整流程用 `--bootstrap-all`） | [18-总路线图](18-业务四模块-总路线图.md) · [20-新库与迁移](20-销售管理-新库与迁移.md) · [39-owner 迁移/授权](39-销售单据归属授权.md)；历史不补造确认、拣货事件、质检或客户处置结论 |
| **委外管理** | ⛔ 历史发料待重迁验收 | `E_` 前缀：`E_In`/`E_SOut`/`E_WithDraw`/`E_SWithDraw`/`E_SWaste` | `subcontract_*`（8 单据） | `migrate.sh --subcontract --confirm-destructive` | 现有历史库 49,889 发料明细数量口径失真；须用修正导出重迁并复核 [22](22-委外管理-新库与迁移.md) / [42](42-财务对账单自动生成.md) |
| **生产管理** | ✅ 已实现 | `F_Plan`(7235)+Item(73388) / **`F_PlanCostItem`(1359892)** / `F_DateReport`(0) | `production_plans(+items/+costs 按年分区)` / `production_daily_reports` | `migrate.sh --production` | [18] · [23-老库溯源](23-生产管理-老库溯源.md) · [24-新库与迁移](24-生产管理-新库与迁移.md) |
| **钱流管理** | 🟡 功能主体已导入，财务验收未关闭 | `M_Get`/`M_In`/`M_Paid`/`M_Out`/`M_DPaid`/`M_OGet`/`M_Acc`/`M_Style`/`M_AllCheck` | `finance_receipts/payments/expenses/...(+_lines)` + `ar_ap_ledger` + 主档 | `migrate.sh --finance --confirm-destructive` | 总账开账、账户期初、材料领用结转和 AR/AP 对账必须由财务签字；见 [26](26-钱流管理-新库与迁移.md) / [44](44-总账子系统.md) |
| **资产与长期待摊专业子账** | 🟡 新功能安全骨架；完整生产 **NO-GO** | **无老库业务数据，本次不迁移** | V123/V140 主档兼容升级 + V183 类别、账簿、计划、审批、事件、期间、不可变批次/明细 | **无 legacy flag；禁止用破坏性脚本或手工 SQL 回填** | 只能从经财务批准的当前期间初始化；历史期初/累计额/剩余期限能力未交付。核心落账门禁默认关闭，见 [51](51-资产与待摊专业化全链路.md) / [ADR-018](../99-决策记录-ADR/ADR-018-资产与待摊专业子账及不可变过账.md) / [验收报告](../99-项目治理/2026-08-01-资产与待摊全链路实现与验收报告.md) |
| 工资 / 员工报销 / 检测 | ⏳ 待做 | 待最终探源 | 待 | 待 | V133 已建工资/员工报销新域，但老库源表、映射、导出、导入、reject 和对账尚未实现；一般费用单不是员工报销 |

> 模块对应的完整老库结构见 [01-YTDQ老库总览](01-YTDQ老库总览.md)。

---

## ⚙️ 老库连接与一致性要求

ERP 运行时不包含 SQL Server 驱动、生产迁移 DataSource 或生产迁移 HTTP 端点。`app.legacy.enabled` 是已退役通道的关闭哨兵，内部测试环境固定为 `false`。正式源读取只允许由 `export_legacy.ps1` 在受审运维会话中通过私有 `LEGACY_DB_CONNECTION_STRING` 连接离线恢复库。

- **dev**：指向本机 LocalDB（集成认证，账号密码留空）。
- **上线演练/最终切换**：只连接停写后恢复出的离线备份、只读副本或数据库级一致性快照。
- **禁止**让 CSV 导出直接扫描仍在持续写入的生产 SQL Server。全量导出只接受停写后恢复的离线备份，并在一个 `Serializable` 事务中读取全部表。
- `export_legacy.ps1` 可用 `LEGACY_DB_CONNECTION_STRING` 指向离线恢复库；连接串不得写入文档、manifest 或 Git。

---

## 🧾 导出 Manifest 与离线快照

推荐顺序：

```powershell
# 1. 停止老系统写入，取得并恢复离线备份/一致性快照
# 2. 通过私有环境绑定 CMDB 源身份、离线备份摘要和批准窗口
$env:LEGACY_SOURCE_AUTHORITY_ID='<CMDB_ID>'
$env:LEGACY_SOURCE_BACKUP_SHA256='<64_HEX_SHA256>'
$env:LEGACY_EXPORT_APPROVAL_REFERENCE='<APPROVAL_REFERENCE>'

# 3. 从恢复库导出全部 CSV
powershell -ExecutionPolicy Bypass `
  -File server/legacy_migration/export_legacy.ps1 All

# 4. 核验 export_manifest.json + export_manifest.sha256；迁移入口也会自动校验
# 5. 在可清空目标库执行破坏性引导
bash server/legacy_migration/migrate.sh --bootstrap-all --confirm-destructive
```

`export_manifest.json`（formatVersion 3）记录：

- 导出目标、UTC 时间、非秘密源 authority、离线备份 SHA-256 和批准引用；
- 每个文件的行数、字节数和 SHA-256；
- `consistency = serializable-read-transaction` 与 `offlineBackupRequired = true`；
- 导出脚本 SHA、仓库 commit，以及 `export_manifest.sha256` 自身的 SHA；
- 不记录 server、database、连接串或凭据。

`migrate.sh` 会自动：

- 拒绝 JSON/sha256 清单缺失、两份清单不属于同一导出、目标 CSV 未登记或内容被篡改；
- 拒绝 manifest 提交与当前 importer/Flyway 提交不同，或 scoped 源码仍有未提交字节；
- 将 run 的两个 manifest 指纹、迁移脚本指纹、代码 commit 和映射版本写入
  `legacy_migration_runs`；
- 将本次实际消费的 manifest、CSV、Shell、SQL、Flyway 清单及其 SHA-256/字节数写入 `legacy_migration_run_files`；
- 对全量 bootstrap 固定写入 20 项核心行数、CSV 消费、系统根、UUID 关系、结算方式、仓库映射、活动 BOM、reject 与历史 anchor 结构化证据；任一强制项失败则 run 失败。

Manifest 证明受审导出器在一个串行化事务中捕获了绑定到离线备份的文件集合，但不证明恢复可用或业务口径正确。最终迁移包还必须保存停写时间、恢复演练、目标 Flyway 版本、执行人、run_id、金额/数量/来源谱系报告和业务/财务签字。

---

## 🔁 当前能力边界与未来增量验收

| 能力 | 当前状态 | 上线要求 |
|---|---|---|
| 四棵分类树 Java upsert | 已有 | 补源水位、删除语义、冲突与回滚测试 |
| Shell 首次引导 | 已有破坏性脚本；输入、提交、实际消费文件和 20 项自动结构对账可追溯 | 仅在可清空库执行；必须用同一离线备份、manifest 和 run_id |
| 全模块增量追平 | **未实现** | 按稳定业务键/watermark/CDC 实现，不得 TRUNCATE |
| dry-run / reject / quarantine | V134 已有结构化 reject 表，但各模块尚未统一写入 | 所有丢弃/修复/存根均可追踪、可复核、可重放 |
| checkpoint / resume / rollback | V134 已有未来 checkpoint 表；当前 bootstrap 不推进，增量 loader 未实现 | 中断可继续，切换失败可回退且不丢新写 |
| 自动对账 | 全量 bootstrap 已固定写入核心源行数、CSV 消费和 UUID/结构不变量；金额、数量、状态、来源谱系仍需模块报告与人工签字 | 完整实现 `源数 = 目标数 + 批准拒绝数`、金额/数量/hash/孤儿与状态分布，并纳入同一 run |

未来可重复迁移只有同时满足以下门禁才算完成：

- [ ] 映射规则版本化，脚本、Flyway、源快照和目标版本可关联；
- [ ] 全量、增量、dry-run、断点续跑、幂等重跑和回滚均有命令与测试；
- [ ] 每模块显式源水位/时间窗/业务键，定义新增、更新、删除和冲突策略；
- [ ] 先进入 staging，拒绝行进入 quarantine，不允许只打印“跳过 N 行”后丢弃；
- [ ] 自动校验 `源数 = 目标数 + 批准拒绝数`，并核对关键金额/数量/状态/hash；
- [ ] 迁移运行有互斥锁、目标库保护、维护窗口、run_id、日志和失败告警；
- [ ] 使用生产同构数据至少完成两次全流程演练，记录耗时、停机窗口和恢复时间；
- [ ] 最终切流执行停写 → 增量追平 → 对账 → 业务/财务签字 → 切换；失败按预案回滚。

---

## 📁 目录结构

```
docs/数据迁移/                          ← 本文件夹（迁移执行文档）
├─ README.md                            ← 你在这（主索引 / 一键迁移）
├─ 01-YTDQ老库总览.md                   ← 老库整体结构（196 表/168 视图/91 触发器/模块前缀）
├─ 02-货品分类-老库溯源.md              ← 货品分类在老库的存储 + 数据坑
└─ 03-货品分类-新库与迁移.md            ← 新库表设计 + 迁移用法 + 校验

server/src/main/java/com/uten/imp/legacy/       ← 仅 dev profile 的分类样例种子
├─ reader/
│  ├─ LegacyCategoryRow.java
│  ├─ LegacyCategorySource.java
│  └─ LegacyCategoryCsvSource.java              （dev：按 itemClassId 读取四份 classpath 样例）
├─ migration/
│  ├─ MaterialCategoryMigrator.java             （货品分类，ItemclassID=1）
│  ├─ ClientCategoryMigrator.java               （客户分类，ItemclassID=2）
│  ├─ SupplierCategoryMigrator.java             （供应商分类，ItemclassID=3）
│  └─ MouldCategoryMigrator.java                （模具分类，ItemclassID=18）
└─ web/LegacyMigrationController.java           （仅 dev：/api/admin/dev/legacy-category-seed/*）

server/legacy_migration/                        ← shell 离线破坏性引导（不依赖 server）
├─ migrate.sh                                   （一次一个目标；--bootstrap-all 才执行全量依赖链；强制破坏性确认）
├─ migrate_reconciliation.sql                   （全量导入 20 项结构化对账；失败阻断候选）
├─ migrate_goods.sql / migrate_goods_data.sql   （货品分类 / 主档）
├─ migrate_mould.sql / migrate_mould_data.sql   （模具分类 / 主档）
├─ migrate_client.sql / migrate_client_data.sql （客户分类[递归CTE] / 主档）
├─ migrate_supplier.sql / migrate_supplier_data.sql （供应商分类[扁平根] / 主档）
├─ migrate_color.sql / migrate_unit.sql        （颜色 / 基本单位 主档[扁平，无分类]）
├─ migrate_purchase.sql                         （采购四类单据；单位确定性回填 + 歧义行诊断）
├─ export_legacy.ps1                            （离线备份→UTF-8 CSV；串行化事务输出 v3 manifest + sha256 清单）
└─ data/                                        ← 离线 CSV + export_manifest.json + export_manifest.sha256（敏感迁移包，不进 git，受控保管）

server/src/main/resources/legacy-migration/     ← dev Java 路径读的 classpath CSV（分类树快照）
├─ goods_categories.csv
├─ client_categories.csv
├─ supplier_categories.csv
└─ mould_categories.csv
```

---

## ➕ 新增迁移模块

1. **探源与批准**：在离线恢复源库定位表、字段、字符集、关系和异常行，记录源库 authority、备份摘要与双人批准引用。
2. **前向结构**：需要新结构时只新增不可变 Flyway migration；已应用文件不得修改或 `repair`。
3. **受审导出**：把查询加入 `export_legacy.ps1` 的固定目标 inventory，使 CSV、行数和 SHA-256 同时进入 v3 manifest。
4. **离线导入**：新增 `migrate_*.sql`，保持 FK/审计触发器开启，明确 UUID 真源、历史快照和 reject 口径。
5. **编排与证据**：把脚本加入 `migrate.sh` 的固定依赖顺序、逐文件摘要和 reconciliation；单模块成功不能替代完整对账。
6. **验证与文档**：增加静态合同、空库 Flyway、真实 PostgreSQL 正负例和业务对账说明，再更新本页模块清单。

如确需本地 UI 样例，可另加 `dev` profile 的 classpath seed；不得增加生产 SQL Server reader、运行时迁移端点或可切换的老库凭据配置。

---

## ✅ 校验

每个模块迁移后必须对账（详见各模块文档「校验」段）：总数恒等、主键（`legacy_id`）覆盖、
关键金额/数量/状态汇总、外键/孤儿、抽样字段与业务单据。被跳过的数据必须进入 reject/quarantine
并由业务批准处置；“脚本成功”或“源数−跳过数=目标数”不等于迁移验收通过。

首次 `--bootstrap-all` 会写入 20 项固定结构对账，覆盖核心分类/主档行数、CSV inventory、系统根
authority、当前 UUID 关系、客户默认结算方式、仓库/车间映射、活动 BOM 端点和 rejects。必须得到
20 项 mandatory、0 项 failed 且 `legacy_migration_runs.reconciliation_status = PASSED`；单模块执行保持
`NOT_RUN`。这些只是结构证据，仍须完成金额、数量、状态、来源谱系、抽样单据和岗位签收，才能形成
目标环境迁移验收。

### BOM 占位货品专项门禁（V181）

- 业务历史表可为 NOT NULL FK 保留 `goods.auto_created=true` 占位，它只代表“原货品主档已不存在”的身份锚；
  不得进入当前货品选择、活动 BOM、MRP 或成本重算。
- `--goods-bom` 的父件和组件均须满足 `legacy_id` 命中、未删除、非 `auto_created`；末尾硬断言活动
  BOM 占位端点为 0。先迁业务 stub 或先迁 BOM 都必须得到相同结果。
- 旧口径误把 81 条 stub 支撑的孤儿边算作有效：正确对账为
  `218,820 = 198,022 有效源行 + 20,798 拒绝行`。V181 软删错误 BOM 边，但不删除 31 个历史引用锚，
  也不批量重算 `goods.source_e`，避免改写历史预算口径。
- 若错误 BOM 已派生运营草稿，V181 仅在全量下游依赖检查为 0 时软删：本机为 2 条未领用 DRAW
  占位明细，以及 1 张仅含占位明细、未下单的 MRP 采购申请；任何已审核、已领用、已下单或有台账/
  财务/Outbox 事实的记录都会使迁移 fail-closed。历史盘点单、7 条占位货品库存余额和成本快照不动。
- **现库验证（2026-08-01）**：V181 已在 `flyway_schema_history` 成功应用，现为不可变迁移；活动 BOM
  198,025 条、活动 stub 端点 0，活动 DRAW/采购申请 stub 明细均为 0。Q7 真实第 7 项保留、虚假 7.1 已隔离；
  20,798 条源端 reject 仍需逐行治理，V181 的技术隔离不等于业务认定或生产验收完成。

### 采购单位专项门禁

采购明细的 `QTY` 是单据单位量，必须先用有效 `unit_rate` 换为货品基本单位后才能参与库存和 MRP：

- **安全修复**：源 `UnitID=0/NULL`、`COALESCE(URate,1)=1`，且货品基本单位可解析时，
  全量导入脚本 `migrate_purchase.sql` 和既有库规范化迁移
  `V168__normalize_legacy_purchase_item_units.sql` 均回填货品基本单位及换算率 1。
- **待治理**：不满足上述唯一确定条件的行不得猜测单位或换算率，保持待治理并 fail-closed；
  不能把它们当成零在途继续计算齐套。
- **MRP 阻塞范围**：只有“订货单已审核、未中止、未结案、未删除，明细未删除，且
  `GREATEST(qty-received_qty,0)>0`（源字段口径 `QTY-RQTY>0`）”的开放订货明细参与在途与单位有效性检查；历史已完成、已中止、已结案或已删除行不阻塞。
- **旧尾数处置**：若开放订货尾数已不再履约，必须由业务执行中止/结案并留痕；禁止迁移脚本仅按单据年龄
  自动关单。

2026-07-31 对 V168 做过事务内演练并已**回滚**：四类采购明细分别可安全规范化
345/394/756/39 行；开放订货单位异常 54 行中 41 行可安全修复、13 行仍待治理，
货品 `V51115` 的异常开放行由 5 行降为 0。该结果仅证明迁移可执行，**不表示正式数据库已经应用**；
正式应用状态必须以目标库 `flyway_schema_history` 和发布迁移记录为准。

### V187 销售发运与仓库作业迁移门禁

`V187__sales_shipment_policy_and_warehouse_work.sql` 是向前加法迁移，不修改 V90 预留数量、库存余额、流水、订单数量或历史审核状态：

- 历史销售订单的 `shipment_policy` 只回填 `LEGACY_UNSPECIFIED`；不得批量猜成“允许分批”或伪造客户确认。
- 历史出货按原删除/驳回/审核状态映射为 `CANCELLED/SHIPPED/REVERSED/LEGACY_PENDING`；历史 `picking_started_at/picked_at/handed_over_at` 保持空。
- 新单数据库默认 `CUSTOMER_CONFIRM` / `PENDING_PICK`，应用仍必须显式走服务端状态机。
- 新权限 `sales_order:confirm_partial_shipment` 默认授销售部，`sales_shipment:warehouse-work` 默认授 PMC；上线前须按真实岗位复核，默认部门授权不等于最终职责分离签字。
- V90 `chain_status=0` 且无有效预留的旧未结订单不得自动变为可发。新建 V187 出货必须提前 fail-closed；业务须逐订单行对账库存、历史已发和旧排产后显式激活。当前没有自动批量激活脚本，禁止为“让页面可用”伪造预留。
- V187 不回写历史商业字段。新业务由应用从来源订单重建出货客户、币税/付款条件和行价格/金额；迁移不能替应用猜测或修复历史定价事实。

目标库执行前后至少对账：四类销售主表/明细行数和数量金额汇总不变；V187 新列 null/枚举分布符合历史映射；迁移后旧草稿仍能走兼容审核，新单不能走旧审核；无权限用户看不到动作且直接调用 403。下文“171 个迁移至 V190、真实 PG 54/54”是 2026-08-01 的历史候选证据；V187–V189 与后续 V220 当前已包含在公司目标库 V238，但这仍不能替代历史全量对账、对象权限、岗位 UAT 和发布签字，销售生产门禁尚未关闭。

### V188 销售仓库事件账迁移门禁

`V188__sales_shipment_warehouse_event_ledger.sql` 只新建 `sales_shipment_warehouse_events`、索引、append-only 守卫和审计触发器，不回填历史 V187/老库出货时间线，不修改任何出货当前状态、库存、预留、订单累计或应收。

目标库应用后新事件的 `from_status/to_status/reason/actor_employee_id/occurred_at` 必须与同事务状态转换一致；UPDATE/DELETE 必须由数据库拒绝。新表初始为空是正确的历史边界，不得以“时间线看起来完整”为由批量造事件。

### V189 销售退货质量冻结迁移门禁

`V189__sales_return_quality_quarantine.sql` 只新建质量冻结当前投影、追加式处置事件和权限，不回填历史已审核退货，不修改历史库存余额或流水。历史行没有质检证据，因此禁止用脚本推断为良品、报废或返工。

目标库执行前后必须满足：`sales_returns`、`sales_return_items`、`stock_movements` 和 `stock_balances` 的历史行数/数量/金额不变；两张新质量表初始行数为 0；新退货审核后只增加冻结行而不增加库存；只有 `GOOD_RELEASE` 增加库存；事件 UPDATE/DELETE 被数据库拒绝。发生处置后整单红冲会正确阻断，但当前没有处置级复核红冲/补偿命令，此项仍为运行 NO-GO。详见 [销售退货质检冻结与处置](../07-业务链路/06-销售退货质检冻结与处置.md)。

### V190 新业务表后审计完整覆盖门禁

`V190__refresh_audit_trigger_coverage.sql` 在 V188/V189 新表出现后重跑完整 fail-closed sweep：公开业务表必须恰有一个 `trg_audit*`，且为启用的 AFTER ROW、同时覆盖 INSERT/UPDATE/DELETE、调用批准的脱敏审计函数。已有合法触发器不重复创建；缺失时只为**以后操作**补挂 `fn_audit()`。

V190 不修改业务数据、不扫描回填历史 `audit_log`，也不能证明迁移前操作已被记录。目标库必须用 Flyway 应用并执行触发器矩阵契约/实库探针；任一表重复、禁用、事件位不全或函数不受信都应阻断迁移，而不是手工删记录绕过。

### V196–V202 计划申请分解、订货财务审批与超量到货

> 版本边界（2026-08-09 更新）：V191–V202 已包含在公司目标库当前 V238 以内；但迁移应用不替代
> 非空数据对账、恢复演练和真实岗位/实物 UAT，不能据此放行相应业务链。

- `V196` 新建 `procurement_order_approval_cases/events`、`inbound_expectations/items`（原建 `workflow_responsibility_assignments` 已于 V229 删除，见 ADR-027）。生产物料分析按用户所选缺口下达采购/委外申请，业务端只读并跨申请选行、部分分解；一张订货单限一个供应商/委外商（订货仓库约束已随 V292/ADR-038 撤销：订货不携带仓库，跨仓库明细可同单，入库仓库到收货/进仓登记时必填）。V196 历史上以复合码 `finance_order_approval:review` 保护批准和驳回；V328 已将该旧码停用，并把既有授权保真展开为现行 `finance_order_approval:approve` / `finance_order_approval:reject`。订货保存草稿后提交，由持对应现行动作权限且通过财务审核资格校验的人员审批，通过才令订单 `status=1`、回写申请累计并生成预计到货。应用层只允许合格审核人在精确 PENDING case 上临时打开 owner 隐藏的订单详情；决定、业务副作用和响应详情同事务，case 结束后恢复普通对象范围。
- `V197` 对 V196 新表重跑完整审计覆盖；`V198` 消除父部门授权向计划泄漏商业单据；`V199` 以 `v_procurement_decomposition_tasks` 统一扣除已生效量和其它 `PENDING` 财务订单占用；`V200` 继续阻断计划继承委外商业字段及供应商主档。
- `V201` 新建 `procurement_arrival_exceptions`、`supplier_return_tasks`、`procurement_arrival_exception_events`，并以数据库守卫把财务追加额度绑定到具体收货单。发现超量时只提交异常/Outbox 后返回 409；库存、AP、订单累计和收货状态都不改变。现行批准走 `finance_order_approval:approve`，不批超量走 `finance_order_approval:reject`；V328 对旧 `finance_order_approval:review` 授权做保真展开，不再把旧复合码写成当前门禁。服务端收窄草稿数量/金额，未批准量只交原下单账号完成供应商退回，批准量仍须仓库再审。
- `V202` 不是“仅给上述三表挂触发器”的定向脚本，而是再次遍历全部 `public` 业务表：缺触发器才补 `fn_audit()`，重复、禁用、非 AFTER ROW、I/U/D 不全或函数不受信均 fail-closed。它只记录 V202 应用后的未来操作，不补造历史审计。

数量基准示例：订单财务已批 10 吨且尚未收退，本次草稿到货 100 吨，则批准余量 10、请求超量 90。`APPROVE_ALL` 接受 100/退回 0；`APPROVE_CUSTOM(customApprovedExcessQty=5)` 接受 15/退回 85；`REJECT_EXCESS` 接受 10/退回 90。三种情况在财务决定后仍未写库存/AP；接受量只有仓库再审成功才过账。若决定时批准余量已因并发变为 0，不批将删除该草稿行并直接形成 100 吨退回任务。

Flyway 已应用迁移必须保持原字节、文件名和顺序；任何共享环境一旦执行 V196–V202，修正只能新增 V203+。API、权限、状态与委外 `check_qty/girth_qty` 调整见 [Java 后端契约 §十](28-Java后端契约.md#十计划需求分解订货财务审批与超量到货专用契约v196v202)。

### V230 生产计划自底向上整树确认迁移门禁（历史兼容）

`V230__production_plan_bom_depth_and_auto.sql` 是纯加法迁移：给 `production_plans` 加 `bom_depth INT NULL`（MAKE 树距根深度，0=根）和 `auto_generated BOOLEAN NOT NULL DEFAULT FALSE`（标记 orchestrator 自动建的子计划）+ 两个 partial 索引。**不修改任何业务数据、不回填历史行、不增删约束/触发器**，旧行两列保持 NULL/FALSE。

- 目标库执行前后必须满足：`production_plans` 行数与历史 `status/bill_no/source_doc_no` 等不变；`auto_generated` 全库为 FALSE（仅新 orchestrator 调用才写 TRUE）；`bom_depth` 全库为 NULL（仅自动子计划写值）。
- 该两列只服务 [ADR-028](../99-决策记录-ADR/ADR-028-计划部自底向上整树确认.md) 的自底向上整树确认（`BottomUpPlanOrchestrator.confirmFullTree`，能力开关 `production.bottom-up-orchestrator.enabled` **默认关**）：`bom_depth` 驱动「最深层可开工优先」UI 排序，`auto_generated` 使级联回退只作用于自动子。迁移本身不开启该能力，历史计划绝不自动展开或重排。
- 无 BOM 的自制叶子件不被 confirm 展开（其 snapshot 内联 goods_bom_items 会得空产品行）；它由应用层报工 + 成品入库直接生产，与人工流程一致。本迁移不改变该语义。

V230/ADR-028 的 orchestrator 默认关闭，且不再是新业务目标。V234 新链路先创建物料分析和
MAKE_COMPONENT child demand，由用户在子件齐套后分批形成正式计划；不得重新开启“递归自动创建正式
子计划”来绕过分析、路线确认、分批计划或批准事务。历史 `bom_depth/auto_generated` 字段和旧计划保持原样。

### V247–V250 阶段化齐套、精确执行需求与来源谱系门禁

| 迁移 | 结构与数据策略 | 上线前必须证明 |
|---|---|---|
| `V247__bom_control_stage_and_packaging_measurement.sql` | BOM 新增 `control_stage/hard_gate` 与 `PER_UNIT/PER_PACKAGE/FIXED_BATCH` 包装规则；分析节点冻结边规则和 start/finish/ship 分配，item 新增三类 ready 量。历史 BOM 默认 START/PER_UNIT；旧分析保留 `LEGACY_CUMULATIVE_PER_UNIT`，重置旧组合预览 | 包装基数/尾包策略已由业务复核；`ready_now=ready_finish`、`ship<=finish<=start`；旧分析不从当前 BOM 反推；迁移前后需求/计划/link 守恒 |
| `V248__production_exact_material_demand_snapshot.sql` | `production_material_demands` 新增 `LINEAR/EXACT_SNAPSHOT`、段产品量及规则指纹；非线性需求身份和数量不可原改 | 每个非线性段的产品量、精确基本数量和 SHA-256 指纹一致；不存在用六位平均率还原整包/固定批次 |
| `V249__execution_segment_material_requirement_shape.sql` | 执行段显式 `DEMANDED/ZERO_MATERIAL`；ZERO_MATERIAL 只允许 `DIRECT_MAKE`、`PLAN_BOM_OVERRIDE`、`NO_PRODUCTION_HARD_GATE` 三类证据，前两类冻结分析/授权事实，第三类冻结“BOM 存在且无生产硬门槛”的形状；无需求、无 DRAW、不得 WAITING，无法从历史证据分类时迁移 fail closed | DEMANDED 全有完整需求；ZERO_MATERIAL 全有合法证据且无假需求/预留/DRAW；历史未分类行已人工处置并留证 |
| `V250__preplan_external_supply_source_guards.sql` | 外部化 action/allocation 的身份与 route/type/id 冻结；保护采购申请、委外申请及后续订货来源行；deferred trigger 同查 OLD/NEW，来源单禁止绕过取消后复活 | action route/type/id 合法、allocation 数量守恒且下游行归属正确；批准/反向/action 推进后的通用改删被拒；取消/释放专用事务可闭环且无孤儿 |
| `V253__website_inquiries.sql` | 官网询盘汇入表、审计触发器和最小权限；与生产车间建议无关 | 官网 source_id 幂等、权限/对象处理、审计、历史零回填和目标环境 UAT 单独验收；不得据此增加第二套产品默认车间字段 |

上述迁移不会自动创建采购或委外商业订货。物料分析通知只生成用户勾选缺口对应的采购申请、委外申请
或 MAKE child；采购/委外人员仍须从任务中心分解并提交正式订单财务审批。只有 IQC 合格且真实入库数量
进入当前齐套，待检/拒收/预计到货不得计入现货。普通 generate 只写计划草稿和 SUBMITTED link；批准
才原子形成 READY、LINEAR/EXACT_SNAPSHOT 需求、完整预留、DRAW、销售分摊和 APPROVED link。

V250 迁移前必须先执行只读审计，至少核对：外部 action 的 route/type/id 三元组、每个 action 的
allocation 汇总、allocation.external_item_id 对应的申请/应用/MAKE child 归属、下游订货行来源、
CANCELLED action 与来源单状态。任一不一致都应阻断迁移，不得用 `flyway repair`、删触发器或手工断链掩盖。

---

> **现行覆盖说明**：以下 V306 历史段保留的“顶部 V375/337”是原时点措辞；现行迁移头一律只认本页
> 顶部 V423/385，不得把历史数字重新写成当前候选。
**历史清单更新（2026-08-20，V306 时点）**：该阶段目录最高 V306，共 287 个迁移文件、287 个唯一版本且无重复；当前全目录头只认本页顶部 V375/337 复扫。V265/V267 收付款类别引用守卫、V266 总账来源 UUID、V268–V271 生产/采购/销售 UUID 与历史快照、V272 未分类主档系统根、V273–V276 关系/编号治理、V277 账户科目 UUID strict authority、V278 系统过账角色 UUID 映射、V279 全局业务标识注册、V280/V281 人员与附件授权/元数据治理、V282 员工扩展 PII 局部加密、V283 生产关联订货审批快照锁守卫修正、V284 个人信息变更敏感快照/历史审计副本保护、V285 客户默认结算方式 UUID 收紧、V286 员工扩展-only 敏感行兼容、V287 可选主身份派生一致性、V288/V289 现货借用结构、终态守卫与全 `public` 审计 sweep、V290/V291 销售物流单号与退货处置纠错、V292 来源单号可读化清洗（`物料分析-UUID`/`MAKE-UUID` 改写为可读标签，订货仓库口径调整见 ADR-038）与 V293 IQC 权限，以及 V294 销售订货财务确认闸门（销售审核→财务确认→计划部接收）、V295 工资可变金额审计脱敏补漏、V296 仓储部收货权限补齐、V297 管理员临时密码 72 小时有效期、V298 计划前物料分析备料库存绑定（`PREPLAN_ANALYSIS` 归属预留，见 [ADR-039](../99-决策记录-ADR/ADR-039-计划前物料分析备料库存绑定.md)，不回填历史已入库库存）、V299 结算方式主档编号命名空间注册、V300 客户收货地址簿与销售订单财务驳回（含权限点 `client_address:delete` 与审计 sweep，见 [ADR-040](../99-决策记录-ADR/ADR-040-销售开单体验与财务审核中心.md)）、V301 采购/委外任务中心「等待财务审核」生命周期档（同名视图重建，不新建业务表）、V302 收货单价格脱敏权限点（采购收货/委外进仓）、V303 货品颜色/单位旧库哨兵 `0` 归一为 `NULL`、V304 委外发料计划/仓库出仓/损耗扣款权威链、V305 委外出仓独立权限点、V306 在 V304 新业务表之后刷新并强校验全 `public` 审计触发器覆盖，均仍是未提交源码候选；V288/V289 的在线 create/revoke、双趟生效计算和 Flutter UI 已接通并通过专项验证，但目标库/UAT/恢复/签名发布仍未完成。开发原库 V244/225、一次性隔离克隆 V250/231、公司目标库 V238 是不同环境证据，不能互相替代。
下文保留 V190、V191–V202 等当时章节作为历史迁移设计，不得覆盖顶部当前事实。
迁移脚本和多数业务映射已经形成，但当前发布结论仍为
**NO-GO**：BOM 20,798 条拒绝行、委外发料 49,889 条历史数量、客户归属计数、
总账开账/材料结转，以及全模块增量追平/回滚尚未关闭。财务 API/UI 已实现不等于财务数据已签字验收；
一般费用单也不等于员工报销。销售—仓库—计划—生产/采购/委外当前边界以
[2026-08-01 全链路安全复核报告](../99-项目治理/2026-08-01-销售仓库生产采购委外全链路安全复核报告.md)为准；
[生产就绪审计报告](../99-项目治理/2026-07-30-生产就绪审计报告.md)保留历史审计，最终发布仍须目标库对账与签字报告。
