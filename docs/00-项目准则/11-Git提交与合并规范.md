# 11 - 单维护者 Git 上传与合并规范

> **2026-09-01 起（ADR-060）**：主仓库为 `BruceChu0424/utenelec_imp`（本地 `origin`），旧组织库仅为
> 归档备份（本地 `old-origin`，push 已禁用）。发版 = 在 `main` 上打 `vYYYY.MM.DD-N` tag 并推送，
> `simple-release.yml` 自动构建签名上传 OSS，服务器自动/受控激活。详见
> [ADR-60](../99-决策记录-ADR/ADR-060-单维护者简化发布链与旧发布链退役.md)。

> 本文规定 Uten IMP 的日常代码提交、远端推送、Pull Request（PR）和合并流程。
> 核心原则是：**Git 负责版本与推送，PR 负责合并前门禁；`gh` 只是可选工具，不是提交代码的前提。**
> 公司当前只有 1 名维护者：不虚构第二位 reviewer、不要求自己批准自己，也不为普通内部开发购买
> Enterprise；但秘密扫描、自动测试、`main` 稳定性和服务器发布隔离继续保留。

本文命令中的 `{scope}`、`{description}`、`{task}` 等内容是占位符，执行前必须替换为本次任务的实际值。

---

## 零、单维护者最简流程

| 要做的事 | 最少步骤 | 不需要做的事 |
|---|---|---|
| 日常上传 GitHub | 定向测试 → 精确暂存 → Commit → push `main`（大改动可走功能分支+PR 自审） → SHA 回读 | 不需要 `gh`、第二审批人、OSS、服务器操作 |
| 发版（internal-test） | Quality Gate 全绿 → `git tag vYYYY.MM.DD-N && git push origin v…` → 服务器 5 分钟内自动拉取；纯代码自动激活，含迁移 SSH `activate` | 不需要手动构建、手动传文件、手动改服务器目录 |

上传功能分支只证明代码已在 GitHub；不等于已合并 `main`，更不等于已部署服务器。

日常只有一个任务时，连续使用同一短期功能分支即可，不必为每个小 Commit 新建 worktree。只有确有并行写入、
工作区混入别的任务时才使用独立 worktree。

推荐在完成本次定向测试后运行一条命令：

```powershell
pwsh -File scripts/publish_feature_branch.ps1 `
  -CommitMessage "feat(scope): 简述" `
  -Paths @("path/to/file1", "path/to/file2", "path/to/test")
```

脚本负责暂存明确路径、检查敏感/生成文件、执行 `git diff --cached --check`、Commit、push 和远端 SHA
核对；它拒绝直接推送 `main` / `master`，并在 Commit 前复核暂存树未被改变。脚本运行期间必须停止
其它 Git 暂存/Commit 进程，独占当前 worktree 的 index。

---

## 一、最终规则

| 环节 | 规定 |
|---|---|
| 本地版本管理 | 使用普通 Git 完成分支、暂存、提交和推送 |
| GitHub CLI | `gh` 可用时可以辅助创建/查看 PR；失效时改用 GitHub 网页，不影响 `git push` |
| 日常目标分支 | 从最新 `origin/main` 创建短期功能分支 |
| 合并方式 | 功能分支推送后通过 PR 合并到 `main` |
| `main` | 日常禁止直接推送，禁止任何形式的 force push |
| CI | Quality Gate、CodeQL、Dependency Vulnerability Scan 全部通过后才可合并 |
| 规模 | 一个分支、一个 PR 只处理一个明确业务目标；禁止长期堆积“全量快照/保命快照” |
| 证据 | 本地测试、远端推送、PR 检查和最终合并分别验证，不互相替代 |

PR 是 Git 分支的合并门禁，并不是 Git 的替代品。直接用 Git 把代码推入 `main` 也会触发 CI，
但失败时错误代码已经进入主分支，因此不能用“只用 Git”绕过 PR 或检查失败。

---

## 二、开始开发

### 2.1 普通干净工作区

开始新任务前必须从远端最新 `main` 建分支：

```powershell
git fetch origin --prune
git switch main
git pull --ff-only origin main
git switch -c feat/{scope}-{description}
```

分支、Commit 和 PR 标题遵守[命名规范 §四](01-命名规范.md)：

- 分支：`feat/...`、`fix/...`、`docs/...`、`refactor/...`、`test/...`、`chore/...`
- Commit：Conventional Commits，例如 `feat(sales): 支持批量发货`
- PR 标题：与主 Commit 同口径，准确概括整个 PR

不得从一个长期功能分支继续派生无关功能。确需依赖另一个未合并 PR 时，必须在 PR 描述中写清
依赖关系、合并顺序和解除依赖的方法。

### 2.2 共享工作区或并行任务

共享工作区存在其他人的未提交内容时，不切换分支、不 reset、不覆盖，也不把所有文件一并暂存。
优先从 `origin/main` 创建独立 worktree：

```powershell
git fetch origin --prune
git worktree add ..\uten_imp-{task} -b feat/{scope}-{description} origin/main
```

如果必须在共享工作区继续当前任务：

- 开始和提交前都运行 `git status --short --branch`；
- 明确记录哪些文件属于本任务；
- 只暂存明确属于本任务的路径；
- 检查期间出现新的并行改动时停止提交，重新确认范围；
- 全库格式与完整门禁应在干净 worktree/检出中验证。

---

## 三、控制提交范围

### 3.1 提交前检查

```powershell
git -c core.quotepath=false status --short --branch
git diff --stat
git diff -- path/to/file
```

提交必须覆盖一个可说明、可验证的业务目标。该目标需要的 UI、API、事务、迁移、测试和文档可以在
同一 PR 中闭环；与目标无关的修改不得借机混入。

### 3.2 精确暂存

共享或混合工作区默认使用显式路径：

```powershell
git add -- path/to/file1 path/to/file2
git diff --cached --name-status
git diff --cached --stat
git diff --cached --check
```

只有确认整个工作区都属于同一任务时，才允许 `git add -A`。暂存后必须再次检查，而不能把“执行过
git add”当成提交范围正确的证据。

### 3.3 永不提交的内容

提交前必须排除：

- 真实 `.env`、令牌、密码、私钥、访问密钥和连接串；
- `server/.env`、`build/`、`server/target/`、`.dart_tool/` 等本地生成物；
- 真实业务 CSV/Excel 导出、数据库备份、生产迁移快照和调试转储；
- `website/public/uploads/` 等运行时媒体；
- 临时复现脚本、scratch 测试和仅供本机排障的文件，除非已整理为正式回归测试。

发现疑似密钥时不得简单改名或删当前行来掩盖历史。真实密钥立即轮换；确认是假阳性时，只能使用
精确 fingerprint 忽略并保留原因，禁止关闭整类 Gitleaks 规则。

---

## 四、验证

### 4.1 开发过程中

每次小改动先运行最接近变更的定向测试。跨模块业务链必须验证 UI → API → 事务 → 持久化/
审计事实 → 可见结果，不能只验证按钮或单个 Service。

### 4.2 PR 合并前的完整门禁

普通功能分支上传只要求范围检查和本次变更的定向测试；不必先完成目标库迁移、UAT、签名或服务器
门禁。准备合并 `main` 时，才要求下面与改动范围相关的完整本地检查和当前 PR 远端门禁。

远端真实门禁定义在：

- [quality.yml](../../.github/workflows/quality.yml)
- [codeql.yml](../../.github/workflows/codeql.yml)
- [osv-scanner.yml](../../.github/workflows/osv-scanner.yml)

Flutter/Web 在仓库根目录执行：

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test
flutter analyze --no-pub
flutter test --no-pub
pwsh -File ./.github/scripts/verify-font-assets.ps1
flutter build web --release --no-pub --no-web-resources-cdn --dart-define=API_BASE_URL=/api
```

如果格式检查失败，先对本任务文件执行 `dart format <明确文件列表>`，再在干净 PR 基线运行全库检查。
禁止在带有他人改动的共享工作区直接全库格式化后全部提交。

后端完整验证需要 Java 21、Docker/PostgreSQL/Testcontainers：

```powershell
Push-Location server
try {
  $env:UTEN_RUN_DB_TESTS = "true"
  mvn --batch-mode --no-transfer-progress verify
} finally {
  Remove-Item Env:UTEN_RUN_DB_TESTS -ErrorAction SilentlyContinue
  Pop-Location
}
```

本机不具备完整环境时，可以先推 Draft PR，但必须明确写出未验证项和原因；不得把跳过的数据库测试、
旧报告或另一个工作区的结果写成当前 PR 已通过。

CodeQL 与 OSV 以 GitHub Actions 的本次远端运行结果为准。本地构建通过不等于远端 CI 已通过。

### 4.3 Website 额外门禁

当前 GitHub Actions 尚未覆盖 `website/`。只要修改 `website/`，除远端现有门禁外，还必须在
`website` 目录执行：

```powershell
Push-Location website
try {
  npm ci
  npm run lint
  npm run test:admin-guardrails
  npm run test:catalog-public
  npm run test:catalog-normalization
  npm run test:legacy-series-content
  npm run test:inquiry-security
  npm run test:legacy-import
  npm run test:news-content
  npm run test:seo-localization
  npm run test:publication-guards
  npm run build
} finally {
  Pop-Location
}
```

提交验证不得运行 `db:push`、`db:seed`、`db:upgrade`、`*:apply` 或其它会改数据库/内容的脚本。
需要真实数据迁移时，必须作为单独受控步骤记录目标、备份、dry-run、审批、回滚和结果。

---

## 五、Commit 与推送

### 5.1 Commit

```powershell
git diff --cached --check
git commit -m "feat(scope): 简述"
git status --short --branch
git log -1 --oneline --decorate
```

禁止把未验证的混合改动包装成“全量快照”“保命快照”后作为正常交付。需要保存现场时使用独立临时
分支或 worktree，整理、验证并拆分后才进入正式 PR。

### 5.2 推送功能分支

```powershell
$branch = git branch --show-current
git push -u origin $branch
```

推送成功必须用远端 SHA 复核：

```powershell
$branch = git branch --show-current
$localSha = git rev-parse HEAD
$remoteLine = git ls-remote origin "refs/heads/$branch"
$remoteSha = ($remoteLine -split "\s+")[0]
if ($localSha -ne $remoteSha) {
  throw "远端 SHA 与本地 HEAD 不一致"
}
```

终端没有明确的 push 成功输出，或远端 SHA 不一致时，不得声称“已上传”。

### 5.3 单维护者安全上传脚本

日常使用显式路径：

```powershell
pwsh -File scripts/publish_feature_branch.ps1 `
  -CommitMessage "fix(scope): 简述" `
  -Paths @("lib/path.dart", "test/path_test.dart")
```

脚本不会创建 PR、合并 `main`、打 tag 或部署服务器。本机 Git 代理失效、且已确认可直连 GitHub 时，
可仅对本次网络调用增加 `-DisableProxyForThisRun`，不会修改全局 Git 配置。

用户明确要求“完整上传当前现场”时，使用独立快照分支和双重确认：

```powershell
git switch -c uimp/solo-maintainer-full-upload-YYYYMMDD
pwsh -File scripts/publish_feature_branch.ps1 `
  -CommitMessage "chore(snapshot): 完整上传已审查工作区" `
  -All `
  -ConfirmFullSnapshot UPLOAD_ALL_REVIEWED
```

完整上传只用于保存已经逐项审查的现场。它要求停止并行写入、基于最终冻结字节重跑验证，并自动拒绝
真实 `.env`、私钥、业务 Excel/CSV、备份、构建目录和运行时媒体。包含多个业务目标的快照分支不能
未经整理和完整 CI 直接合并 `main`。

---

## 六、创建 PR

优先使用 GitHub 网页创建 PR：目标分支为 `main`，来源为刚推送的功能分支。`gh` 只作为可选方式：

```powershell
gh auth status
gh pr create --base main --head (git branch --show-current) --fill
```

`gh auth status` 失败时停止使用 `gh`，改用网页；不需要因此重复 commit，也不需要重新 push。

PR 描述使用[仓库模板](../../.github/pull_request_template.md)，至少写清：

- 业务目标和用户影响；
- 本 PR 明确包含/不包含什么；
- UI、API、数据库/Flyway、权限、审计、文档影响；
- 已执行的定向与完整检查，以及未验证项；
- 数据迁移、回滚和兼容风险；
- 关联 Issue、ADR、SOP 或验收文档。

### 6.1 PR 规模

- 一个 PR 只处理一个业务目标；
- 提交历史应能说明实现过程，避免大量无意义 WIP/快照 Commit；
- 达到 GitHub/CodeQL 无法完整展示 diff 的规模（例如 300+ 变更文件）时必须拆分；
- 生成物、锁文件或不可拆迁移造成体积异常时，在 PR 描述中单独解释；
- 依赖前置 PR 时使用显式 stacked PR，并写清 base/head，禁止把所有未合并分支合成一个总包 PR。

---

## 七、CI 失败处理

先区分失败类型：

| 类型 | 处理 |
|---|---|
| `gh`/GitHub App 认证失败 | 修复登录或改用网页；不等于代码或 CI 失败 |
| Git push 失败 | 检查 Git 凭据、远端、upstream 和 fast-forward；不创建重复 Commit |
| 格式、测试、构建失败 | 读取本次作业日志，修复最小根因并本地复现 |
| Gitleaks 命中 | 先判断真实秘密还是假阳性；真实秘密轮换，假阳性精确忽略 |
| CodeQL/OSV 失败 | 修复工作流权限、漏洞或代码问题；不得关闭门禁换绿灯 |
| Cancelled | 检查是否被同一 PR 的新 push 取消，不把 cancelled 误报为代码失败 |

CI 失败时禁止：

- 直接把同一代码推入 `main` 绕过 PR；
- 使用 `--force` / `--force-with-lease` 覆盖 `main`；
- 批量忽略测试、漏洞或密钥规则；
- 用旧运行、旧 Commit 或本地其他工作区的绿色结果代替当前 PR。

---

## 八、合并与合并后验证

满足以下条件才可合并：

- PR 范围、描述、迁移和文档完整；
- Quality Gate、CodeQL、Dependency Vulnerability Scan 本次运行通过；
- 所有 Review 意见已处理；
- 来源分支已吸收最新 `origin/main` 且无未解释冲突；
- 没有未确认的生产数据、权限、会计、库存或迁移风险。

默认通过 GitHub PR 创建 merge commit，保留 PR 边界和审计链。已发布给多人协作的功能分支不做会改写
历史的 rebase/force push；需要同步主分支时使用普通 merge。

合并后验证：

```powershell
git fetch origin --prune
$featureSha = "{合并前功能分支 HEAD}"
git merge-base --is-ancestor $featureSha origin/main
if ($LASTEXITCODE -ne 0) {
  throw "功能分支提交尚未进入 origin/main"
}
git log -1 --oneline origin/main
```

确认 `origin/main` 包含功能分支提交且 main 的远端 CI 正常后，才删除远端功能分支。

---

## 九、直接推送 `main` 的例外

日常开发没有例外。只有明确批准的紧急恢复/热修复才可考虑纯 Git 合并，并同时满足：

1. 从最新 `origin/main` 创建干净隔离工作区；
2. 变更范围单一、可回滚，并有明确批准人和原因记录；
3. 执行与 PR 相同的完整门禁；
4. 本地先生成正常 merge/fast-forward 历史，绝不 force push；
5. 推送后立即核对远端 SHA 和 main 的 Actions 结果；
6. 事后补齐 PR/Issue/事故记录，恢复正常分支流程。

任何“为了让红灯消失而直接推 main”的操作都不属于紧急例外。

---

## 十、提交速查

```text
同步 origin/main
  → 建短期任务分支/独立 worktree
  → 只改一个业务目标
  → 定向测试
  → 精确暂存 + diff/敏感内容检查
  → Conventional Commit
  → git push 功能分支
  → 本地/远端 SHA 对比
  → 已上传（到这里不要求发版门禁）
  → 准备合并时运行完整 Flutter/后端/Website 门禁
  → 网页或可选 gh 创建一个成型 PR
  → 远端三类检查全绿
  → PR 合并 main
  → 验证 origin/main 包含功能提交
  → 只有明确发版时才进入签名、迁移和服务器激活
```
