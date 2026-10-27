# 已核验员工身份的纯 alias 维护

此目录是显式维护工具，不属于 Flyway、启动任务或旧 HR 重导。它只登记经过人工和来源证据确认的历史员工查询别名，不修改员工、账号、密码、授权、消息、会话或历史 UUID。

2026-10-26 公司只读复核仍为 v2.5.31 / V935，因此本工具**未在公司执行**。原石磊账号已经恢复到 UT0010；不得重跑 `output/staff-feedback-20261026/merge-confirmed-stone-identity.sql` 及其旧执行器，它们包含已被后续正式恢复取代的停用、回绑和会话撤销。UT0189 与历史锚点只能在当前事实重新核验后作为归档 alias；不能按姓名自动匹配。五个用户明确保留的停用账号不在本维护范围。

执行前必须先完成统一版本上线，确认正式目录里的 alias 迁移、账号行锁前向迁移和查询代码均已部署。由已有维护授权的操作人取得新鲜物理数据库身份、数据集及代际、完整 Flyway 校验和指纹、UT0010 原员工/用户 UUID、各行版本和当前启用永久凭据事实，核对明确身份来源，并完成配对备份及独立验证。本工具不申请或授予生产维护权限，也不把本地测试库或历史 71 条覆盖数当作公司当前事实。

执行角色须是既有授权的维护角色，能够读取 `pg_control_system()`、Flyway 和受保护账号/员工/审计原行、取得目标行锁，并向 `employee_identity_aliases` 显式插入。SQL 使用调用者权限，不是 SECURITY DEFINER，不给应用角色扩权；缺少权限直接失败，不以跳过物理身份核验作为兼容方案。当前 `StaffAuthenticationPolicy` 只有 `temp_password_expires_at` 临时凭据到期字段，没有另一个永久密码到期字段。本次恢复事实的前提比一般登录更明确：`must_change_password=false`、`temp_password_expires_at IS NULL`、数据库内原凭据非空，且 status/员工身份/锁/原UUID及版本匹配。工具只检查凭据存在并逐行保全，不检查员工真实密码，也不输出原哈希。

`prepare_employee_alias_only.py` 只读取计划并生成 SQL，不连接数据库。计划须采用以下精确字段（值均来自同一次最新只读核验；不含姓名、手机号、密码、密文或原始哈希）：

```json
{
  "protocol": "verified-employee-alias-only-v1",
  "captured_at": "带时区的最新 ISO 时间",
  "database_identity": {
    "database": "实际数据库名",
    "system_identifier": "实际集群标识",
    "database_oid": 0,
    "dataset_id": "实际业务数据集 UUID",
    "generation": 0,
    "migration_max": 947,
    "migration_sha256": "64位小写SHA256"
  },
  "canonical": {"employee_id": "实际已恢复员工UUID", "code": "UT0010", "version": 0},
  "retained_user": {"user_id": "原用户UUID", "version": 0, "auth_version": 0},
  "aliases": [{"employee_id": "已核验归档旧员工UUID", "code": "实际旧工号", "version": 0,
               "reason": "明确身份来源与人工核验理由"}],
  "backup": {"reference": "本次配对备份验证回执位置", "manifest_sha256": "64位小写SHA256", "verified": true},
  "evidence_reference": "本次受审身份依据的稳定标识",
  "maintenance_actor": "实际维护审计账号"
}
```

`migration_sha256` 使用数据库函数中的同一表达式：对所有 `success` 的 `flyway_schema_history`，按 `installed_rank` 排序的 `jsonb_agg(jsonb_build_array(version,checksum))::text` 求 SHA-256。计划的最大迁移号和指纹均必须是实际完整版本，不能照抄示例号。当前工具最低要求正式目录中的 V947 成功，另核 alias 查询对象存在；完整受审指纹仍由当前部署核验资料提供。当前资料有效期 24 小时，SQL 在真实目标再次核对；旧版本、错物理库、版本漂移、不是当前启用永久凭据的原账号、不是归档且无活动账号的 alias、已有冲突证据均拒绝。`backup.verified` 和 SHA 只登记外部已验证回执，本工具不读取备份文件、不证明其可恢复性。

先生成并审阅回滚预演：

```powershell
python server/maintenance/prepare_employee_alias_only.py --plan <私有最新计划.json> --out <私有预演.sql>
```

已有授权、备份和预演都通过后，再以同一受审计划生成 `--commit` 版本。两个生成器输出都不会自动执行；操作人通过既有受控维护连接以 `psql -X -f <SQL>` 执行，认证不放在命令行。输出文件必须不存在，防止覆盖旧回执。默认 SQL 使用 `ROLLBACK`，不得把预演安全回执当作已提交。显式提交和默认预演均处于单个 repeatable-read 事务，触发器和审计保持启用。

SQL 只创建连接内的临时函数并 `INSERT employee_identity_aliases`；按既有 alias 锁取得员工和原用户行锁，锁内核对当前绑定与版本。事务内逐行对比这些身份的员工、所有具有 `employee_id`/`user_id` 的原行、原账号、个人 grant/revoke 及来源、消息/已读和原 actor/target 审计（含归档）；数据库内的私有比较值不输出。当前前提仍匹配时，重复相同 identity、理由和 evidence 返回零插入；版本已变化须先重新只读核对并生成新计划，冲突证据拒绝。只允许 alias 审计新增和每个新 alias 触发一次既有 authorization epoch 更新，以失效旧查询缓存；不改账号 auth_version、不撤销会话。旧访问令牌仍可能因既有全局 epoch 机制需要刷新，不能将此描述成完全没有会话可见影响。

提交后必须另开连接独立回读 alias 精确集合、原账号绑定/资格/版本、完整个人覆盖及生效权限、消息内容/已读、原 actor 审计和员工历史查询结果，并登记备份回执、实际数据库身份、受审 SQL SHA、事务与回读证据。若回执丢失或连接中断导致提交未知，先独立回读；同证据可幂等重试，不能自动重放任何业务写入。真实员工本人登录、MFA 和业务浏览器 UAT 仍单独验收。
