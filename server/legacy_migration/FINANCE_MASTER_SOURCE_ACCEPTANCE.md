# 财务主档来源保全与首次导入验收（bootstrap-v18 / V914）

本节补充主导入 SOP。所有行数、待核理由、角色候选均从当次封存来源动态计算；旧彩排的数量不能作为下次导入条件。这里的“原账户引用”指资金分类指向账户的关联，不是财务冲销。

## 执行顺序

1. 封存最新旧库备份、完整 RAW 导出及审核文件，完成来源完整性和账户显式审核。不得修改 CSV 来迁就平台约束。
2. 冻结完整代码、SQL、运行时及媒体清单；新空候选库正常执行全部 Flyway 至 V914。确认没有业务数据，然后用 `capture_finance_seed_baseline.py` 只读捕获该库的系统财务主档、已配置角色、代码保留记录、序列和完整迁移集合。保存原 JSON 与其 SHA256。以前 V913/839 的夹具不得标成 V914/840 的实际基线。
3. `rehearse_local_import.py prepare` 除原参数外，必须显式提供 `--finance-seed-baseline <捕获JSON> --finance-seed-baseline-sha256 <独立保存SHA256>`。prepare 验证完整 SQL 来源、原生 Flyway checksum、空业务状态及物理库身份，原字节复制为 `finance_seed_baseline.json`；`derived_inputs.json.provenance` 绑定 `financeSeedBaselineFile` 和 `financeSeedBaselineSha256`。它不是新增业务 CSV。
4. 使用该新封包执行一次原有完整导入流程。apply 在读取凭据及认领 run 之前检查本地 Docker、冻结来源及基线身份；基线另登记到 `legacy_migration_run_files`。先人事，再依赖顺序中的主档及业务模块。不得复用已失败或退休的 run/命令计划。
5. 财务模块先以原 COPY 列顺序/类型读取 M_Style、M_Acc，TEMP 保存完整 typed 行及 SHA。全源按旧 ID 排序统一分配 `SK000001…` / `ZH000001…`，不按树深度重新计数。原编号、ItemID、状态、余额和金融流水金额保持原来源事实。所有下游仍按旧 ID → UUID 关联。
6. 资金分类首次 INSERT 写入三个只读来源字段：`legacy_source_code`、`legacy_source_item_id`、`legacy_source_import_run_id`。原 NULL、空串、0、负数完整保存。现行 `linked_account_id` / `linked_account_legacy_id` 仅在资金分类为 ACCOUNT、正原引用存在且同 ID 真实账户当前可用时成对设置；其他情况两者为空并动态记待核理由。不得造账户、启用禁用账户或修改 V277 authority guard。
7. 账户类型先执行原已审核名称规则（“一般账户”“一般帐户”均保留 GENERAL），再以完整来源父链上唯一真实 ACCOUNT 银行存款根进行 BANK 兜底。缺链、循环和歧义阻断；该兜底不替代新增账户显式审核。币种保持已审核规则。
8. 所有 V626 来源注册及财务流水处理完成后，才刷新 `reconciliation_summary.financeMasterSources`，保存完整 typed 来源、文件/行 SHA、原码/目标码、UUID、待核理由、导入前系统主档和角色快照。仅明确、唯一、同类别的真实来源根可填原本为空的受支持角色；已有配置不覆盖。没有可靠候选的角色保持空。
9. 所有 executable modules 及 V626/V913 注册完成后、最终核对及 SUCCESS 之前，coordinator 调用 `personnel_source_archive.render_personnel_source_archive_sql` 晚写 `personnelSourceArchive`。只保存来源 SysOp 名字字典、所需委外原操作人引用及真实目标 UUID 锚，不创建用户/员工，不冒充实际历史审批人。
10. 整批 SUCCESS/PASSED 后才运行实际目标验收。通用 `verify_rehearsal_result.py` 保留原参数，额外传入同一份 `--finance-seed-baseline` 与独立 `--finance-seed-baseline-sha256`。要求 `finance_master_sources.verified` 为 true，且 `seed_baseline_sha256` 与独立基线、封包 provenance、run 记录一致。schema ≥914 或协议 ≥18 都强制此门禁，省略/降低 expected-schema 不能绕过。
11. 目标 SQL 仅在 REPEATABLE READ / READ ONLY 中核对来源双向覆盖、完整业务列、原始字段、原生 typed 行 SHA、旧 ID/UUID/父级/币种关系、当前关联、系统种子和既有角色、编号保留及物理库身份。来源期望由受本地 Docker guard 保护的独立 network-none PostgreSQL 按原 COPY 类型重算，不能相信 run 自报 passed。
12. 改名切换后，用同一封包、run、独立基线和 before receipt 再验一次；只允许同 system_identifier/databaseOID 的物理库改名。`--renamed-from` 与 `--pre-rename-proof` 沿用主 SOP。不得改基线 JSON 以适配改名。财务来源留档和人员来源另按各自独立验收执行。

## 只读报表语义

显示编号 SK/ZH 不再承担旧报表路径语义。共享只读函数 `fn_legacy_payment_style_source_root_matches(uuid,text,text)` 仅认可 SUCCESS/PASSED 同 run 来源证据中的真实根、原码和类别；普通现代同码根不能冒充旧来源根。现代子节点沿真实父 UUID 归属，已有角色/报表配置继续使用 UUID。

验收输出当批全部来源根与固定 20 报表语义的覆盖及未映射根。例如旧源已存在的 EXPENSE 原根 044 不属于既有固定分组，完整保留并提示未纳入，不能猜并到 043；总损益和明确 UUID 配置的行为由报表实现维持。

## 可复跑检查

在冻结仓库的 `server/legacy_migration` 目录，以项目 Python 执行：

```powershell
python -B -m unittest discover -s . -p 'test_verify*.py' -v
python -B -m unittest test_finance_seed_prepare test_personnel_source_archive test_rehearse_local_import test_rehearse_frozen_authority test_rehearse_source_completeness -v
```

默认 source-only 命令不启动 Docker、不读目标或凭据：

```powershell
python -B verify_finance_master_sources.py --inputs <新封包目录> --manifest-sha256 <derived_inputs.json的SHA256> --frozen-commit <冻结commit> --finance-seed-baseline <独立基线JSON> --finance-seed-baseline-sha256 <独立SHA256> --output <全新输出文件>
```

只有显式追加 `--typed-source-only` 才会在验证本地 Docker context/环境后创建独立无网络、无端口的 PostgreSQL 重算来源 typed SHA；仍不读实际目标。正式目标验收通过通用 verifier 的受保护入口执行，禁止把夹具输出标成实际导入成功。

run.summary 是来源留档位置，不是新增不可变表。门禁用于刚完成导入、开始普通业务之前的验收；原生平台允许的后续账户配置维护仍由现有 V277 等业务守卫负责。
