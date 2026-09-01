# GitHub OIDC → 阿里云 RAM/OSS 最小权限闭环（v1）

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../simple/RUNBOOK.zh-CN.md)。

本目录只生成、校验和验收策略，不创建或修改任何真实阿里云资源。生产启用前必须由云平台/安全负责人把渲染结果作为受控变更应用，再读回核对并保存证据。GitHub 仓库身份、套餐、ruleset、Environment、人员
Commit/Tag 签名与 Release 制品签名的前置清单见
[GitHub 保护/签名 authority 配置执行清单](../release/GITHUB_SIGNING_AND_PROTECTION_SETUP.zh-CN.md)。

## 结论与不可消除的 NO-GO

截至 2026-08-15 复核的本仓库合同，阿里云 OIDC 角色条件键使用 `oidc:iss`、`oidc:aud`、`oidc:sub`。
`iss` 和 `aud` 必须使用 `StringEquals`，`sub` 可使用字符串比较。v1 模板固定使用精确 `StringEquals`，
不接受通配符，并把两个 GitHub Environment 分开：

- 日常发布：`production-release-publisher` → 独立 publisher role；
- 一次性初始化：`production-release-bootstrap` → 独立 bootstrap role；
- 内部服务器：不信任 GitHub；只允许一个精确 RAM role（短期 workload identity/broker）假设 downloader role，下载角色本身只有 `oss:GetObject`。v1 配置拒绝 RAM user Principal，避免把长期 AccessKey 伪装成角色方案。

GitHub 使用 Environment 时，默认 OIDC `sub` 是 `repo:<owner>/<repo>:environment:<name>`，不会同时包含 tag ref。
因此必须先冻结最终 Organization/仓库身份，再在云端精确绑定实际 repository + Environment；tag ref 由三层
互补门禁绑定：受保护的 `vYYYY.MM.DD-N` tag、两个 Environment 的 selected-tag deployment rule，以及工作流
对 `github.ref`、`github.ref_type`、`github.ref_protected` 的 fail-closed 检查。不得声称 RAM trust 本身已经校验
ref。正式启用前必须从真实 acceptance job 保存不含 token 的实际 `iss/aud/sub`；若组织使用不可变 repository-ID
subject，必须按实际 subject 重新渲染并做正确/错误 subject 正负验收，不能猜测或沿用仓库转移前的值。

OSS 的首次上传与同名覆盖都使用 `oss:PutObject`。官方 OSS 条件键列表没有“对象尚不存在”、ETag CAS 或 `x-oss-forbid-overwrite` 条件键。因此 RAM 策略无法把 `releases/*` 和版本化 channel 对象真正强制成 create-only，也无法对 `LATEST.txt` 强制 CAS。模板虽把“不可变对象”和可变 `LATEST` 分成独立 Statement，二者仍是同一个 RAM Action。

所以：

1. `ossutil --forbid-overwrite` 只是客户端请求保护，绝不是 IAM 保证；
2. 静态校验可 PASS，但 `--require-commissionable` 必须返回非零并保留 `COMMISSIONING NO-GO`；
3. 真实 bucket 至少要启用 Versioning，并锁定 COMPLIANCE WORM，保留历史版本和不可删除证据；
4. WORM + Versioning 仍允许同名上传形成新版本，不能消除“当前版本被替换”的风险；必须保留非生产同名覆盖实测和发布签名/回读证据；
5. 若安全负责人要求 IAM 层真正 create-only/CAS，则当前阿里云能力下仍是 NO-GO，需要把不可变制品与可变 pointer 分桶/引入独立受控指针服务，或等待可验证的服务端条件能力。

官方依据：

- [RAM OIDC 角色及三个条件键](https://www.alibabacloud.com/help/en/ram/user-guide/create-a-ram-role-for-a-trusted-idp)
- [RAM 角色精确 RAM user/role Principal](https://www.alibabacloud.com/help/en/ram/user-guide/edit-the-trust-policy-of-a-ram-role)
- [RAM 策略元素与 Resource ARN](https://www.alibabacloud.com/help/en/ram/policy-elements)
- [OSS Action、Resource 与受支持条件键](https://www.alibabacloud.com/help/en/oss/user-guide/authorization-syntax-and-elements)
- [PutObject、默认覆盖与 `x-oss-forbid-overwrite`](https://www.alibabacloud.com/help/en/oss/developer-reference/putobject)
- [Versioning 及 forbid-overwrite 在版本控制下不生效](https://www.alibabacloud.com/help/en/oss/user-guide/overview-78/)
- [WORM 与 Versioning：同名上传会创建新版本](https://www.alibabacloud.com/help/en/oss/user-guide/oss-retention-policies)

## 三个身份边界

| 身份 | 信任 | Allow | 明确没有 |
|---|---|---|---|
| publisher | 精确 GitHub issuer/audience/repository/publisher Environment | 读取并逐字节回核 release、`LATEST` 与版本化 channel；写 release、版本化 channel 和 `LATEST` | List、ACL、策略、Bucket 管理、Delete |
| bootstrap | 精确 GitHub issuer/audience/repository/bootstrap Environment | 首次写入及回读 release、版本化 channel、`LATEST` | List、ACL、策略、Bucket 管理、Delete；完成后必须停用/删除角色授权 |
| server downloader | 精确 RAM role Principal，不信任 GitHub | `GetObject`：`releases/*`、版本化 channel、`LATEST` | Put、Delete、List、ACL、Bucket 管理 |

`server-assumer-permission.json` 只允许源角色假设一个精确 downloader role。现有 updater 能读取短期 `OSS_SECURITY_TOKEN`，但仓库尚无自动续期 broker；在根控制的短期凭据续期完成前，不得把服务器角色方案标为已投产。禁止给 RAM user 附加 downloader permission，禁止在 GitHub/服务器保存长期 AK/SK；任何历史长期 AK/SK 必须先在私下轮换/撤销并留存无秘密证据，不能把密钥放入 Git、聊天、命令行或日志。

所有 OSS Allow 都要求 `acs:SecureTransport=true`。publisher/bootstrap 还显式 Deny 对本发布前缀的对象/版本删除，防止其他误附加 Allow 绕开删除边界；角色上仍必须只附加一个本目录的自定义策略。

## 渲染与静态校验

复制示例配置到工作区外的受控路径，只填非秘密参数。不要填 AccessKey、OIDC token 或任何密码。

```bash
python3 deploy/aliyun-oidc/render-policies.py \
  --config /secure/change/policy-config.json \
  --output /secure/change/rendered-v1

python3 deploy/aliyun-oidc/validate-policies.py \
  --bundle /secure/change/rendered-v1
```

校验器要求：精确文件清单、非符号链接、精确 schema、三个不同 role、publisher/bootstrap 不同 Environment、精确 issuer/audience/sub、精确 Action/Resource、HTTPS 条件、downloader 只有 GetObject，以及策略字节与 v1 模板完全一致。篡改任一 Action/Resource/Condition 都失败。

检查当前发布工作流是否已切换独立边界：

```bash
python3 deploy/aliyun-oidc/validate-policies.py \
  --bundle /secure/change/rendered-v1 \
  --workflow .github/workflows/release.yml
```

当前源码中的 `release.yml` 已切换为独立边界；上面的命令应返回 0。源码通过不代表真实 GitHub/阿里云已配置。
必须先按中央 GitHub 清单确认最终仓库和套餐；私有仓库若不能提供 required reviewer、prevent self-review 与
selected-tag deployment rule 的等价能力，保持发布 **NO-GO**，不得把 ERP 仓库改成 public 规避限制。启用前
必须设置并验收：

- `production-release-publisher`：`ALIYUN_RELEASE_PUBLISHER_ROLE_ARN`；
- `production-release-bootstrap`：`ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN`；
- 两个 Environment 都设置相同的非秘密 `ALIYUN_OIDC_PROVIDER_ARN`、OSS bucket/endpoint/region 与
  `RELEASE_ALLOWED_SIGNERS`；publisher Environment 单独持有 Release 制品签名 Secret；required reviewers、
  prevent self-review、selected `v*` tag 和 no-bypass 分别读回验收。人员 Git signing key、Release signing key、
  Admin SSH key 和 Host Key 不得复用。

## 真实环境验收（默认只出计划）

默认命令不调用云 API：

```bash
python3 deploy/aliyun-oidc/acceptance.py --bundle /secure/change/rendered-v1
```

只读验收需要操作员已在进程外配置的阿里云 CLI/ossutil 管理会话；脚本不接受秘密参数、不打印环境变量，并拒绝把带 credential-like 字段的响应写入证据：

```bash
python3 deploy/aliyun-oidc/acceptance.py \
  --bundle /secure/change/rendered-v1 \
  --read-only \
  --evidence /secure/evidence/aliyun-oidc-2026-08-12
```

它会读回三个 role 的 TrustPolicy、精确且唯一的自定义权限策略、OSS Versioning 和锁定 WORM。证据目录必须不存在；创建后为 `0700`，文件为 `0600`。只读 PASS 仍会记录 create-only/CAS NO-GO。

用已获得的某一个短期角色会话做对象权限正负验收（该命令只有 GET/List/GetBucketInfo，没有写操作）：

```bash
python3 deploy/aliyun-oidc/acceptance.py \
  --bundle /secure/change/rendered-v1 \
  --role-read-probe server-downloader \
  --evidence /secure/evidence/downloader-read-probe-2026-08-12
```

脚本要求读取现有 `LATEST.txt` 成功，同时 `ListObjects` 和 `GetBucketInfo` 必须被拒绝。publisher、bootstrap 分别改用对应参数和短期会话重复执行。若 `LATEST` 尚未初始化，这项正例不能通过，不能把 `NoSuchKey` 当成权限成功。

OIDC 正负交换由手工 dispatch 的 `.github/workflows/aliyun-oidc-acceptance.yml` 完成。它不 checkout、不执行仓库脚本、不访问 OSS、不上传对象，只验证：publisher subject 能假设 publisher role 且不能假设 bootstrap role；bootstrap 反向同理。必须从要验收的受保护 tag dispatch，同时输入 `READ_ONLY_OIDC_ACCEPTANCE` 和精确 `refs/tags/vYYYY.MM.DD-N`；预检要求实际 ref 完全相等、类型为 tag 且 `github.ref_protected=true`。两个正例还要求 action 产生非空 security token，以证明是短期 STS 会话。保留预检、两个 Environment 审批及四个正负 job 结果。

## 显式非生产写验收

生产 bundle 永远拒绝写测试。另渲染一个 `environmentClass=nonproduction`、独立测试 bucket、`keyPrefix=acceptance/<change-id>/`、`nonProductionWriteTestAllowed=true` 的 bundle，并让当前临时测试身份只得到该前缀的等价策略。确认字符串包含实际 bucket 和前缀：

```bash
python3 deploy/aliyun-oidc/acceptance.py \
  --bundle /secure/change/nonprod-v1 \
  --write-test \
  --evidence /secure/evidence/aliyun-oidc-write-2026-08-12 \
  --confirm 'WRITE_TEST:actual-nonprod-bucket:acceptance/CHG-1234/'
```

脚本只写很小的测试对象：先在允许的 release 测试路径 create，再进行一次不带 `forbid-overwrite` 的同名覆盖；同时尝试一个前缀外 Put、Delete 和 List，后三项必须被拒绝。任一禁止操作成功都会保存退出码并返回 NO-GO。测试身份没有 Delete，探针对象故意保留供审计。绝不能把生产 bucket、空前缀或普通 release 前缀用于写验收。

## 应用、风险与回退

本目录不提供自动 apply。受控应用顺序是：先创建三个无权限 role → 设置精确信任 → 创建版本化 custom policies → 逐一附加 → 只读读回 → 非生产正负验收 → 配置并人工验收两个 GitHub Environment → 运行只读 OIDC 正负工作流 → 才允许受保护 tag 发布。bootstrap 首次使用并完成全部对象回读后立即停用其 Environment 并撤销/删除 role 授权。

回退不是放宽权限：撤销 workflow Environment 访问，Detach 新策略或恢复上一版精确信任策略，并撤销未使用的 role；OSS WORM 锁定后不可缩短/关闭，这是有意的不可逆安全控制，启用前必须在非生产验证容量、保留期和成本。不得为了让 CI 通过而临时授予 `AliyunOSSFullAccess`、`oss:*`、Delete、List 或 bucket 管理权限。
