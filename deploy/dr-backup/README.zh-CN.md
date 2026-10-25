# 公司到云端的成套加密备份操作说明

本目录是独立的运维备份链，不会清空业务数据，也不自动接管业务主库。2026-10-23 本轮收口后保持已安装服务运行；AI 凭据和员工索引均未在生产修改。

## 当前已运行的链路

| 位置 | 单元/目录 | 作用 |
| --- | --- | --- |
| 公司 | `uten-imp-dr-snapshot.timer` | 每 5 分钟生成数据库与实际原件对应的成套快照，分块加密去重后上传 |
| 公司 | `uten-imp-dr-backup.timer` | 每小时生成独立整包密文，作为分块链以外的后备 |
| 公司 | `/data/uten-imp-backups/dr-continuous` | 独立 paired 成套源备份，不改既有 paired/repo1/repo2 |
| 公司 | `/srv/uten-backup/dr-continuous-exports` | 已确认上传的整包密文，仅清理本链超过两天的 ACK 导出件 |
| 云端 | `/srv/uten-imp-dr/continuous` | 唯一命名的密文整包、密文块和签名清单 |
| 云端 | `uten-imp-dr-backup-retention.timer` | 独立 root 定时保留/闭合引用回收，上传账号不能调用删除 |
| 云端 | `uten-imp-dr-backup-publisher.timer` | 每分钟向固定 `127.0.0.1:9087` 控制面发布当前密文恢复点目录 |

上传身份 `uten-dr-ingest` 使用专用 SSH key、固定强制命令和精确 sudo 规则；不提供任意 shell、端口转发、删除或恢复命令。云端没有备份解密私钥。分块 ID 使用公司端独立随机 HMAC key，避免用公开业务原文哈希作为云端对象名。每个新块随机 GPG 加密，私有清单绑定顺序、大小、摘要、随机 nonce 和成套 manifest；公司独立 Ed25519 签名由管理机固定公钥验证。

保留策略是最近 7 天全部完整点、30 天每天一个点、至少 3 个完整点。云端设 **10 GiB 本链预算和 10 GiB 磁盘空闲保留**，容量不够时拒绝新上传，不删除受保护历史来伪造成功。该策略不等于容量已证明足够：实际数据库 dump 变化可能使大量块发生位移，不能按单次低增量估算长期空间。整包约 42.3 MB/小时，分块首次约 27.8 MB，后续实测从约 0.1 MB 到约 26 MB/点不等；上线后应依据实际增长扩容。

这是离散、完整的一致性恢复点。`snapshotRpo15MinutesFresh=true` 只表示最近完整成套点未超过 15 分钟；连续 WAL、任意时刻原件历史、任意 PITR 均尚未完成。市场缓存与客户端发布状态在当前线上 paired helper 中未纳入，状态明确标为 false。云盘目前没有 OSS WORM，root 失陷仍可删除云盘；上传账号受限不等于不可变存储。

## 日常检查

### 采集、传输和保留任务互斥

小时整包与五分钟分块任务各自持有作业锁，防止同一种任务重入；两者仅在创建成套备份、
采集一致原件与必要恢复材料期间共用 `.source.lock`。完整私有密文或内存快照形成后立即释放
采集锁，网络上传、加密后续处理与接收端保留等待不会继续占用它。采集锁最多等待六十秒，
接收端写入与保留共用的互斥锁最多等待三十秒，均计入原有服务总预算；四分钟/三十五分钟的
服务限时保持原值。采集锁排队耗尽时明确记录 `DEFERRED/SOURCE_BUSY`、`health=DEGRADED` 和
`retryPolicy=NEXT_TIMER`，结束本轮并由下一个正常 timer 周期续接，避免三十秒重启风暴。
这不会生成成功恢复点或刷新旧点时间；无新点、旧点过期和实际失败继续可见。接收端等锁耗尽、
备份失败和传输失败仍返回非零，不以延期掩盖这些故障。

接收端保留在同一个互斥锁内先形成整包、快照和对象的完整删除计划，验证两类待保留集合与快照完整引用闭包，
每个唯一、不可变密文块只读验一次；
同一块在不同清单中的摘要/大小有冲突时停止。全部预检完成前不删除任何旧整包、快照或对象，再执行既有保留和
未引用块两天宽限规则。该复用仅存在于本次持锁事务，不跨任务缓存文件状态。

接收端提前拒绝输入时通过标准输出返回固定结构化 `errorCode`。源端会读取该回执，保留
`RECEIVER_BUSY`、`RECEIVER_CAPACITY_LIMIT` 等明确原因；随后的管道关闭不再覆盖它。
没有可信回执、截断、错误摘要或非零退出仍失败，原始 SSH stderr、路径和配置值不会公开。
流式传输使用非阻塞读写，连续六十秒没有本机管道 I/O 进展时失败；有进展的慢传可以继续，
总耗时仍受从作业开始计算的小时三十五分钟、快照四分钟绝对期限约束。快照所有分块 RPC
共享剩余期限，不为每块重新分配四分钟。提前拒绝或写入失败会先关闭输入再读回执，超时与
异常均终止并回收本次子进程和管道，不在内存中一次装入整个密文包。

此修复需要公司端与云端将同一提交的 `continuous_backup.py` 和 `snapshot_chunks.py` 成套安装，
不能只换应用 JAR。先暂停后续 timer 调度并等待实际作业与锁自然释放，私有保存旧脚本，
按现有 root 属主/私有权限原子安装并核对摘要，再恢复原先启用的 timer。不要强杀正在生成的
一致性备份或删除锁文件；回退也应等待所有任务完成后成套恢复旧脚本。四个 DR service 的
`LimitCORE=0` 必须从实际单元与 drop-in 读回确认，避免持有恢复材料的进程生成 core dump。

公司服务器以已有管理员 SSH 身份执行：

```sh
sudo systemctl status uten-imp-dr-snapshot.timer uten-imp-dr-backup.timer --no-pager
sudo systemctl show uten-imp-dr-snapshot.service -p Result -p ExecMainStatus
sudo cat /var/lib/uten-imp-dr-backup/snapshot-status.json
sudo cat /var/lib/uten-imp-dr-backup/status.json
```

云端以受信任管理员身份执行：

```sh
systemctl status uten-imp-dr-backup-retention.timer uten-imp-dr-backup-publisher.timer --no-pager
python3 -I /usr/local/libexec/uten-imp-dr-backup/continuous_backup.py status --config /etc/uten-imp-dr-backup/receiver.json
cat /var/lib/uten-imp-dr-backup/publisher-state.json
```

优先看最新完整点时间、服务退出码、`health`、`freeBytes` 和 `storedCiphertextBytes`。失败时旧完整点仍有效，但不能把旧 JSON 的 HEALTHY 当作当前健康；`status` 命令会重新计算年龄。断线或云重启后下一周期重试，半包不会成为恢复点。需要补一次备份时可 `sudo systemctl start uten-imp-dr-snapshot.service`；同一源锁会阻止与小时任务并发。不要手工删除 `objects/`，它可能被多个保留点共同引用。

控制面归档 publisher 固定 `canDrill=false`，即使源报告成功，控制面仍保存 `keysCovered=false/verified=false`。密文校验通过不能替代管理机真实恢复。目录从最新上报中移除或 publisher 超过五分钟未更新，旧点会显示不可确认可用。当前单次上报最多最新 100 点，云目录中的更早保留点仍在，但需管理员按签名目录选择并独立恢复；后续再完善分页目录，不能将控制面目录视作全部历史。

## 已验证的恢复材料

公司正式远程网关恢复材料已加入严格 allowlist：24 个物理文件及 4 个 LE live→archive 受控链接映射，覆盖 DNS01、正式 ACME 账号、两组 machine CA、受限发布 SSH key、公司 WG private key 和正式 TLS key/cert。测试 CA、CSR、中间 extensions 不采集，不递归导出 `/etc`。2026-10-23 已从云端读回相应密文，在管理机内存中独立验签、解密并逐文件核对摘要，24/24 成功；这项证明不表示已演练灾难接管。

本地新增的“4 个 LE 链接必须同一证书版本”一致性门禁通过了回归，留待统一部署。源侧该单个 helper 已按收口要求恢复为读回验收版本 `15e5d00c0943ba755571a4d32745b70440bacc0ed01b876b36f331145468537b`；本地新版本为 `df148247d348f8b78fea5d4af1157f4a09628fd409ea9073be76b1bb527a0fe5`，不宣称本地所有字节已经激活。

管理机私有目录：

`D:\Projects\uten_imp\.local-artifacts\security-prelaunch-20261023\backup-escrow`

仅当前 Windows 用户及 SYSTEM 可访问。`recovery-private-key.gpg` 为口令保护的私钥导出，`passphrase.dpapi` 使用 CurrentUser DPAPI 托管口令；WSL GPG home 位于 `/home/bruce/.local/share/uten-imp-backup-escrow-20261023`。`recipient.asc` 是可送往备份源的公钥；私钥、口令、历史 HMAC 不发到公司备份源或云端。换管理机/Windows 用户前必须另行安排受保护离线恢复托管，不能假定另一用户能解开 CurrentUser DPAPI。

已保存的私有证据：

| 文件 | 证据 |
| --- | --- |
| `escrow-verification.json` | 新 keyring 私钥重导入、错口令拒绝、正确 DPAPI 口令解密 |
| `continuous-drill/restore-report.json` | 整包真实隔离 PG16 恢复，516 表、V897、1107 个 PGP 值与实际原件核验 |
| `chunk-drill/restore-report.json` | 签名分块闭合依赖重建后，真实隔离数据库与原件恢复 |
| `remote-recovery-readback-receipt.json` | 正式网关 24 文件/4 链接/21 密文块云读回证明 |
| `historical-key-catalog.dpapi` | 历史开发 HMAC 与 `uten-imp-dev` issuer 的本机保护恢复目录；已证明 378 个旧索引与 2 条 AI 密文 |
| `chunk-drill/ai-only-candidate-report.json` | 隔离副本仅重封装两条 AI 密文，员工数据零更新，原文保持一致 |
| `production-ai-candidate.dpapi` | 生产只读采集的旧两行 cipher/version/整行摘要、新密文及配置绑定；不是生产 apply |
| `production-ai-candidate-preimage.gpg` | 上述维护候选旧像的 recipient 加密副本 |
| `identity-collision-review-protected.json` | 待用户核对的 1 组/2 条记录；仅姓名、工号、证件类型/遮罩尾4、状态、删除标记、UUID |

恢复工具 `restore_drill.py`/`restore_snapshot.py` 只在断网、只读根文件系统、非 root、内存 tmpfs 的一次性 PG16 容器中执行；不启动 ERP、不发通知/AI 调用、不连接生产，结束即销毁。`restore_snapshot.py` 先验证固定公司签名公钥，再验 GPG 与每个块的密文/明文摘要、HMAC ID、顺序和成套绑定。私有目录内 `invoke_snapshot_drill.ps1` 演示如何通过 stdin 从 DPAPI 供给口令，固定的是当时验收点；选择新点时应绑定其准确 set ID 与 source manifest SHA，不要覆盖旧报告。

云端管理命令 `continuous_backup.py bundle --config ... --snapshot-id ...` 可导出闭合密文 tar。它只属于管理员 CLI，不在强制上传协议内。Windows 应使用二进制 stdout 文件句柄保存，不能经字符串解码再写文件。不要把解密口令放在命令行、环境配置、聊天或日志里。

恢复报告新增加的 `cloneDatabaseSystemIdentifier`、`cloneRestoredLsn` 与 `pairedRecoveryInputBindingSha256` 已在源码准备；本轮收口未重跑生成这些新字段。它们属于逻辑恢复 clone 的实际身份/LSN，绝不是源库 WAL 水位。旧报告不追补伪造字段。

## 需要后续处理的业务完整性问题

当前公司 384 个已索引值中 6 个使用公司当前 HMAC，378 个沿用了历史开发 HMAC。PGP 原文全部可读，规范化已验证一致；旧 key 对 378/378 精确匹配。规范身份证重建存在一组真实同号记录，会触发正式 `UNIQUE(id_card_hash) WHERE id_card_hash IS NOT NULL`；不同规范原文同一 HMAC 的碰撞为 0。原有 8 个共享手机号重复行不新增等价类。32 个原无身份证 hash 的行必须保留 NULL。

用户先按受保护审阅项中的工号在 ERP 员工管理核对实际档案，并通过正式业务流程更正错误证件资料。若同人两档，应先确认正式业务纠错方案，不能删业务资料、清空 hash 或挑一行覆盖。仅离职、停用或软删不会释放该唯一索引，因为索引谓词不排除删除记录。用户确认并更正后，再用新成套备份重做只读计划、碰撞/依赖检查和隔离克隆验收，最后另行安排有审计的生产维护。

两条 AI 凭据已经证明非已知占位符、存储尾4均匹配；隔离副本用旧 key+dev issuer 解密，并以**公司当前 HMAC+公司当前 issuer**重封装，原文一致、版本递增。生产尚未执行。后续维护须重新核对当前配置摘要、完整旧两行/版本 CAS、数据库身份/授权与重置 epochs，保留加密旧像及显式审计；不得替换公司 HMAC，不调用外部 AI 来猜测有效性。历史 provider history 与旧备份仍需受保护历史 key catalog，不能因新密文可解就宣称历史点全部只需当前 key。

控制面 SQLite 身份/审计状态的异机反向密文备份尚未部署；只有管理机 DPAPI master 不足以重建丢失的身份与审计数据库。其一致性内存 SQLite backup+master/config/两个 token 的加密 get-only 方案草稿保留在 `.local-artifacts`，本轮停止扩展，不纳入已上线清单。备用 Windows 2008 R2 的 `.253` 仍未建立可信连接，尚未写入任何业务数据或密文。

## 本地回归

```sh
cd deploy/postgres/backup
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_sealed_paired_export test_remote_recovery_catalog -v
cd ../../dr-backup
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest test_continuous_backup test_snapshot_chunks test_restore_snapshot test_clone_integrity_candidate -v
```

上述为 Linux/WSL 的 52 项针对性测试，包含真实 GPG、真实 OpenSSH 签名、真实 Node AES-GCM、截断/碰撞/容量拒绝和闭合 GC。它们不替代已有真实恢复收据，也不代表完整接管验收、云 WORM、连续 PITR 或待用户纠错的 PII 索引已完成。

可单独运行 `python3 deploy/dr-backup/benchmark_retention.py --snapshots 256 --chunks 2048`
验证约五十二万条共享引用的保留开销。它只在新的系统临时目录创建合成密文和清单，不接受正式目录，
不会连接服务器或执行生产清理；输出实际核验次数、耗时与保留结果，结束即移除自己的临时夹具。
