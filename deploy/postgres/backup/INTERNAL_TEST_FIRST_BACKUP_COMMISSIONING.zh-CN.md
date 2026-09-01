# 既有 internal-test 新集群首份本机恢复层 commissioning

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../../simple/RUNBOOK.zh-CN.md)。

本流程只建立 **本机、同故障域、短期有效** 的首份 full + WAL 证据。终态回执固定声明
`localRecoveryOnly=true`、`restoreVerified=false`、`productionAuthority=false`；它不能替代异地仓、
恢复演练、生产备份验收或生产激活授权。

执行前必须先按
[目标服务器带外身份与访问 authority 清单](../../target-host-oob-authority.zh-CN.md)完成 H01–H12，并证明
candidate 来自
[GitHub 保护/签名 authority 清单](../../release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)定义的受保护
lineage。OOB 只读批准、备份 `record-plan` 与不可逆 `apply/resume` 必须分别授权。

## 不可逆边界

1. `assess`：零锁、零写，只读证明签名 candidate/onboarding/runtime/storage authority、实时
   system identifier/timeline/Flyway、loopback、systemd、所有入口和 timer 关闭、repo1 为空及容量足够。
2. `record-plan`：在 release operation lock 内重新观察；只在 root-only state 目录暂存新生成的
   repo1 cipher，并以 SHA-256 绑定 plan。plan/stdout/receipt 不含 secret。
3. `apply` / `resume`：先持 release operation lock，再持 shared DB maintenance lock。配置发布、
   `daemon-reload`、PostgreSQL restart 和身份复验均有 append-only、O_EXCL、hash-linked phase。
4. `repository-mutation-authorized` phase **先于** `stanza-create` 持久化。此前可以用专用 rollback
   恢复精确 preimage；此后即使命令失败，也不得自动删除 repo/WAL、覆盖未知配置或回退。
5. full 只能由 PID 1 启动既有 `uten-pgbackup.service`，其固定 `ExecStart` 是
   `locked_job.py repo1`。启动前 commissioner 释放 maintenance lock、但继续持 release lock；服务
   完成后 commissioner 按相同锁顺序重新取得 maintenance lock。`uten-pgbackup.timer` 始终 disabled。
6. 最后等价调用固定 `internal_test_first_backup.py`，绑定 locked_job terminal receipt、最新 full、
   WAL start/stop、repo1 check、同一 DB/candidate/onboarding，随后写 commissioning terminal receipt。
   调用前先持久化 `first-backup-receipt-authorized` 并证明固定回执此前 absent；掉电留下的非 JSON
   半写文件只能在该阶段后由程序清理后重试，任何完整 JSON、未知 schema 或 digest 漂移均不得删除/覆盖。

一旦跨过第 4 步，失败只允许处于 contained 状态后执行受审 `resume`；不得手工删除
`/data/backups/pgbackrest`、WAL、active/phase 文件或伪造终态回执。

## 目标机必须真实存在的输入

- terminal internal-test onboarding、固定 runtime contract、同一签名 candidate payload/manifest；
- PostgreSQL 16 新集群，`archive_mode=off`、空 `archive_command`，实时 Flyway/ACL 与 onboarding 一致；
- `/data/backups/pgbackrest` 为 `postgres:postgres 0750` 且严格空，所在存储仍匹配 storage authority；
- `/usr/bin/pgbackrest`、`systemd`、`ss`、`psql`、`runuser` 可用；repo1 可用容量至少
  `max(4 GiB, 2 × live DB size + 1 GiB)` 且至少 20%；
- existing-host backup installer 已完成 asset-only apply，所有入口/ERP/watchdog/updater/backup service
  均 stopped，所有相关 timer 均 disabled；无 release/commissioning/locked_job marker；
- `/etc/pgbackrest.conf` 只能 absent 或 comment-only 的 `root:postgres 0640` 新集群 preimage；
  repo1 cipher target 和 `zz-uten-imp-internal-test-backup.conf` 必须 absent。

commissioner 会生成并安装新的 repo1 cipher，不要求也不接受在命令行、环境变量、plan 或日志传 secret。

## 受审命令

```bash
sudo /usr/bin/python3 -I \
  /usr/local/libexec/uten-imp-backup/internal_test_first_backup_commissioner.py assess

sudo /usr/bin/python3 -I \
  /usr/local/libexec/uten-imp-backup/internal_test_first_backup_commissioner.py record-plan \
  --expected-assessment-sha256 '<assess 输出>' \
  --confirm 'RECORD REVIEWED INTERNAL TEST FIRST BACKUP PLAN'

sudo /usr/bin/python3 -I \
  /usr/local/libexec/uten-imp-backup/internal_test_first_backup_commissioner.py apply \
  --expected-plan-sha256 '<record-plan 输出>' \
  --confirm 'APPLY REVIEWED INTERNAL TEST FIRST BACKUP PLAN'
```

掉电或 SIGKILL 后使用同一 plan SHA 和同一确认串执行 `resume`。程序只从已验证的连续 phase 继续；
未知 phase、preimage/source/DB/storage/systemd 漂移、非空旧 repo、locked_job uncertain transaction 或
既有无匹配 receipt 的 full 都会零写/contained 拒绝。

仅在尚无 `repository-mutation-authorized` phase 且 repo 仍严格为空时，才允许：

```bash
sudo /usr/bin/python3 -I \
  /usr/local/libexec/uten-imp-backup/internal_test_first_backup_commissioner.py rollback-pre-repository \
  --expected-plan-sha256 '<record-plan 输出>' \
  --confirm 'ROLLBACK BEFORE INTERNAL TEST BACKUP REPOSITORY MUTATION'
```

## 终态与仍为 NO-GO 的事项

成功终态是：archive override 生效、repo1 stanza/check 健康、PID1-owned locked_job 新增且仅新增一份
fresh full + WAL、first-backup receipt 和 commissioning terminal receipt 均为 root-only 单链接文件，
timer 仍 disabled。此时只具备本机恢复材料；在完成独立 repo2、恢复演练、7 点 retention/WAL 健康、
告警送达、生产验收和 production authority 前，生产激活仍为 NO-GO。
