# 单维护者 internal-test 离线发布例外运行手册

> ⚠️ **已随 ADR-060 退役（2026-09-01）**：本文属旧发布链/旧部署链文档，按 [ADR-060](../../docs/99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md) 保留作未来引入第二维护者时的参考，不再具有操作效力。现役链见 [deploy/simple/RUNBOOK.zh-CN.md](../../simple/RUNBOOK.zh-CN.md)。

## 1. 适用范围与当前状态

本例外只解决私有仓库当前没有可用的第二位人工审核者/Environment reviewer 的现实约束。
它不虚构第二审核人，不要求为了内部测试购买 Enterprise，也绝不把私有 ERP 仓库改为 public。

合并实现本框架的 PR **不会生成 unsigned candidate**；本次没有触发新增 workflow。
unsigned candidate 不等于已签名，不等于 OSS 发布，不等于服务器 staging、activation、UAT 或恢复完成。
当前 H01–H12 为 0/12，项目专用 `known_hosts` 不存在，因此包括只读 SSH 在内仍然禁止。

现有 `.github/workflows/release.yml` 保持不变。离线链不得调用其 `publish-release` 或
`bootstrap-initial-candidate` job，也不得降低其保护门禁。

## 2. 权限和设备隔离

必须使用五个相互分离的权限角色：

1. 人员 Git annotated-tag 签名 key；
2. Release artifact 签名 key；
3. 管理员 SSH Key A；
4. 管理员 SSH Key B；
5. 服务器 Host Key authority。

离线设备只能保存 Git tag key 或 Release artifact key（建议进一步分设备），不得保存 GitHub token、
OSS 凭据、服务器 SSH key 或服务器密码。在线管理机不得保存任何签名私钥。服务器不得保存发布私钥。

`release-decision` 永久固定：

- `environment=internal-test`；
- `singleMaintainerException=true`；
- `independentReviewerPresent=false`；
- `activationAuthorized=false`；
- `stagingAuthorized=false`；
- `remoteTagPublished=false`。

后续 activation 必须产生新的独立授权记录，禁止改写已签 decision。

## 3. 工具摘要的带外冻结

在任何候选字节进入离线设备前，通过独立介质/设备批准并记录以下文件的 SHA-256：

```text
deploy/release/offline_release.py
deploy/release/validate_single_maintainer_decision.py
deploy/release/release_tools.py
deploy/updater/release_guard.py
固定 git / ssh-keygen / ossutil 二进制
Release allowed_signers
Git tag allowed_signers
```

所有离线子命令都必须传 `--expected-self-sha256`；涉及 sibling 工具时还必须传其独立摘要。
运行使用固定 Python 与 `python -I`。verifier 只读取 ZIP/TAR/JAR/Web/SBOM/Flyway 字节，绝不执行
candidate 内的 JAR、Python、Shell、Web、`.pth` 或其他内容。

## 4. GitHub 仅构建 unsigned candidate

仅在目标提交已经是 `main` 当前 head，且该 SHA 的 Quality Gate、CodeQL、OSV 三条 push workflow
共七个 job 全部 `completed/success` 后，才可人工 dispatch：

```bash
gh workflow run unsigned-release-candidate.yml --ref main \
  -f version="$VERSION" \
  -f expected_main_sha="$EXPECTED_MAIN_SHA" \
  -f confirmation=BUILD_UNSIGNED_INTERNAL_TEST_CANDIDATE_NO_SIGN_NO_PUBLISH
```

workflow 只具备 `contents:read`、`actions:read`、`checks:read`，没有 Environment、secret、OIDC、
OSS、签名、服务器、staging 或 activation 能力。它强制 exact-SHA checkout、
`persist-credentials:false`，验证 current main、远端 tag 不存在、workflow path/event/branch/SHA/attempt，
并精确要求以下七个 GitHub Actions job：

1. Secret history scan
2. Backend / Java 21
3. Flutter / Web
4. Deployment contracts
5. Java security and quality
6. Generate dependency inputs
7. scan / osv-scan

缺失、重复、额外 job、旧 attempt、错误 app/path/SHA/event/branch、分页不完整或任何非 success 结论均失败。
构建结果只保留 1 天，仍是 unsigned。

在线管理机随后只读捕获 artifact 和 GitHub 证据（不得把 token 写入参数或日志）：

```bash
export GH_TOKEN=... # 短期、只读；命令结束立即 unset
python -I deploy/release/offline_release.py verify-github-artifact \
  --version "$VERSION" --expected-main-sha "$EXPECTED_MAIN_SHA" \
  --expected-service-sha256 "$ARTIFACT_SERVICE_SHA256" \
  --artifact-id "$ARTIFACT_ID" --workflow-run-id "$RUN_ID" \
  --workflow-run-attempt 1 \
  --require-workflow-success \
  --output-zip unsigned-candidate.zip \
  --output-evidence unsigned-candidate-evidence.json
unset GH_TOKEN
```

## 5. 离线验 candidate 与 signed tag object

把 candidate ZIP、evidence、预审工具和摘要通过只读介质送入离线设备：

```bash
python -I offline_release.py verify-candidate \
  --expected-self-sha256 "$OFFLINE_RELEASE_SHA256" \
  --artifact-zip unsigned-candidate.zip \
  --evidence unsigned-candidate-evidence.json \
  --expected-evidence-sha256 "$GITHUB_EVIDENCE_SHA256" \
  --release-guard release_guard.py \
  --expected-release-guard-sha256 "$RELEASE_GUARD_SHA256" \
  --output-receipt verified-candidate-receipt.json
```

Git tag authority 在离线 Git repository 中创建并签名 annotated tag object，但**不得 push GitHub**。
推送 `v*` 会触发现有在线 `release.yml`，属于另一项授权和冲突处理。本例外只绑定 tag object/bundle：

```bash
python -I offline_release.py verify-source-tag \
  --expected-self-sha256 "$OFFLINE_RELEASE_SHA256" \
  --git-repository ./offline-repository \
  --git-bin /reviewed/bin/git --expected-git-sha256 "$GIT_SHA256" \
  --ssh-keygen /reviewed/bin/ssh-keygen \
  --expected-ssh-keygen-sha256 "$SSH_KEYGEN_SHA256" \
  --allowed-signers ./git-tag-allowed-signers \
  --expected-allowed-signers-sha256 "$TAG_ALLOWED_SIGNERS_SHA256" \
  --tag-bundle ./source-tag.bundle --version "$VERSION" --commit "$EXPECTED_MAIN_SHA" \
  --expected-tag-key-id "$TAG_KEY_ID" --output-receipt source-tag-receipt.json
```

## 6. 准备、decision、四项离线签名

先准备兼容现有 manifest/channel v1 的 publication 输入：

```bash
python -I offline_release.py prepare-publication \
  --expected-self-sha256 "$OFFLINE_RELEASE_SHA256" \
  --artifact-zip unsigned-candidate.zip \
  --candidate-receipt verified-candidate-receipt.json \
  --tag-receipt source-tag-receipt.json \
  --release-key-id "$RELEASE_KEY_ID" --published-at-utc "$UTC" \
  --output-dir publication
```

根据 `publication/publication-inputs.json` 填写
`single-maintainer-release-decision.example.json`，用 validator 验证。示例中的 placeholder 故意不能通过真实验证。
decision 要诚实保留三项残余风险，且 H01/known_hosts 未齐时不得填完成 evidence。
`ossPublicationAuthorized=false` 表示这份单维护者 release decision 本身永远不授权任何云写入；后续
OSS apply 必须另有变更授权、获批 plan SHA-256、精确确认串和短期 STS，不能把 decision 当作写权限。

随后由 Release artifact key 签四个对象：

- manifest：`uten-imp-release-v1`；
- channel：`uten-imp-release-v1`；
- updater wheelhouse attestation：`uten-imp-updater-wheelhouse-v1`；
- release-decision：`uten-imp-single-maintainer-decision-v1`。

```bash
python -I offline_release.py sign-publication \
  --expected-self-sha256 "$OFFLINE_RELEASE_SHA256" \
  --publication-dir publication \
  --expected-publication-inputs-sha256 "$PUBLICATION_INPUTS_SHA256" \
  --decision release-decision.json \
  --decision-validator validate_single_maintainer_decision.py \
  --expected-decision-validator-sha256 "$DECISION_VALIDATOR_SHA256" \
  --private-key /offline/key/release_ed25519 \
  --ssh-keygen /reviewed/bin/ssh-keygen \
  --expected-ssh-keygen-sha256 "$SSH_KEYGEN_SHA256" \
  --allowed-signers ./release-allowed-signers \
  --expected-allowed-signers-sha256 "$RELEASE_ALLOWED_SIGNERS_SHA256"
```

再运行 `verify-publication`，生成 deterministic signed-publication tar 与独立 receipt。私钥在该步骤后保持离线，
不得随 publication 离开设备。verify 会在制 tar 前对每个成员做 regular/single-link 字节快照，并要求
artifact、`.sha256` sidecar、backend/flutter SBOM 和 updater attestation 分别与 signed manifest/decision
lineage 一致；在线 plan 会再做同一反向绑定，重算 inventory 或未签 receipt 不能替换这些 standalone 对象。

## 7. 在线 create-only OSS publication

在线管理机只接收已签 publication 与 receipt。先用只读 OSS 权限取得并验签旧 `LATEST`、旧 channel/signature；
新 sequence 必须严格递增。`plan-oss-publication` 零写入，只产生 canonical plan。首次 bootstrap 必须使用：

```text
CREATE_INITIAL_SIGNED_INTERNAL_TEST_POINTER_ONCE
```

普通后续 publication 必须使用：

```text
PUBLISH_VERIFIED_SIGNED_INTERNAL_TEST_OBJECTS_CREATE_ONLY
```

计划命令必须同时传固定 `ssh-keygen`、Release `allowed_signers`、`release_guard.py` 和 decision validator
及各自带外 SHA-256。普通发布还必须传已从 OSS 只读取得的旧 `LATEST`、旧 channel 和 signature；plan
会把旧 pointer 原字节/摘要写入批准计划。示意：

```bash
python -I offline_release.py plan-oss-publication \
  --expected-self-sha256 "$OFFLINE_RELEASE_SHA256" \
  --signed-publication signed-publication.tar \
  --publication-receipt signed-publication-receipt.json \
  --bucket "$BUCKET" --endpoint "$HTTPS_ENDPOINT" --region "$OSS_REGION" \
  --confirmation "$PUBLISH_CONFIRMATION" \
  --allowed-signers release-allowed-signers \
  --expected-allowed-signers-sha256 "$RELEASE_ALLOWED_SIGNERS_SHA256" \
  --ssh-keygen /reviewed/bin/ssh-keygen \
  --expected-ssh-keygen-sha256 "$SSH_KEYGEN_SHA256" \
  --release-guard release_guard.py \
  --expected-release-guard-sha256 "$RELEASE_GUARD_SHA256" \
  --decision-validator validate_single_maintainer_decision.py \
  --expected-decision-validator-sha256 "$DECISION_VALIDATOR_SHA256" \
  --output-plan oss-publication-plan.json
```

`apply-oss-publication` 只从环境读取短期最小权限 STS，不接受 credential 参数。所有 version 对象和 versioned
channel 都 create-only，每一个对象上传后立即逐字节、有大小上限地 readback；`LATEST.txt` 永远最后。核心
对象键保持与 updater 合同一致：`channels/candidate/<version>.json|.sig`、`releases/<version>/manifest.*`
和 `releases/<version>/sbom/...`。失败时不删除、不覆盖 immutable 对象；重试时只接受已存在且字节完全
一致的对象。

apply 在第一笔 version 写入前先 create-only 抢占永久
`channels/candidate/transitions/<old-pointer-sha256|ABSENT>.json`。记录绑定旧 pointer、获批 plan、
signed-publication、目标 version 与 sequence；同一旧 pointer 的异计划永远拒绝，同计划可精确续跑。
随后在第一笔写前和 `LATEST` 更新前都重读 plan 绑定的旧 pointer，并输出独立 OSS byte-readback receipt，
不把半成品伪装成成功。示意：

```bash
export OSS_ACCESS_KEY_ID=...
export OSS_ACCESS_KEY_SECRET=...
export OSS_SESSION_TOKEN=...
python -I offline_release.py apply-oss-publication \
  --expected-self-sha256 "$OFFLINE_RELEASE_SHA256" \
  --plan oss-publication-plan.json \
  --expected-plan-sha256 "$OSS_PLAN_SHA256" \
  --confirmation "$PUBLISH_CONFIRMATION" \
  --signed-publication signed-publication.tar \
  --ossutil /reviewed/bin/ossutil \
  --expected-ossutil-sha256 "$OSSUTIL_SHA256" \
  --output-receipt oss-byte-readback-receipt.json
```

## 8. 永久 NO-GO 边界

- H01–H12 或项目专用 `known_hosts` 缺一项时，包含只读 SSH 在内都禁止；
- updater/retention timer 保持 disabled；
- staging 和 root activation 只能人工执行；
- decision 不授权 staging/activation；
- 未取得目标库 `flyway_schema_history` 前，V304 target lineage 仍 unknown；
- 未完成可恢复备份、目标库精确校验、真实岗位 UAT、故障/重启/监控验收前，internal-test 仍 NO-GO。
