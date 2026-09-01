# 现有内部 ERP 测试主机 monitoring 安装与回退

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../simple/RUNBOOK.zh-CN.md)。

> 状态：本文件描述的是可审计的源码安装事务，不是目标服务器已安装、已启用或已验收的证明。
> 任何目标机写入仍须先刷新主机身份、SSH/OOB、磁盘、systemd 和 policy 只读快照，给出风险与回退，
> 再取得明确批准。安装完成时三个 timer 必须仍是 **disabled + inactive**。
> 主机身份、Host Key、两把管理员密钥、批准路由和控制台的统一材料见
> [目标服务器带外身份与访问 authority 清单](../target-host-oob-authority.zh-CN.md)；H01–H12 未齐全时不得连接。

## 1. 固定边界

`existing_host_monitoring_installer.py` 只管理：

- `/usr/local/libexec/uten-imp-monitoring/` 的稳定描述符运行时启动器及 4 个 Python runtime；
- `/etc/uten-imp-monitoring/` 的真实 `host-policy.json`、`external-policy.json` 和
  `storage-hardware-authority.json`；
- `/etc/systemd/system/` 的 host/external/drain 三组 service+timer 和 failure template，共 7 个 unit；
- `/usr/local/share/doc/uten-imp-monitoring/` 下的运行说明与安装器 runbook 两个文档；
- `/var/lib/uten-imp-monitoring/journal/` 下的 plan、preimage、事务、回退凭据。

它不会执行 `start/stop/enable/disable/mask/restart/try-restart`，不会访问 provider 或业务网络，不会启动
SMART/RAID check，不会改 PostgreSQL/Nginx/ERP。唯一 systemd 写动作是安装 unit 后的
`systemctl daemon-reload`；随后逐项验证精确 `FragmentPath`、空 `DropInPaths`、固定 launcher
`ExecStart`、无 pending job、三个 timer disabled/inactive、四个 service/template inactive。

alert sender 固定为 `/usr/local/libexec/uten-imp-alerting/submit`。缺失时安装允许完成，但 receipt 明确记录
sender absent，drain timer 仍 disabled；安装器从不把“sender 文件存在”当作 provider 已送达。

## 2. 两层可信执行

禁止直接从 checkout、上传目录或源码包路径执行安装器。唯一入口是独立安装为
`/usr/local/sbin/uten-imp-existing-monitoring-installer` 的 root-only launcher：

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-monitoring-installer -- <action-and-arguments>
```

当前源码冻结摘要：

- installer：`903e5bf56305d127bb0f00940ba65075d7c8616130b71283ec3aaf6215b09c6a`；
- runtime launcher：`c9d43a645ba6ebef0a368f1bcaab057db9d991c2e9985ccc12df6f58d068a2fb`。

installer launcher 固定检查 `/usr/local/share/uten-imp-monitoring-installer-source/` 的 15 项精确 allowlist：
所有目录 `root:root 0500`，所有文件 `root:root 0400`、普通文件、单硬链接；从文件到 `/` 的父链均
root 控制且组/其他用户不可写。它以 `O_NOFOLLOW` 稳定捕获 15 个文件并逐字匹配各自内嵌 SHA-256，
安装器只从已捕获字节 `compile/exec`；同时清理环境、固定 argv/PATH/locale/cwd/umask。任何缺项、额外
对象、symlink、hardlink、owner/mode/父链/路径替换或任一摘要漂移都会在安装器执行前 NO-GO。

installer launcher 不属于上述 15 项 source bundle，且不能用自身文件中的摘要证明自身。发布者必须把
launcher 作为独立 `root:root 0500` 资产，与 15 项 source bundle 的路径/SHA/owner/mode 一起写入外层
reviewed-host manifest 和签名发布 SHA 级联，再由目标机受审发布入口原子安装。此组件没有改外层清单或
签名；外层绑定证据缺失时，禁止复制到主机或从 checkout 直接运行。

安装后的 4 个 runtime 也不能互相按 sibling 路径 import。7 个 unit 只调用
`monitor_runtime_launcher.py`；该 launcher 在任何状态写入或外部网络前，先稳定捕获并验证自身目录的
完整精确 inventory 和以下 4 个内嵌摘要，再把 module 从已认证字节预载到内存：

- `monitoring_common.py`：`82b88da8b6707a352a9531db6feff12930bc058af39cbd7ff2442e7b7e4772c9`；
- `alert_spool.py`：`12ce37f6dc9e86472c379957ffae8b0603bdc730ae2c66a83cf6b7f44a59c810`；
- `host_monitor.py`：`197c35eae0997c3302bf5fe1acd9c7c5255b16c48a203c94b9afffa0dd40fe59`；
- `external_probe.py`：`33782a7975e933ac4686bcca06272451f69325bc217da57eeb52a5539aacbdd4`。

任一 runtime 改动都必须先更新并复核 launcher 内嵌摘要；installer 改动还必须生成并复核新的 installer
launcher。禁止新旧 launcher/source bundle 交叉搭配。

## 3. 真实输入与只读 assess

三个现场输入都必须是 root 控制、非 symlink、单硬链接、canonical JSON；路径和 SHA-256 必须显式给出。
文件名/路径含 `example`、`.sample`、`.template`，或内容含 placeholder/changeme/example.invalid 时拒绝。
host policy 必须把固定安装路径及摘要绑定到同一 hardware authority。示例模板不能直接使用。

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-monitoring-installer -- assess \
  --host-policy-source /root/reviewed-monitoring/host-policy.json \
  --host-policy-sha256 '<approved-host-policy-sha256>' \
  --external-policy-source /root/reviewed-monitoring/external-policy.json \
  --external-policy-sha256 '<approved-external-policy-sha256>' \
  --hardware-authority-source /root/reviewed-monitoring/storage-hardware-authority.json \
  --hardware-authority-sha256 '<approved-hardware-authority-sha256>'
```

`assess` 只向 stdout 输出 canonical JSON，不创建目录、lock、plan 或临时文件。审核端应带外保存并复核：
每个 source/target/path/mode/SHA、所有目标 preimage、7 个 unit、loaded drop-in、pending job、sender 状态，
以及 `timerCommissioningAllowed=false`、外部故障域/provider receipt 两项均为 false。

## 4. record-plan、apply 与 resume

批准只读摘要后才允许第一次写入：

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-monitoring-installer -- record-plan \
  <与 assess 完全相同的六个 source/SHA 参数> \
  --expected-assessment-sha256 '<approved-assessment-sha256>' \
  --confirm 'RECORD REVIEWED UTEN MONITORING INSTALL PLAN'
```

它在独占 lock 内重做完整 assessment；任一 source、target、unit、job、drop-in、sender 或 preimage 变化即
拒绝。固定 plan 为 `/var/lib/uten-imp-monitoring/journal/installer/install-plan.json`。

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-monitoring-installer -- apply \
  <与 assess 完全相同的六个 source/SHA 参数> \
  --plan /var/lib/uten-imp-monitoring/journal/installer/install-plan.json \
  --expected-plan-sha256 '<reviewed-plan-sha256>' \
  --confirm 'APPLY REVIEWED UTEN MONITORING INSTALL PLAN'
```

`apply` 先再次稳定捕获全部 source，并在任何托管目标写入前重验路径/父链/metadata/SHA；然后才记录每个
目标 preimage。每个目标只能处于“计划 preimage”或“计划新字节”之一，写入使用同目录临时文件、
`fsync`、atomic rename 和父目录 `fsync`。每个文件、daemon-reload 前后、loaded verify、receipt 都是
独立 durable phase。

SIGKILL/掉电留下固定 active evidence 时，先只读复核其 SHA 和三个 timer disabled/inactive，再执行：

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-monitoring-installer -- resume \
  <与 assess 完全相同的六个 source/SHA 参数> \
  --expected-evidence-sha256 '<reviewed-active-transaction-sha256>'
```

resume 不盲写：source 必须仍匹配 plan，目标必须是 preimage 或计划字节，unit 必须 quiescent。完成后仅有
`uncommissioned-install.json`，三个 timer 仍 disabled/inactive。禁止手工删除 active marker。

## 5. 回退

正常未投产安装以 uncommissioned receipt 回退；中断事务以 active transaction 回退：

```bash
sudo /usr/bin/python3 -I -B /usr/local/sbin/uten-imp-existing-monitoring-installer -- rollback \
  --evidence /var/lib/uten-imp-monitoring/journal/installer/uncommissioned-install.json \
  --expected-evidence-sha256 '<reviewed-evidence-sha256>' \
  --confirm 'ROLLBACK UNCOMMISSIONED UTEN MONITORING INSTALLATION'
```

rollback 拒绝 commissioned marker、active unit/job 和目标漂移；在第一笔托管目标写入前，先只读复验
全部目标状态、稳定捕获全部 preimage 并校验摘要，任一未知/缺失/漂移即整体 NO-GO；之后才逐项恢复
确切 preimage，重新 daemon-reload 并逐字复验原 loaded systemd 状态。回退 receipt 先持久化，之后才退休 active/
uncommissioned 指针。`/var/lib/uten-imp-monitoring/journal`、transaction、preimage 和回退凭据永不被回退
删除。

## 6. journald 是独立可选事务

`journald-uten-imp.conf.example` 只是评审起点。真实文件须另存为不含 example 的 root-only canonical LF
文本并显式提供 SHA。独立动作是 `journald-assess`、`journald-record-plan`、`journald-apply`、
`journald-resume`、`journald-rollback`；对应确认短语由 `--help`/源码固定。

该事务只管理 `/etc/systemd/journald.conf.d/60-uten-imp.conf`，保存/恢复 preimage；要求 journald loaded+
active 且无 pending job。apply/rollback 都明确输出 `restartPerformed=false`、`activationPending=true`，不会
执行 daemon-reload、reload、kill 或 restart。根卷容量、`journalctl --disk-usage/--verify`、合并配置和
真实持久日志先验收后，journald 激活/回退重启必须作为另一项有 OOB 的批准事务。

## 7. 仍然 NO-GO 的验收门禁

源码测试或安装 receipt 不允许启用 timer。至少还需真实主机证明：

- host monitor 的 systemd sandbox、SMART 权限、NVMe/LVM/挂载、NTP、TLS、PostgreSQL 和 journal 观察；
- external probe 位于独立故障域，并通过企业 VPN 探测 ERP；宿主完全断电时仍能告警；
- sender/provider 完成 opened/updated/recovered/monitor-failed 的真实送达，receipt 回绑 event ID；
- sender 断网跨重启 pending 可恢复，provider receipt 已由第二人核对；
- 三个 oneshot 手工演练成功，故障注入/重启/容量/配额/回退演练通过并双人签字。

这些证据缺失时，三个 timer 继续 disabled/inactive，monitoring commissioning 与生产切换继续 NO-GO。
