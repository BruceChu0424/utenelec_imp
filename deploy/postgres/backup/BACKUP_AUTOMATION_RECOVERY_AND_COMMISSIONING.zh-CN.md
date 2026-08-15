# 备份掉电恢复与自动化投产合同

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260812 -->
> 2026-08-12 的最后只读快照显示旧 repo1 02:17 timer 当时在运行；该状态尚未通过当前 OOB authority 和
> 新只读会话刷新。本文件描述的新自动化尚未 commissioned，全部相关新增 timer
> 继续 disabled。未来 03:00 是维护/自检窗口，不是 backup timer。commissioning 前必须重新排程并证明：
> 02:17 full 未结束就跳过维护；backup/expire、SMART 长测、RAID check、apt/dpkg 和重启彼此不重叠；
> 不能为了赶 03:00 强停 pgBackRest。实时状态见 `../../current-test-server-status.zh-CN.md`。
> 首次连接前必须先按
> [目标服务器带外身份与访问 authority 清单](../../target-host-oob-authority.zh-CN.md)完成 H01–H12；该清单
> 通过也不授权安装、启用 timer 或执行备份。

> 当前结论：源码已具备 fail-closed 工具与静态/故障注入测试；真实服务器、PID 1 systemd、真实
> pgBackRest 仓库、SIGKILL/OOM/掉电和告警送达尚未验收，因此生产启用仍是 **NO-GO**。

## 1. durable backup transaction

`locked_job.py` 对 repo1/repo2 full 使用固定 root-only 状态目录：

- `/var/lib/uten-imp-backup-transactions/repo1.active.json`
- `/var/lib/uten-imp-backup-transactions/repo2.active.json`
- `/var/lib/uten-imp-backup-transactions/receipts/`

状态只允许 `running -> committed -> expire-pending -> complete`；任何无法证明的命令返回、信号、
超时、inventory 读取失败或门禁变化进入 `uncertain`。`running` 在 full 前持久化 pre-inventory 和固定
backup/expire 命令摘要；full 返回后必须从 `pgbackrest --repo=N --output=json info` 证明恰好新增一个
成功 full，才能进入 `committed`。expire 前先持久化 `expire-pending`。completion receipt 先 fsync，
最后才 fsync-unlink active marker。

只要任一 active marker 存在，repo1、repo2 和 health 均以 exit 78 失败，timer 或重启不得再次执行 full，
也不得由管理员删除 marker。先在受控终端执行只读核验：

```bash
sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/locked_job.py \
  transaction-assess repo1
```

assessment 同时绑定 active bytes、当前仓库 inventory、对应 service inactive/MainPID=0，以及系统中不存在
任何名为 `pgbackrest` 的进程。全局 `pgrep --exact pgbackrest` 会把无关手工任务也视为阻塞；这是故意的
保守误拒，必须等待并重新 assess，不能绕过。

只有以下三类 action 可执行：

- `abort-retry`：当前 inventory 与 pre-inventory 完全一致，证明没有新成功 backup；先写 reconcile receipt，
  再删 active，下一 timer 才能重新 full。
- `resume-expire`：证明恰好一个新成功 full，或 durable committed full 仍存在且无未知新增；只执行固定
  `--repo=N expire`，绝不重跑 full。
- `finalize-complete`：complete phase 的 final inventory 与当前完全一致；补 completion receipt 后删 active。

执行必须逐字传入本次 assess 的 active SHA、assessment SHA 和对应确认短语。例如：

```bash
sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/locked_job.py \
  transaction-reconcile repo1 \
  --reconcile-action resume-expire \
  --expected-active-sha256 '<本次 active SHA-256>' \
  --expected-assessment-sha256 '<本次 assessment SHA-256>' \
  --confirm 'RESUME EXPIRE FOR VERIFIED UTEN BACKUP TRANSACTION'
```

reconcile receipt 在动作前持久化。若 expire 失败，active 会进入新的 `uncertain` phase，旧 SHA/assessment
必须失效；必须重新 assess 新状态，不能复用旧批准。receipt 写完、active 尚未删除时掉电可用完全相同的
证据幂等重入。

## 2. commissioner 前置证据

现有主机必须先由固定 root-only `uten-imp-existing-backup-installer` 启动器验证并执行冻结的
`existing_host_installer.py` 捕获字节，安装完整 runtime/unit，且保留：

`/var/lib/uten-imp-backup-installer/uncommissioned-install.json`

禁止直接按路径运行/import 安装器；启动器、安装器和保留仓库布局的完整源码包清单必须分别复核摘要，
升级时也必须保存并验证三者的旧 preimage。具体固定路径、mode 和切换顺序见
[`EXISTING_HOST_INSTALLER.zh-CN.md`](EXISTING_HOST_INSTALLER.zh-CN.md)。

commissioner 会逐字绑定该 receipt 和每个已安装 helper/unit 的 SHA/owner/mode；它不会删除
uncommissioned receipt。最终成功才另写：

`/var/lib/uten-imp-backup-installer/commissioned.json`

还必须由既有 `backup_acceptance.py` 生成并复制/命名为固定详细 receipt：

`/var/lib/uten-imp-backup/acceptance-receipts/commissioning-backup-acceptance.json`

它必须在 24 小时内，且已绑定双仓各至少 7 个成功 full、连续 WAL、一致的最新 WAL、有效 WORM、
active repo2 preflight、真实 provider alert receipt、隔离 repo2 PITR、七类业务 PASS 与签名 Flyway 身份。

容量证据固定为：

`/var/lib/uten-imp-backup/acceptance-receipts/commissioning-capacity-quota.json`

字段合同见 `capacity-quota-acceptance.example.json`。它必须在 7 天内、由两名不同人员验收，证明 `/data`
下的 backup scope 有硬 quota、filesystem-full 与掉电测试通过，并至少预留两个并发/catch-up full 加一个
最大 full 的最低空闲量。example 不是验收证据，禁止直接复制成 PASS。

## 3. assess、record-plan 和分阶段投产

`assess` 只读，不创建目录/锁/plan，不执行 systemctl 写命令：

```bash
sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/backup_commissioner.py assess
```

真实只读结果经带外复核后，才允许：

```bash
sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/backup_commissioner.py \
  record-plan \
  --expected-assessment-sha256 '<approved assessment SHA-256>' \
  --confirm 'RECORD REVIEWED UTEN BACKUP COMMISSION PLAN'

sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/backup_commissioner.py \
  apply \
  --plan /var/lib/uten-imp-backup-commissioner/commission-plan.json \
  --expected-plan-sha256 '<reviewed plan SHA-256>' \
  --confirm 'APPLY REVIEWED UTEN BACKUP COMMISSION PLAN'
```

apply 先持久化 `/var/lib/uten-imp-backup-commissioner/active-transaction.json`，helper 与三个 database job
unit 都把它作为硬门禁。然后每次调用只推进一个阶段：

1. alert-drain timer；
2. repo1 timer；
3. health timer；
4. repo2 timer。

每阶段先 `enable` 再 `start` timer；Persistent catch-up 即使立即触发 job，也会被 active marker 和共享
database-maintenance lock 拒绝。commissioner 随后 stop/reset-failed 对应 job，严格核验 timer 已
enabled+active、job 已 inactive，才 fsync stage-complete。下一阶段必须携带最新 active SHA：

```bash
sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/backup_commissioner.py \
  resume \
  --expected-active-sha256 '<latest active SHA-256>' \
  --confirm 'RESUME REVIEWED UTEN BACKUP COMMISSION TRANSACTION'
```

四阶段完成后，工具先持久化 marker-pending，再原子写 commissioned marker，再写 commission receipt，
最后删 active。任一掉电边界都复用已存在 marker 的原 bytes/时间和证据摘要，不生成第二个时间身份。

## 4. 失败与 rollback

marker 尚未写入时，apply/resume 失败会尝试把四个 timer 恢复为初始 disabled+inactive，并 stop/reset
四个 job，写 rollback receipt 后再删 active。自动回退也失败时保留 active，不得手删。批准后使用：

```bash
sudo /usr/bin/python3 -I -B /usr/local/libexec/uten-imp-backup/backup_commissioner.py \
  rollback \
  --expected-active-sha256 '<reviewed active SHA-256>' \
  --confirm 'ROLLBACK UNFINISHED UTEN BACKUP COMMISSION TRANSACTION'
```

一旦 commissioned marker 已存在，rollback 必须拒绝，因为 timer 已成为生产自动化；后续停用需要新的
生产变更、备份证据和回退方案，不能借未投产工具绕过。

commissioner 的 systemctl allowlist 仅含上述四个 backup timer/job。它永不启用 updater staging 或
retention timer，不写 `/etc/pgbackrest*`、repo2 secret/policy/WORM 或 alert provider 配置，也不启动
PostgreSQL 或 `/data` mount。

## 5. 真实环境仍需验收

- disposable Linux/PID 1 VM 的 unit sandbox、CAP_SETUID/GID、loaded FragmentPath/DropInPaths；
- timer Persistent catch-up、PG 慢起、断网、SIGKILL、OOM、12 小时 timeout、掉电各 phase；
- repo1/repo2 full 提交边界、inventory 判定、expire-only reconcile、容量打满且不重复 full；
- alert-drain sender/provider receipt 与值班实际到达；
- 真实 RAID/SMART、`/data` quota、WORM、连续 WAL、7 个成功恢复点和隔离 PITR/UAT。

上述证据未通过前，四个 timer 必须保持 disabled/inactive。
