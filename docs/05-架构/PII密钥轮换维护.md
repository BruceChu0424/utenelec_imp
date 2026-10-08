# PII 密钥轮换维护

此功能对既有 pgcrypto 密文重新加密，不改变员工资料、审批快照、薪资基数的明文内容，不调整 HMAC，不修改数量、账簿金额和历史审计。默认关闭，仅本地实例提供维护端点；部署本功能不自动启动轮换。源码与隔离测试不能证明公司服务器已经完成轮换。

## 字段范围

`PiiRotationCatalog` 是唯一执行目录，当前覆盖 8 张表的 27 列：

| 表 | 密文字段 |
| --- | --- |
| `employee_sensitive` | 证件、手机、银行账号/支行及 7 项扩展 PII，共 11 列 |
| `employee_compensation` | 5 项原有密文薪资/社保/公积金基数 |
| `emergency_contacts`、`employee_phones`、`visitor_accounts` | 各自的 `phone_enc` |
| `visitor_applications` | `phone_enc`、`id_card_enc`、`plate_no_enc` |
| `profile_change_requests` | 仅 `value_encoding='PGCRYPTO_V1'` 的 `old_value_enc`、`new_value_enc` |
| `employee_reconcile_plan_items` | `old_value_enc`、`new_value_enc`、`candidates_enc`，包含长期保留的已更正证据 |

普通工资条、经营单据、`audit_log`、归档审计与备份均不由本功能重写。AI 服务商密钥使用 `SecretCipher` 的 AES-GCM 机制，仍走其独立版本化流程。

审批快照的整个解密载荷原样重新加密，内层 `uten-profile-change-snapshot:v1:` 标记也必须保留。维护事务绑定 V284 的 codec capability，原数据库守卫继续生效。非敏感 `PLAIN` 快照不会被误当成密文；`LEGACY_UNKNOWN` 会出现在最终余量中，不得据此宣布扫描无残留。

## 配置与执行前条件

1. 先完成经授权的备份与隔离恢复核验。旧备份需要原来的解密密钥，不能因为在线库重包完成就删除旧密钥。
2. 通过服务器受保护的环境/外部配置注入新的 `uten.crypto.pgp-master-key`，并为它选择新的 `pgp-key-version`。历史版本及原密钥放在 `pgp-legacy-keys` 中。任何版本标签不得改绑到另一把密钥。
3. `pgp-unversioned-key-version` 默认固定为 `1`；它表示无前缀历史密文原来使用的密钥。切换当前版本时不能随之调整它。存量无前缀密文会验证后转换为新版本前缀；无法识别或解密的内容保持原样并阻止本批提交。
4. 数据库实际业务连接的 `log_parameter_max_length` 与 `log_parameter_max_length_on_error` 必须都是 `0`。每次执行批次都会只读检查实际连接，不满足时在任何加解密之前拒绝。还应关闭应用、代理及诊断工具的敏感 SQL 参数记录；不能在命令行参数、访问日志或工单中填写/粘贴密钥。
5. 只在本地实例显式开启 `uten.crypto.rotation.enabled=true`（环境开关 `UTEN_PGP_ROTATION_ENABLED`）。`cloud` profile 不注册入口；`uten.deployment.site=cloud` 也会由服务拒绝，即使错误地启用了开关。

受控 `server.env` 的版本编号使用正整数字符串（如 `1`、`2`、`3`），历史钥匙用既有 Spring 环境变量映射
`UTEN_CRYPTO_PGPLEGACYKEYS_1`、`UTEN_CRYPTO_PGPLEGACYKEYS_2` 等登记。不能给当前版本再配置同名历史版本；
当前版本与无前缀历史版本不同时，后者必须出现在历史钥匙目录里。旧钥匙必须保持原值，不能为了满足新钥匙的强度门槛
重新生成或替换它；数据库会用实际密文验证其正确性。此处不展示任何钥匙值。

当前生产安装走 `deploy/simple` / `validate-server-env.sh`，旧受控内测安装走 `validate-internal-test-server-env.sh`；
两者都执行同一 PGP 版本/目录校验合同，内测白名单允许上述窄映射和两个维护开关，不再把当前版本强制降回 `1`。
配置通过 root-only 待审文件和既有受控安装流程合入，禁止用首装示例覆盖现有 `server.env`。
`phase3-runtime.sh` 只在没有现役环境文件时生成版本 `1`、无前缀版本 `1`、维护关闭的首装候选，不重生成现役密钥。
环境文件是数据，不 `source`，不为值加 shell 引号或转义；开启维护不改变旧内测机的附件关闭与网络隔离规则。

这是运行时维护配置，不是启动 runner，也不是数据库迁移自动重包。V827 只建立不含密文的检查点和专用权限。

## 受控 API

所有端点要求 `pii_key_rotation:manage`。权限目录将它固定为 `SUPERADMIN_ONLY`，不能委派给普通账号。服务还从数据库核对当前超管账号有效，拒绝模拟身份。

写入口为 `POST /api/admin/pii-key-rotation/batches`。每次请求都需要本人当前会话的 `X-Uten-Step-Up` 一次性凭证，通过既有 `POST /api/auth/step-up` 以当前密码换取；不要把密码或令牌写入持久脚本及日志。

请求示例仅含维护元数据：

```json
{
  "runId": "e5971052-f715-42f0-88ce-f7473caa12ae",
  "targetVersion": "2",
  "expectedSequence": 0,
  "limit": 50
}
```

为一次新任务生成新的 UUID。后续沿用这个 `runId`，把服务端返回的 `nextSequence` 原样作为下一批的 `expectedSequence`，每批 1—100 行。整个请求中没有接收密钥的字段，也不接受任意表名、列名或 SQL。

查询入口为 `GET /api/admin/pii-key-rotation/{runId}`，不消耗再认证凭证。超时或断线后先读取进度，不能凭请求失败推断本批未提交。同一已提交序号重发只回显进度，不会再重包一遍；超前序号拒绝。

## 原子性、恢复与完成口径

- 一批只锁定一张源表中的最多 100 行。读取的是等待行锁之后的最新值，普通资料修改不会被旧密文覆盖；不跨源表持锁，避免与「先审批申请、后员工 PII」的正常业务形成相反锁序。
- 密文在数据库内通过绑定参数解密、重新加密、再解密，比较 UTF-8 字节相等后才返回新密文；明文不回到 Java。已有当前版本的密文也必须验证可读，验证成功保持原密文字节。
- 一个密文损坏、未知版本、缺少历史密钥或快照域不匹配，会使本批全部修改和检查点一起回滚。异常只包含表、记录主键、字段，不输出密钥、明文或密文。之前成功提交的批次保留，可修复配置后从同一序号继续。
- 检查点与成功审计同事务提交。`pii_key_rotation.batch` 属于 `system` 审计；工作台清空业务数据保留维护检查点与此类审计。
- `RUNNING` 表示仍有目录未扫描，响应里的空余量不代表完成。`SCANNED` 只表示本轮逐行验证已走完，完成时的在线旧版本余量为零。`RESCAN_REQUIRED` 表示检测到旧版本、无前缀或未分类快照，需要排查仍在用旧钥写入的实例，再新建任务从头扫描。
- 查询进度会重新统计在线余量 `remainingByVersion`，所以扫描过的主键范围后来又写入旧版本，仍会被发现。恢复任务也会核验已提交的当前版本密文，防止误换相同版本标签下的密钥后继续办理。
- `canRemoveOldKeys` 始终是 `false`。本接口没有删除或退役密钥功能；备份、WAL、离线副本、旧实例写入窗口和灾难恢复均需要另外的验收。当前版本余量统计也不能替代每个密文的可读性证明。

完成维护后关闭开关。若中途需要暂停，只需停止发送下一批；不要删除检查点、清空密文、修改已应用迁移，或使用不理解新密文版本的旧应用回滚。回退运行配置也必须继续保留所有已写入版本的解密能力。

## 回归依据

`PiiKeyRotationPostgresTest` 在全迁移的隔离 PostgreSQL 中覆盖字段目录、无前缀/多版本密文、UTF-8 内容守恒、当前密文字节不变、同版本错钥、未知/损坏密文整批回滚、检查点与序号回放、审批载荷域、历史审计不改写、并发资料更新和旧版本迟到写入。`PiiKeyRotationSecurityContractTest` 检查默认关闭、本地实例、专用超管权限及写端点再认证。目标服务器执行与真实恢复验收另记。
