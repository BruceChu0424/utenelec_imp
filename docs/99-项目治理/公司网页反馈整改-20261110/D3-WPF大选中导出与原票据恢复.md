# D3：WPF 大选中导出与原票据恢复

本轮修复单位导出的本机完整链。原 1001/50001 项不能在 WPF 构造请求，Core 也拒绝原票据；即使只放开构造器，普通 16KiB 传输、2MiB 原请求回执及 8MiB 混合业务台账仍会再次阻断。现在输出使用独立、逐层受限的请求与原回执通道，保留原任务编号、完整原筛选/选择字符串、owner、权限/读取版本、未知提交与只读核对。

独立工作树为 `D:/Projects/uten_imp_worktrees/feedback-wpf-export-20261110`，分支 `uimp/feedback-wpf-export-20261110`，基准候选 `42b7bf76ffb18bd89dae332f9be08b30fc1a696a`。源码修复 `4d50b5b88f886848d6876add37862015dcd47b19`，复跑工具启动兼容修复 `58a7fe15308e7b074ab8f59825aafea6b7385069`。后者没有 C# 增量。本轮未改 Java、Flutter 业务或迁移，未合并 main、推送、部署、安装或正式打包。

## 公共入口与适用调用方

| 层/调用方 | 本轮结果与保留边界 |
| --- | --- |
| WPF `UnitExportWindow → UnitExportService.CreateBody/PrepareSubmit` | 完整选中 UUID 只出现于原 `parameters.selectedIds` JSON 字符串，拒绝重复/非规范 UUID，不截断、不按业务写批拆分；重试使用原冻结 body/任务 ID。构造/校验在工作线程，按钮使用项目等待件，取消保存不会下载。 |
| Core `UnitExportMutationContract` / `MutationRequest` / `MutationWirePermit` | 唯一 `UnitExportBudget` 规定输出请求 UTF-8 16MiB；UUID 节点预算由字节预算推导，不再是固定 1000 行。普通业务请求原 16KiB、单位批操作 64KiB、平台值 512KiB 不变。 |
| 单任务读取 / 创建和取消响应 / 原 GET 回执核对 | `GetUnitExportJobJsonAsync` 检查 `unit:export`、规范任务 ID、owner/read revision，经同一 Session/TLS/HTTP 栈；仅批准的单任务响应允许 16MiB+64KiB。原请求证明仍逐字段及原 filter/selectedIds 字符串精确匹配。普通 GET 和错误正文仍按配置上限。 |
| 最近任务 | 保持 2MiB、最多 50 个元数据，服务端现有 `view(job,false)` 不带请求证明。当前 `attempt/precisionRequirement/precisionChoices/totalRows` 仅有界读取，`WAITING_PRECISION` 显示只读状态；没有扩展精度业务写入口。 |
| DPAPI / 原票据恢复 | 新输出独用 `unit-export-mutations.dpapi`，每 owner 64MiB；发送前为完整原回执预留空间，不足时首个请求字节前拒绝。进程冻结输出原请求 UTF-8 总计 32MiB，整体记录数仍 512。普通 `mutations.dpapi` 与 drafts 仍 8MiB。旧输出票据继续在原文件核对/更新，不批量迁移、不删旧票据。两文件共享原 owner namespace lock、attempt lease 与 Sending→Unknown 恢复。 |
| 显式旧服务端单位下载 | 仅能力明确不可用时的原入口：大选中请求经原有 owned export sink 和同一 HTTP 编码器；16MiB 只适用 `/master/units/export`，文件流 512MiB、取消/临时文件/完整发布/权限边界不变，不在未知创建后自动降级。 |
| 共享 Flutter Web/Windows 与 Java | 原统一候选已采用服务端完整结果、单 UUID 数组字符串与 16MiB 输出预算；本轮补齐已实现的 WPF 单位调用方。其他 WPF 尚未迁移业务未新建写入口，Win7 完整 ERP/真机支持状态没有改变。 |

## 原始失败与修复后验证

原始证据根目录：`D:/Projects/uten_imp_worktrees/feedback-wpf-export-20261110/evidence/wpf-export-20261110`。`original-source/` 保存基准 owning source 原字节，`original/` 保存合成原请求；`preservation.json` 记录 SHA-256 与原 compact 1000/1001/50001 body 在两架构修复后逐字节相同，并证明 work-items 数据、后端与 Flutter 未改。

| 验证 | 证据与结论 |
| --- | --- |
| 原反例 | `baseline-{x86,x64}-build.log` 编译 0；`baseline-{x86,x64}-red.log` 退出 1。1000 项原链通过，1001/50001 项 Core `MUTATION_BODY_INVALID`、Desktop `EXPORT_SELECTION_INVALID`。 |
| 实施期原 compact 请求重放 | `final2-{x86,x64}-large.log` 均退出 0。该轮 C# 内容与修复提交相同，编译时 HEAD 尚为基准候选加工作改动，不能冒充干净提交轮。原 1001 为 41,281 字节、原 50001 为 2,050,281 字节；完整受控 HTTP 编码、真实 CurrentUser DPAPI Sending 完成阶段中断、关闭后重开恢复 Unknown、按原 GET 证明核对，实际受控创建次数恒为 1。 |
| 超 2MiB 原证明 | 另加 50001 个 UUID 后保留合法原空格的 body 为 2,100,281 字节。原字符串未被标准化；通过单任务证明通道，普通 GET 与 Recent 的 2MiB 拒绝对照保持成立。篡改单个选中 UUID 的证明不能结清原 Unknown。 |
| 边界与旧票据 | 精确 16MiB 请求可准备并保全，超一字节拒绝；32MiB 进程冻结请求预算拒绝后不发送。64MiB 台账预留不足使第二次发送前拒绝，首个未知票据 DPAPI 原字节不变。旧 `mutations.dpapi` 原票据可核对，继续留原文件。 |
| WPF 实际窗口与对照 | `final2-*-large.log` 含 1001/50001 实际 `UnitExportWindow` 生成→Unknown→原 GET 核对→保存弹窗取消；UI 计时器持续运行、只提交一次、无下载文件。x64 50001 合计 7423ms，x86 11104ms（整条多步链，非单次读取或 1s 验收）。 |
| 全量本机回归 | `final2-{x86,x64}-full.log` 对应进程均自然退出 0；包含 Core、Session/权限/旧版本/草稿/未知结果、HTTP framing/gzip/TLS、下载/发布/更新、单位业务/历史/原 41 项导出 UI 等。编译无警告，`git diff --check`、依赖固定哈希、主题与包契约检查通过。 |

上述是本机 WPF 实际控件、真实 DPAPI、同一原生 HTTP 编码器与受控内存传输。UUID 不是 50001 条真实数据库记录，工作簿响应为合成字节；不能据此宣称真实 PG 50001 行文件、100k/百万 XLSX 或 Win7 目标机通过。真实库包含缺失/未选项与服务端权限的核对由统一 Java/PG 验收另列。

## 干净提交与统一候选重跑

干净提交复跑目录：`D:/Projects/uten_imp_worktrees/feedback-wpf-export-20261110/evidence/wpf-export-native-committed-2`。`result.json` 固定 source SHA/tree、每步退出码、原始输入与日志哈希；只有两架构编译、大选中及原全量全部自然退出 0 且源码前后一致才会 `passed:true`。最终整合候选必须在同一个固定 SHA 再执行：

该轮已实际 `passed:true`，总进程退出 0；前后 source SHA 均为 `58a7fe15308e7b074ab8f59825aafea6b7385069`，tree 均为 `ad5e8ea85e8e057b292132d0883094fcce3cd84b`，`canonicalDiffAfter` 为空。不是只看最后一行 PASS。证据包含原 compact 1000/1001/50001、另加空格版 50001 的原 body；均可与实施期原输入按哈希核对。

| 干净提交步骤 | x86 | x64 |
| --- | --- | --- |
| Debug/Unreviewed 编译（警告视为错误） | 0，8.617s | 0，6.617s |
| 大选中/中断/回执/边界/实际窗口链 | 0，39.813s | 0，45.152s |
| 原完整本机套件 | 0，145.904s | 0，134.401s |

干净轮实际窗口 50001 多步链 x86 7631ms、x64 10274ms，计时器分别 465/609 tick；这是受控合成输出完整操作链，未作为一秒读取验收。真实库与最终整合 SHA 的结论不得由本表替代。

```powershell
python tool/company_feedback_wpf_export/run.py --root D:/Projects/uten_imp_worktrees/feedback-remediate-20261110 --run-tag final-native-export-1 --restore-pinned-dependency
```

每次换新 run-tag，不复用 build/日志/原始 body 目录。工具仅使用已安装 MSBuild 和工作树内固定依赖，Debug/Unreviewed 输出；不生成正式安装包、更新包或修改共享 SDK。

## 保留的失败与现场步骤

中间 `fix-x64-build-2.log` 因自己仍在运行的完整测试锁住 DLL，MSBuild 复制失败；没有取消旧测试，后续所有轮使用独立 OutputPath。`fix-x64-large-2.log` 中原 compact 50001 尚小于 2MiB，错误的超限期望失败；保留原输入后另外加入合法空格版越界对照。`committed-driver.log` 因此机嵌入 Python 的 `sys.executable` 实为目录而启动失败；`58a7fe153` 只修正已安装解释器定位。失败日志均保留，没有改记通过。

现场在目标 Win7 SP1/.NET 4.8 的 x86/x64 对应候选分别登录普通有单位导出权限账号，使用公司原筛选与明确选中 1001/50001 项（包含额外未选行），生成后核对真实 XLSX UUID/总数/筛选/列/数值精度。导出中断客户端，重开只核对原任务；未获原请求证明保持 Unknown，不换号盲重试。核对权限撤销/数据版本变化、取消保存与下载中断、旧版本不支持选中时明确拒绝，复制本机运行日志。必须记录目标 OS/位数/运行时/源码与服务端版本、原文件及哈希；公司原单、私有文件和目标设备未在本轮提供，这些不列本地通过。
