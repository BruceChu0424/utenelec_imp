# 目标服务器带外身份与访问 authority 执行清单

> **日期**：2026-08-15（Asia/Shanghai）
> **适用范围**：Uten IMP 现有内部 ERP 测试服务器
> **配套合同**：[当前目标机状态](current-test-server-status.zh-CN.md)、
> [续作交接](ERP_INTERNAL_TEST_SERVER_CONTINUATION_HANDOFF.zh-CN.md)、
> [操作手册](operator-guide.zh-CN.md)、[脱敏交接模板](server-handoff.example.md)
> **强制边界**：本文只定义带外材料、验收方法和首次只读连接前置条件。真实地址、账号、人员、序列号、
> 公钥、指纹、工单和网络范围只保存在受控 CMDB、加密交接库或密码管理器中，不进入 Git、聊天、命令行
> 历史或普通日志。材料未齐全时不得连接目标机；材料齐全后也只能先执行经批准的只读刷新。

## 1. Authority 不是一个密码

必须由相互独立的责任人提供并复核以下证据：

| 证据 | 提供者 | 证明内容 |
|---|---|---|
| CMDB 资产记录 | 资产负责人 | 目标环境、资产、FQDN/IP、端口、管理账号和责任归属 |
| SSH Host Key | 现场或 BMC 控制台操作员 | 连接到的是经登记的那台服务器，而不是中间人或同地址新主机 |
| 管理员 Key A / Key B | 两名管理员或两个独立受控设备 | 登录能力不依赖共享密码或单一设备 |
| VPN/VLAN/源路由 | 网络与安全负责人 | 管理路径经过批准且没有临时公网暴露 |
| 物理/BMC 控制台 | 现场运维 | SSH/UFW 变更失败时存在独立恢复入口 |
| 口令轮换记录 | 运维负责人和复核人 | 曾在非密码管理器渠道出现的旧口令已失效 |
| 维护与回退批准 | 变更负责人和第二审核人 | 只读刷新与后续写入不是同一项默认授权 |

以下密钥角色必须分离，不得复用：人员 Git Commit/Tag 签名密钥、CI/离线 Release 制品签名密钥、
管理员 SSH Key A、管理员 SSH Key B、服务器自身 SSH Host Key。

## 2. CMDB 资产元组

资产负责人必须在受控系统中填写并标记采集时间与有效期：

```text
environment：internal-test
asset ID / physical location / serial reference
current FQDN / IP / SSH port
management username and sudo boundary
operating system and ownership team
collectedAt / expiresAt / collector / reviewer
change ticket and incident contact
```

公开仓库只登记该记录是否存在及其去敏引用，不复制真实值。任何字段为空、过期或与现场不一致都保持
**NO-GO**；不得根据旧 `known_hosts`、旧聊天、DHCP 记录或历史快照猜测目标身份。

## 3. 从真正带外控制台取得 SSH Host Key

现场人员必须通过物理键盘显示器或已验收的 iDRAC/iLO/IPMI/KVM 控制台登录目标操作系统。不能先通过待验证的
SSH 会话取得指纹，再把同一结果称为“带外证明”。在控制台执行只读命令：

```bash
hostnamectl --static
for key in /etc/ssh/ssh_host_*_key.pub; do
  sudo ssh-keygen -E sha256 -lf "$key"
done
```

私下保存完整公钥行，并记录：算法、SHA-256 指纹、CMDB 资产引用、采集人、采集时间、控制台类型和复核人。
优先使用 Ed25519 Host Key。不得读取或复制 `/etc/ssh/ssh_host_*_key` 私钥。

若现场结果与历史 `known_hosts` 不同，必须同时存在正式轮换记录，写明旧/新指纹、原因、时间、执行人与复核人。
没有轮换记录时立即停止；不得删除本地旧记录、使用 `StrictHostKeyChecking=no` 或点选“仍然连接”。

`ssh-keyscan` 只能在已经取得带外公钥/指纹后用于网络侧字节比较，不能创建信任根。

## 4. 两把独立管理员密钥

Key A 与 Key B 必须分别由两名管理员或两个真正独立的受控设备保管。优先使用 FIDO Ed25519；否则使用带强
口令、受操作系统凭据保护的独立 Ed25519 私钥。每名管理员只交付公钥，并在自己的受控设备上生成 SHA-256
指纹：

```text
ssh-keygen -E sha256 -lf <ADMIN_PUBLIC_KEY_FILE>
```

受控记录必须包含：公钥算法、指纹、持有人/设备、用途、创建时间、到期或复核时间、撤销联系人。不得把私钥、
私钥口令或 agent socket 交给另一名管理员，也不得把人员 Git 签名密钥或 Release 签名密钥拿来登录服务器。

若目标机尚未安装两把公钥，必须另开“SSH access bootstrap”变更，在物理/BMC 控制台保持打开的情况下，按
[操作手册 §4.0](operator-guide.zh-CN.md#40-ssh-与-ufw-的两阶段切换)分阶段安装和验收。安装公钥、轮换口令、
修改 SSH/UFW 都是服务器写入，不属于本文的只读材料收集，也不能在首次只读连接中顺便执行。

## 5. 批准网络路径

网络与安全负责人必须给出：

```text
VPN/zero-trust profile and MFA/device policy
approved source CIDR and source device/user boundary
target FQDN/IP and exact TCP port
firewall/ACL/change record and expiry
route owner and emergency revocation contact
```

路径必须是公司 LAN、企业 VPN/零信任或经审计跳板。禁止为了远程维护临时公网暴露 SSH、PostgreSQL、
8080/8081、Actuator 或 ERP HTTP。网络连通性只证明“可达”，不能代替 Host Key、账号授权或控制台证据。

## 6. 控制台、口令与回退

在任何 SSH/UFW 写入前必须完成并记录：

- 物理/BMC 控制台实际登录成功，且变更期间保持可用；
- 控制台账号、MFA/保管责任与故障联系人已确认；
- 曾在聊天、普通文档、命令行或非密码管理器渠道出现过的旧服务器口令已通过私密渠道轮换；
- 只记录“已轮换”、时间、工单、执行人与复核人，不记录新旧口令值；
- Key A 与 Key B 均能建立新的独立会话并完成账号和 sudo 边界只读验证；
- 失败时的恢复人、回退入口和会话保留顺序已写入变更单。

## 7. Project-specific `known_hosts`

审核端必须从第 3 节取得的**完整带外公钥行**预制项目专用 `known_hosts`，不得让首次网络连接自动写入信任。
文件中的 host 字段必须与 CMDB 的 FQDN/IP 和端口精确一致。审核端再次执行：

```text
ssh-keygen -E sha256 -lf <PROJECT_KNOWN_HOSTS_FILE>
```

结果必须逐字匹配带外记录。首次连接固定使用以下安全属性：

```text
BatchMode=yes
IdentitiesOnly=yes
StrictHostKeyChecking=yes
UpdateHostKeys=no
ForwardAgent=no
PasswordAuthentication=no
KbdInteractiveAuthentication=no
UserKnownHostsFile=<PROJECT_KNOWN_HOSTS_FILE>
```

不得使用 `accept-new`、默认交互确认、agent forwarding 或共享全局 `known_hosts` 隐式接受目标。首次连接会产生
SSH 审计日志，因此也必须位于已批准的只读维护窗口内。

## 8. 首次连接只允许刷新事实

Authority 材料全部通过后，首次会话只采集：主机/boot/time、LVM/NVMe/旧 md、`fstab`/挂载、监听、
PostgreSQL system identifier 和 `flyway_schema_history`、systemd unit/timer/effective properties、旧 Phase
evidence、备份与证据目录。不得安装包、修改文件、写数据库、`enable/start/stop`、改防火墙或 reboot。

尤其要先确认旧 `uten-imp-phase1-resume.service` 是否仍可在 reboot 时触发；在它通过受审事务证据化退役以前，
禁止计划重启。只读结果必须与同一受保护提交生成并签名的 Flyway manifest 逐版本、script、checksum 对比；
不得使用 `flyway repair`、旧 JAR 或手工 SQL 掩盖不一致。

只读刷新完成后，操作员必须另行展示精确写入计划、风险、回退和验收点，并取得人工确认。只读批准不能自动
升级为存储、数据库、发布、监控、备份或重启写入授权。

## 9. 完成记录

受控交接记录至少包含：

```text
H01 CMDB/资产记录引用
H02 当前环境/FQDN/IP/端口/管理用户已核对
H03 Host Key 算法、SHA-256 指纹与完整公钥的保管引用
H04 Host Key 带外采集人、时间、渠道和复核人
H05 Host Key 轮换记录或“无轮换且与基线一致”证据
H06 Admin Key A 指纹、持有人和到期/复核时间
H07 Admin Key B 指纹、持有人和到期/复核时间
H08 VPN/VLAN/来源 CIDR 与防火墙变更引用
H09 物理/BMC 控制台实测记录
H10 泄露口令轮换记录（无口令值）
H11 只读维护窗口、操作人和审核人
H12 回退负责人、应急联系和证据保管位置
```

对外协作只报告每项“已完成/未完成”和去敏引用。任何秘密、真实地址、完整公钥或主机指纹不得粘贴到聊天；
需要自动核验时，从受控本地文件稳定读取并禁止回显。

## 10. GO/NO-GO

只有 H01–H12 全部有效、两把管理员密钥和控制台均实测、项目 `known_hosts` 与带外 Host Key 一致，才允许开始
首次只读刷新。完成这些材料不等于服务器已部署；GitHub/Release authority、签名候选、目标机安装、数据库
迁移、HTTPS/UAT、备份/PITR、故障与 reboot 仍须分别验收。
