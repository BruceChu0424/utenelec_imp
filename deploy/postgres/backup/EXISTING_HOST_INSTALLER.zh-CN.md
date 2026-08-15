# 现有 PostgreSQL 主机备份运行时安装器

> 状态：这是“已有主机、禁止重跑 Phase 2”场景的证据驱动安装工具。
> 它只安装固定备份运行时与完整 systemd unit，完成后所有 job/timer 仍为
> **disabled + inactive（未投产）**。真实主机执行 `record-plan`、`apply` 或 `rollback`
> 都属于写操作，必须在只读核验、变更审批、维护窗口和回退评审之后进行。
> 主机身份、Host Key、两把管理员密钥、批准路由和控制台必须先按
> [目标服务器带外身份与访问 authority 清单](../../target-host-oob-authority.zh-CN.md)完成 H01–H12；该清单
> 通过也只授权首次只读刷新，不自动授权本安装器写入。

## 1. 安全边界

`existing_host_installer.py` 的固定目标只有：

- `/usr/local/libexec/uten-imp-backup/` 下的 `locked_job.py`、`pgbackrest_repo2.py`、
  `pgbackrest_health.py`、`backup_alert.py`、`internal_test_first_backup.py` 与
  `internal_test_first_backup_commissioner.py`；
- `/etc/systemd/system/` 下 repo1、repo2、health、alert、alert-drain 的 5 个完整 service
  与 repo1、repo2、health、alert-drain 的 4 个 timer；
- `/var/lib/uten-imp-db-maintenance/operation.lock`（`root:postgres 0660`、单硬链接、空文件）；
- `/var/lib/uten-imp-backup-health/`（`root:postgres 0770` 专用叶目录）和 root-only
  `/var/lib/uten-imp-backup-installer/` 计划、preimage、事务及回退凭据。

工具不会：

- 写 `/etc/pgbackrest.conf`、`/etc/pgbackrest/conf.d/`、repo2 policy/secret、WORM evidence、
  alert provider/sender 配置或 commissioning marker；
- 运行 `systemctl start/stop/restart/enable/disable/mask`；唯一 systemd 状态刷新是
  `systemctl daemon-reload`；
- 启动 PostgreSQL、挂载 `/data`、执行 backup/health、连接 repo2 或运行 `expire`；
- 把 Phase 2 当成现有主机升级器。

完整 repo1 unit replacement 是必需的：systemd 的 `Requires=`/`After=` 等依赖不能靠 drop-in
空赋值可靠清除。三个数据库 job 只有 `After=postgresql@16-main.service` 排序关系，没有
`Requires=`、`Requisite=` 或 `RequiresMountsFor=`，因此 timer 不能反向拉起 PostgreSQL 或 `/data`。
每次真正运行时由 root supervisor 持数据库维护锁，并在降权为 `postgres` 后执行固定命令。

## 2. 执行前只读条件

在真实服务器上先完成并留证：RAID/SMART/挂载/容量、PostgreSQL 与 Flyway 身份、当前 unit/drop-in
的路径/owner/mode/SHA-256、全部备份任务状态、repo1 恢复点、备份/恢复责任人、维护窗口和控制台回退。
必须确认：

- 主机指纹已带外核验，使用两把独立管理员 SSH 密钥；聊天中出现过的密码已私下轮换；
- `postgres` 是非 root 固定账号/主组，`/data` 与 PostgreSQL 当前状态仅观察、不由本工具改变；
- 4 个 timer 均 disabled + inactive，5 个 job/template 均 inactive，无 alert 实例和 pending systemd job；
- installer bundle、所有父目录和源文件均为 root 控制且不可被组/其他用户写，源文件为单硬链接普通文件；
- 没有 `active-transaction.json`、未处理的 `uncommissioned-install.json` 或 commissioned marker；
- 目标磁盘有保存全部 preimage、事务凭据和原子临时文件的余量。

任一条件不成立时停止，不要手工删除 marker、receipt、旧 unit 或 drop-in 来绕过门禁。

## 3. 三步安装

以下命令只展示固定接口；真实 SHA-256 必须来自本次只读结果并由第二名审核人带外复核。
不要把 secret 放入参数、stdout、工单或聊天。

### 3.0 独立可信启动器与源码包边界

禁止从 checkout、临时上传目录或安装器路径直接运行 `existing_host_installer.py`，也禁止用
`PYTHONPATH`、`runpy` 或 import 加载它。唯一入口是独立安装为
`/usr/local/sbin/uten-imp-existing-backup-installer` 的 root-only 启动器；固定调用形状为：

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-backup-installer -- <installer-action-and-arguments>
```

当前冻结边界必须由两名审核人分别核对：

- `launch-existing-host-installer.py`：`a9f7e32cb8011f0a15af27d4620a9afa8cae7eee50f09a214a3cb84034d040a8`；
- `existing_host_installer.py`：`512b7c7132c2016d1557723b90bef520349b5cbd7875af296d6d0554b9ade727`。

启动器以 `root:root 0500` 安装；源码包保留仓库相对布局并固定在
`/usr/local/share/uten-imp-backup-installer-source/`，从文件所在目录一直到 `/` 的全部父链都必须是
root 控制、非 symlink 且组/其他用户不可写，
所有源文件为 `root:root 0400`、单硬链接普通文件。启动器只用 `O_NOFOLLOW` 打开固定的
`deploy/postgres/backup/existing_host_installer.py`，逐字匹配其内嵌摘要后，从已捕获字节
`compile`/`exec`；它不会按路径执行或 import 安装器，并会清除继承环境、固定 `argv`、`PATH`、locale、
工作目录与 umask。

源码包的带外审核清单必须**恰好**包含安装器、`ASSETS` 中 8 个 Python runtime 和
`deploy/systemd/` 中 9 个对应 unit/timer 源文件；路径、SHA-256、owner、group、mode、link count 和
父目录元数据全部逐项复核。主机安装前先只读确认启动器路径和源码包根目录均不存在；如任一路径已存在，
必须把它当作 preimage，完整采集上述清单并与上一批准版本逐字匹配。未知、缺失或漂移的 preimage 一律
停止，禁止 `cp -r` 覆盖、原地修补或删除后伪装首次安装。

启动器内嵌摘要只认证安装器本身；其余 17 个 asset 的代码信任由安装器 plan 闭合：`record-plan` 的
`assessment.sources` 逐项绑定固定 name/source/target/mode/SHA-256，`apply` 在创建事务/preimage 或改变
任何托管目标前重跑完整 assessment 并逐字比较，再用单一 `O_NOFOLLOW` descriptor 捕获每个 source，
复核路径/父链/owner/mode/link count/metadata 与 plan SHA-256。任一 asset 在批准后漂移都会在写边界前
fail closed，不能仅凭“目录布局正确”获得信任。

首次安装或升级都是独立主机写变更：先在同一文件系统的 root-only staging 目录安装**精确 allowlist**，
复核完整清单且确认无额外对象，再经审批原子切换固定源码包和启动器。安装器任何一个字节变化，都必须先
冻结新安装器摘要，再生成并独立审核一个内嵌该摘要的新启动器；启动器自身变化也必须单独复核。升级前保存
旧源码包、旧启动器及其完整元数据/摘要作为回退 preimage；两者切换中间态只允许 fail closed，不得运行
安装器。回退也必须恢复匹配的一对旧源码包与旧启动器，不得把新启动器配旧安装器或反之。

### 3.1 `assess`：纯只读、零目标机落盘

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-backup-installer -- assess
```

工具只向 stdout 输出 canonical JSON，外层 `assessmentSha256` 绑定内部 `assessment` 的逐字 canonical
字节。它不创建状态目录、锁或 plan，不运行任何 systemctl 写命令。初次只读阶段不要在目标机用
shell 重定向落盘；通过受控会话记录在带外审核端保存输出，并复核：

- `sources` 与 `targets` 的精确路径、源/目标 SHA-256、owner/mode；
- `dropins` 与 loaded `DropInPaths`；
- 全部 unit 的 `ActiveState`/`UnitFileState`、pending jobs 与 alert instances；
- PostgreSQL meta/instance 状态、通过 `ss` 读取的 TCP/5432 listener 数量/端点集摘要，及 `/data`
  的只读 `findmnt` 安全派生结果。`assess` 不发起数据库连接；mount source/options/UUID 只输出
  安全派生字段，不把可能含凭据路径或网络身份的原值写到 stdout/plan。source/UUID 仅输出
  SHA-256；options 只记录是否存在和条目数，避免低熵内联 secret 的无盐摘要成为离线猜测 oracle。

### 3.2 `record-plan`：批准后的第一次写入

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-backup-installer -- record-plan \
  --expected-assessment-sha256 '<approved-assessment-sha256>' \
  --confirm 'RECORD REVIEWED UTEN BACKUP INSTALL PLAN'
```

该命令先取得固定 installer lock，再在**同一把锁内**重新完成全部只读 observation；任何字节或状态
变化都会拒绝。只有完全相同才原子写入 root-only 固定 plan：
`/var/lib/uten-imp-backup-installer/install-plan.json`，并输出 `planSha256`。旧 plan 先按内容摘要归档，
但存在活动事务、未投产 receipt 或 commissioned marker 时拒绝重录。

### 3.3 `apply`：只消费固定 plan

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-backup-installer -- apply \
  --plan /var/lib/uten-imp-backup-installer/install-plan.json \
  --expected-plan-sha256 '<reviewed-plan-sha256>' \
  --confirm 'APPLY REVIEWED UTEN BACKUP INSTALL PLAN'
```

`apply` 在 installer lock 内再次逐字复核 plan、主机 observation 和全部源字节，然后：

1. 在 root-only 事务目录保存所有目标文件及全部 `/etc/systemd/system/<unit>.d/*.conf` preimage；
2. 原子创建固定目录/maintenance lock，非阻塞取得数据库维护锁；
3. 以同目录临时文件、`fsync`、atomic rename 安装固定 runtime/完整 unit，并移除已记录的旧 drop-in；
4. 持久记录 `daemon-reload-pending`、`daemon-reloaded`、`loaded-verification-pending`、
   `loaded-verified` 等阶段；
5. 执行 `systemd-analyze verify`，并从 loaded systemd 严格验证每个 unit 的精确
   `FragmentPath=/etc/systemd/system/<unit>`、空 `DropInPaths`、无反向 PG/`/data` 依赖、
   全部 timer disabled/inactive、全部 job/template inactive、无 pending job；
6. 写入 `/var/lib/uten-imp-backup-installer/uncommissioned-install.json` 后结束。

此时只是“已安装、未投产”。不得启用任何 timer；尤其 alert-drain 必须等真实 sender 及 provider
receipt 送达演练，repo2 必须等 policy/secret/WORM、连续 WAL、full/restore/PITR 验收。

既有 internal-test 新集群的首份本机恢复层使用
`INTERNAL_TEST_FIRST_BACKUP_COMMISSIONING.zh-CN.md` 的独立 plan/apply/resume 状态机；安装器本身仍不
生成 cipher、不写 archive/pgBackRest 配置、不创建 stanza、不启动 full。

## 4. 失败与回退

如果 preimage 准备失败且尚未改变任何托管目标，工具写 root-only
`preparation-failed-before-managed-mutation` 凭据后关闭活动事务。进入目标变更后，任何异常都会在同一
installer lock 下重新取得数据库维护锁，逐文件恢复 preimage，持久记录 rollback reload 前/后阶段，
重新 `daemon-reload` 并验证原 loaded systemd 状态。maintenance lock 的命名路径会保留到所有其他
文件与 loaded-state 均恢复后才最后还原，避免持锁 inode 被提前 unlink 后出现第二把同名锁。原始错误
始终是主错误；自动回退也失败时，消息会
同时给出回退错误和 `active-transaction.json` SHA-256，绝不会用“清理成功/失败”掩盖原故障。
即使活动 evidence 本身损坏或在第二次中断中无法读取，诊断也只输出 `unreadable-<type>`，不会覆盖
最初的 apply/rollback 错误。

掉电或双重失败留下活动证据时，先只读取得固定 evidence 的 SHA-256、核对所有 job/timer 仍 inactive，
再经批准执行：

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-backup-installer -- rollback \
  --evidence /var/lib/uten-imp-backup-installer/active-transaction.json \
  --expected-evidence-sha256 '<reviewed-active-evidence-sha256>' \
  --confirm 'ROLLBACK UNCOMMISSIONED UTEN BACKUP INSTALLATION'
```

正常未投产安装也可把 `--evidence` 换成固定
`/var/lib/uten-imp-backup-installer/uncommissioned-install.json` 及其 SHA-256。rollback 只接受这两个
固定路径，只允许 uncommissioned 且所有相关 unit inactive 的状态；它拒绝 commissioned marker，
拒绝覆盖已漂移目标，并保存 root-only rollback receipt。禁止管理员手工删除任何 marker/receipt。
完成回退时，工具先验证 rollback receipt 已持久化，再先删除 stale uncommissioned receipt、最后删除
active transaction；若在两次删除之间掉电，active evidence 仍可幂等重放，不会留下必须手删的死角。

## 5. 验收与仍然 NO-GO

仓库验证入口：

```bash
python3 -m unittest -v deploy.postgres.backup.test_existing_host_installer_launcher
python3 -m unittest -v deploy.postgres.backup.test_existing_host_installer
bash -n deploy/postgres/backup/test_existing_host_installer_systemd.sh
```

只有明确确认是可销毁、PID 1 为 systemd 的 Linux VM，才可运行 opt-in loaded-unit 测试：

```bash
sudo env UTEN_RUN_EXISTING_BACKUP_INSTALLER_SYSTEMD_TESTS=I_ACKNOWLEDGE_THIS_IS_A_DISPOSABLE_SYSTEMD_VM \
  bash deploy/postgres/backup/test_existing_host_installer_systemd.sh
```

源码/模拟测试不能替代真实机 namespace/capability、`systemd-analyze`、信号/超时/OOM、掉电原子性、
PostgreSQL 慢启动、Persistent timer catch-up 和维护锁竞争验收。安装后仍不得 commission/enable，直至：

- repo1 实际 full/expire、容量上限、7 个成功恢复点与隔离恢复通过；
- repo2 最小权限、TLS、WORM、连续 WAL、PITR、断网/积压/恢复通过；
- 外部 alert sender 的 pending/retry/provider receipt 与值班到达通过；
- 发布事务与同一 maintenance lock 的真实竞争、失败 marker、重启/掉电恢复通过；
- backup helper 已实现跨重启 durable phase 与证据绑定的 `transaction-assess`/`transaction-reconcile`，
  但仍须在 disposable Linux/systemd VM 与真实维护窗口验证 SIGKILL/OOM/掉电、pgBackRest inventory 和
  Persistent catch-up 确实不会盲目重复 full；禁止手删 active marker；
- 独立 commissioner 已实现只读 assess、计划记录、四阶段 enable/start、resume 与 rollback，但只有绑定
  真实 repo1/repo2/WAL/7 点/WORM/PITR/告警送达/容量 quota receipts 并完成双人书面验收后才能执行。
  详见 [`BACKUP_AUTOMATION_RECOVERY_AND_COMMISSIONING.zh-CN.md`](BACKUP_AUTOMATION_RECOVERY_AND_COMMISSIONING.zh-CN.md)。

上述真实证据缺失时，backup automation 与生产灾备继续 **NO-GO**。
