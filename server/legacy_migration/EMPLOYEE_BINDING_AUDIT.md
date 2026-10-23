# 员工绑定与现行责任只读核对

`verify_employee_bindings.py`用于本项目旧库首次导入的候选库验收。它按原单ID和旧员工ID核对新UUID、工号、历史人员字段及现行责任；不以新工号尾数、姓名或同号账号替代真实身份。不会修改数据库、封存CSV或映射，不回填历史UUID，不导出姓名、手机、证件或密码。所有结果应写到私有运行目录。

## 执行

依赖Python标准库，以及本机Docker/psql；脚本通过`docker exec`连接已完成导入的候选库。使用真实Python可执行文件。先冻结导入源码、完成prepare，取得本轮`run_id`及`derived_inputs.json`，使用新输出目录。

```powershell
$repo = '<本轮冻结工作树绝对路径>'
$py = '<真实python.exe绝对路径>'
$inputs = '<本轮final-inputs绝对路径>'
$hr = '<同批hr层绝对路径>'
$attempt = '<本轮apply的log父目录>'
$database = '<本轮候选库全名>'
$out = '<本次员工审计独立私有输出目录>'
$snapshotPrivatePath = '<本轮原管理员快照路径>'
$runId = (Get-Content -Raw -LiteralPath "$attempt/run_id.txt").Trim()
$manifestSha = (Get-FileHash -Algorithm SHA256 -LiteralPath "$inputs/derived_inputs.json").Hash.ToLowerInvariant()
$mapperSha = (Get-FileHash -Algorithm SHA256 -LiteralPath "$repo/server/legacy_migration/migrate_sales_owner.sql").Hash.ToLowerInvariant()
$commit = (Get-Content -Raw -LiteralPath "$inputs/derived_inputs.json" | ConvertFrom-Json).provenance.importerRepositoryCommit
$adminUserId = (Get-Content -Raw -LiteralPath $snapshotPrivatePath | ConvertFrom-Json).id

# 仅离线准备，不连接数据库。
& $py "$repo/server/legacy_migration/verify_employee_bindings.py" `
  --inputs $inputs --hr $hr --output $out --run-id $runId --database $database `
  --manifest-sha256 $manifestSha --sales-owner-mapper-sha256 $mapperSha `
  --frozen-commit $commit --admin-user-id $adminUserId

# 只有确切run提交SUCCESS/PASSED后，才追加--verify执行同一组参数。
& $py "$repo/server/legacy_migration/verify_employee_bindings.py" `
  --inputs $inputs --hr $hr --output $out --run-id $runId --database $database `
  --manifest-sha256 $manifestSha --sales-owner-mapper-sha256 $mapperSha `
  --frozen-commit $commit --admin-user-id $adminUserId --verify
```

不要打印或提交管理员快照。该工具只使用保留账号的UUID，验证其启用、超级管理员标记及关联ADMIN；原密码哈希保全由管理员保留工具和整体验收另行核对，不把本工具结果当成实际密码登录。

`--verify`强制显式manifest SHA、销售归属mapper SHA和管理员UUID；`--frozen-commit`如提供，必须等于manifest中冻结导入commit。`--expected-worker-count N`可额外绑定独立审查过的源员工数。默认从本批源身份集合计算，不沿用上一轮人数。`--container`默认本项目本地容器，`--user`默认本地角色；连接失败或权限不足直接退出。

输出目录的`run_binding.json`绑定run、目标、输入摘要、mapper、共享custody helper及本审计脚本的真实路径/摘要。同一次准备与验证使用同一脚本路径和字节；换run、输入或脚本后新建输出目录，不能覆盖旧证据。脚本先确认这次run已提交SUCCESS且reconciliation_status为PASSED，并核对目标与raw谱系，再读取业务目标。该入口按候选库原名执行；数据库改名切换后的验收由切换流程处理。

## 85项字段规则与边界

- 源`B_Worker`、HR实际写入名录及crosswalk的旧ID集合必须相等且唯一。实际FK使用`hr_rehearsal.csv`的旧ID/新工号与目标UUID；`canonical_code`仅作候选解释，不是实际绑定。候选别名相同也不能掩盖独立旧身份。
- 采购、销售、委外、库存、生产、资金的历史人员字段按逐源原单ID核对。旧业务员/经办人确属`B_Worker`时才连接员工。`Sys_Operator`制单/审核旧ID与冻结姓名走独立命名空间；原文本人员字段按原文SHA核对，不猜UUID。库存按`doc_type+legacy_id`区分并精确剔除DROP仓整单。
- 当前客户、供应商、货品与销售归属独立重算。active/probation/onLeave且未删除的员工可担现行责任；失效私有责任归保留ADMIN托管，原公开空值/0保持公开。逐对象核对custody队列、原因和helper SHA。
- 销售逐明细真实上游FK重算继承：单一责任沿用，多个不同非空责任由ADMIN临托，完整核对`MIXED_UPSTREAM_OWNER_CUSTODY`、旧业务员、目标/上游单据及明细UUID证据。缺失上游引用保留源缺口，不猜接同号单据。
- 部门负责人和实际员工FK目录另行核对；存在legacy_id而未被已知规则覆盖的非空员工FK会报阻断问题。

`ROOTS`是当前`migrate_goods_owner.sql`中6个旧分类根到旧员工ID的既有责任规则镜像，不是任何旧库都适用的通用规则。换新源后必须核对分类真实身份、路径和负责人证据，并与本轮冻结导入SQL一致；不得因整数仍存在就沿用旧解释。若发生变化，应先修订受审导入规则及本审计镜像、更新回归、冻结新commit并重新prepare。

规则数85只表示当前平台字段清单，不保证以后新增模块/字段已自动覆盖。每次换源都须查看FK目录和逐表处置矩阵。历史冻结单据中可由真实旧ID追溯、但未物化UUID的字段标记`LEGACY_ONLY`；源员工身份本就缺失的字段标记`UNRESOLVED_SOURCE_IDENTITY`，不得混为可安全回填。尚无目标旧ID/姓名快照的委外字段标记source-only，不计已结构化迁移。页面只读历史姓名投影、密码登录、权限接口、财务开账及业务签字不由本脚本替代。

## 收据与停止条件

主要输出：`employee_binding_verification.json`、`employee_binding_issues.json`、`actual_employee_crosswalk.csv`、`actor_binding_summary.json`、`employee_fk_inventory.json`、`current_owner_custody_validation.json`、`sales_owner_conflict_validation.json`及逐行历史待核清单。员工对照只含旧ID、目标UUID、工号、状态和候选别名，不含姓名等身份原文。

阻断问题非零时状态FAILED并返回非零，停止切换。`PASSED_WITH_PENDING`表示未发现错绑，但来源缺失身份、LEGACY_ONLY和source-only仍须逐项交接；不表示所有历史字段已经物化或所有来源身份已经查明。全部数据库命令为`BEGIN REPEATABLE READ READ ONLY`、SELECT和ROLLBACK；不创建临时表。

```powershell
& $py -m unittest discover -s "$repo/server/legacy_migration" -p test_verify_employee_bindings.py -v
```

回归覆盖实际旧身份与候选别名、离职历史人与现行托管、公开值、命名空间、混合上游责任、最终输入/管理员UUID锁定，以及源身份缺失/重复拒绝。回归通过不代表最终候选库已验证；以对应run的实际收据为准。
