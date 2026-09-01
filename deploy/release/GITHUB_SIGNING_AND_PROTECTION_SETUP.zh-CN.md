# GitHub 保护/签名/发布 authority 配置执行清单

> **⚠️ 已归档（2026-09-01，ADR-060）**：现役发布链的 GitHub 配置只需 3 个 secret + 2 个 variable，
> 见 [`deploy/simple/RUNBOOK.zh-CN.md`](../simple/RUNBOOK.zh-CN.md)。本清单（组织 ruleset/Environment/OIDC）
> 是旧链要求，仅作未来多人团队的加固参考。

> **日期**：2026-08-15（Asia/Shanghai）
> **当前 checkout 对应仓库**：`BruceChu0424/uten_imp`；若转移到最终 Organization，必须先更新本清单、
> OIDC policy config、Environment 和全部读回证据，再允许发布
> **配套合同**：[release/README.md](README.md)（签名发布与 staging 合同）、[../current-test-server-status.zh-CN.md](../current-test-server-status.zh-CN.md) §8、
> [../aliyun-oidc/README.zh-CN.md](../aliyun-oidc/README.zh-CN.md)（OIDC/OSS 最小权限与不可消除 NO-GO）
> **强制边界**：本清单只配置外部 authority。在 §1–§6 全部完成并留存读回证据前，**禁止 push 受保护
> 分支、打 tag、dispatch release.yml**——release.yml 的 Protected source gate 会 fail-closed，但不得以
> “试试看”的方式验证。人员 Git 签名、Release 制品签名、服务器管理员 SSH 密钥和服务器 Host Key 是四类
> 独立 authority，禁止复用。
>
> **2026-08-29 单维护者口径**：公司当前只有 1 名维护者。源码 PR 不虚构第二审批人，也不以购买
> Enterprise 作为内部开发前置；PR required approvals 设为 0，由最终 diff 自审 + required checks 留证。
> internal-test 继续执行 ADR-044 的离线签名和人工激活补偿控制。下方 2026-08-15 网页实测保留为
> 历史快照，当前远端设置仍需重新读回，不能用该快照冒充现状。

## 执行状态（2026-08-15 凌晨实测，先于一切步骤阅读）

1. **仓库已在组织 `UTEN-ELECTRICAL` 下**（网页实测，私有）。本机 `origin` 仍指向旧个人地址
   `BruceChu0424/uten_imp.git`（GitHub 会做重定向，短期内可用）。**必须先确认这是 transfer 还是并存副本**；
   是 transfer 则择期 `git remote set-url origin <新地址>`，并在发布前按 §0.1 重新核对所有绑定了
   owner/repository 的项（ruleset、Environment、OIDC subject、读回证据）。
2. **`protect-main` ruleset 已创建**（5 条 branch 规则、覆盖 1 个分支），但页面横幅明确：
   **免费版 Organization 的私有仓库不执行 ruleset**，需升级 GitHub Team 才执法。此前"所需 plan 未证明"
   现已证实为硬阻塞。`protect-release-tags` 与两个 Environment **尚未创建**。
3. **Quality Gate #58（main@bd70d7f，手动 dispatch）结果**：`Flutter / Web` ✅；`Secret history scan` ❌——
   gitleaks 命中 `website/tests/admin-guardrails.test.ts` 的 `TEST_AUTH_SECRET`（commit `0403391`），
   2026-08-14 晚本地扫描已定性为**测试常量误报**，待按固定 commit+路径+规则登记 `.gitleaksignore`；
   `Backend / Java 21` ❌——注解仅有 deprecation 警告，**失败根因待 job 日志尾部确认**（注意这是 main 上的
   旧代码，不是当前工作树）。正面效果：三个检查名已注册，可在 ruleset 的 required checks 中搜索到。
4. **负责人决定（2026-08-15）**：外部 authority 配置整体推迟；在 plan 升级并走完 §1–§6 之前，维持
   禁止 push 受保护分支、打 tag、dispatch release.yml，发布链与目标机均保持 NO-GO。

## 0. 前置事实（已核对工作流源码）

- Quality Gate 工作流（`quality.yml`）当前在 PR 和 push 到 main 时运行四个 job：`Secret history scan`、
  `Backend / Java 21`、`Flutter / Web`、`Deployment contracts`。CodeQL 与 OSV 另提供三个 job；
  internal-test 候选按源码合同精确核对共七个 job。
- 发布工作流（`release.yml`）只接受 `v*` tag 或带精确确认串 `CREATE_INITIAL_CANDIDATE_POINTER` 的手动 dispatch；运行时硬校验：
  - tag 必须被 ruleset/保护规则覆盖（`github.ref_protected=true`）；
  - tag 必须**精确指向当前 `origin/main` 头**（`git rev-parse refs/remotes/origin/main == GITHUB_SHA`）；
  - `main` 分支 API 的 `protected` 必须为 `true`。
- 版本格式 `vYYYY.MM.DD-N`，N=1..999（由 `deploy/release/release_tools.py validate-version` 校验）。
- 仓库内 Actions 已全部按 commit SHA 钉住——配置时**不要**改成浮动 tag。
- 2026-08-15 本机只读核对显示 `user.signingkey`、`commit.gpgsign`、`tag.gpgsign`、`gpg.format` 均未配置，
  `gh auth status` 也报告默认 token 无效；因此当前不能读回远端保护设置，更不能把历史截图当成现状。
- GitHub 当前官方文档说明：Free/Pro/Team 的 Environment required reviewers 只适用于 public repository。
  当前单维护者内部开发不启用无法履行的 required-reviewer + prevent-self-review 假门禁，也不得为此把
  ERP 仓库改成 public；发布补偿控制按 ADR-044 的独立设备/密钥、离线签名、decision record 和人工激活执行。
  参考：<https://docs.github.com/en/actions/reference/workflows-and-actions/deployments-and-environments>。

### 0.1 先冻结最终仓库身份与套餐

1. 确定最终 owner、Organization、repository 名称、可见性与 GitHub plan；推荐公司 Organization 下的
   GitHub Enterprise Cloud。
2. 若需要 transfer，先完成 transfer 和权限复核，再配置 ruleset、Environment 与 OIDC。OIDC trust 不得绑定
   一个随后还会变化的 `owner/repository`。
3. 由仓库管理员、独立发布审核人、安全/云负责人分别登记职责；同一人不能创建 release、批准自己的
   Environment deployment 并单独掌管 Release 私钥。
4. 恢复受控 CLI 读回能力时用浏览器完成 `gh auth login -h github.com -w`；不得把 token 粘贴到聊天、脚本、
   文档或 shell history。网页设置与 REST/CLI 读回必须指向同一最终仓库。

### 0.2 单维护者 internal-test 离线例外

当真实维护者只有一人、私有仓库套餐又没有可用 required reviewer 时，不得虚构第二审核人、双账号互审、
购买与风险不匹配的套餐或把 ERP 仓库改 public。可改用
[`SINGLE_MAINTAINER_INTERNAL_TEST_RUNBOOK.zh-CN.md`](SINGLE_MAINTAINER_INTERNAL_TEST_RUNBOOK.zh-CN.md)
与 ADR-044 的离线补偿控制，但它仅适用于 internal-test，并且不能弱化本文件的正式生产发布合同。

该例外的 GitHub workflow 只产生 unsigned candidate；Git tag object 与 Release artifact 使用不同离线 key，
在线管理机只处理已签 publication 和短期 create-only OSS 凭据。Release decision 永久
`activationAuthorized=false`。现有 `release.yml`、manifest/channel/updater schema 均不修改。
离线路径必须在空 bare repo 验证完整 tag bundle；OSS apply 必须先以旧 pointer 摘要 create-only
占用永久 transition 记录，再按现有 updater 对象键执行有上限的逐字节回读，最后更新 `LATEST`。
Git tag key、Release key、Admin A、Admin B、Host Key authority 必须相互分离；离线设备不得保存 GitHub、
OSS 或服务器凭据。H01–H12/项目 `known_hosts` 不齐时，包括只读 SSH 也继续 NO-GO。

## 1. main 分支保护（GitHub 网页：Settings → Rules → Rulesets）

新建 branch ruleset，命名如 `protect-main`：

- Target：default branch（`main`）。
- Rules 勾选：
  - **Require a pull request before merging**；当前单维护者阶段 required approvals = 0，不虚构非作者 reviewer；
  - **Require conversation resolution**；以后有独立维护者时再启用 stale/latest approval 规则；
  - **Require signed commits**；
  - **Require status checks to pass** 且 branch 必须 up to date → 添加四个精确 Quality Gate 检查名：
    `Secret history scan`、`Backend / Java 21`、`Flutter / Web`、`Deployment contracts`（先在功能分支/PR 运行
    `quality.yml` 注册检查名，禁止为了注册检查直接 push main）；
  - 状态检查来源固定为预期 GitHub Actions App，不接受任意来源伪造同名 status；
  - **Block force pushes**、**Require linear history**、**Restrict deletions**、**Do not allow bypassing**。
- Enforcement：Active。
- 读回证据：`GET /repos/BruceChu0424/uten_imp/branches/main` 返回 `"protected": true`；保存去敏 JSON 截图/导出。
- 第一批进入受保护 main 的提交也必须由已登记的人员 Git signing key 签名并在 GitHub 显示 `Verified`。

## 2. release tag 保护（同一 Rules 页面）

新建 tag ruleset，命名如 `protect-release-tags`：

- Target tags：Include by pattern `v*`。
- Rules：**Restrict creations**（仅 maintainer/admin）、**Restrict updates**、**Restrict deletions**、**Block force pushes**。
- 读回证据：打一个**测试以外的**空操作不可行——改为保存 ruleset 列表页截图；release.yml 运行时会用 `ref_protected` 实测，首次真实 tag 即为验收点。

### 2.1 人员 Commit/Tag 签名 authority

人员 Git 签名密钥只证明谁批准了 Git 对象，不等于 §4 的 Release 制品签名密钥。推荐使用独立 FIDO
Ed25519；软件 Ed25519 必须带强口令并由受控 agent/凭据库解锁。把公钥在 GitHub
`Settings → SSH and GPG keys` 中登记为 **Signing Key**，然后在本仓库配置：

```powershell
git config gpg.format ssh
git config user.signingkey "$env:USERPROFILE\.ssh\uten_imp_git_signing.pub"
git config commit.gpgsign true
git config tag.gpgsign true
```

不得在当前脏工作树创建空提交测试。候选冻结后，在功能分支形成真实签名提交，并同时保留 GitHub
`Verified`、公钥 SHA-256 指纹与第二人复核记录。正式 release 使用签名 annotated tag；受保护 tag 与签名
tag 是两个不同门禁。当前 `release.yml` 只强制 tag protection、main equality 和 source SHA，尚未独立验证
tag object signature，因此首次发布前还必须由第二审核人执行 `git verify-tag` 并保存结果；后续应把该验证
纳入 CI 后再取消人工补充证据。GitHub 签名说明：
<https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification>。

## 3. 两个 Environment（Settings → Environments）

分别新建 `production-release-publisher` 与 `production-release-bootstrap`。私有仓库必须先满足 §0 的套餐
边界；设置页不显示 Required reviewers/Prevent self-review 时就是 **NO-GO**，不得只创建空 Environment 冒充
审批边界。两者配置相同的三条：

- **Required reviewers**：加至少 1 名非触发者 reviewer；勾选 **Prevent self-review**。GitHub 内置列表即使
  配置多名 reviewer，通常只要求其中一人批准；需要“两名审核人都批准”时必须再结合 PR 审批或外部变更系统，
  不能把 reviewer 列表长度误报成审批次数。
- **Deployment branches and tags**：选择 **Selected branches and tags**，只添加 tag pattern `v*`；若当前
  Enterprise UI 提供等价的 **Protected tags only**，必须同时证明 §2 tag ruleset Active 且读回结果精确。
  不选 “All branches and tags”，不添加 branch 或 PR ref。
- 禁止管理员 bypass（若租户策略提供该选项）。
- 留存每个 environment 设置页的截图作为评审证据。

## 4. Release 制品签名密钥（在一台受信管理机上执行，不是服务器）

```bash
umask 077
ssh-keygen -t ed25519 -a 100 -C uten-imp-release -f ./uten-imp-release-ed25519
ssh-keygen -E sha256 -lf ./uten-imp-release-ed25519.pub   # 记录指纹，作为发布证据
```

- 私钥**只**放进 `production-release-publisher` 环境的 secret `RELEASE_SIGNING_PRIVATE_KEY`；不得进 repository/
  organization secret、不得进服务器、不得复用为人员 Git signing key 或管理员 SSH 登录密钥。当前 workflow
  接口要求非交互、可导出的 OpenSSH 私钥，这只是 Enterprise Environment 审批和全新 GitHub-hosted runner
  下的过渡 custody；组织不允许该模式时必须先改为 HSM/KMS/离线签名 job，不能删门禁让现有 job 勉强运行。
- 公钥按 canonical 三字段格式 `uten-imp-release ssh-ed25519 <BASE64>` 写入**两个**环境的变量 `RELEASE_ALLOWED_SIGNERS`（每行一个当前有效 key）。
- 同一公钥行将来还要落到服务器两处：`/etc/uten-imp-release-trust/release-allowed-signers` 与 `/etc/uten-imp-updater/release-allowed-signers`（目标机事务时执行，先登记在交接里）。
- 轮换当前是 NO-GO（无受审重叠轮换事务）；密钥泄露即走变更重签，不手改信任文件。

## 5. 阿里云 OIDC + OSS（安全/云负责人执行，仓库只提供渲染物）

按 [../aliyun-oidc/README.zh-CN.md](../aliyun-oidc/README.zh-CN.md) 执行，要点：

1. 复制 `deploy/aliyun-oidc/policy-config.example.json` 到**工作区外**受控路径，只填非秘密参数（不得填 AccessKey/token/密码）。
2. `render-policies.py` 渲染 → `validate-policies.py` 静态校验（注意：`--require-commissionable` 必须返回非零并保留 COMMISSIONING NO-GO 字样，这是预期，不是故障）。
3. 渲染结果作为**受控变更**在阿里云应用：OIDC IdP、publisher/bootstrap 两个 RAM role（精确
   issuer/audience/final repository/Environment subject）、downloader role、OSS bucket。
4. 不猜 OIDC subject。仓库转移、重命名以及 GitHub immutable repository-ID subject 都可能改变 `sub`；必须
   从真实 acceptance job 保存不含 token 的实际 `iss/aud/sub`，据此重新渲染，并完成正确 subject 成功、错误
   repository/environment subject 拒绝的正反验收。
5. Bucket 必须启用 **Versioning** 并锁定 **COMPLIANCE WORM**；读回 RAM/OSS 配置并保存证据。
6. 已知不可消除项（不得在验收里声称已消除）：RAM 无法对 `PutObject` 强制 create-only/CAS，靠
   forbid-overwrite + Versioning + WORM + 回读缓解。
7. 本步产出 §6 表格所需的 6 个值：OIDC provider ARN、bucket 名、endpoint、region、publisher role ARN、
   bootstrap role ARN。

## 6. 回填 Environment 变量/secret（精确对照）

`production-release-publisher` 环境：

| 类型 | 名称 | 值来源 |
|---|---|---|
| secret | `RELEASE_SIGNING_PRIVATE_KEY` | §4 私钥全文 |
| variable | `ALIYUN_OIDC_PROVIDER_ARN` | §5 第 7 项 |
| variable | `ALIYUN_OSS_BUCKET` | §5 第 7 项 |
| variable | `ALIYUN_OSS_ENDPOINT` | §5 第 7 项（纯 HTTPS origin） |
| variable | `ALIYUN_OSS_REGION` | §5 第 7 项 |
| variable | `RELEASE_ALLOWED_SIGNERS` | §4 公钥行 |
| variable | `ALIYUN_RELEASE_PUBLISHER_ROLE_ARN` | §5 第 7 项 |

`production-release-bootstrap` 环境：同上 variable 六项，但 role 变量换成 `ALIYUN_RELEASE_BOOTSTRAP_ROLE_ARN`；**不放任何 secret**（bootstrap job 设计上无私钥、无 checkout）。

历史静态 CI publisher AK/SK 若存在：先在私下轮换/撤销并留存无秘密证据，再启用本工作流。

## 7. 冻结提交与首次发布（§1–§6 全部有证据后）

1. 从干净受审工作树形成签名提交并通过 PR 合入受保护 main（冻结顺序见续作交接 §5.1：leaf helper →
   consumer → verifier → updater → preparer/builder 重算固定 SHA 后全套验证）。读回 GitHub `Verified`，并
   证明 local HEAD、remote feature branch、PR merge commit 和 `origin/main` 的关系。
2. 从最新 `origin/main` 创建从未使用过的签名 annotated tag 并验证后推送：

   ```text
   git tag -s v2026.MM.DD-1 -m "Uten IMP v2026.MM.DD-1" <main-head>
   git verify-tag v2026.MM.DD-1
   git push origin v2026.MM.DD-1
   ```

   tag 必须精确指向 main 当前头、GitHub 显示 `Verified` 且受 §2 ruleset 保护，否则 Protected source gate 或
   人工签名门禁拒绝。禁止使用 lightweight tag、仅 `-a` 的 unsigned tag、移动旧 tag 或从功能分支打 tag。
3. 首个候选指针只能走一次性 bootstrap：Actions → `Signed production release` → Run workflow → ref 选该 tag → 填 `CREATE_INITIAL_CANDIDATE_POINTER`。命令行等价：
   `gh workflow run release.yml --ref "v2026.MM.DD-1" -f confirm_initial_bootstrap=CREATE_INITIAL_CANDIDATE_POINTER`
4. bootstrap 成功后**停用/删除 bootstrap role 授权**（见 aliyun-oidc README 身份边界表）；之后日常发布只走 push `v*` tag。
5. 任何一步失败：不为了重试而授予 delete/覆盖权限；查半成品对象，用新的受审版本号重发。

## 8. 每步必须留存的证据

- 最终 owner/repository/visibility/plan、仓库管理员、发布审核人和安全/云负责人的职责记录；
- main/tag ruleset 读回 JSON 或设置页截图，以及 main `protected=true`；
- 两个 Environment 的 required reviewers / prevent-self-review / selected `v*` tags / no-bypass 设置截图；
- 人员 Git signing key 指纹、签名 commit/tag 的 GitHub `Verified` 与 `git verify-tag` 结果；
- Release 制品签名公钥指纹（`ssh-keygen -E sha256 -lf` 输出）与 `RELEASE_ALLOWED_SIGNERS` 行数核对；
- 阿里云 RAM role trust/permission、bucket Versioning+WORM 的读回与 OIDC 正/反验收记录；
- 首次 bootstrap 的 workflow run 链接、签名 manifest/channel 的 OSS 回读字节比对结果。

## 9. 硬 NO-GO 提醒（来自 release README，配置时逐条自查）

- build/test job 不得能读到签名或云 secret；publish/bootstrap job 不得 checkout 仓库；
- OIDC subject/audience 不得宽于精确 repository + Environment；
- OSS downloader 不得有写/删权限；CI 不得能覆盖版本化对象；
- CLI token 无效、remote ruleset/Environment 无法读回、套餐不支持 private required reviewers、commit/tag
  未显示 `Verified` 或任何审批可由触发者自批时，均保持 NO-GO；
- 不把真实 ARN、私钥、token、AccessKey、密码或其他秘密写进 Git、聊天、日志或本文档。公钥和指纹虽不
  是秘密，仍只在受控 evidence 中保存，公开文档只登记去敏引用。
