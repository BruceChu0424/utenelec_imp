# 第二台内部服务器接入合同与只读规划

本目录新增的 `offsite_plan.py` 只读取配置、供应的接收端收据和可选的接收端本机权限；
没有网络连接、传输、定时任务、安装、启用或删除操作。`enabled` 必须为 `false`。
填完地址也只产生 `CANDIDATE_NOT_CONNECTED`，不能成为运行许可或“备份已经可恢复”的证据。
它不更改现役 pgBackRest repo1/repo2、配对备份和升级前 dump 的配置或保留规则。

用户当前目标是**最多丢失 15 分钟数据、4 小时内恢复**，第二台服务器的地址与接入方式尚未确定。
当前现役口径见 [ADR-157](../../../docs/99-决策记录-ADR/ADR-157-服务器备份分故障域与密钥托管.md)：
repo1 是 `/data` 的本地仓，repo2 是本机 NVMe 仓。旧 `pgbackrest_repo2.py` 的 S3/OSS 模板属于
退役部署链，不能直接升级成第二台服务器的运行配置。此合同使用独立名称 `receiver`，避免复用仓号。

## 恢复能力与容量方案

第二台服务器建议保留 35 天连续 PITR、12 个每周恢复点和 12 个每月恢复点，至少 35 天不可变保护。
这只是待容量测算的候选策略，不是本次改动后的实际保留期。每个长期点必须保留其全量基线、
所需 WAL、timeline history、相应时间范围的全部附件和私有原件版本、恢复软件与独立托管密钥。
不能仅保留一份月份 dump 或按 WAL/object 文件年龄分别删除。每月点只保证该点可恢复；
35 天外是否仍有任意时间恢复窗口，应由点所绑定的 WAL 范围明确表达。

接入前测量实际库、每天 WAL 增量、原件增长量、压缩/去重效果、不可变期内删除延迟和恢复吞吐；
为最慢全量恢复、对象解包、恢复库引用比对、业务核对与重建服务预留 4 小时总预算。
达到容量或空间告警后停止推进新水位并通知管理员，不能临时删掉尚被恢复点引用的历史来报绿。
全量备份暂沿用现役每日调度；此合同没有把每日全量改成每周全量。

两台内部服务器不自动等于异地或独立故障域。同机不同逻辑卷、同一 NVMe 的附件卷与备份卷、
同一 RAID 上的数据库与 repo1 都不能算独立物理故障域。需要确认第二台机器的磁盘、管理员/凭据、
交换机、供电、机房以及离线/异站保护。配置里的 `UNVERIFIED` 不能手填 `VERIFIED` 来解除门禁。
以后由独立带外审查收据证明，当前程序没有替代该审查。

## 权限与接入方向

由第二台机器主动拉取，生产机持有零份可删除接收端历史的凭据：

| 身份 | 允许职责 | 禁止能力 |
|---|---|---|
| 生产机 `uten-backup-source` | 读取协议许可的已完成清单、原件版本和 WAL | 写源库、写原件、shell、sudo、转发、接收端历史删除 |
| 接收端 `uten-backup-receive` | 拉取到独立暂存区、校验、提交完成集合 | 更改/删除已有不可变集合、历史快照或保留策略 |
| 接收端 `uten-backup-retain` | 独立审核保留点引用图后执行生命周期 | 接受源机传来的删除指令、删除最后一份已验证恢复点 |

SSH 私钥只出现在接收端专用文件，配置仅引用路径；使用专门的 `known_hosts` 和通过另一条可信途径
取得的 ed25519 SHA-256 主机指纹，强制 `StrictHostKeyChecking=yes`、密钥登录、禁转发。
生产机的 authorized_keys 最终必须用 forced-command 限制到 `uten-offsite-source-read-v1`，限制来源地址，
禁 shell、PTY、用户 rc 与全部转发；该协议名是预留合同，**执行器尚未实现**，不能据此安装授权键。
未来传输器还须固定系统 SSH 程序及参数、禁 user config/代理/ControlMaster，不能把路径拼成远程 shell。

pgBackRest 仓内有可变元数据，不能对活动仓目录直接施加 WORM 锁，也不能对运行中的仓作未经协议保证
的一次 rsync 后报完整。未来的源读取协议须导出固定清单与稳定读视图；接收端先落暂存、验证全部摘要和
恢复引用闭合、fsync，再用独立保护层发布完成快照。历史删除只在目标端发生，不能用 `rsync --delete`
镜像生产机。源机 root 被攻破时仍可能伪造后续备份，因此历史不可变、独立告警和恢复演练缺一不可。

## 15 分钟共同恢复水位

计划预算：发布/归档最多 300 秒 + 每 300 秒拉取 + 传输最多 180 秒 + 重试余量 120 秒 = 900 秒。
这是排程上限，须以接收端持久收据测量真实端到端延迟；配置预算不能证明系统已经达到目标。
WAL 可以依靠现役归档，但**配对备份每天 03:40/13:10，最长间隔约 14 小时 30 分钟**，
不能单凭它承诺 15 分钟原件 RPO。

未来必须实现保留历史版本的连续不可变原件保护/变更日志，并让已提交业务引用的对象先被接收端
完整验证落盘；更新、软删除和物理删除前后都要保留在任一恢复窗口被引用的版本。
数据库确认水位来自可恢复全量 + 连续 WAL，原件确认水位来自全范围引用清单 + 每个 provider/key/version
的 bytes/SHA-256 + 不可变与持久收据。共同恢复水位取两者较早者。失败、缺件、超时、无 fsync 或
只完成数据库复制都不能推进共同水位。严格目标下，若异机原件滞后，须告警并由已批准策略限制依赖
新原件的提交；不能悄悄声称数据安全，也不能未经业务评估自动暂停 ERP。

`offsite-receiver-receipt.example.json` 故意是 `UNVERIFIED`，不能通过恢复证据校验。
真实收据字段必须由目标端验证器产出，不能人工照填。原件对象清单须涵盖所有保留窗口的历史引用，
不只是当前数据库的 CLEAN 集合。配对集合必须绑定同一套数据库 dump 与 media 清单。
仅有配对备份时，原件水位最多保守取 `started_at`，不能取导出完成时间；
新版恢复证据需要实际快照时刻时应扩展协议，不能由集合文件 mtime 推断。

只读校验现在支持同一 timeline 的完整 full 基线与逐段 WAL 范围，检查段大小、连续性、重复、顺序、
跨 log 进位、基线范围、系统 ID、双机身份、清单摘要、时钟以及共同水位。incremental/differential
链、timeline 切换和真实文件内容验证属于后续源/目标协议职责，当前输入会拒绝前两项。
供应的收据需要附带从带外渠道取得的精确文件摘要；程序只证明输入契约一致，不证明收据真实签发、
物理文件未损坏或某个时间能真正恢复。输出一直含 `liveReadinessVerified=false`、`rtoVerified=false`。

## 只读使用

在开发机上查看未配置缺口，标准输出是机器可读 JSON；不会产生文件：

```powershell
python -I deploy/postgres/backup/offsite_plan.py plan --config deploy/postgres/backup/offsite-internal-server.example.json
python -I deploy/postgres/backup/offsite_plan.py validate --config deploy/postgres/backup/offsite-internal-server.example.json
```

配置 `null` 表示尚未提供，计划返回 `DISABLED_UNRESOLVED`。所有字段填实后仍返回
`CANDIDATE_NOT_CONNECTED`。同机 ID、重叠 IP/目录、路径穿越、placeholder、弱 SSH、混用账户、
过宽历史删除权限、超过 900 秒预算或试图启用会返回 `INVALID_INPUT` 和退出码 78。
退出码 0 只表示草案/证据格式通过，不能作为 ready/activation gate。

若已有独立目标端真实收据，在接收端以 Linux Python 运行：

```sh
python3 -I offsite_plan.py plan --config candidate.json --receipt receiver-completed.json --receipt-sha256 <带外取得的64位小写SHA256>
python3 -I offsite_plan.py validate-receiver-files --config candidate.json
```

`configCanonicalSha256` 按 JSON 键排序、无空白、ASCII 转义的 UTF-8 编码计算，因此不受排版影响；
`walInventorySha256` 对有序 `[{"name":...,"sha256":...}, ...]` 用相同算法。
`--receipt-sha256` 对完整收据文件原始字节计算。哈希校验与解析使用同一次有界读取，拒绝重复键、BOM、
非有限数字和超大 JSON。连接地址和对象摘要是私有运维资料，不要提交填实后的配置或收据。

`validate-receiver-files` 只在 `machine-id` 与配置接收机一致时检查；私钥及 pin 文件必须为接收账户
所有的 0400/0600 普通文件，各级父目录不得是符号链接或被组/其他用户写入。主机 pin 文件只允许
唯一显式的 ed25519 目标项，与带外指纹逐字匹配。私钥内容从不读取或打印。
接收账户也必须能够逐级进入父目录，UID 0 的别名账户会被拒绝。
主机 pin 以 `O_NOFOLLOW` 打开并用同一 fd 的 `fstat` 比对检查时的 inode/device、属主、权限、链接数和
文件版本信息；拒绝硬链接和检查后替换，读取最多 65537 字节，超过 64 KiB 即拒绝。
本机检查还不能证明 forced-command、远端权限、不可变存储或网络隔离已经生效。

## 后续接入门禁

拿到第二台服务器信息后，先只读核实地址、双机 ID、DNS/IP、磁盘、机房与独立账号，核对 SSH 指纹。
完成容量与恢复时长基准、源稳定读取协议、连续原件保护、接收端完成集合/不可变层、引用图清理器及
独立失联告警后，再准备精确目标、配置变更、网络影响、重试/WAL 积压上限和回滚步骤供批准。
实际联机、账户/目录创建、传输、保留清理和定时器启用是后续生产变更；本次没有执行。

上线前必须断网/目标满盘/中断/源删改/凭据滥用演练，恢复任意窗口点并比对财务、库存、审计、
全部原件下载和权限，证明端到端 RPO ≤ 900 秒、RTO ≤ 14400 秒。软件测试或一份供应的 JSON
不能替代该演练，两个故障域和异站/离线副本未证实时仍有共同故障与勒索风险。

本地验证：`python -m unittest discover -s deploy/postgres/backup -p test_offsite_plan.py -v`。
