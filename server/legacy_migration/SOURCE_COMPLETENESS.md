# 来源完整性和未来备份复跑

`prepare` 必须同时提供全表审计 `--reference` 与独立、全新的 `--completeness-audit`。旧的 reference 和已封存 manifest 均不补写。本校验不连接数据库，也不生成或猜测业务数据。

先恢复这次选定的 SQL Server 备份到独立审计库，确认物理 `READ_ONLY`。使用冻结的 `export_source_completeness_audit.ps1`，显式指定备份集位置 `-BackupSetPosition`，在同一 Serializable 事务中导出 `source_columns.csv`、`system_item_full.csv`、`system_item_class_counts.csv`、`system_part_full.csv`、`mk_stock_goods_full.csv` 及 `audit-manifest.json`。输出目录必须全新。该 manifest 绑定 raw export manifest、备份 SHA、来源截止时间、导出脚本 SHA，以及五份文件的实际行数、字节数和 SHA。换新备份后重新导出，不能沿用本轮辅助证据。

LocalDB 可能在不同连接之间恢复为可写；每次导出都必须在实际导出连接里重新检查物理只读，不能把之前一次检查当作持续成立。实际为可写时应拒绝且不创建输出目录。只允许对本次新建独立 clone 设置只读，不能为通过校验去修改旧来源库或业务库。

正式生成导入输入前，运行：

```powershell
& $python "$migration/validate_source_completeness.py" `
  --audit $freshCompletenessAudit `
  --raw-manifest "$raw/export_manifest.json" `
  --reference $referenceAudit `
  --schema-contract "$migration/source_schema_contract.json" `
  --profile-contract "$migration/source_profile_contract.json" `
  --audit-generator "$migration/export_source_completeness_audit.ps1" `
  --output $newProofPath
```

然后原 `rehearse_local_import.py prepare` 全参数命令新增 `--completeness-audit $freshCompletenessAudit`。校验在创建最终输入目录前执行；`apply` 在 claim 和业务写入前再次比对同一完整证明。不存在辅助审计、任一文件漂移或证明变化都会停止。两个 policy JSON 和导出 PS1 采用明确路径加入冻结源检查及 `provenance.scripts`，须已跟踪、无未提交改动；不从运行 data 目录通配查找政策文件。

完整 schema、字典、原权限行只保存在私有辅助文件中。最终 manifest 仅引用辅助目录和小型证明，`legacy_migration_run_files` 登记一份 `source-completeness-audit-manifest.json` 的实际 SHA/字节数，由其继续绑定五份完整文件。辅助 CSV 不参与 loader CSV 数量对账，也不把完整行塞进 RUNNING `reconciliation_summary`。

## 阻断与允许增长

| 来源 | 处置和复跑要求 |
| --- | --- |
| 所有用户表 | 全表 gate 核对逐表行数与总数；非空未知处置停止。该 gate 自身允许新增空表，但 schema gate 仍要求审核其新列结构。没有固定表数或总行数。 |
| 全部列 | `source_schema_contract.json` 仅包含表名、列名、类型、长度、精度及 nullable/identity/computed 标记。新增、删除或改变列/表先停止审核；业务行数增长不要求改合同。不能仅通过重建合同来消除报错，须先补导出/迁移或明确归档处置。 |
| SystemItem 1/2/3/5/18 | 原类别全行与相应 raw CSV 做逐 ID/编码/名称核对，具有 parent 导出字段的类别同时核对 parent。历史部门投影不含 parent，其原层级继续由完整辅助文件保留。新增未知非空 class 停止，已知 class 的更多行可完整导入。 |
| SystemItem 10 | 原账户分类标签保留在独立历史证据命名空间，并核对所有非零 `M_Acc.ParentID` 均有原标签。其“现金/开户行”不并入财务科目、收款方式或新账户类型，不用相同名称推断 FK。 |
| SystemItem 12 | 与 `B_WorkShop` 的名称一一核对，保存同名不同 ID 的镜像字典证据。不把这组 ID 当作 B_WorkShop ID，也不新增重复部门。新增普通车间须审核部门映射；符合已审核“注塑N号机/安装N线”规则的数量可增长。 |
| SystemPart | 全行封存旧权限可见性历史，不导入旧用户、角色授权或覆盖新平台权限。新增历史行可归档，无固定行数。 |
| MK_StockGoods | 仅允许已审核旧年份范围内、全部数量/金额/单价事实为零的旧账行归档。新增符合条件的行可增长；任何非零事实、新事实列或超过已审核年份均停止，不能沿用“旧零库存”理由忽略。 |
| M_Acc | 已审核的每个 legacy ID 绑定编码/名称/状态指纹，以及当前迁移 SQL 实际能表达的账户类型和币种。新增、删除、改名、改码或状态变化先审核，不能静默走 GENERAL/RMB 默认值。余额和收付款金额增长正常进入现有严格金额对账，不受固定 27 条或余额快照限制。没有明确证据时不猜新币种。 |
| SystemAccinfo | 原企业名称、负责人、银行、地址和联系人等有历史价值，保留完整原备份供核对；旧开账年月、版本和许可配置不覆盖新平台设置。当前平台品牌与人事 Excel 的权威顺序不变，不能笼统称整表无用。 |

本 gate 证明上述来源及处置边界，不替代目标 FK、数量累计、财务归档、BOM、管理员保留及最终 SUCCESS/PASSED 验证。新备份触发政策 review 后，修正对应步骤与受审合同，冻结新 commit，再从新的输出目录重跑。
