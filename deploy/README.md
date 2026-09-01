# Uten IMP 稳定运行与原子发布基线

> **⚠️ 本目录已归档（2026-09-01，ADR-060）**：现役发布链是
> [ADR-060 单维护者简化发布链](../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md)
> 与 [`deploy/simple/RUNBOOK.zh-CN.md`](simple/RUNBOOK.zh-CN.md)。本文件及其描述的重链
> （离线签名、H01–H12、WORM/OIDC、NO-GO 门禁）仅作为未来引入第二维护者时的加固参考，
> 不再具有操作效力。

<!-- CURRENT-ERP-TEST-SERVER-SCOPE-20260812 -->
> **当前执行范围（2026-08-15）**：本轮只建设公司内部 ERP 测试服务器，部署 PostgreSQL、Spring Boot
> 后端和 Flutter ERP Web/Nginx；企业官网延期到独立云服务器。当前采用系统 NVMe 上独立 350 GiB
> LVM/ext4 `/data`；两块桌面级 SMR 机械盘退出 ERP 路径但不擦除，保留为短期回退证据。先完成可恢复的
> NVMe 存储事务，再建立干净测试库、安装冻结 ERP 制品并做真实开机自启验收。简化后的权威顺序见
> [current-test-server-status.zh-CN.md](current-test-server-status.zh-CN.md)。
> 未来正式使用后的维护/自检窗口为 03:00（Asia/Shanghai）；2026-08-12 最后只读快照中的旧 repo1 full
> 是 02:17，须刷新后重新排程，不得与维护窗口混为一项。
> 跨任务/跨对话继续时，以
> [ERP_INTERNAL_TEST_SERVER_CONTINUATION_HANDOFF.zh-CN.md](ERP_INTERNAL_TEST_SERVER_CONTINUATION_HANDOFF.zh-CN.md)
> 作为完成项、剩余门禁、强制规范和恢复内网执行顺序的总交接；该交接同样不代表目标机已部署。
> GitHub/签名 authority 统一按
> [release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md](release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)
> 执行；目标机身份、Host Key、双管理员密钥、批准路由和控制台统一按
> [target-host-oob-authority.zh-CN.md](target-host-oob-authority.zh-CN.md)执行。两份清单均通过前，发布与目标机连接分别保持
> **NO-GO**。

当前 NVMe 内部测试运行面的唯一配置入口是
[internal-test-runtime.zh-CN.md](internal-test-runtime.zh-CN.md)。它使用独立 `internal-test` profile，
不会把 `prod/cloud` 的 OSS、HTTPS、迁移和密钥门禁改成本地测试默认值；企业官网不在该运行面中。

> **适用边界（2026-08-11）**：本文是通用的单版本、不可变制品、Nginx/systemd 和 watchdog 发布基线。
> 当前权威操作入口是 [operator-guide.zh-CN.md](operator-guide.zh-CN.md)，真实主机事实只以受控私有交接为准。
> [cloud/README-cloud.md](cloud/README-cloud.md) 是尚未完成目标环境验收的可选异地灾备设计草案。
> 历史环境证据与未关闭门禁的旧清单（2026-08-09）已随 2026-09-01 文档清理归档至 git 历史；
> 现役部署/发版链见 [deploy/simple/RUNBOOK.zh-CN.md](simple/RUNBOOK.zh-CN.md) 与
> [新库上线与首装操作指引](../docs/99-项目治理/2026-09-01-新库上线与首装操作指引.md)。
> 模板、脚本和隔离演练通过不等于目标服务器已安装或生产放行；填写环境变量也不能替代 VPN、迁移、
> PITR、真实 OSS、故障注入和岗位 UAT。

> **数据库保护边界（2026-08-14）**：金额、余额、汇率、税额、成本和数量保持精确 `NUMERIC`，不做逐列随机、确定性或保序加密。已列明 PII 的版本化 pgcrypto 只是过渡字段保护，不是全库/TDE，也不是外部 KMS envelope。生产必须分别验收数据库 TLS `verify-full`、LUKS2/加密云盘、pgBackRest 加密仓库、最小权限、审计和隔离恢复；KMS/HSM/Vault 选型、目标主机卷加密、目标库 PII 回填及备份恢复目前均未部署验收，继续 **NO-GO**。详见 [ADR-037](../docs/99-决策记录-ADR/ADR-037-数据库数据保护与分级加密.md)与[数据保护执行合同](../docs/05-架构/数据保护与加密分级.md)。

公司员工使用的 Web 入口不得由开发调试进程提供。生产入口必须由 Nginx 持续提供版本化的
Flutter Web Release，并把同域 /api 反向代理到受系统服务或编排器监督的 Spring Boot。

## 一、签名不可变制品

当前权威发布契约见 [release/README.md](release/README.md)，日常操作见
[operator-guide.zh-CN.md](operator-guide.zh-CN.md)，GitHub 保护、人员 Commit/Tag 签名、隔离 Environment 和
Release 制品签名的配置步骤见
[release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md](release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)。
CI 必须先完成后端、数据库、Flutter
质量门禁，再产生 Ed25519 签名 manifest、候选 channel、SBOM 和不可变归档。服务器不得自行
生成 manifest 或通过“下载源相同的 SHA256 文件”证明远程对象可信。

远程 payload 的唯一允许内容是：

~~~text
<version>/
  SHA256SUMS
  server/uten-imp-server.jar
  server/uten-imp-migrator.jar
  web/index.html
  web/version.json
  web/...
  sbom/backend.cdx.json
  sbom/flutter.cdx.json
~~~

`deploy/`、watchdog、systemd、Nginx、安装器和任何 root 脚本都不得进入远程应用 payload。
watchdog 固定安装在 root 控制的 `/usr/local/libexec/uten-imp/`，不随 `current` 切换。
生产秘密只保存在各自隔离的 `/etc` 目录，不进入版本目录、仓库、命令参数或日志。

<!-- MANUAL-STAGING-ONLY -->
发布分两阶段：非特权 `uten-imp-updater` 下载、验签并写 staging；当前只允许管理员人工触发
一次 oneshot，保留/配额/告警和受审清理任务完成前定时器保持 disabled。人工确认备份、迁移和
会话清退后，root 激活器从不可信 staging 建立 root 私有快照并重新复验，再安装到
`/opt/uten-imp/releases/<version>`、原子替换 `current`、检查后端/Nginx/静态入口/watchdog。
严禁手工复制 staging、直接执行 `ln -s`/`mv current` 或原位覆盖 JAR/Web。

systemd 起点见 `systemd/uten-imp.service.example`。签名制品中的独立 migrator 只由固定
`uten-imp-migrate.service` 在停服窗口以专用身份运行；应用进程不持有迁移凭据且禁用内置 Flyway。
Nginx 从 `current/web` 提供静态文件，Spring 只绑定 `127.0.0.1:8080`；静态入口探针只监听
`127.0.0.1:8081`。Phase 2/3 先独立证明并启用 `postgresql.service` 与
`postgresql@16-main.service` 的开机恢复；首次激活全部健康后，只事务化启用后端、Nginx 和两个 watchdog
timer 的入口开机链。发布失败会保持入口关闭，但不会 stop/disable 权威数据库，便于保留只读核验证据。
普通开机的依赖图固定为 `/data` mount → PostgreSQL 16 → ERP → readiness=UP → Nginx；
Nginx 通过 `BindsTo`/`PartOf` 跟随 ERP 停止和重启，不能在数据库、数据盘或后端未就绪时先开放入口。
PostgreSQL unit 自身在 postmaster 写入前调用固定、root-owned 存储 verifier：当前 internal-test authority
只接受 schema v3 `lvm-linear-nvme`，精确核对 LV/VG/PV/NVMe 身份、ext4 UUID、挂载选项、容量/inode 余量和
`16/main` 的有效 `data_directory`。旧 md observer/`DeviceAllow` 只保留为历史兼容证据，不得成为本目标机
正常开机 authority。ERP 启动前再把签名
release/current/active/runtime authority、systemd MainPID、唯一 `127.0.0.1:5432` listener、数据库
system identifier/timeline 与逐行 Flyway 历史绑定；错误卷、根分区旧 cluster 或另一 PostgreSQL 实例均关门。
Ubuntu 24.04/systemd 255 是 `RestartSteps` 有界退避合同的一部分，旧 systemd 必须在 Phase 3 前拒绝。

每次维护和切换都必须先停止 watchdog timer/oneshot，排空请求并清退会话；成功完成原子切换、
严格探针和真实账号冒烟后才恢复。涉及 Flyway migration-set 变化时，旧 JAR 不被视为自动可回滚；
必须按备份恢复或前向修复流程处理。

## 二、监督、健康与容量

Restart=always 只能发现 JVM 退出，无法处理“PID 仍在但事件循环卡死、健康端点超时”的故障。
本目录提供两个运行在目标进程之外的独立监督链：

- `uten-imp-watchdog` 开机宽限 120 秒后，每 15 秒直连
  `127.0.0.1:8080/actuator/health/liveness`，5 秒超时；必须同时满足 HTTP 2xx 与 JSON
  `status=UP`，连续 4 次失败才进入恢复评估，单次抖动只记日志；只有 activation/recovery/boot/failure
  marker 全部不存在、共享 operation lock 可取得、app/watchdog/PostgreSQL 仍开机启用时才评估恢复。若
  `/data` 尚未挂载，带网络的 watchdog 仍保持 `PrivateDevices=true`；它只能写一次性 nonce 请求，由无网络、
  `DevicePolicy=closed` 且仅放行已审批 `/dev/mdN` 只读访问的 root observer 核对同一 boot、helper/unit/fstab
  摘要、UUID/type/rdev 和完整空闲 RAID，再消费 30 秒 receipt。消费后重新核对 marker/lock/enablement，才可
  启动 `data.mount`；挂载后的固定 storage verifier 仍须通过，PostgreSQL 才可启动/ready，随后才允许
  `reset-failed` 并重启 Spring。重试按 2/5/15/30 分钟退避，
  后续保持 30 分钟上限；恢复后的健康探针才清零；
- `uten-imp-entry-watchdog` 每 15 秒同时证明仅回环开放的 `127.0.0.1:8081/index.html` 含
  `flutter_bootstrap.js` 制品标记且后端 readiness 为 `UP`。连续 4 次 readiness 失败后，在 marker/operation
  lock 复核下停止 Nginx 并确认 `ActiveState=inactive`，但不重启 JVM；关闭入口不受 enablement 阻挡，避免
  “disabled 但进程仍 active”继续开放。readiness 恢复后，只有 timer/Nginx/ERP 仍 enabled 才按同一有界
  退避显式 start Nginx；静态入口异常但后端 ready 时可有界 restart。entry oneshot 只有
  `After=nginx.service`，没有 Wants/Requires/BindsTo/Upholds，因此 timer 探测本身不会把手工停止或禁用的
  Nginx 反向拉起。Nginx master 异常退出则由 `Restart=on-failure` 更快拉起；
- 两条链的计数文件都以同文件系统 rename 原子写入 `/run`，`flock` 保证探测/重启单飞；脚本绝不
  读取 token 或业务数据，StartLimit 继续限制重启风暴；
- readiness 失败达到阈值后由 entry watchdog 关闭本机 Nginx 入口并告警，但不触发 Spring watchdog 重启；
  外部负载均衡/监控仍须单独探测；
- 外部域名的 health/readiness、静态首页和真实业务可用性持续 60 秒失败必须告警，即使本地探针
  正常；systemd 进入 failed/StartLimit 状态也必须立即告警；
- 安全前置恢复后，watchdog 可在有界退避窗口自动清理 StartLimit 并恢复；若 30 分钟窗口仍持续失败，
  必须由外部告警升级并调查，不能另写高频无限重启循环，也不能在维护时只 stop 而不 disable timer/unit。

Kubernetes 等编排环境应分别配置 startupProbe、livenessProbe、readinessProbe：startup probe 保护
冷启动，liveness 连续失败才替换容器，readiness 只摘流；仍需全局不可用告警与工作负载重启退避。

Nginx 的 IP 桶只是有限洪泛保护，不能承担账号策略。模板针对同一 NAT 下约 1,000 个恢复客户端分离为：

- health：独立 1000 r/s、burst 5000，不再与普通 API 的 3000 r/m 桶争抢；
- auth：300 r/s、burst 2000，容纳早班登录及故障后的集中 refresh；
- 普通 API：继续使用独立有限桶；账号、手机号等低阈值仍由应用层实施。

这些是容量起点，不是所有现场通用值。必须从真实办公 NAT、运营商 CGNAT、WAF/CDN 路径压测
2/5/10/15 秒恢复波次和登录/刷新峰值，再调整；计划恢复波不得大量 429，明显超出批准容量的持续洪泛
仍必须被 429 限制。

Nginx 只代理根 health、liveness 和 readiness。普通 location /actuator/ 明确返回 404，且没有 ^~，
因此三个允许的 exact/regex location 仍优先，而 /actuator/info 等路径不会落入 SPA index.html 冒充 200。
后端 SecurityConfig 继续保护非 health Actuator 端点。

## 三、最小 staff JWT 的发布与回滚边界

最小 staff access token 不再携带 emp/acc/roles/perms/mcp，只保留主体、类型和授权版本。旧 token 可由
新 JAR 读取；新最小 token 到旧 JAR 可能以 403“无权限”结束且不会自动刷新。因此：

- 禁止新旧 JAR 直接滚动混跑，也禁止携带新最小 token 直接回滚旧 JAR；
- 单机必须维护窗口全停、排空、原子切换版本，并通过受控 issuer/签名密钥轮换及 refresh 撤销或等价
  机制清退既有会话，强制重新登录；回滚旧 JAR 前必须再次清退已签发的最小 token；
- 当前源码没有“继续签发旧兼容 claim”的 writer 开关，因此本候选**不支持集群滚动升级**；
  只能全停、排空、清退会话后切为同一版本。若未来实现并验证兼容 writer，才可采用 reader-first、
  minimal-writer-second 的两阶段滚动发布；
- 发布记录保存版本、SHA256 校验结果、current 前后目标、issuer/密钥版本、会话清退时间、节点清单及
  验证结果；不得记录真实密钥或 token。

## 四、连接与有限包络

- Spring Boot 的请求行加全部请求头预算为 16 KiB；Nginx 使用两个 8 KiB 大缓冲与 8 KiB 单字段
  上限。两者计数语义不同，代理还会追加转发头，因此这是测量后的有限包络，不是逐字节相等。
- access token 只携带最小身份及授权版本；X-Uten-Audit-Context 客户端编码上限为 1536 字符。
  禁止在请求头携带正文、查询值或令牌副本。
- 普通 API 读取超时为 45 秒；只有 /api/**/export 使用 120 秒。写请求不得自动重放。

## 五、目标环境验证

健康验证必须检查 JSON；单纯 curl --fail 不能防止 SPA index.html 冒充 200：

~~~bash
systemctl is-enabled uten-imp.service
systemctl is-active uten-imp.service
systemctl is-failed uten-imp.service && exit 1 || true
test -L /opt/uten-imp/current
readlink -f /opt/uten-imp/current

for endpoint in health health/liveness health/readiness; do
  curl --fail --silent "https://<production-host>/actuator/$endpoint" \
    | jq -e '.status == "UP"' >/dev/null
done

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  https://<production-host>/actuator/info)" = "404"
~~~

还必须完成：

- 对当前本地服务器按 [operator-guide.zh-CN.md](operator-guide.zh-CN.md) 和受控私有交接逐项保存
  执行人、命令/日志、结果和复核人；旧云端清单只保留历史/可选灾备证据，任何红项或无证据勾选
  都不能进入 GO；

- 对版本目录执行 SHA256SUMS 校验，证明 current 只经原子 symlink rename 切换；检查运行 JAR/Web 从未
  原位覆盖，并演练保留目录间的原子回滚；
- 不能只 kill JVM：在保持 Java PID 存活时，用测试故障注入令 liveness 持续超时/失败，验证 watchdog
  达到连续失败阈值后通过 systemd/编排器替换实例，同时产生不可用告警且不突破启动限速；
- 单独令 readiness 失败，验证摘流和告警但不会形成无意义 JVM 重启循环；
- 主动终止一次 JVM，验证 Restart=always 拉起；再连续触发失败验证 StartLimit 与 failed 告警；
- 在 `/data` 晚挂载、PostgreSQL 启动慢/active-but-not-ready、StartLimit 已触发三种情况下分别验证：
  前置未满足时没有 reset/start；真实 systemd sandbox 内证明 schema v3 boot authority 不含 md
  `DeviceAllow`，错误 mapper/LV/VG/PV/NVMe、UUID、文件系统、根分区伪目录、冲突/重复挂载选项和旧 authority
  全部拒绝；条件恢复后无需 reboot 可自动恢复，且重试间隔不会突破 2/5/15/30 分钟；未完成这组实机测试前
  晚到挂载仍是 NO-GO；
- 主动终止 Nginx master，验证 drop-in 自动拉起；分别让回环 index 缺标记和后端 readiness 持续 DOWN，
  验证短抖动不动作、阈值后 Nginx 已确认 inactive、数据库恢复后按退避显式 start；另在 Nginx disabled/stop
  时启动 entry probe，证明 unit 依赖不会反向拉起 Nginx，并确认 marker/operation lock 会阻断服务动作；
- 从同一源 NAT 压测 1,000 客户端的 health 恢复波及集中 login/refresh，确认批准容量内不大量 429，
  超过洪泛边界仍返回 429；
- 验证根 health、liveness、readiness 到达 Spring 且为 JSON；停止后端时均不得由 SPA 返回 200，
  /actuator/info 等非公开路径在网关固定 404；
- 验证优雅停止期间的在途请求，确认 90 秒 systemd 总窗口不会提前 SIGKILL；
- 验证普通 API 45 秒与仅 export 120 秒边界、请求头正反例、断网读恢复与写请求不重复；
- 按单机全停或集群两阶段方案验证新旧 token 矩阵、会话清退和受控回滚。

源码与本地测试通过不等于目标环境的 checksum、原子切换、真实网关容量、外部 watchdog、告警或会话
清退演练已经完成。
