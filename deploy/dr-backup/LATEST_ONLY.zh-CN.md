# 云端仅保留一个完整恢复点

这是显式 opt-in 的云 DR 策略。**没有配置 `retention_mode` 或配置为 `history` 时，仍按原有 7/30 天与最低 3 点执行。公司本地双仓、pgBackRest 与 paired 的 14 天历史不变。** 本功能不购买云容量、不更换真实密钥，也不会自动启用生产策略。

源与接收端同时配置 `"retention_mode":"latest_snapshot"`。稳态跨整包和分块两格式只保留一个最新完整、独立签名的 snapshot；不会两个格式各留一份。排序以真实 `sourceSnapshotAt` 为先，迟到的旧源集不能取代更新源集。活跃导出暂时保护的旧点属于公开的例外，结束后由同一策略继续清理。

## 成功与失败边界

- 每个新点须通过 source 签名、nonce/源集/配置绑定、manifest 密文 SHA/长度与全部 cipher chunk 闭包校验，并将完整 receipt 原子发布、fsync 后，才允许清理旧点。partial/incoming/未引用块不计恢复点。
- 删除前共同 receiver 锁内预检两格式的保留集合、所有活跃导出与上传依赖。最新模式对保留 manifest、签名及去重后的每个 cipher object 实际复核 SHA；不缓存跨操作的“已验证”。
- 失败的上传保留旧点。完整新点已发布但旧清理失败时返回 `cleanupState=FAILED`，source 与 target 均为 DEGRADED；下一次 begin 须先完成旧清理，不能每次失败再积累一根。
- obsolete 先原子移动到 `.latest-retired/<随机ID>/payload`，其 root 私有 marker 记录原始名称、类型与 dev/inode，再删除。删除中断只能继续清理已经脱离有效 catalog 的同 inode payload，不重放陈旧的源路径删除计划。未知内容或替换 inode 保留并阻断。
- 没有真实恢复 commissioning 时保护原有完整旧链，只允许一个新的完整 seed；之后拒绝新增 seed，等待实证验收。profile、恢复配置变化或验收过期会重新保旧并公开原因。

## 上传与孤儿对象的上界

新模式先发送 `beginSnapshotUpload`，固定 point/nonce/source set/manifest/recipient、恢复配置 HMAC 版本与排序后的最多 8192 个 opaque IDs。每 namespace 只有一个 upload lease，总期固定 **900 秒**，相同请求重试仅取回原 lease，绝不续期。probe/put/commit 均须持有 lease 且匹配其固定闭包；history 模式的旧 v1 客户端保持原协议。receiver 的 CLOCK_BOOTTIME 与 boot ID 共同约束期限，墙钟回拨、suspend 或重启不能复活旧 lease。

GC 保护 lease 中已经存在的旧加密对象，因此被复用的历史对象不会在 probe 与 commit 之间被删除。缺失的计划对象不算损坏的完整点。lease 结束后，未被任何完整点/活跃导出引用的对象按 receiver 原子发布 receipt 的时间保留额外 **120 秒**，随后可回收；默认 history 的两天 grace 不变。

只有一个 lease 并不等于总空间足够。每个 put 仍以**整个 storage_root（含 staging、旧根、未引用对象）**核算 `max_storage_bytes` 与 `min_free_bytes`，另留 metadata 余量；超限拒绝新对象并保留旧根，不通过删锚点腾位置。公开 `latestRotationUnreferencedObjectCount/latestRotationUnreferencedCipherBytes`，持续检查容量和 freshness。

新接收 staging 带 root 私有 inode marker；同一 receiver 锁证明旧 writer 已结束后，才可回收已识别的中断 staging。未知旧 `.incoming-*` 不按名字删除，会阻断并要求先核查。每次新接收前先处理这种遗留，防止异常目录无限积累。

## 首次真实恢复与凭据验收

旧 `restore_drill.py` 的 `knownAncillaryCredentialIssuesCleared=false` 是**没有验证所有附属凭据的明确声明**。普通 drill 已实际检查 GPG/PGP、HMAC、数据库和原件，但不会因此声称 AI 的历史 issuer、外部服务凭据或离线私钥托管均已处置。历史证据曾有 AI 凭据需要旧 key/dev issuer；这不是对今天生产值的推断。

不修改这个硬编码、不追补旧报告，也不接受 `cleared=true` 单布尔作为绕过。可达流程如下：

1. 使用 `bundle` 管理命令导出准确新 snapshot。通过受保护输入供给 recipient 私钥口令，在离线一次性 PG16 clone 上执行 `restore_snapshot.py`，绑定准确 source set 与 manifest SHA；保留工具新生成的完整报告。物理 PGDATA 展开空间、实际大包耗时及所有原件必须真实通过，合成测试不能代替。
2. 若附属 AI 凭据需要历史材料，使用已有受限的 `--exercise-integrity-candidate` 路径在**同一个隔离 clone**执行实际解密、当前 issuer 重封装与原文一致性验证。所需历史 HMAC/issuer 材料通过受保护 stdin 提供，不进入命令行/日志。正式数据、公司 HMAC 与现役密钥不在此过程中修改。所有 core HMAC、候选 after blockers 及 `aiCredentialsToRewrap` 须通过；只写一个人工状态字符串无效。
3. 管理员对已恢复的配置做 root 本地独立审查：应用/迁移配置与账号恢复；recipient 与签名信任/离线私钥恢复材料；外部凭据清单中每项确实可恢复，或依照已恢复配置明确关闭。这里不以调用外部 AI 猜测凭据是否有效。任何未恢复的私钥口令或配置缺口均保持 BLOCKED。
4. 将实际报告、三份审查证据和 root review 放到管理员私有目录，目录 root0700、文件 root0600。review 必须绑定准确新点、完整恢复报告 SHA、paired 输入清单 SHA、恢复配置版本、实际 server.env SHA、recipient/signers/principal/namespace/schema profile，并有最多 30 天的有效期。不能把未经检查的模板直接标为 VERIFIED。
5. 确认旧的无租约手工下载已结束，调用下列 root-only 本地 CLI 登记证明，然后独立执行 `retain` 并读回完整状态。登记本身不删除任何点，接口不在上传 RPC 中。

```sh
python3 -I /usr/local/libexec/uten-imp-dr-backup/continuous_backup.py commission-latest \
  --config /etc/uten-imp-dr-backup/receiver.json \
  --snapshot-id '<准确已恢复snapshot ID>' \
  --restore-report '<root私有真实恢复报告路径>' \
  --credential-review '<root私有实证review路径>' \
  --legacy-exports-drained
python3 -I /usr/local/libexec/uten-imp-dr-backup/continuous_backup.py retain \
  --config /etc/uten-imp-dr-backup/receiver.json
```

review 精确 schema（见 `latest_snapshot.credential_review`）：

| 字段 | 实证来源 |
| --- | --- |
| `format` | 固定 `uten-dr-credential-review-v1` |
| `restoreReportSha256` | 原始完整恢复报告文件 SHA；不改写报告 false 字段 |
| `pairedRecoveryInputBindingSha256` | 同一真实恢复报告的完整输入绑定 |
| `configurationVersion` | 已签名 receipt 与真实解密重建报告一致的 opaque 配置 HMAC |
| `configurationFileSha256` | 实际 clone `integrityCandidate.plan.configSha256`，after 必须一致 |
| `profile` | `latest_snapshot.profile(config,base)` 的完整输出 |
| `reviewedAt/expiresAt` | UTC，当前有效，跨度最多 30 天 |
| `checks` | 下述三个独立 scope 的 `scope/evidenceFile/evidenceSha256`，每个文件 root 私有且 SHA 一致 |

三份 evidence 均采用 `format=uten-dr-credential-evidence-v1`，精确字段为 `format/scope/method/state/restoreReportSha256/configurationFileSha256/pairedRecoveryInputBindingSha256/observedAt`。state 仅在对应实际检查完成后为 `VERIFIED`，时间在 review 前一天以内，绑定同一完整输入：

| scope | method | 实际检查 |
| --- | --- | --- |
| `applicationConfiguration` | `RESTORED_CONFIGURATION_AUDIT` | 审阅已恢复的应用、数据库/迁移账号及必需环境；与真实 clone 配置摘要相符，无未处置占位符 |
| `signingAndRecipientRecovery` | `OFFLINE_PRIVATE_KEY_RECOVERY` | 确认 recipient 私钥口令实际完成此次 GPG 解密，固定签名信任有效，离线恢复材料可用 |
| `externalCredentials` | `RESTORED_CREDENTIAL_INVENTORY_AUDIT` | 附属凭据清单审查；AI 真实 clone roundtrip 必须另外由报告的 integrityCandidate 证明，无未处置恢复缺口 |

上述操作性审查是可追溯的 root 证明；程序不会声称自动验证了未调用的外部服务。核心要求同时验证真实 report 中 `databaseRestored/attachmentsVerified/corePgpAndHmacVerified/keysVerified/sourceSignatureVerified/isolated/sideEffectsDisabled=true`、正确状态、source/manifest/reference/config 的精确绑定，以及真实 clone 候选的 after 无 blocker、AI roundtrip 成功、生产未改。缺失、过期、错误 SHA、profile 改变或输入不一致一律不授权删旧。

commissioning 只授权**已验 profile 与恢复配置**轮换，不把后续点标记 restoreVerified。恢复配置 HMAC 覆盖加密清单中的 recovery 文件路径与内容摘要，不公开配置或可猜测的明文摘要。profile/配置改变、证明过期时需新实证；一旦观察到过期，墙钟回拨不能复活旧证明。30 天到期须安排新的真实恢复审查，不能把它当一次永久验收。

## 协调安装与回退

1. 先保存公司/云端**非 secret**版本、unit 与配置 SHA/有效预算。两端同提交安装 `continuous_backup.py/snapshot_chunks.py/latest_snapshot.py`，恢复机同步 `restore_snapshot.py`；libexec 目录 root0700、脚本 root0600。不能漏装新模块。受控备份卷上的 source spool 仍须先核挂载/UUID/剩余空间并 root0700 预建；不回落 `/tmp` 或系统盘。
2. 待正在运行的 DR full 服务完成，暂停公司**专用云 DR full timer**，再同步两端 opt-in 配置；不要停/改数据库、导入容器、pgBackRest 或本地 paired 历史。新模式明确拒绝普通 full submit，避免残留 hourly timer悄悄堆积整包。
3. source 现役 unit 若真实为 15 分钟，显式工作预算可为 `snapshot_budget_seconds=870/snapshot_unit_timeout_seconds=900`；仓库默认仍为 210/240。安装后需读回 effective unit，不用代码默默缩短现场预算，也不加外层 timeout 凑绿。冷 seed 是否能完成必须实测，900 秒 lease 不是性能验收；若不足，保旧并另外设计受控初始化，不能无限续租。
4. 先取得一个完整 seed，再按上节完成真实恢复、凭据审查和 commissioning。首次删旧前不能借历史小包或本地合成回归宣称实际大库可恢复。
5. 读回 root policy 的 activation/cleanup、完整点数、active export 数、orphan 字节、容量与真实捕获年龄。`COMPLETE` 且无 active export 时应跨格式仅剩一个完整 snapshot；受保护导出可临时多点，结束后再 retain。
6. 需要读取旧整包时，用 root-only `archive-bundle --export-id '<已登记ID>'` 导出带真实 FD lease 的 ciphertext tar；snapshot 继续用 `bundle`。新模式不声称普通 scp 自动注册租约。
7. 回退应两端协调恢复 `retention_mode=history`、原配置与已验同批 helper；保持新解码器可读取含配置绑定的新点。history 恢复 7/30/min3 与两天 orphan grace；已经合法轮换删除的云旧历史不会凭回退重现，公司本地历史始终未改。不要自动重启 full timer，先确认原容量预算足够。未知 staging/retired slot 需核查身份，禁止宽泛 rm/手工改 receipt 来“修绿”。

实际生产密钥、profile 和策略由主发布流程统一应用。本文件及合成测试只证明候选实现的边界，不证明新的真实大库已完成 GPG/PGDATA 恢复、15 分钟源 RPO 或公网下载时限验收。
