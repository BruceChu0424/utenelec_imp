# 既有测试主机：内部 ERP 受控初始化与首次发布

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../simple/RUNBOOK.zh-CN.md)。

> 本手册只描述内部测试数据链路，不包含真实主机名、地址、账号、人员或密钥。
> 仓库中的脚本和测试通过不等于服务器已经执行。所有 `<占位符>` 必须来自受审交接，不能自行猜测。
> **2026-08-15 状态：本手册描述目标合同，当前工作树仍是未提交源码候选，禁止照抄命令上机。** 先按
> [完整续作交接](../ERP_INTERNAL_TEST_SERVER_CONTINUATION_HANDOFF.zh-CN.md) 第 5 节关闭源码门禁并重新
> 生成签名候选，再按本文执行。任何 builder/preparer/commissioner/updater 的 CLI 或 JSON schema 变化，
> 都必须同时更新生产者、全部消费者、测试和本手册。
> 当前还缺少
> [目标服务器带外身份与访问 authority 清单](../target-host-oob-authority.zh-CN.md)要求的 H01–H12，以及
> [GitHub 保护/签名 authority 清单](../release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)要求的受保护
> commit/tag、隔离签名 Environment 和 OSS readback。
> 本文命令块仅记录最终 CLI 合同；在新的只读刷新、精确计划/风险/回退复核和人工确认完成前，不得在目标机
> 执行写入、enable/start、数据库初始化、激活或 reboot。

## 1. 适用边界

本流程把已经完成 v3 NVMe `/data` 切换的空测试主机，依次收口为：

1. 内部测试运行时已安装但入口仍关闭；
2. PostgreSQL 16 空集群已由签名 migration-only JAR 迁移到同一签名发布目标；
3. 首次签名发布可以在一次受控事务中写入 `current`、启动并验证后端，再开启员工 HTTPS 入口。

所有结果都固定为 `dataClassification=discardable-test-only`、`productionAuthority=false`。
旧 pgBackRest 仓库和任务保持关闭，新集群固定 `archive_mode=off`、空 `archive_command`；因此本流程不允许
权威数据或正式业务数据进入，也不构成备份、PITR、UAT 或生产验收。

## 2. 总顺序与停点

```text
NVMe assess/plan/apply/late-finalize
  -> 审核标准签名 release 与主机源清单
  -> 主机运行时 prepare（同参数重跑即 resume）
  -> 无特权 updater stage + inspect
  -> DB commissioner assess
  -> 人工核对 assess 与签名 manifest
  -> DB commissioner apply（或 resume）
  -> 人工核对 onboarding/complete/committed pointer
  -> 首份本机恢复层 commissioner assess/record-plan/apply（或 resume）
  -> 核对新 full、WAL、check 与一次性 first-backup receipt
  -> 首次 activate --first-release --enable-on-boot
  -> 重启与故障注入验收
```

每个箭头都是停点。上一步没有终端 receipt、摘要不一致、存在 active/failure marker，或检查人员无法解释
某个字段时，停止并保留原始证据；不得删除、改写、移动或手工补 JSON。

当前证据层必须分开登记：源码候选仍在收口；受审提交/tag、CI 签名、OSS 不可变候选/readback、目标机
安装、首次激活和 HTTPS/UAT/故障/reboot 验收均尚未形成。任何前一层成功都不能代替后一层。

## 3. 前置只读评估

先按 `EXISTING_TEST_HOST_NVME_COMMISSIONING.zh-CN.md` 完成 NVMe 流程，并确认：

- 唯一 v3 `complete.json` 状态为 `COMMITTED_STORAGE_ONLY`；
- 同一事务的 `late-committed-finalization.json` 状态为
  `COMMITTED_STORAGE_ONLY_LIVE_VERIFIED`；
- NVMe `active.json` 已不存在；
- PostgreSQL、ERP、Nginx、watchdog、updater timer 和全部旧备份 unit 仍关闭；
- `/data/postgresql/16/main` 是已挂载目标 NVMe 上的空目录。

只读确认 Phase 4 已经提供通用、profile-neutral 的 staging 基座：专用无登录 updater 账号、固定 virtualenv、
两份相同 allowed-signers、root 管理的 OSS 凭据、operation lock、updater service/timer 均存在，service/timer
仍 inactive，timer 仍 disabled。此时**不要先 stage**：host preparer 会先用 reviewed source manifest 替换并固定
updater、guard、下载 wrapper、OSS helper/validator、service/timer 和 root activation/recovery wrapper；之后才允许
无特权下载候选。若任一基座缺失或权限不符，停在这里并回到受审 Phase 4 安装链，不能由操作员手工补文件。

## 4. 受审主机源清单

发布审核方必须提供 root-owned `0600` canonical JSON 清单及其独立传递的 SHA-256。清单固定绑定：

- 创建/失效时间和受控变更编号；
- preparer 自身摘要；
- systemd、环境/存储校验器、DB commissioner、release guard、updater、boot/DB/storage verifier、
  PostgreSQL internal-test 配置和 Nginx 模板的逐文件摘要；
- 固定 `launch-existing-host-installer.py` 以及其 allowlist 中恰好 18 个备份 source-bundle 文件的逐文件
  摘要；builder 必须从同一次稳定 fd 捕获的字节静态核对 launcher 内嵌的 installer SHA、固定目标路径、
  `0400/0500` 模式和完整 allowlist，不能 import 或执行任一备份资产；
- 固定 monitoring installer launcher 及其嵌入逐文件 SHA 的恰好 15 个 source-bundle 文件，以及 retention
  installer launcher 与恰好 10 个 source-bundle 文件；retention bundle 还必须把 runtime launcher 内嵌的
  updater/manager SHA、updater 内嵌的 guard SHA 绑定到同一批捕获字节；
- 目标文件的精确 preimage 摘要（目标不存在时为 `null`）；
- 三套 source-bundle 目标树各自的精确 inventory preimage；缺少、增加、符号链接、非单链接、owner/group
  或模式不符都不是可自动修复的 preimage；
- 内部 DNS、精确 RFC1918 办公网子网、`server.env` 摘要、TLS 证书/私钥摘要；TLS 叶证书必须显式包含
  与内部 DNS 完全相同的 DNS SAN（CN 或通配符不替代 exact SAN），并通过 root-controlled
  `/etc/ssl/certs` 系统 CA 库的 strict `sslserver` 链验证。

清单的 `kind` 必须为 `uten-imp-internal-test-reviewed-host-sources`。不得由服务器操作员临时手写、不得从
可变工作树事后计算摘要、不得在过期后开始新的变更。真实密钥只存在于固定 root 私密路径，不进入清单、
  命令、日志或聊天。

不得把可变快照中的 builder 直接交给 Python；即使只传 `--help`，Python 也会先执行其顶层字节，builder
事后自校验不能建立首次执行前的信任。审核方必须先通过独立通道审核
`launch-internal-test-reviewed-host-manifest-builder.py` 的 SHA-256，再从 root-controlled 只读发布快照把该精确
字节安装为固定的 `/usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher`。首次安装示例（路径已存在、
任一摘要或 metadata 不同均立即 NO-GO，不得原地覆盖）：

```bash
sudo /usr/bin/sha256sum \
  '<受审根快照>/setup/launch-internal-test-reviewed-host-manifest-builder.py'
# 先与独立传递的 launcher SHA-256 逐字核对，再继续。
sudo /usr/bin/test ! -e \
  /usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher
sudo /usr/bin/install --owner=root --group=root --mode=0500 \
  '<受审根快照>/setup/launch-internal-test-reviewed-host-manifest-builder.py' \
  /usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher
sudo /usr/bin/sha256sum \
  /usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher
sudo /usr/bin/stat --format='%U:%G %a %h %d:%i %n' \
  /usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher
```

固定 launcher 必须为 `root:root 0500`、单链接，且所有父目录均为 root-controlled、不可组/全局写；其安装后
SHA-256 必须再次与独立 authority 核对。launcher 只允许由固定系统 Python 的 `-I` 模式运行。它以
`O_NOFOLLOW` 打开 builder，读取前后绑定 fd 与 live pathname 的 dev/inode/nlink/mode/uid/gid/size/mtime/ctime，
校验独立 builder SHA-256，然后只 `compile/exec` 从同一 fd 取得的已验证内存字节；不按路径二次打开，也不通过
子进程运行 builder。先查看受审 builder 参数：

```bash
sudo /usr/bin/python3 -I \
  /usr/local/sbin/uten-imp-reviewed-host-manifest-builder-launcher \
  --builder '<受审根快照>/setup/build-internal-test-reviewed-host-manifest.py' \
  --expected-builder-sha256 '<独立审核的 builder SHA-256>' \
  -- --help
# 按 --help 中的固定 source/target、created/expires、domain/CIDR、TLS、server.env、
# allowed-signers 与 updater venv inventory 参数放在同一个 `--` 之后，生成
# root-only <reviewed-manifest.json>；不得自行再传 --expected-builder-sha256，launcher 会注入已验证值。
sudo /usr/bin/sha256sum '<reviewed-manifest.json>'
```

launcher 成功时只向 stderr 输出已绑定的 builder SHA/dev/inode/size，manifest stdout 不被混入。审核人与目标机
操作员通过独立通道逐字核对 launcher SHA、builder SHA、manifest SHA、创建/到期窗口和变更编号；不得把
`sha256sum` 输出和清单放在同一个可变传输包中，也不得使用已过期或尚未生效的窗口。已有 launcher 的升级或
回退必须作为独立受控变更，先记录 preimage SHA/metadata 并准备恢复该精确字节；本流程不得覆盖未知 preimage。

## 5. 主机运行时 prepare / resume

从受审 root-only 源快照运行 preparer。它没有“跳过检查”的参数；第一次调用是 apply，掉电后使用完全相同
的参数重跑即是 evidence-bound resume：

```bash
sudo /usr/bin/python3 -I '<受审根快照>/setup/prepare-existing-test-host-internal-runtime.py' \
  --domain '<内部 DNS 名称>' \
  --office-cidr '<精确 RFC1918 子网>' \
  --tls-cert '<固定 TLS 目录中的证书>' \
  --tls-key '<固定 TLS 目录中的私钥>' \
  --approval-reference '<受控变更编号>' \
  --expected-preparer-sha256 '<preparer SHA-256>' \
  --source-manifest '<root-only reviewed manifest>' \
  --expected-source-manifest-sha256 '<reviewed manifest SHA-256>' \
  --expected-server-environment-sha256 '<internal server.env SHA-256>' \
  --expected-server-environment-preimage-sha256 '<Phase4 prod server.env SHA-256>' \
  --expected-allowed-signers-sha256 '<reviewed allowed-signers SHA-256>' \
  --expected-updater-venv-inventory-sha256 '<reviewed venv inventory SHA-256>'
```

成功后必须同时核对：

- `/var/lib/uten-imp-internal-test-host-preparation/active.json`；
- 其指向事务的 `complete.json` 和 `mutation-authorized.committed.json`；
- `/var/lib/uten-imp-release/internal-test-runtime-contract.json`；
- `entryEnabled=false`、`productionAuthority=false`；
- 唯一 enabled Nginx 链接、`nginx -T` 摘要、附件目录 receipt、旧备份关闭 receipt、storage complete/late
  receipt 摘要都与 runtime contract 一致；
- ERP、Nginx、watchdog 与自动 updater timer 仍未启动。
- `/usr/local/sbin/uten-imp-existing-backup-installer` 为 `root:root 0500` 单链接；
  `/usr/local/share/uten-imp-backup-installer-source` 及其中 `deploy` 子目录全部为 `root:root 0500`，且
  launcher allowlist 对应的 18 个文件恰好存在、均为 `root:root 0400` 单链接，逐文件摘要与 reviewed
  manifest、事务 source snapshot 和 plan 完全一致；不得存在第 19 个对象。
- `/usr/local/sbin/uten-imp-existing-monitoring-installer` 与
  `/usr/local/sbin/uten-imp-release-retention-installer` 均为 `root:root 0500` 单链接；对应固定 share 根的
  15 个和 10 个 allowlist 文件恰好存在、均为 `root:root 0400` 单链接，目录为 `root:root 0500`，没有额外对象。
- Phase4 `/etc/nginx/conf.d/uten-imp.conf` 已按 reviewed preimage 原子归档，live 路径不存在，且
  `nginx -T` 的完整 server/listener/forwarding 图只包含受审 internal-test 模板。
- `/var/lib/uten-imp-release` 仍为 `root:uten-imp-updater 0750`，固定 `operation.lock` 为
  `root:uten-imp-updater 0660`；专用 updater 身份能够遍历并取得同一 inode 的 flock。

若 `mutation-active.json` 仍存在，或 live/committed mutation authority 同时存在，停机保留证据；不得复制
任一文件去“补齐”另一状态。

本步只原子安装三套受审 launcher 与惰性的 root-only source bundle，并在每套完整 bundle 落盘后最后发布
该套 launcher。preparer 不运行任何 launcher/installer，不写 pgBackRest repo 或 monitoring/retention policy，
不执行 stanza-create/check/full/WAL，不启动或 enable 任一 backup、monitoring 或 retention service/timer。
首次本机恢复层必须在 DB onboarding 完成后，另按
[`INTERNAL_TEST_FIRST_BACKUP_COMMISSIONING.zh-CN.md`](../postgres/backup/INTERNAL_TEST_FIRST_BACKUP_COMMISSIONING.zh-CN.md)
持锁执行；不要用本节的安装完成状态冒充备份、恢复验证或生产 authority。

## 6. 标准签名候选 stage / inspect

host preparation 终端完成后，才用固定 systemd service 进行一次手工 staging。OSS 凭据只由 systemd 注入，
不能进入命令行：

```bash
sudo /usr/bin/systemctl start uten-imp-updater.service
sudo -u uten-imp-updater /opt/uten-imp/updater/venv/bin/python -I \
  /opt/uten-imp/updater/release_updater.py inspect '<签名版本>'
```

必须核对 `inspect` 显示的签名 key、version、sequence、commit、artifact/JAR 摘要和完整 Flyway inventory。
自动 updater timer 继续 disabled；此步骤只下载、验签和检查，不发布 `current`、不启动服务、不接触数据库。

## 7. 数据库 assess / apply / resume

主机准备终端完成后，DB commissioner 才能运行。下面的 CLI 是唯一 dispatcher；它在发布 root-only
request 前先验证 static worker 的 FragmentPath、无 drop-in、ExecStart、sandbox、KillMode=control-group、
listener/entry/pre-DB 合同。`worker` 子命令仅供固定 systemd unit，禁止操作员直接执行。先做只读 assess：

```bash
sudo /usr/bin/python3 -I /usr/local/sbin/uten-imp-existing-test-host-db-commissioner \
  assess --version '<签名版本>'
```

审核输出中的版本、release sequence、commit、signing key、server/migrator JAR 摘要、Flyway head、完整
migration-set 摘要、runtime contract 摘要和 storage receipt 摘要。任何一项与 `inspect` 不同都停止。

核对后执行一次：

```bash
sudo /usr/bin/python3 -I /usr/local/sbin/uten-imp-existing-test-host-db-commissioner \
  apply --version '<签名版本>' \
  --approval-reference '<受控变更编号>'
```

命令中断或主机重启后，不运行 `initdb`、psql 或 JAR 的手工补救；使用同一版本和同一批准编号：

```bash
sudo /usr/bin/python3 -I /usr/local/sbin/uten-imp-existing-test-host-db-commissioner \
  resume --version '<同一签名版本>' \
  --approval-reference '<同一受控变更编号>'
```

commissioner 会在固定 release lock 与 DB maintenance lock 内重新验证 storage、candidate 签名、initdb
generation、迁移 terminal、live Flyway、system identifier/timeline、角色/成员关系/owner/ACL、
`archive_mode=off` 和空 `archive_command`。它不会开启员工入口或备份任务。
apply/resume 的 `dispatcher` 只是外部 `systemctl` 客户端：它提交 root-only exact request，由 PID 1 启动并持有
`uten-imp-internal-db-commissioner.service` 的固定 worker cgroup；直接运行 initdb、psql、Java migrator 或隐藏
worker 子命令均属 NO-GO。dispatcher 被 SIGKILL 不会隐式杀死 PID-1-owned worker；固定 unit 的
`KillMode=control-group` 负责收容 worker 自己的全部子进程。之后只允许以同参数 resume 重入，并继续或采纳该
exact request 已持久化的 terminal，不得启动第二个 worker 或另造 request。

成功后必须核对：

- `/var/lib/uten-imp-release/internal-test-onboarding.json`；
- 事务 `complete.json` 状态为 `COMMITTED_AWAITING_FIRST_ACTIVATION`；
- `active-pointer.committed.json` 的四个字段精确绑定同一 transaction manifest；
- live DB identity 与 onboarding、migration terminal 一致；
- DB commissioner 的 live `active.json` 已被原子归档，不再存在；
- `remainingNoGo` 仍包含权威数据、备份恢复和业务 UAT。

## 8. 首次受控激活

开始本节前必须已经按备份 commissioning 手册得到同一签名 candidate/DB identity/Flyway 的 terminal receipt
和未过期一次性 `first-backup.json`。updater 会以稳定 fd 重验并在 active/runtime authority 双提交后才归档消费；
手写、复制、重放或仍缺 full/WAL/check 的 receipt 都必须保持入口关闭。

若 commissioner 已把过期 onboarding 标记为 `EXPIRED_AWAITING_REAUTH`，不得重跑数据库初始化或手改时间。
只能由固定 DB commissioner 的 `reauthorize-activation` 路径在入口关闭、live DB/runtime/storage/candidate 全部
重验且两把锁均持有时签发短时、一次性的 activation-only authority；激活器必须消费其精确摘要。该路径不改
PostgreSQL、不安装 release、不启服务，也不能替代首份备份 gate。未过期 onboarding 不得走再授权路径。

重新运行 updater `inspect`，从签名 manifest 逐字复制版本、Flyway head 和 migration-set SHA。确认无人正在使用
测试系统后，才运行固定 root wrapper：

```bash
sudo /usr/local/sbin/uten-imp-activate '<签名版本>' \
  --confirm-version '<同一签名版本>' \
  --confirm-flyway '<签名 Flyway head>' \
  --confirm-flyway-digest '<签名 migration-set SHA-256>' \
  --confirm-session-clearance \
  --first-release \
  --enable-on-boot
```

不要加入 `--approve-database-change`；空库 onboarding 已经由 commissioner 证明精确到目标。首次激活在同一
锁事务内重验 live DB 和 runtime contract，消费一次性 onboarding，健康检查成功后才写 `active.json`、
`runtime-authority.json` 并开启 boot/入口。掉电后保留 adoption/activation marker，按 updater 的
`recover interrupted-assess` 或 `recover assess` 输出执行受控恢复；不得直接重跑普通 activate。
恢复提交后会留下 root-only `recovery-ingress-finalizing.json`。Nginx 的 fatal `ExecStartPost` 由 PID 1
完成 backend/static/version 与两个 watchdog probes，全部通过后才写 terminal receipt 并清 finalizing；unit
固定 `Restart=no`，因此任一 ExecStartPost 非零退出都只形成一次失败的 start transaction 并保持入口关闭，
不是由某个特殊退出码决定是否重启。finalizing 存在时所有后继 updater/watchdog mutation 均必须拒绝。

## 9. 立即 NO-GO 的情况

- 任何真实数据、正式数据或需要保留的数据已经进入该库；
- NVMe active pointer 未清、`/data` 未挂载、UUID/LV/PV/NVMe 身份漂移或 PGDATA 不为空；
- reviewed manifest 过期、摘要不同、源码或目标 preimage 漂移；
- host preparation terminal、runtime contract、DB complete/committed pointer 任一缺失或多份；
- 旧备份 job 正在运行，或旧 backup/health/timer 仍可用；
- 签名候选、Flyway inventory、JAR、system identifier、timeline、角色/ACL 或 archive 设置漂移；
- PostgreSQL `start.conf`、meta/instance enablement 或 Ubuntu systemd generator 的真实状态未通过目标机
  重启验证；
- activation/recovery/boot-enablement/adoption marker 无法由固定 verifier 解释；
- TLS、内部 DNS、CORS、精确办公子网或 Nginx effective configuration 不一致。
- builder 自身没有在执行前由外部可信 snapshot 校验，或 prospective Nginx expanded configuration 没有
  独立 reviewed authority；目标机事后运行 `nginx -T` 不能批准自身。
- finalizing、worker request、activation/recovery marker 或共享 operation lock 不能形成唯一可解释状态；
  任何 mutation 入口在这些状态下仍能写文件、启动 unit 或改数据库。
- root helper 在摘要后又从可变路径 import/exec，或 producer/consumer 的 schema、canonical digest、固定
  SHA、TLS/Nginx/runtime contract 任一尚未完成 leaf-to-root 冻结。

<!-- INTERNAL-TEST-NEW-MIGRATION-HARD-NO-GO -->
新的 Flyway migration-set 仍保持硬 NO-GO，直到另有签名 from-to rehearsal/backup/UAT/PITR producer。
同一 migration-set 的后续更高 sequence 发布仍必须走标准 stage、inspect、activate 和每次 boot verifier，
不能把本手册中的首次 onboarding receipt 重放为第二次授权。

## 10. 服务器验收仍需完成

源码测试全绿后，目标 Ubuntu 24 主机仍必须实际验证：PostgreSQL generator/unit 状态、关机再开机、
`/data` 缺失、错误 UUID、DB/ACL/archive 漂移、密钥缺失、错误 profile、Nginx 配置漂移和健康检查失败时
入口全部保持关闭。完成独立备份 commissioner、首份新 system identifier 全备、异机恢复、UAT 和正式审批
以前，本主机只能标记为“内部测试”，不能标记为“生产可用”。

目标机还必须执行并留存以下不可由 CI/PID1 模拟替代的证据：全部安装后 unit 的
`systemd-analyze verify` 与 `systemctl show` effective properties；以 updater 身份遍历 release state/非阻塞
flock；确认 80/443/8080/8081 无未管理 listener；分别在 commissioning worker、recovery finalizing 写入前后、
Nginx start/ExecStartPost 探针中 SIGKILL/reboot，证明 systemd cgroup 收容、`Restart=no` 下所有 start failure
均无 restart loop、boot verifier 能采用 exact terminal receipt或恢复 activation-failed gate。不得在真实数据
主机做这些故障注入。
