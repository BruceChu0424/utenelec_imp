# 主机稳定性与外部可用性观察器

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260812 -->
> 当前主机只监控内部 ERP 测试环境；企业官网延期到未来独立云服务器，不属于本机 policy、探针、告警
> 或 timer。SMART/RAID 状态只来自 2026-08-12 的旧快照，必须重新只读采集；三个监控 timer 继续
> disabled，不得为了“监控”启动 SMART 自检、RAID check 或旧 Phase 1。未来正式使用后的计划维护/自检窗口
> 为 03:00，但监控本身不因维护窗口
> 自动重启服务器。实时状态见 `../current-test-server-status.zh-CN.md`。
> 首次连接前必须先按
> [目标服务器带外身份与访问 authority 清单](../target-host-oob-authority.zh-CN.md)完成 H01–H12；材料齐全
> 后也只允许先做只读刷新，不自动授权安装或启用 timer。

本目录补齐的是“观察、持久告警、开机后自动巡检”源码边界，不是服务器已经投产的证据。它不执行
`systemctl start/stop/enable`、不挂载磁盘、不启动 SMART 自检、不设置时钟、不安装 ACME 客户端、
不续签证书，也不修改 PostgreSQL/Nginx/ERP/官网或备份。

## 固定边界

- `host_monitor.py` 在无网络的 root oneshot 中只读核对：persistent journald 的固定容量/保留设置和
  实际日志文件、选定 NTP provider 的同步/offset/root distance、批准的 md RAID 和 SMART 身份/健康/
  自检新鲜度、精确挂载身份/options/容量/inode、已批准 TLS 文件的 SAN/期限及已有 renewal unit 的
  timer/最近成功结果、PostgreSQL、ERP/Nginx/watchdog/备份 timer 的启用/运行/失败/最近触发状态。
- RAID/SMART 设备不能由 CLI、环境变量或 `/dev` glob 指定。root-owned `storage-hardware-authority.json`
  绑定现有 `/etc/uten-imp/storage-authority.json` 的 SHA-256、md UUID/级别/成员和磁盘 by-id+序列号哈希；
  `host-policy.json` 再绑定 hardware authority 的 SHA-256。换盘/换阵列必须重新只读核验并走新审批。
- `external_probe.py` 只接受 root-owned policy 中无凭据、无 query/fragment、HTTPS/443 的固定 URL，使用
  系统信任库校验 DNS/SAN/证书链，禁止重定向，验证精确 HTTP 状态和 JSON/静态标记。ERP 的真正外部
  探针必须放在独立故障域并通过企业 VPN；把它只放在 ERP 主机上不能证明主机宕机告警。
- 观察报告与事件都声明 `containsSecrets=false`。告警 sender 路径固定为
  `/usr/local/libexec/uten-imp-alerting/submit`，只接收 `--event-file`/`--receipt-file`；不存在 shell、URL、
  provider 命令或凭据注入。sender 退出 0 不代表送达，只有绑定同一 event ID、送达 UTC 和 provider
  message ID 的 root-only receipt 才把 pending 原子移动为 delivered。
- pending 最多 1000 个/16 MiB；事件、active episode、transition 均 canonical JSON、`O_NOFOLLOW`、
  单 hardlink、fsync+rename。掉电遗留 transition 会在下一次 record/drain 幂等补齐。相同故障只发一次；
  描述/级别变化发 update，恢复发 recovered。sender 或网络中断只保留 durable pending。

## 安装与 commissioning

仓库现提供证据绑定、可恢复的现有主机安装事务源码，但这不代表目标服务器已经安装或启用。唯一受支持
入口、固定 source bundle、真实 policy/authority 参数、plan/apply/resume/rollback 与 journald 独立事务
见 `EXISTING_HOST_MONITORING_INSTALLER.zh-CN.md`。安装器不会 enable/start timer；完成 receipt 仍明确为
uncommissioned，三个 timer 必须保持 disabled/inactive。`host-policy.example.json`、
`storage-hardware-authority.example.json` 和 `external-policy.example.json` 内都是占位值，安装器会拒绝
路径含 example 或内容含 placeholder 的输入，禁止原样安装。
`journald-uten-imp.conf.example` 的 2 GiB/5 GiB/30 天只是评审起点，必须按真实根卷、日志速率、事故调查
窗口和备份容量调整；启用 persistent journal 前先证明根卷不会被日志挤满，并保留原配置/日志作为回退证据。

只有完成下列真实验收，才可以分阶段安装为 root-owned 固定文件，并最后启用三个 timer：

1. 只读保存根卷/数据卷容量和 inode、`journalctl --disk-usage`、journald 合并配置、NTP provider、
   `/proc/mdstat`、mdadm detail、每块真实磁盘 SMART、挂载、TLS 文件/SAN/期限、renewal unit、所有被监控
   unit/timer 的 enabled/active/failed/last trigger；PostgreSQL 还须单独核对 Debian cluster 的
   `start.conf=auto`、generator 结果以及 `postgresql.service` meta 与 `postgresql@16-main.service` instance
   同时 enabled/active。观察器监控后两项，但本版不把 distro-specific `start.conf` 解析当成生产证明；
   真实值须由第二人/OOB 复核。
2. 评审并 canonical 化 policies/authority，固定 SHA-256；provider-managed 云盘不得伪造本地 SMART，
   必须另接云监控事件。证书 provider/renewal unit 由现场选择，本实现不会猜测 Certbot/acme.sh/云证书。
3. 在测试 VM 注入：journald 配置漂移和容量边界、NTP 丢同步/大 offset、RAID 降级/resync/mismatch、SMART
   failing/高温/identity/self-test 过期、只读/错误挂载/低容量/低 inode、证书 SAN/过期/renewal 失败、
   PostgreSQL/app/Nginx/watchdog/backup timer disabled/failed/stale/restart storm、HTTP 错误/伪 JSON/TLS
   错误、sender 超时/坏 receipt、pending 配额、在每个 fsync/rename 边界 SIGKILL 和重启恢复。
4. 外部 provider 收到 opened/updated/recovered 和 monitor-execution-failed 测试告警，receipt 回绑正确，
   sender 断网跨重启后 pending 能送达；在宿主完全断电时，独立故障域仍能告警 ERP 不可用。官网未来
   上云后使用其独立故障域监控，不继承本机 policy。
5. systemd sandbox、SMART 权限和 journald 持久化通过真机验证后，两人审批安装；先手工启动各 oneshot，
   再启用 `uten-imp-host-monitor.timer`、`uten-imp-external-monitor.timer`、
   `uten-imp-monitor-alert-drain.timer`。任何一步失败立即保持/恢复三个 timer 为 disabled/inactive。

### 回退

监控本身异常时，先 `disable --now` 三个 monitor timer（不停止业务服务），保留
`/var/lib/uten-imp-monitoring` 与 journal，恢复审批前的 unit/policy/journald drop-in 并 daemon-reload；若
journald 设置变化，先验证容量和 `journalctl --verify`，再重启 journald，禁止用删除 journal 充当回退。
本地监控不可用时外部探针仍应报警；两者都不可用时生产继续 NO-GO，而不是静默运行。

源码模板和测试通过不证明真实日志留存、磁盘硬件、TLS provider、NTP 质量、外部链路或告警送达。
