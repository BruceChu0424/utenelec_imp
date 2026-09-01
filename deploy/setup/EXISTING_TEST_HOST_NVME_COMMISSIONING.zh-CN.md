# 现有内部测试服务器：NVMe `/data` 安全切换

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../simple/RUNBOOK.zh-CN.md)。

> 当前仓库候选已经实现并离线验证两阶段无人值守恢复、root gate-authorizer、`systemd-analyze verify`
> 以及 SIGKILL/掉电/重启状态故障注入；这仍然只是**尚未部署的源码候选**，不是服务器执行证据。
> 上机前必须重新取得目标主机的 `assess`/`plan`、核对 plan SHA 和受控批准编号；服务器执行后还必须保留完整 evidence，
> 并在数据库/应用桥接完成后做一次真实重启验收。
> **2026-08-15 暂停线：** 当前缺少
> [目标服务器带外身份与访问 authority 清单](../target-host-oob-authority.zh-CN.md)要求的 H01–H12，且
> [GitHub 保护/签名 authority 清单](../release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)要求的签名发布
> candidate 尚未形成。下列命令块只描述最终 CLI 合同，不是对当前目标机的执行授权；
> 在新的只读刷新、精确计划/风险/回退复核和人工确认完成前，不得运行任何写入、enable/start 或 reboot 命令。
> 当前只有源码候选；受审提交/tag、CI 签名、OSS readback、目标机安装/receipt 与真实 reboot 验收均未形成。

本工具只适用于由执行人通过 `--expected-hostname` 明确绑定的已审计内部测试主机；仓库不保存真实主机名。它把 ERP 数据盘从旧的
`/dev/md0` 切换到 NVMe LVM，但不会部署官网，也不会初始化业务数据库、创建账号、执行
Flyway、删除旧数据库、擦除机械盘或停止 RAID 阵列。

## 固定结果

- 在 `ubuntu-vg` 创建一个固定 350 GiB 的线性 LV：`ubuntu-vg/uten-data`；
- 完成后 VG 必须仍保留至少 20 GiB 未分配空间；
- 新 LV 格式化为标签为 `uten-data` 的 ext4，并通过 UUID 挂载到 `/data`；
- `/etc/fstab` 使用 `rw,nodev,nosuid,noexec,nofail,x-systemd.device-timeout=30s`，仅在根 LV 所在 NVMe 仍可用而
  数据 LV/文件系统挂载失败时避免 `/data` 阻断启动；整块 NVMe 物理故障会同时失去根系统，不能承诺远程维护；
- PostgreSQL unit 同时安装严格的 `/data` 挂载点、ext4 类型和 UUID 前置校验，并把 Debian cluster
  `start.conf` 保留注释后切换为 `manual`；因此 `nofail`
  不会允许 PostgreSQL 错写根分区下面的空 `/data` 目录；
- `/data/postgresql/16/main` 只创建为空目录并交给 `postgres`，不会执行 `initdb`；
- PostgreSQL、备份、ERP、Nginx 和旧 Phase 1 resume 在成功边界仍保持 disabled/inactive，等待
  下一阶段完成数据库初始化、角色、迁移、备份和入口验收后再启用；
- 旧 md RAID 保持 assembled，只解除 `/data` 挂载，不 wipe、不 stop、不当作新的备份权威。

这只是“内部测试存储已准备”的边界，不是生产 GO。单块 NVMe 仍是单点故障；正式数据进入前
必须有另一个故障域中的可恢复备份，最好再增加第二块适合服务器的 SSD。

## 三步调用

先在受控临时目录校验发布方提供的 SHA-256，再用 `sudo install -o root -g root -m 0700` 复制到只允许 root
写入的固定哈希路径；`apply` 会拒绝用户可写、硬链接或非 root-owned 的脚本。以下命令里的 `<root安装副本>`
必须指向该副本，所有 Python 调用都使用隔离模式 `-I`：

先把通过 SSH 上传的文件保持为上传用户所有、`0600`、单硬链接，再执行一次固定 SHA 的 root 安装（占位符必须替换）：

```bash
b='/home/<ssh-user>/existing-test-host-nvme-commissioner.py'
h='<发布方提供的脚本 SHA-256>'
u='<ssh-user>'
sudo /bin/bash -c 'set -Eeuo pipefail; umask 077; b=$1; h=$2; u=$3; test -f "$b"; test ! -L "$b"; test "$(/usr/bin/stat -c %U:%a:%h "$b")" = "$u:600:1"; test "$(/usr/bin/sha256sum "$b" | /usr/bin/cut -d" " -f1)" = "$h"; d="/root/uten-imp-commissioning/nvme-$h"; /usr/bin/install -d -o root -g root -m 0700 "$d"; /usr/bin/install -o root -g root -m 0700 "$b" "$d/commissioner.py"; test "$(/usr/bin/sha256sum "$d/commissioner.py" | /usr/bin/cut -d" " -f1)" = "$h"; /usr/bin/sync -f "$d/commissioner.py"; /usr/bin/sync -f "$d"; /usr/bin/sync -f /root/uten-imp-commissioning' _ "$b" "$h" "$u"
```

此后 `<root安装副本>` 就是 `/root/uten-imp-commissioning/nvme-<sha256>/commissioner.py`。不要从上传用户可写目录直接以 root
运行 Python，也不要把密码放入上述变量或命令。

```bash
sudo /usr/bin/python3 -I '<root安装副本>' assess
sudo /usr/bin/python3 -I '<root安装副本>' plan \
  --expected-hostname '<已核验的目标主机名>'
sudo /usr/bin/python3 -I '<root安装副本>' apply \
  --expected-hostname '<与 plan 完全相同的目标主机名>' \
  --plan-sha256 '<plan 输出中的 planSha256>' \
  --storage-approval-reference '<受控变更/批准编号>' \
  --confirm 'COMMISSION-NVME-UTEN-DATA-350G-RETAIN-OLD-MD'
```

`assess` 和 `plan` 不执行业务或存储变更，不停止服务、不挂载/卸载设备，JSON 只写 stdout；psql、LVM、pgBackRest
等正常只读清单命令仍可能产生系统日志。调用者如果
用 shell 重定向保存输出，那是调用者的单独写操作。`apply` 会重新只读评估；主机状态变化导致
plan SHA 不匹配时会拒绝，必须重新查看计划。
`--storage-approval-reference` 必须来自实际的受控批准/变更记录，工具不会自己生成批准编号。

禁止把密码、私钥、token 或真实数据库密码放入命令行、计划或 evidence。工具不接受这些参数。

## 应用顺序与失败边界

`apply` 的顺序固定：

1. 在 `/var/lib/uten-imp-nvme-commissioning/<transaction>` 原子保存 assessment、plan、fstab、
   unit preimage 和原服务状态；
2. 安装 SHA-256 版本化的恢复 helper、永久 early wants 链接、late service/timer、root gate-authorizer 及 timer wants 链接，
   并给固定保护清单中的每个 unit 安装 unit-specific gate；先持久写入 active pointer，再强制重跑 authorizer 并证明全部 marker 为空，
   之后才允许停止服务或改动存储。普通期 authorizer 为全部 unit 写入 `/run` marker，活动事务期默认一个都不写；
3. 在任何存储/服务写入和任何计划 reboot 之前，disable 旧 Phase 1 resume，保留它的 unit 文件和全部
   receipts，并用 effective unit/link 状态证明重启不会再调用旧 helper；无法证明时停止，不进入后续步骤；
4. 非阻塞取得共享数据库维护锁，在锁内先停 backup timers 再复核 job；若备份任务正在运行则直接阻断，
   不会 stop/kill pgBackRest；随后关闭入口和 PostgreSQL；
5. 执行 `vgcfgbackup`，再创建 350 GiB LV，复核 LV 大小及剩余空间；
6. 临时挂载新 ext4，执行真实写入、`fsync`、删除和 filesystem sync 验证；
7. 验证 fstab candidate 后卸载旧 `/data`，原子切换 fstab，挂载并复核新 UUID；
8. 安装 PostgreSQL mount guard，创建空 PGDATA 和 storage-authority marker；
9. 写入 `COMMITTED_STORAGE_ONLY` receipt 后保留 active pointer，排队 30 秒后的 late committed finalizer；只有它在
   local-fs/multi-user 后完成 live `/data`、LVM/PV/NVMe、空 PGDATA/备份目录、入口/DB/ERP/备份自动化关闭状态验收，并精确恢复
   OS 自动更新基础设施原状态，才在 gate 仍关闭时删除并 `fsync` pointer，随后让无 pointer 的 authorizer 恢复正常 marker。
   永久恢复 unit/link/authorizer 保留；若 finalization receipt 已写入但掉电，下一次会严格校验并复用该 receipt、重新做 live 验证后再收尾。

在 durable `complete.json` 之前捕获失败时，early 阶段只恢复原 fstab、原 PostgreSQL guard、unit enablement 和旧 `/data`
挂载，写入不可混淆的 handoff 后保留 active pointer；它不会在 `local-fs.target` 之前启动 PostgreSQL、ERP 或 Nginx。
late service 明确排在 `multi-user.target`/`network-online.target` 之后。提交前回滚路径会再次核对旧 md UUID、RAID1 双成员
clean/idle、旧 ext4 UUID、全部文件 preimage 和新 LV 已无挂载；提交后路径改为核对新 `/data` exact UUID/ext4/options/rdev、
LV/VG/PV/NVMe authority、空 PGDATA/备份目录和全部业务/备份 unit 仍关闭。它每次只给下一个精确 unit 发布一次 grant；grant
绑定 active pointer SHA、boot ID、late systemd invocation、PID/start time 和同一进程持有的 commissioning/数据库维护两把 flock。
root authorizer 验证后只写该 unit 的 `/run` marker；blocking `systemctl start` 一返回（包括异常）就立即重跑 authorizer 消费 grant、
删除 marker，然后才进入健康验证，下一个 unit 必须取得新的 grant，杜绝全局或可复用临时放行。每个 boot 最多尝试三次；任一步失败都会停止 authorizer、
移除全部 marker、停用受保护服务并保留 pointer。若最终 `ROLLED_BACK` receipt 已持久写入、但在 pointer 删除前掉电，下一次会
严格采用该 receipt，重新验证旧存储并恢复/验活原先 active 的服务与 OS 更新基础设施，然后直接收尾；不会再消耗三次 attempt 预算。
late helper 若被 SIGKILL 或超时，late-resume service 的固定、active-pointer-aware `ExecStopPost` 还会独立执行同一
containment，处理已经启动而不会仅凭 Condition 自动停止的 unit。只有严格绑定 transaction/plan/authority/live evidence、
root:root 0600 且单硬链接的 committed late receipt 已存在时，StopPost 才保留已恢复且已验证的 OS 更新基础设施；receipt
缺失、损坏或绑定不符时仍执行全 containment。每个受保护 service/timer 的永久 drop-in 使用普通
`Requires=gate-authorizer`、`After=gate-authorizer` 和普通 `ConditionPathExists=<unit-specific-marker>`；authorizer 失败会阻止启动，
普通 Condition 也不会与别的 `|` trigger condition 合并。drop-in 不放无条件 `ExecStopPost`，避免
事务结束后的正常停服误停整条业务链，也避免非 root service 或 timer 承担 root containment。late verifier 在每个依赖启动后立即
做有界健康验证，任一关键依赖退出或不健康即进入上述 containment。

`complete.json` 是存储切换的不可回滚点：之后的故障只校验已提交的新存储并重试 finalization，绝不切回旧 md。
工具明确不执行 `lvremove`，因此新 LV 会留作证据。

删除 active pointer 前不会发布“全部 unit 临时放行”的 grant；删除后才恢复正常 authorizer。若进程恰在 pointer 已持久删除、
正常 marker 尚未恢复的窄窗口退出，固定 `ExecStopPost` 会重试无 pointer 的正常 authorizer；若整机掉电，`/run` 会清空，
下次受保护 unit 启动时又必须先成功运行 authorizer，因此不会遗留手工开门步骤。若 pointer 删除后连续两次 authorizer
仍失败，命令返回非零并追加不可覆盖的 `gate-finalization-failed.json`（含 marker 与 authorizer 状态）；此时已提交存储不会回滚，
后续任一受保护 unit 仍必须通过 `Requires=gate-authorizer` 才能启动。

若进程遭遇 SIGKILL 或整机掉电，持久 active pointer 会保留，而 `/run` 中的 grant 和 unit marker 会随服务退出或重启消失，
因此所有受保护 unit 在下一次启动仍保持关闭。提交前由 early 恢复旧存储和 enablement、late 健康恢复此前 active 服务；提交后
early 绝不删除 pointer，只排队 committed late live finalizer。也可以在安全控制台手工触发 early 阶段：

```bash
sudo /usr/bin/python3 -I /usr/local/libexec/uten-imp-nvme-commissioner-<sha256>.py recover
```

不要手工调用隐藏的 `--from-systemd-early` 或 `--from-systemd-late` 参数；它们只供已安装的固定 unit 使用。

恢复后若 350 GiB LV 已存在，下一次 `plan` 只在以下条件全部满足时允许 `adopt-retained`：恰好
一个本工具的成功 `lvcreate` 日志、对应 eligible plan、完整 `ROLLED_BACK` receipt、精确大小及
NVMe PV、未被挂载，以及空白设备或标签/类型正确的 ext4。重新应用还会检查盘内只能有
`lost+found`、本工具创建的空目录及合法 marker；出现任何陌生内容都拒绝且不删除。只有不可变旧事务证据逐项绑定当前
LV/VG/PV UUID、目标 LV 确认无签名，并再次通过 plan SHA 与 typed confirmation 授权时，才允许格式化 retained LV。

## 成功后的必做下一阶段

看到 `COMMITTED_STORAGE_ONLY` 仍不能启动 ERP。下一阶段必须单独完成并留证：

1. 对空 PGDATA 执行受控 PostgreSQL 16 初始化；
2. 创建最小权限数据库角色和 root-only secrets 文件；
3. 从冻结且校验过的迁移制品运行 Flyway，并核对 `flyway_schema_history`；
4. 先按首备份 commissioning 合同建立与同一数据库身份绑定的本机 full/WAL/check 恢复层；它只满足首次
   激活 gate，不得冒充异地灾备；另行建设独立故障域副本并完成 PITR restore drill 和告警验收；
5. 部署同一签名候选的 ERP 后端和 Flutter Web，验收 readiness 后才 enable PostgreSQL/ERP/Nginx；
6. 最后另行批准一次真实重启，验证缺盘、空 PGDATA、后端失败时入口均保持关闭。

这里必须使用新的 `existing-test-host` 数据库初始化桥接事务，不能直接运行现有
`phase2-postgres.sh` 或 `phase3-runtime.sh`：前者仍按旧 RAID/全新 cluster 前提校验，后者要求正式
storage drop-in 唯一。桥接事务必须在同一证据链中原子地把本工具的临时 PostgreSQL mount guard
替换为正式 `uten-imp-storage.conf`，再完成 initdb/角色/迁移；不得让两个 drop-in 并存。

参考恢复契约：

- [early resume unit](../systemd/uten-imp-nvme-commissioning-resume.service.example)
- [late resume unit](../systemd/uten-imp-nvme-commissioning-late-resume.service.example)
- [late resume timer](../systemd/uten-imp-nvme-commissioning-late-resume.timer.example)
- [gate authorizer unit](../systemd/uten-imp-nvme-gate-authorizer.service.example)
- [active transaction gate drop-in](../systemd/uten-imp-nvme-active-transaction-gate.conf.example)
