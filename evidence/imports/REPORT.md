# C 包整改与验收

当前主线/被审版均为 `fdeda88b3d73b24b8691ad132caa765196b19a3d`。实施工作树 `D:/Projects/uten_imp_worktrees/feedback-remediate-c-20261110`，分支 `uimp/feedback-remediate-c-20261110`。产品提交为 `85418bf82c4795d94940d88ccd2f08c34daf75ec`、`9eccf1850cd9f5806342c4136f8777ca6d3f425b`。历史夹具修正提交为 `43116cb7fff9288b4f43ec1c87b4ef38f8e582fb`，原断言全部保留。没有修改已应用迁移、没有新增迁移，也没有合 main、上传、部署或正式打包。

本文为 C 包阶段证据；最终整合 SHA、同一候选的真实网页/桌面闭环及独立总复核由根验收报告统一记录，不能用本包阶段 SHA 替代。

## 原反例、公共修复及合法对照

| 问题 | 被审版实测 | 当前处理、适用入口及对照 |
|---|---|---|
| 成本额外列含“产品名称：A” | `baseline/probe-files-0.log`：v1 接受，仅保留铜柱，铜钉消失 | 成本标题必须是独立字面量行；混合明细/标题明确定位第3行，公式不能充当标题/表头；无归属的非空结构行、缺材料名称的有值行不能静默丢弃。沿原 `ImportColumnGuard` 分块验证未知/同义列。合法独立标题、多块、缓存金额公式、缺价非零补、样式空尾保留；`cost-legal.xlsx` 的两条材料均保留，真实公开服务已应用逐行 SKIP 映射并落不可变映射回执。 |
| 经营备注 D 冒名/未知 | 原 v1 两份文件均 issues=0，只采用 AC | `FinanceOperatingNoteParser` 逐一核对原30列标签；中间列只允许真实月份/比率只读字段，第28列保留1–12月平均动态标签，AC/AD 写入列保持原位置。两份原件明确拒绝第4列，真实月份金额继续只读；合法备注实际写入1条。 |
| 科目未知 D 放到小计 | 原 v1 小计漏检并可 APPLIED | 无条件保留公共原单元格守卫的问题，不再按“普通明细已接管”抑制整本问题；首次有值位置明确到原行/列，按列有界去重。小计不生成科目；真实 PG 的新预览有问题、apply拒绝，合法目录实际写入1条。 |
| 凭证物理第84列空缓存公式/第83列假签名 | 原版两种均 issues=0、2条分录 | 会计模板选择前先查原工作簿可见性/物理内容；凭证分支也核对物理尾列。83列表头签名结构及原账套、公司原文和年度一致，名称内合法冒号保留；假签名拒绝。合法 BIFF8、纯样式空尾、真实借贷分录保留；额外表空缓存公式不能漏掉。凭证/余额提交仍由原会计映射、完整期间及不同人复核合同控制。 |
| 货品/BOM 第二张表 | 原探针：货品签 planId；BOM 到达模拟写适配器 | 复用 `ImportColumnGuard.requireSingleContentSheet` 检查全部工作簿实际单元格/公式/隐藏内容；有内容的额外表明确定位，不签可执行计划，所有 commit/merged 路径复检。样式空表可留；行/列/单元格及文本预算扩展到所有物理工作表，未增大原预算。当前真实 Spring+真实仓库的 detect、commit、APPEND/REPLACE/merged 均拒绝原件，数据库货品/BOM未变。 |
| 同义、空表头、平台 marker/只读列 | 原有保护部分存在 | 公共守卫继续处理有值未知列、同义/重复、空表头、空缓存公式；平台 marker 验实际 sheet/header/index/label、去重UUID/index及安全整数，缺损/未来版/过大/错引用拒绝。UUID/scope/index/label、共享 columnSets、续表和加密后识别已复跑；带平台列必须重导仅系统列，标记不授予写权限。库存/折扣/BOM真实用料等既有只读字段的写入规则未扩大。 |

指纹口径：产品 Java/测试等 Git 源文件用 Git blob 字节；原件、日志、退出码和数据库dump用实际原始字节。新 `evidence/imports/.gitattributes` 仅固定本目录原始证据/归档文本为 `binary`（含 `-text`，保留CRLF实际字节，不对原始日志运行源码空白规范化），不改旧审查的两个属性文件或其指纹。`manifest.json` 记录源码/原始字节的独立SHA-256。

`original-file-manifest.json` 对本次入 Git 的11份原 XLS/XLSX 与旧审查原件逐字节核 SHA-256，全部一致。原审查目录 `D:/Projects/uten_imp_worktrees/feedback-audit-20261110/audit` 未改写。旧探针实际执行源码归档为 `baseline/probe.executed.ps1.txt`，不能原地执行覆盖现有证据；复现基线应先复制到新输出目录。新基线探针输出、原版成功复现错误的断言保留；新回归断言表达正确业务结果。

## 七类完整调用方

| 类型 | 共享权威入口 | 提交/应用 |
|---|---|---|
| 货品 | `GoodsImportService.parse`→`GoodsImportWorkbookSecurity`→公共守卫 | detect、带行修正/排除的检测、原文件 commit 均重检；不扩大业务写入批次 |
| BOM | `GoodsBomImportService.parseAndValidate`→同一工作簿守卫 | detect、APPEND、REPLACE、merged；原锁顺序/状态指纹/删除权限保留 |
| 成本 | `SpreadsheetEvidenceReader`、`GoodsCostWorkbookParser`、公共分块列守卫 | `GoodsCostImportService.preview/apply`；原 `CostImportEvidenceGuard` 与映射记录保留 |
| 科目 | `FinanceChartWorkbookParser`、原工作簿守卫 | `FinanceChartService.preview/repreview/applyCommand`，原文件重读、原命令及父子谱系保留 |
| 凭证/余额 | `FinanceAccountingWorkbookParser`、`SpreadsheetImportVisibility`、原物理尾列守卫 | `FinanceAccountingImportService.preview/submit/approve`；成对批次、原审核操作与已POSTED结果优先级保留 |
| 辅助明细 | `FinanceAuxiliaryWorkbookParser`、原物理列守卫 | `FinanceAuxiliaryImportService.preview/recheck/applyDirectory`；`FinancialAuxiliarySourceReadAdapter` 的会计资格也要求当前服务端安全版本 |
| 经营备注 | `FinanceOperatingNoteParser`、原物理列守卫 | `FinanceExpenseAnalysisService.previewNotes/applyNotes`；原owner、期间锁、原成功回执顺序保留 |

Web 与 Flutter 桌面复用以上 HTTP/文件合同；没有仅靠前端传字段修守卫。当前文件守卫/契约由服务端维护，客户端不能自报 `columnContractVersion` 获权。

## C2：旧程序实际签发 v1 后升级

`ImportColumnGuard.VERSION` 升为 **2**。五类持久化来源由各自服务器构造器签发当前版本；旧 JSON 不 UPDATE，V755/V1090 及原不可变约束未关闭。货品旧内存计划/BOM提交仍重读原 bytes。旧成功/停止/未知回执和身份核对顺序不改：备注先返回原 applied_result，再看期间锁/版本；科目、辅助及会计原成功/停止/已提交/已记账结果优先于新应用安全门。成本原成功映射与已保存成本可读取/保留，新的重新映射必须使用当前安全文件，不回写旧结果。

真实隔离 PostgreSQL 16.15 容器 `uten-remediate-c-upgrade-1110`，回环端口 **26632**，数据库 `imports`。旧程序加载旧审查 build（原源码 fdeda88b3），正常应用1068次迁移至V1129，使用实际普通员工/用户（`is_super_admin=false`）的公开服务签发并持久化以下原件：

- 成本攻击 v1：铜钉已被旧程序漏掉，只剩一条。
- 科目小计攻击 v1 及真正公开 repreview 派生的子批次。
- 经营备注 D 重复列攻击 v1（未应用）。
- 辅助明细 v1；原凭证与余额 v1。
- 另有合法经营备注由旧程序真实应用，客户端不采用首次响应，然后经正常服务锁定期间。

原 UUID、owner、原回执、父子及7份不可变预览 JSON 在 `old-program-manifest.json`。升级前真实整库备份为 `imports-before-v2.dump`，12,832,379字节，原始二进制 SHA-256 `120f2ad263a1304e641302b7daf23b809be550298e9b7a086a4884f58fb463f6`；文件不进入源码 Git，本地保留。它不是公司数据库备份。

`upgrade-verify-2.log` / `.exit`：新程序读取同一数据库，五类旧待应用来源（含科目父/子）全部明确拒绝；原7份 JSON逐字相同，业务表无新增。旧合法备注原owner、原ID、锁期后返回同一原JSON，备注仍只有一条；另一个真实员工/普通账号持同权限被拒。辅助 v1 也不能作为新会计接续的有效来源。输出 `UPGRADE_VERIFIED pendingKinds=5 immutableParentsAndChild=true noBusinessWrites=true oldAppliedReceiptReplayedAfterLock=true otherOwnerRejected=true`，退出0。

恢复步骤：保留旧批次与原件/来源；未应用旧预览先从当前程序重新导出仅系统列、核对原数据，再新检测。仅改文件名不会改变内容哈希；原错误列仍会被新解析拒绝。需要重新生成时更改实际安全内容/导出格式，而非伪造版本。已经完成的科目/会计记录或成本映射不自动回改、冲销或重建；发现旧业务实际被错误应用时保留原回执，由原岗位按原人工更正合同处理。

## 实际运行与边界

这些组有重叠，不能相加。

| 分组 | 通过/失败/错误/跳过 | 原始证据 |
|---|---|---|
| 当前物理原件/解析与合法对照，13类 | **58 / 0 / 0 / 1**，共59项 | `candidate-2/parsers.log`，23.625秒；唯一缺少 `UTEN_FINANCE_SOURCE_DIR` 的私有旧会计文件条件跳过 |
| 旧程序真实签发→同库新程序提交，五类来源 | 逐步断言完成，退出0，不伪造JUnit计数 | `upgrade-seed-resume.log`、`old-program-manifest.json`、`upgrade-verify-2.log` |
| 当前版七类攻击，普通岗、真实Spring/仓库/PG | 全部公开检测/提交拒绝，7张业务表数量未变，退出0 | `upgrade-files.log`；真实当前 v2 科目/凭证/辅助错误预览保留，不能执行 |
| 相邻合法公开服务业务 | 科目1条、备注1条、辅助目录1项、成本两行映射成功；GL未增 | 同一 `upgrade-files.log`，`CURRENT_FILES_LEGAL`；独立只读SQL在 `proof-queries.sql`/`.log`（退出0），确认两普通账号、相同财务权限、所有版本/谱系和最终业务计数 |
| 完整财务PG回归 | 31通过、1执行错误（32项），原记录保留 | `candidate-2/db.log`；唯一为加载的旧成本测试夹具把v0/v1都命名legacy-zero导致同哈希唯一键拒绝。当前源码按版本唯一命名后的定向7项全部通过（`cost.log`/`.exit`，0失败/错误/跳过），与本组重叠不相加。 |
| 货品历史/撤销及BOM状态PG | 35通过、1执行错误（36项），原记录保留 | `candidate-2/goods.log`；唯一为既有历史夹具在V1128当前库中软删已用货品，原守卫正确拒绝。已改为独立V1127真实迁移库合法造历史，再正常升级当前版本；原检测/提交断言全部保留，不关触发器、不造历史事实。当前整类31项定向复跑全部通过，0失败/错误/跳过（`legacy.log`/`.exit`）；正常1066次迁移至V1127、造历史、再正常应用2次迁移至V1129。该组与前轮重叠，不相加。 |
| 首轮独立完整Maven | **57 / 3 / 5 / 1**，共66项，退出1，原记录不改 | `candidate-1/maven.log`、`build/surefire-reports`、`results.json`；测试源码先于版本/夹具修正编译，未来版本常量2和成本合法夹具写死v1、BOM探针前缀/权限不符。相应当前测试改为真实v2合法源、v1旧源明确拒绝，未放松业务断言。 |

保留的准备/中间失败：`upgrade-seed.log` 的合法对照生成器误用 POI 可写 File 打开新复制件，导致旧成本看到两条合法行；`setup-mutated-copies` 保存当时副本，旧审查原件/已入Git测试原件没动，生成器改为 InputStream 后恢复攻击副本再测。`upgrade-seed-retry.log` 为读取 repreview 回执 envelope 的夹具错误，公开子批次已生成且保留；`upgrade-seed-resume.log` 用实际保留的子ID续完。`upgrade-verify.log` 在所有业务拒绝/不可变/锁期回执断言通过后，另一owner夹具撞员工唯一约束；更正为另一真实员工后 `upgrade-verify-2.log` 全通过。两个解析中间红轮分别保存在 `parsers-attempt1.log`、`parsers-attempt2.log`，另有签名合法标点扩展前的已通过结果 `parsers-before-signature-control.log`。不覆盖原失败计数。

命令均从本工作树执行：

```powershell
pwsh -NoProfile -File evidence/imports/run-candidate.ps1
# 可指定最终工作树与新输出名称，自动避开已有日志：
pwsh -NoProfile -File evidence/imports/run-candidate.ps1 -workspaceRoot '<最终候选工作树>' -runName final-C
pwsh -NoProfile -File evidence/imports/run-overlay.ps1 compile
pwsh -NoProfile -File evidence/imports/run-overlay.ps1 parsers
pwsh -NoProfile -File evidence/imports/run-overlay.ps1 db
pwsh -NoProfile -File evidence/imports/run-overlay.ps1 goods
pwsh -NoProfile -File evidence/imports/run-overlay.ps1 cost
pwsh -NoProfile -File evidence/imports/run-overlay.ps1 legacy
# 新的空隔离PG，旧程序签发；已存在本轮专用库时不要重新seed覆盖。
pwsh -NoProfile -File evidence/imports/run-upgrade.ps1 seed
pwsh -NoProfile -File evidence/imports/run-upgrade.ps1 verify
pwsh -NoProfile -File evidence/imports/run-upgrade.ps1 files
# 最终整合候选重新编译后，明确指定其独立build，可再核对同一原v1库：
pwsh -NoProfile -File evidence/imports/run-upgrade.ps1 verify -candidateBuild '<最终候选独立编译目录>'
```

所有 Maven目录、TMP、存储/日志和PG独立；overlay是在本包首轮完整编译基础上，将从fdeda88b3至本包当前源的全部改动重新编译，保留每轮输入参数；它是本包阶段验证，最终整合按完整新编译和固定SHA复跑。没有使用正在运行的共享后端 target/classes 或 target-dev。

## 多端与现场项

`wpf-applicability.json` 按 fdeda88b3 对六项的 status、owner、DoD、dependencies、nativeTargets逐字段核对一致。W7-BIZ-025为已有只读货品候选；026/028/216/066/072均没有相应原生导入检测/提交调用，保持原状态，不开放 WPF 写壳。C#仅公共 `ReadScopeRevisionState` 识别相关摘要路径；未把共用后端或台账当成原生导入已完成。

真实网页步骤和合成工作簿见 `WEB-STEPS.md`、`web-fixtures/`，由根任务在最终同一候选统一执行。服务层 PG、带 mock 的合同/控件、真实浏览器及桌面/真机分开记账。本包没有冒称 Windows Flutter 安装版、WPF或Win7真机交互通过。

公司私有旧 Excel缺失：提供原文件后用 `UTEN_FINANCE_SOURCE_DIR` 指定只读副本，在相同候选重跑 `FinanceAccountingWorkbookParserTest.privateSuppliedFilesAreReadOnlyOptionalEvidence`，核对真实字段、账套/年度、借贷与原数据；按原会计映射和不同人审核走应用，记录原问题/正例及最终GL，不把解析通过当已入账。公司原单和权限需在公司测试环境用正确普通岗位重复网页步骤；不能用本地合成单证明原单已通过。Win7原生导入目前未迁移，先满足对应DoD再安排目标机实际流程，不假签。

完整自定义 TEXT/NUMBER 回写未实施；`PlatformColumnService.write` 未改，也没有把整组替换当局部更新。多人分次领料自动关联不属C包实施，没有借整改扩项。正式CI、部署和打包未执行。
