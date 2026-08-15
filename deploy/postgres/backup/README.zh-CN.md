# ERP PostgreSQL repo2、PITR 与外部告警合同

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260812 -->
> 2026-08-12 的最后只读快照显示 repo1 full timer 当时为每天 02:17；该状态尚未通过当前 OOB authority
> 和新只读会话刷新。用户指定的 03:00 是未来正式使用后的维护/自检
> 窗口，不是备份时间。下面 repo2 03:17 模板会与该窗口冲突，且真实 repo2/WORM/commissioner 尚未验收，
> 因而必须继续 disabled。启用前须根据真实 repo1 时长和维护内容重新排程，使备份、维护、repo2 与 health
> 不重叠。03:00 时若 repo1/expire 仍在运行，维护必须跳过/顺延，不能终止备份；必须先取得同一数据库维护
> 互斥锁。SMART 长测、RAID check、apt 更新和重启也不能与 backup/expire 并发。实时服务器状态见
> `../../current-test-server-status.zh-CN.md`。
> 首次连接前必须先按
> [目标服务器带外身份与访问 authority 清单](../../target-host-oob-authority.zh-CN.md)完成 H01–H12；只读
> 刷新、备份安装、repo2 commissioning 和 timer enable 是四个独立授权阶段。

> 当前状态：仓库内校验器、候选渲染器、双仓健康门禁、告警 spool 和 systemd 模板可在隔离环境验收；
> **真实 repo2、对象锁/WORM、连续 WAL、7 个成功恢复点、外部告警送达和 PITR 业务恢复仍是 NO-GO**。
<!-- REAL-REPO2-WORM-PITR-ALERTS-NO-GO -->
> 本目录不会连接云端，也不会安装或启用生产配置。不得把模板/单元测试通过登记为灾备完成。

## 1. 已收口的边界

- repo1 仍是 `/data/backups/pgbackrest` 本地快速恢复层，与数据库处在同一故障域，不算灾备；
- repo2 使用 pgBackRest 官方多仓库能力。`archive-async=y` 时 WAL 会发送到所有已配置仓库，full
  backup 必须分别调度，因此 repo2 模板有单独的每日 `03:17` full timer；旧基线 repo1 `02:17` 只作为
  排程输入，commissioning 前必须按 live timer/readback 重新确认；
- repo2 配置固定为 TLS 验证、S3 兼容接口、独立访问凭据、独立 `aes-256-cbc` cipher、full-count
  保留和对应 WAL；保留单位是成功 full 链，不按对象时间或文件名自行删除；
- repo2 backup 显式关闭内建 auto-expire，仅在 full 成功后由同一 oneshot 的 `ExecStartPost`
  对 repo2 执行一次 policy-bound `expire`，避免失败备份触发清理或重复 expire；
- repo2 unit 排在现有 repo1 unit 之后，health 又排在两个 backup unit 之后；掉电重启导致两个
  `Persistent` 日任务同时补跑时，先完成本地 full，再执行异地 full，最后采集 health，避免互相争锁；
- 每日 repo2 backup 在真正写入前运行 pgBackRest `check`，检查已配置仓库及归档路径；5 分钟
  `pgbackrest_health.py` 只读 repo1/repo2 JSON inventory 与 `pg_stat_archiver`，不重复执行 archive-path
  probe。只有双仓各至少 7 个成功 full、
  最新 full 不超过 36 小时、最近 WAL 成功不超过 15 分钟、最新失败未晚于最新成功、双仓最新 WAL
  一致且都不落后于本次采样前 PostgreSQL 已成功归档的 `last_archived_wal` 时才返回 PASS；
- pgBackRest 官方明确说明 inventory 的 min/max 之间可能因保留或其他原因存在 gap；因此该健康检查
  只证明当前归档进程新鲜、两仓最新 WAL 一致，不声明 repository check 或整个历史区间无 gap。
  它也不证明 provider WORM 或某个业务时间点可恢复。每月隔离 PITR、每季度业务级
  财务/库存/生产/销售/采购/审计/附件对账仍必须使用 `deploy/setup/drill-restore.sh` 和批准基线留证；
- 多仓库下每次 full 必须显式选择 repository。现有 Phase 2 repo1 unit 必须先受审安装
  `uten-pgbackup-repo1-override.conf.example`，把 backup/expire 固定为 `--repo=1`、只在成功 full 后 expire，
  并接入 `OnFailure`；完成后所有 backup/health unit 失败才都进入 root-only
  durable alert spool。外部 sender 返回 0 还不够，必须
  写入与 eventId 绑定的收件 receipt，事件才会从 `pending/` 原子移到 `delivered/`；没有 sender、
  超时、receipt 错误或断网时事件保留并由 5 分钟 timer 重试；错误 receipt 保存在 root-only
  `rejected/`，sender 已写 receipt 后掉电则从 `work/` 幂等续完，均不要求管理员删 marker。

pgBackRest 官方参考：
[多仓库与 WAL 行为](https://pgbackrest.org/user-guide.html)、
[稳定 JSON `info` 输出](https://pgbackrest.org/command.html)、
[repo/S3/retention 配置](https://pgbackrest.org/configuration.html)。具体生产版本必须在只读审计后锁定；
数据库主机和远程 repository host（如采用）必须使用完全相同的 pgBackRest 版本。

## 2. 三类输入（都不进入 Git）

从三个 `.example.json` 建立私有文件：

1. `repo2-policy.json`：不含秘密，登记 bucket/endpoint/prefix、7 个恢复点、WAL/full 新鲜度；
2. `repo2-secrets.json`：独立 repo2 访问 key/secret 和 cipher pass；只能 `root:postgres 0640`，
   不得粘贴到命令、日志、工单或聊天；cipher 必须另行离线密封托管；
3. `worm-evidence.json`：第二名审核人通过 provider 控制面/API 只读核验版本控制、不可变保留期、
   独立凭据和独立故障域后的 receipt。正文只放私有证据引用，不放凭据。其 SHA-256 必须通过
   带外批准渠道获得并逐字传给校验器。

example 文件故意含 `REPLACE`，校验器必定拒绝。commissioning policy、WORM evidence 为
`root:root 0600`，secrets 为 `root:postgres 0640`，均必须是非 symlink、单硬链接普通文件。安装时
另复制一份**不含秘密**的 runtime policy 到 `/etc/uten-imp-backup/repo2-policy.json`，并复制经带外
摘要核验的 WORM receipt 到 `/etc/uten-imp-backup/worm-evidence.json`；两者固定
`root:postgres 0640`，供 `postgres` 身份的 health/preflight 只读。WORM receipt 只能含
provider/bucket、验证状态、证据引用和审批元数据，绝不能含凭据；不得让 health 读取 commissioning
目录或任何秘密文件。

`pitr-acceptance.example.json` 是独立 repo2 恢复后的业务验收信封。它必须绑定 PostgreSQL
`system_identifier`/source timeline、真实 backup set 与 WAL 范围、指定 target time、
`drill-restore.sh` 生成的 restore receipt SHA-256、真实 RTO/RPO，以及财务、库存、生产、销售、采购、
审计和附件七类证据。任一类不能是 PASS 时不得生成 backup acceptance receipt。

## 3. 默认只读验证与候选渲染

以下形状只用于已批准的隔离/管理主机；不要把真实 secret 放进 shell 参数：

```bash
sudo /usr/bin/python3 -I pgbackrest_repo2.py validate \
  --policy /root/backup-commissioning/repo2-policy.json \
  --secrets /root/backup-commissioning/repo2-secrets.json \
  --worm-evidence /root/backup-commissioning/worm-evidence.json \
  --expected-worm-evidence-sha256 '<64-lowercase-hex>' \
  --strict-files
```

输出只能是 `VALIDATED_CANDIDATE_INPUTS_ONLY`，并明确 `productionChanged=false`、
`remoteProviderContacted=false`。渲染到全新、root 私有的非 `/etc` 候选文件还需精确确认：

```bash
sudo /usr/bin/python3 -I pgbackrest_repo2.py render-candidate \
  --policy /root/backup-commissioning/repo2-policy.json \
  --secrets /root/backup-commissioning/repo2-secrets.json \
  --worm-evidence /root/backup-commissioning/worm-evidence.json \
  --expected-worm-evidence-sha256 '<64-lowercase-hex>' \
  --strict-files \
  --output /root/backup-commissioning/20-uten-imp-repo2.conf.candidate \
  --confirm 'RENDER VERIFIED UTEN PGBACKREST REPO2 CANDIDATE'
```

工具拒绝覆盖、拒绝向 `/etc` 写、从不把候选内容或 secret 打到 stdout。候选 SHA-256、配置 diff、
pgBackRest 版本、当前 `/etc/pgbackrest.conf` SHA-256、归档积压、磁盘容量、网络出口和回退方案必须
进入变更单。此步骤仍未安装。

## 4. 生产安装/启用前门禁

必须先只读取得并由两人复核：

- 当前主库身份、`SHOW archive_mode/archive_command/archive_timeout`、`pg_stat_archiver`、
  `pgbackrest version/info/check`、repo1 最近 7 个成功 full 与 WAL；
- `/etc/pgbackrest.conf`、默认 include path、`/var/spool/pgbackrest`、现有 backup timer/unit 的准确
  owner/mode/SHA-256；RAID 同步、SMART、`/data` 和根分区容量；
- repo2 bucket/prefix 为专用且为空或已明确归属；TLS/DNS/出口、最小权限凭据、版本控制、WORM
  保留期、容量/费用/告警和 cipher 离线 escrow；
- 变更窗口、审批编号、配置 preimage 的 root-only SHA-256、停止写入方案和恢复主机容量。

现有主机不得重跑 Phase 2。固定 runtime 与完整 backup/health/alert unit 的受控安装使用
[`EXISTING_HOST_INSTALLER.zh-CN.md`](EXISTING_HOST_INSTALLER.zh-CN.md)：先执行零落盘的 `assess`，审批后
`record-plan` 才是第一次写入，再以固定 plan SHA-256 和逐字确认执行 `apply`。安装器保存 root-only
preimage/事务证据，只执行 `daemon-reload`，并严格验证 loaded `FragmentPath`、空 `DropInPaths`、
全部 timer disabled/inactive；它不会启动、停止、启用或禁用 PostgreSQL、backup、health 或 alert unit。
所有 action 必须经固定 root-only 启动器消费已捕获且匹配内嵌 SHA-256 的安装器字节；禁止直接运行或
import 源码包中的安装器。启动器与安装器摘要、完整源码包清单及旧版本 preimage 是三个独立审核/升级边界。
systemd 依赖不能在 drop-in 中用空赋值可靠清除，因此 repo1 必须安装受审的**完整 unit replacement**，
不能再依赖旧的 repo1 override 清除 `Requires=`。

该安装器故意不写 `/etc/pgbackrest*`、repo2 secret/policy/WORM evidence、alert provider/sender 或任何
commissioning marker。真实 repo2 候选仍须先把精确目标、配置 preimage、风险和回退方案告诉负责人并
取得单独确认，再由后续受审变更原子安装为 `/etc/pgbackrest/conf.d/20-uten-imp-repo2.conf`
（`root:postgres 0640`）；不得覆盖 `/etc/pgbackrest.conf`。

既有 internal-test 新集群从 archive-disabled onboarding 终态建立第一份本机 full + WAL，必须走
[首份本机恢复层 commissioning](INTERNAL_TEST_FIRST_BACKUP_COMMISSIONING.zh-CN.md)。该流程的 terminal
receipt 仍明确不是 restore proof 或 production authority，且不会启用任何 backup timer。
Phase 2 可能遗留的 `/etc/uten-imp/templates/pgbackrest-offsite-repo2.conf.example` 只是未启用提示，
不含本目录的 WORM/审批/read-back 门禁，禁止把它直接提升为活动配置。

首次联机时先保持所有新 timer disabled，人工执行 `stanza-create`/`check`、一次 repo2 full、`info
--repo=2 --output=json` 和隔离 restore。若任何检查失败，立即移除尚未批准启用的 repo2 drop-in、恢复
配置 preimage，确认裸 `pgbackrest check` 和 repo1/WAL 仍正常；不得运行 `expire`、删除远程对象或清理
本地 WAL spool 来“修复”。因为加入 repo2 后 archive-push 会触达远程仓库，安装本身就是生产写操作。

只有 WORM 真实证据、repo2 full/restore、外部告警 receipt 和批准通过后，才按
`repo2-enabled.approved.example.json` 创建 `root:postgres 0640` 的
`/etc/uten-imp-backup/repo2-enabled.approved`。它绑定 runtime policy、secret-bearing config、repo1
完整 unit（审批 JSON 为兼容既有 schema 仍使用 `repo1OverrideSha256` 字段）和 WORM evidence 四个
SHA-256、审批/复核人及最长 31 日有效期。backup/health 每次运行前都执行
`validate-active`；它每次重新读取 WORM receipt，核对有效期、策略字段和审批摘要。marker/WORM
缺失或过期、owner/mode 错误或任一 digest 漂移会失败并进入外部告警，不能
像 systemd Condition 一样静默跳过。证据驱动的 transaction/reconcile 与 commissioner 操作见
[`BACKUP_AUTOMATION_RECOVERY_AND_COMMISSIONING.zh-CN.md`](BACKUP_AUTOMATION_RECOVERY_AND_COMMISSIONING.zh-CN.md)。
commissioner 严格按以下阶段，每次调用只推进一步：

1. `uten-pgbackup-alert-drain.timer`；注入 sender 断网/坏 receipt，确认 pending 保留，恢复后 receipt 到达；
2. `uten-pgbackup.timer`；先验证 repo1 full、成功后 expire、容量门禁以及掉电后不重复 full；
3. `uten-pgbackup-health.timer`；以只读方式持续观察双仓 WAL，并验证超 15 分钟/缺 repo2/少于 7 点
   都会报警；确认报告始终明确 `repositoryCheckPerformedByThisRun=false`；
4. `uten-pgbackup-repo2.timer`；执行重启、断网、掉电后 `Persistent=true` catch-up 和不重复破坏性任务测试。

前 7 个**不同日期**的成功 full 尚未形成时，健康门禁应持续 FAIL，这是正确的 NO-GO，不得降低阈值或
伪造 7 次同日备份。最近 7 个成功恢复点必须在 repo1 和 repo2 都可见；每日 full 失败由新鲜度告警，
不能用盲删旧备份或手工 `expire` 掩盖。

`backup_acceptance.py` 是最终 receipt writer。它只在 POSIX root、固定 root-only 目录运行，并要求：

- 重新执行一次 `validate-active`，把当前 policy、secret-bearing config、WORM receipt 与启用审批的
  SHA-256/有效期重新绑定；健康报告本身不能替代这次最终 preflight；
- 15 分钟内的双仓 PASS health（含 `system_identifier`、timeline、7 个不同 UTC 日期 backup set/WAL、
  canonical `flyway_schema_history` SHA-256、签名 head/count）；
- root-installed release guard 对 manifest/signature/allowed_signers 的验签结果；health 中当前数据库的
  每一行 Flyway `version/script/checksum` 投影必须与 guard 输出逐字一致，manifest 的 migration-set
  SHA-256、head/count 也必须与目标一致；
- 当前有效且带外 SHA-256 匹配的 WORM evidence；
- 已投递 event 和 provider receipt 两个 SHA-256 均匹配，receipt 在 31 日内；
- 31 日内的 `drill-restore.sh` restore receipt，以及从 repo2 选择当前 7 个恢复点之一完成的 PITR/业务
  acceptance；restore receipt 必须逐字绑定同一个 repo2 backup set 和同一个非 `latest` target time；
- 受保护签名发布的 version、Flyway head/count 和 migration-set SHA-256，以及变更审批引用。

实际参数只能在真实只读审计后由第二审核人从 receipt/签名发布证据逐字生成；接口形状如下，任何
SHA-256、版本、文件名或确认短语不精确都会失败：

```bash
sudo /usr/bin/python3 -I /usr/local/libexec/uten-imp-backup/backup_acceptance.py \
  --expected-worm-evidence-sha256 '<64-lowercase-hex>' \
  --expected-health-report-sha256 '<64-lowercase-hex>' \
  --alert-event /var/lib/uten-imp-backup-alerts/delivered/ID.json \
  --expected-alert-event-sha256 '<64-lowercase-hex>' \
  --alert-receipt /var/lib/uten-imp-backup-alerts/receipts/ID.json \
  --expected-alert-receipt-sha256 '<64-lowercase-hex>' \
  --restore-receipt /var/lib/uten-imp-release/database-receipts/RESTORE.json \
  --expected-restore-receipt-sha256 '<64-lowercase-hex>' \
  --pitr-acceptance /var/lib/uten-imp-backup/pitr-acceptance/PITR.json \
  --expected-pitr-acceptance-sha256 '<64-lowercase-hex>' \
  --trusted-release-manifest /ROOT_CONTROLLED_EVIDENCE/manifest.json \
  --expected-release-manifest-sha256 '<64-lowercase-hex>' \
  --trusted-release-signature /ROOT_CONTROLLED_EVIDENCE/manifest.sig \
  --expected-release-signature-sha256 '<64-lowercase-hex>' \
  --approval-reference '<approved-reference>' \
  --target-version '<vYYYY.MM.DD-N>' \
  --flyway-head-version '<signed-head>' \
  --flyway-migration-count '<signed-count>' \
  --flyway-migration-set-sha256 '<signed-64-lowercase-hex>' \
  --detail-name '<new-detail-name.json>' \
  --database-receipt-name '<new-backup-receipt-name.json>' \
  --confirm 'WRITE VERIFIED UTEN BACKUP ACCEPTANCE RECEIPTS'
```

它用 O_EXCL/`0600`/fsync 先写详细 receipt 到固定
`/var/lib/uten-imp-backup/acceptance-receipts/`，详细 receipt 保留 system identifier、timeline、
backup set、WAL、active repo2 policy/config/approval digest、canonical Flyway digest、非秘密 WORM 元数据、
WORM/alert/PITR/business evidence digest；再写 recovery helper
兼容的窄 `receiptType=backup` receipt 到 `/var/lib/uten-imp-release/database-receipts/`。窄 receipt 的
`evidenceReference` 只引用固定详细路径及其 SHA-256。任一已存在文件都拒绝覆盖；若窄 receipt 写入失败，
详细 receipt 留作失败证据，不删除 marker 或伪造成功。命令的所有 SHA-256 必须由第二审核人带外核对；
具体命令参数只在真实只读审计和变更批准后生成，不能照抄 example。

## 5. 外部 sender receipt 合同

固定 root-owned 程序 `/usr/local/libexec/uten-imp-alerting/submit` 接收：

```text
submit --event-file /var/lib/uten-imp-backup-alerts/pending/ID.json \
       --receipt-file /var/lib/uten-imp-backup-alerts/work/ID.receipt.json
```

sender 不得修改 event；成功送到企业值班渠道后，以 `0600` 单硬链接普通文件新建 receipt：

```json
{"schemaVersion":1,"eventId":"与事件完全一致","accepted":true,"deliveredAtUtc":"2026-08-12T00:00:00Z","providerMessageId":"provider-unique-id"}
```

stdout、返回码或本机 journal 不是外部送达证据。验收要保存断网 pending、恢复重投、provider 消息、
receipt SHA-256 和值班人员确认；event 只含失败摘要/health digest，不含凭据、连接串或业务数据。

## 6. 最终 GO 证据

- 双仓连续 WAL 与各自最近 7 个不同日期成功 full；对象锁无法由备份写入身份解除；
- repo2 任意选择的 full + WAL 在隔离主机完成 PITR，达到签名 Flyway head/count/checksum；
- 财务、库存、生产、销售、采购、审计、附件及应用 PGP/HMAC 恢复材料对账，记录真实 RTO/RPO；
- 每日 backup、5 分钟 health、外部 alert receipt、RAID/SMART/容量/证书/服务监控均真实运行；
- 数据库主机断网、repo2 故障、archive spool 增长、备份失败、重启/掉电、恢复失败均经过演练并留证。

任一项缺失时，生产灾备继续 **NO-GO**。
