# 历史账户流水来源留档与独立验收

来源留档使用现有迁移run.summary，未新增不可变业务表；仅留档的行不创建账户、当前现金、余额、GL、审批或现行来源证明。原 V626 导入函数与正常在线守卫不变。

仅本轮原 `m_acc.csv` 没有真实账户身份，或 `M_AllCheck.BStyle` 不是 20/21/22/23/27 的流水进入 `ARCHIVE_ONLY`；完整 typed source、原金额、日期、原账户/类型、原文件/行 SHA 与理由一并留档。若下一批补齐真实原账户和合法类型，自动恢复正常导入。原资金单 UUID 缺失仍按 V626 的 `LEGACY_SNAPSHOT` 正常保存，不作为来源留档理由。

`reconcile_modules.py` 将 `archived` 单列，严格使用 `expected=actual+excluded+archived`；不将来源留档当作当前资金流水、拒绝行或隐含排除。模板代码没有固定 27 条/旧 ID 范围；本批 v7 的实际审计为源 30,627、当前历史流水 30,600、来源留档 27。其中 23 条原金额非零，完整金额/日期只在私有证据中保留，绝不改成 0。

## 执行顺序

1. 最新旧库重新导出、校验密封原 CSV 与 manifest，重新运行主重建手册中的清洗/分层/prepare。
2. 在冻结的本轮源码和全新候选中执行完整 bootstrap。`migrate_finance.sql` 在 ACCOUNT_FLOW 前按原账户/类型动态分类；来源账户存在而目标账户缺失仍直接失败。
3. 来源留档在 finance 模块临时表清理前写入 `legacy_migration_runs.reconciliation_summary.financeArchiveOnly`。其他模块继续执行，最终模块对账必须 PASS。
4. 运行通用 `verify_rehearsal_result.py`，**还必须运行本独立资金来源验收**。不要只依据 summary 自报条数。
5. 候选验收通过后按主手册备份/切换本地数据库；切换后对同一 run、同一密封输入再运行本验收，输出到新的私有目录，比较两份安全回执和输入 SHA。

## 准确命令

使用实际本轮 INPUT、run UUID 和全新输出目录替换尖括号。Windows 请使用 bundled Python，不使用 LibreOffice 的同名包装器。

```powershell
& 'C:\Users\bruce\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  'D:\Projects\uten_imp\server\legacy_migration\verify_finance_archive.py' `
  --input-dir '<本轮密封 final-inputs 绝对目录>' `
  --database 'uten_imp_rehearsal_20261022_v2' `
  --expected-run-id '<本轮 SUCCESS 的 run UUID>' `
  --output-directory '<新的私有 before-cutover 证据目录>'
```

切换后只将 database 换成 `uten_imp`、output-directory 换成新的 after-cutover 目录，输入与 run UUID 不变。目标读取固定为 `BEGIN READ ONLY`，没有 INSERT/UPDATE/DELETE/DDL；源 CSV 仅在自建无网络、无主机端口、只读输入挂载的 PostgreSQL 中解释，完成后删除临时容器。

只看下一批来源预审、不访问业务库时：

```powershell
& 'C:\Users\bruce\.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe' `
  'D:\Projects\uten_imp\server\legacy_migration\verify_finance_archive.py' `
  --input-dir '<本轮密封 final-inputs 绝对目录>' `
  --source-only `
  --output-directory '<新的私有 source-only 证据目录>'
```

`SOURCE_ONLY PASSED` 仅证明来源解释和分类，不能替代完整导入或候选验收。目标验收必须是 `SOURCE_AND_READONLY_TARGET PASSED`。

## 独立验证内容

- 本轮 derived manifest 的 m_acc/m_allcheck 字节 SHA、字节数、行数、正整数唯一旧 ID、原导出顺序。
- 完整 typed source 经真实 PG COPY 解释，精确保留引号、空串、NULL、中文、换行和 Decimal；以 loader 实际会话时区重算 `digest(to_jsonb(stage.*)::text)`。
- 动态重算来源留档集合/理由，与 run.summary 逐字段、行号、原文件 SHA/行 SHA 比对，防止仅计数相等却错位或漏项。
- `finance_reconciliations` 和该 run 的 `legacy_finance_import_sources(source_kind='ACCOUNT_FLOW')` 必须恰好覆盖源减归档，归档不得进入任一集合。
- 账户原 ID 集和总数必须恰好等于本轮 M_Acc；不得伪造“未知账户”让来源进入当前资金账。
- 控制台仅输出安全状态，详细来源保存在私有输出文件；每次输出目录必须新建，不覆盖旧证据。

## 接入已有通用验收

本文件是独立 gate，不改并行维护的 `verify_rehearsal_result.py`。如通用验收原来只计算 `expected=actual+excluded`，须兼容独立 `archived` 后再判断，不能仍假设所有来源都在活动表；随后必须核对本工具的安全回执，而不是只放宽通用等式。建议报告键 `finance_archive_only`。

## 当前私有验证边界

9个规则、2个对账SQL生成、3个本地上下文及manifest/commit身份测试通过。v7 源全量独立 source-only 通过；无网络 PG 集成使用未改的 V626 cash_projection 和最小身份 fixture，执行新 loader ACCOUNT_FLOW 段后，独立 READ ONLY target verifier 验证完整来源/哈希/身份集合通过。该 fixture 不替代生产全 schema、bootstrap 权限或完整资金模块验证。

完整 finance 预审另发现 6 条原收款 `qtfymc` 指向非 EXPENSE 类节点，其中 2 条原费用非零。这属于另一来源字段语义问题，本次账户流水留档不修改或吞掉这些收款；该独立问题由V912保留原项目ID与原费用、当前错误类型UUID留空待核；完整彩排仍须实际整批成功和两套验收。
