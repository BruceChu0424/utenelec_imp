# 旧版 Windows 备用机的密文副本接入

本文用于用户明确授权的第二台内网机器副本。它是待接入操作方案，不代表已经完成传输、
自动备份、不可变保护或恢复演练。现役 pgBackRest、配对备份与保留规则保持各自职责；
不要把第二台机器当作现役 `repo2`，现役 repo2 是生产主机自己的 NVMe 仓。

## 当前接入证据

2026-10-23，从管理机和生产主机分别进行有限 TCP 连接检查：指定备用地址的
22、139、445、3389、5985、5986 均超时。生产主机路由为办公网物理接口直连，
邻居记录为 `FAILED`。这只能说明当前路径未取得可达证据，不能据此判定备用机已损坏，
也不能断言其磁盘、共享、补丁或安全策略正常。

管理机没有该目标的已保存凭据。未进行密码猜测、匿名共享降级、SMB1 启用、
防火墙放宽或证书校验绕过。未向该机器传输数据库、附件、密钥或配置。

实际地址、账号、共享目录、主机指纹与详细运维收据存私有运维目录，不提交 Git。

## 操作系统边界

用户描述的系统为 Windows Server 2008 R2；本轮未登录目标核实版本。
该产品已经结束支持：本地部署第三年 ESU 于 2023-01-10 结束；Azure 额外一年于
2024-01-09 结束。来源见 [Microsoft 生命周期](https://learn.microsoft.com/en-us/lifecycle/products/windows-server-2008-r2)
与 [Microsoft 2024-01 更新说明](https://support.microsoft.com/en-us/servicing/os/windows-7/2024/01/january-9-2024-kb5034167-security-only-update)。

应把这台旧机器迁移到受支持的系统。迁移前如临时存放副本，仅接收已经加密的归档，
不运行 ERP、不连接业务数据库、不保存解密私钥、明文业务配置或明文生产账号凭据。
备份被删除的风险不会因加密而消失，因此该机器上的一个副本不能作为唯一灾难恢复保障。

Windows Server 2008 R2 不提供 SMB3 的传输加密；SMB3 从 Windows Server 2012 引入，
见 [Microsoft SMB 协议说明](https://learn.microsoft.com/en-us/windows-server/storage/file-server/troubleshoot/detect-enable-and-disable-smbv1-v2-v3)。
不以“内网”或共享带密码代替归档加密，不为兼容性开启 SMB1、Guest、弱 TLS 或忽略签名。

## 接入所缺的具体信息

1. 现场确认机器已开机，登记的地址正确，生产主机所在网段能访问；核对机器身份与磁盘健康。
2. 登录后检查实际磁盘剩余容量，选择空间充足的卷并建立专用备份目录；核实独立最小权限账号，
   以及通过安全凭据渠道提供的访问能力。
   不把口令发到聊天、仓库或命令行参数。
3. 确认允许的传输协议、服务器身份校验依据、目录 ACL、签名策略；现代管理机只能写入新副本，
   日常传输账号应无删除已完成历史的权限。生产主机不持有目标历史删除权限。
4. 两位保管人的独立备份加密公钥和带外核对指纹。私钥由保管人分别持有，另有离线受保护副本；
   不临时生成一把无托管、无恢复验证的钥匙后宣称数据安全。

## 可复用的封装与校验流程

接通后先完成一次人工受控副本，再考虑自动化。流程必须由现代管理机或受支持的接收端执行；
旧 Windows 仅保存密文文件。

1. 通过既有严格 SSH 主机校验读取生产端 `latest-success.json`，绑定其中的 `set_id` 和
   `manifest_sha256`。只选择正常成功目录，不选择 `.incomplete-*` 或活动 pgBackRest 目录。
2. 复制期间取得配对备份根目录 `.backup.lock` 的共享锁，与生产程序的独占备份/保留锁互斥。
   有界等待，拿不到锁就失败退出；不停止现役定时器。校验 manifest 摘要及整套 `--verify`，
   再打包该固定成功集，保持锁到源端所有文件读完，防止保留清理在读取中删除它。
3. 必须包括同一集合的 `database.dump`、`manifest.json`、`objects.jsonl`、`references.jsonl`
   及媒体子树；存在受 manifest 绑定的行情状态、客户端发行文件等附加子树时一起封装。
   验证程序不能替代“该集合确实覆盖了所需恢复范围”的审查；旧 manifest 缺少的字段不能手填。
4. 源端直接将 tar 数据流加密给已核对的保管人公钥，随后才跨入旧系统。可采用现役 Runbook 的
   age 多接收人方案；当前生产机尚未安装 age，不能把文档示例当作已具备能力。
   已安装的 GnuPG 可作为审核后的替代，使用公钥 `--recipient-file`，不传入口令；
   该参数假定文件内的公钥有效，所以执行前核对指纹是必要步骤。
   见 [GnuPG 官方命令文档](https://www.gnupg.org/documentation/manuals/gnupg26/gpg.1.html)。
5. 每段管道都检查退出码。管理机以独占创建的 `.partial` 文件接收密文；任何 tar、加密、SSH
   或写入失败均保留为失败证据，不发布成功，不移动成功指针。不得在 PowerShell 文本管道中
   传送二进制归档；使用保留字节的进程流或文件复制。
6. 对已完成密文记录字节数和 SHA-256，经核验的会话复制至目标独立暂存路径；重新从目标
   完整读回计算摘要，相符后发布完成文件。不得覆盖已有完成文件，也不得对目标执行镜像删除。
   Windows 侧可以对读回文件使用 `Get-FileHash -Algorithm SHA256`，无需在旧机器安装解密工具。
7. 管理机保存独立运维收据：固定源集合 ID、源 manifest SHA-256、密文字节数/摘要、目标路径、
   读回摘要、完成时间，以及保管人公钥指纹。收据不含秘密或业务记录；目标上同放的摘要不能
   单独证明来源真实性或抵抗目标管理员删改，可信副本须在另一安全位置保存。
8. 保管人在独立恢复环境解密，运行随归档保留的匹配版本校验器，对整套备份执行 `--verify`，
   并在隔离 PostgreSQL 实例执行实际恢复、密文解密可用性和原件引用核对。
   源环境配置及历史密钥另按现役 Runbook 第 9.3 节离线托管；导出工具可以在同一密文归档内包含
   精确允许的恢复配置，不向目标合成或发送明文恢复配置。

完成密文读回只可记录“异机密文副本已校验”；恢复演练通过后才能记录相应范围“已恢复验证”。
一次副本不表示持续 WAL、十五分钟 RPO、四小时 RTO、历史不可变或整机恢复已经达标。
连续保护仍按 [异机接入合同](OFFSITE_INTERNAL_SERVER.zh-CN.md) 实现和验收，
不能把现有只读规划器 `enabled` 改成 `true` 来替代传输、不可变保护和恢复协议。

## 已实现的受控导出工具

`sealed_paired_export.py` 是独立 Linux 导出器，不修改现役配对程序、保留策略或定时器。
它从标准输入接收公钥，通过完整指纹核对后，仅在内存 fd 向 GnuPG 供应公钥；不需要源机保存
解密私钥或解密口令。导出读取 `.backup.lock`、成功指针及清单，调用同目录已安装的配对校验器，
媒体仅选择对象清单中的实际引用；不收 `database.stderr`、未被绑定的媒体文件或额外 `.env`。

恢复配置只允许精确选择以下路径，`server.env` 必选，以保留当前及历史业务密文解密材料：

```text
etc/uten-imp/server.env
etc/uten-imp/migrator.env
etc/uten-imp/paired-internal-backup.json
etc/pgbackrest.conf
etc/pgbackrest/conf.d/20-uten-imp-repo2.conf
```

这些文件只进入 GPG 密文里的 tar；外部 receipt 只含集合身份、密文摘要、范围标志与公钥指纹。
程序同时打包匹配的恢复校验 helper。输出先写入独占 `.incomplete-sealed-*` 目录，全部加密、
摘要与 fsync 完成后原子发布 `sealed-*` 目录，其中只有 `archive.gpg` 和 `receipt.json`。
失败只清理本次新建的精确暂存目录，不操作任何源成功集、已有密文或成功指针。

运行前单独创建 root 私有的输出目录，并把审核后的新工具安装到现役配对 helper 同目录。
公钥指纹从保管人可信通道核对，示例中的占位符不能直接照填：

```sh
sudo python3 -I /usr/local/lib/uten-imp/sealed_paired_export.py \
  --backup-root /data/uten-imp-backups/paired \
  --output-directory /srv/uten-backup/sealed-exports \
  --recipient-fingerprint <完整核对后的指纹> \
  --recovery-file etc/uten-imp/server.env \
  --recovery-file etc/uten-imp/migrator.env \
  --recovery-file etc/uten-imp/paired-internal-backup.json \
  --recovery-file etc/pgbackrest.conf \
  --recovery-file etc/pgbackrest/conf.d/20-uten-imp-repo2.conf < recipient.asc
```

Linux/GnuPG 合成回归验证了真实加密与解密、原件绑定、不混入无关秘密、恢复配置白名单、
公钥指纹、损坏输入、锁冲突、加密失败、历史密文保留和解密流清单校验。
运行：`python3 -m unittest discover -s deploy/postgres/backup -p test_sealed_paired_export.py -v`。

本轮已在现代管理机创建独立受口令保护的备份接收钥匙；强随机口令由 Windows CurrentUser
DPAPI 保护，目录 ACL 仅当前用户及 SYSTEM。加密导出私钥已重新导入独立 keyring，通过
错误口令拒绝及合成挑战解密验证。该保护仍依赖当前管理机和 Windows 用户；不是两位保管人的
离线托管验收，也不应把解密私钥或 DPAPI 文件复制到旧 Windows 备用机。
