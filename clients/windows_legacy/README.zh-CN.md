# UTEN 原生 Win7 WPF 客户端

先读[完整实施计划与交接入口](../../docs/99-项目治理/Win7兼容版/00-总实施计划与交接入口.md)和[逐项进度清单](../../docs/99-项目治理/Win7兼容版/01-逐项进度清单.md)。稳定工作包的数量、状态、依赖、DoD、证据与接手顺序以唯一台账 [`progress/work-items.json`](progress/work-items.json) 为准；本文件是技术概览，不另建完成计数。

本目录实现独立的 **C# / WPF / .NET Framework 4.8** 客户端，不嵌入浏览器，不降低现有 Flutter、Dart、Java、数据库或系统环境版本。共用现有后端接口、授权和业务计算；现有 Win10/11 Flutter 客户端及其凭据、SDK、安装和更新路径保留。

**当前状态：原生基础与部分货品读取已经落地，完整 ERP 迁移仍在进行。** 不能把编译成功、登录窗口、只读货品页、包格式支持或下载入口完成，视为全部业务流程等价。完整覆盖状态见 [`migration-coverage.json`](migration-coverage.json)，由脚本根据 owning Flutter 路由生成并检查漂移；目前没有已完成验收的完整业务模块。

## 目标及隔离

- 初始候选分支标识为 `uimp/win7-wpf-client-20261028`；后续迁移继续使用独立工作树，保留并行改动。
- 已完成候选经审查回归后可按当前会话授权合入本地 `main`；后续未完成任务继续隔离。合并不改变完整ERP/Win7真机验收未完成的事实，不授权替换现有客户端、正式打包、上传或部署公司服务器。
- 目标运行环境：Win7 **SP1** 的 x86/x64；安装策略另列 Win8.1。Win8.0 不在本次 net48 目标范围内。未装 SP1、未具备 .NET Framework 4.8、ARM 或 Server 系统会在安装前明确说明。
- 安装器外层 x86，根据实际操作系统架构选择 x86/x64 payload；不以安装器进程位数判断系统位数。
- 新 AppId：`com.uten.uten_imp.win7_wpf`；安装目录为当前用户 `Programs/Uten/UIMP-Win7-WPF`，会话在当前用户 `Uten/UIMP-Win7-WPF` 私有目录，不复用 Flutter 数据。
- 当前验证程序和安装策略在 Win10+ 默认拒绝替换现有客户端。开发机可显式使用 `--development-smoke` 做独立验证；不会升级、降级或卸载现有 Win10 端。
- 没有部署后端或数据库变更，没有向现役客户端 catalog 上传或发布候选产物。

## 公共入口与现有调用

| 公共实现 | 当前调用与保留的约束 |
|---|---|
| `Uten.Legacy.Core/SessionCoordinator.cs` | 登录、进程内刷新、初始 MFA、改密、注销、会话 watch、工作台与货品 GET；新进程从登录页开始，磁盘旧凭据只向原 issuer 撤销；认证代次/CAS、刷新单飞、持久撤销和未知提交保护统一处理 |
| `ReadScopeRevisionState.cs` | 按现有 Dart 读范围合同统一观察 opaque proof、头体冲突与乱序；读范围和认证代次独立，普通刷新不清空表格，不因旧页取消丢失共享刷新 |
| `ManagedTlsHttpHandler.cs` / `ManagedHttp11.cs` | 唯一生产 HTTPS 传输，连接与响应有界；不重定向、不自动重放写、不共享浏览器 Cookie |
| `ManagedCertificateValidator.cs` | 固定公司根、SAN、时间、用途、签名及链策略校验，不修改系统根证书或全局 TLS 设置 |
| `SessionStore.cs` | CurrentUser DPAPI，原子记录/待撤销队列与恢复栅栏；不保存密码，不把旧服务器令牌交给新服务器 |
| `Features/Goods/GoodsReadService.cs` | 现有分类树、货品分页、UUID 详情 GET；金额、数量、折扣和历史编号保留原始数值文本，尊重服务端遮罩，未知不变成 0 |
| `Themes/Uten.xaml` | WPF 样式唯一入口；按钮、输入、下拉、表格、卡片与窗口使用相同角色 |
| `Controls/RoundedSurface.cs` | 表格/面板真实圆角裁切，避免只画圆框但子内容仍为方角；窗口用 Win7 可用的独立 GDI 区域实现 |

当前货品模块是部分只读迁移；采购、委外、生产、仓库、财务审批、BOM、附件、导入导出、打印、通知、完整多语言、原生更新应用和全部导航仍须逐项迁移及回归。不可用假数据、空页面、通用 JSON 编辑器或转到 Web 代替这些业务流程。

主窗口正常关闭时先通过既有草稿/未知提交保护，再立即清除本机登录并把当前 refresh 凭据持久排入原 issuer 的注销队列；进程退出前最多等候约 3 秒完成服务端确认。离线或异常退出后的残留凭据在下次启动时仅用于注销，不自动刷新登录；最小化保留当前会话。服务端离线时不能宣称已立即完成远端撤销。

已登录原生窗口常驻 `GET /auth/session/watch` 长轮询，并携带 `X-Uten-Automatic: 1`，自动刷新同样不计作用户活动。服务端确认被替换时统一清理当前登录并弹出设备原因，不等人工刷新；旧登录代次的晚到通知不能清除新登录或弹到新登录上。旧服务端无 watch 接口时暂按 3 秒自动探测 `/auth/me`，60 秒后重试 watch。此局部能力仍是候选本机验证，不代表完整 ERP、Win7 真机或正式交付完成。

真人活动续期与撤销监听分开：主窗口存活期间通过 `InputManager.PreProcessInput` 记录本窗口及所属编辑弹窗的键盘、IME、鼠标、触摸/手写输入；仅在最近 30 秒有这些输入时，30 秒心跳才以当前员工会话请求 `/auth/me` 续期。无输入时不续期，不相关窗口的输入不影响本登录；关闭时解除输入订阅。只记录时间，不保存输入内容。

实时下线继续沿原账号、服务器和数据集的草稿 lease 保全最后输入；已发送的未知提交保留原编号及原文，不进入新账号或自动重放。发布队列退休后停止后续 prepare/upload/publish/withdraw，晚到成功/失败都不能覆盖原 Unknown。发布页在 Dispatcher 上退休，防抖间隙和 Dispose 后仍可把冻结快照保存到原 namespace；存储失败时保留全局关闭保护，重试使用原生等候窗口、防重复及后台磁盘 I/O，成功后才释放保护。会话通知逐监听者隔离异常并记技术诊断，单个页面监听失败不能挡掉其他页面清理或被顶提示。

## 与当前 Uten 圆角及样式同源

界面及设计文档默认使用 `frontend-design`，复用 Uten 视觉和交互，不另设一套圆角。

`tools/sync_design_tokens.py` 从现有 Dart tokens、配色、浅色主题、字体及桌面登录组件生成 `Themes/Uten.Tokens.g.xaml`，来源表达式和 SHA256 记录在 `design-token-provenance.json`。生成文件不能手改；构建前必须通过离线漂移检查。

| 角色 | 当前源定义 |
|---|---|
| 普通按钮、输入、下拉 | Control 10 |
| 表格表面 | Table 12 |
| 卡片、面板 | Card 16 |
| 对话框 | Dialog 20 |
| 菜单 / 小元素 / 徽章 | Menu 8 / Small 6 / Pill 999，各按语义使用 |
| 控件高度 | Compact 36 / Standard 40 / Primary 48 / Input 44 |
| 表格 | 内容自然撑高；Cell 32 是编辑控件高度，不是强制整行高度；原主数据表头最低 44 |
| 桌面窗口按钮 | 高 36、命中宽 30、圆形底 22，使用原黄色最小化和红色关闭按钮 |

颜色、字号、间距、表格选中色也由同一来源导出。源发生变化时先更新公共方案和所有适用调用，再重新生成、编译和核验。

```powershell
python clients/windows_legacy/tools/sync_design_tokens.py --check
python clients/windows_legacy/tools/sync_design_tokens.py --write
```

## Win7 HTTPS 的实际兼容边界

Win7 Schannel 的 ECDHE_RSA 套件不包含当前公司 RSA 证书所用的 AES-GCM 组合。因此仅设置 TLS1.2 仍不足以证明能登录；本客户端使用任务私有、版本和摘要固定的 BouncyCastle.Cryptography **2.7.0 / net461** 来实现 TLS，限定 TLS1.2 的 ECDHE RSA/ECDSA AES-GCM，Windows CryptoAPI仍校验链及名称。

已在当前开发机通过本机隔离 TCP 服务进行真实 RSA AES128-GCM 握手及错误 SAN 拒绝检查，没有降低公司 Nginx 的加密配置。该检查不是 Win7 真机验收。参考：[微软 Win7 套件表](https://learn.microsoft.com/en-us/windows/win32/secauthn/tls-cipher-suites-in-windows-7)、[BC 官方发行](https://www.bouncycastle.org/download/bouncy-castle-c/)。

依赖仅写入仓库忽略的 `build/windows-wpf/dependencies`，不运行全局 NuGet restore，不安装 SDK。下载时校验官方 catalog SHA512，提取仅限锁定 net461 DLL 与许可；实际载入 DLL 再检查 SHA256，防止机器上同程序集版本的旧 GAC 库被误用。许可随客户端保留。

```powershell
python clients/windows_legacy/tools/restore_dependencies.py --restore
python clients/windows_legacy/tools/restore_dependencies.py --check
```

## 编译、配置及版本

使用现有 MSBuild 和 .NET Framework 4.8 引用程序集。脚本默认仅显示计划；显式 `-Build` 才编译，不生成 Setup/ZIP 或发布。

```powershell
./clients/windows_legacy/tools/build_windows_wpf.ps1 `
  -Build -Configuration Debug -Architecture all `
  -MsBuildPath '<本机已有的MSBuild.exe>'
```

`BuildVersion.targets` 从同份 `pubspec.yaml` 读取应用版本和构建号，为主程序及 Core 生成相同的 Windows 版本资源，不修改原文件，不降低 SDK。BC 保留其独立第三方版本，不能强改为应用版本。

`uten.client.json` 是审核后的服务器连接配置，仅允许固定 HTTPS `/api`、无密码或任意 query 的端点。当前配置指向公司 DNS 地址；不把 localhost 或测试凭据混入正式配置。根证书直接复用经固定摘要核验的公开公司 CA，不写系统信任库。

Company 候选构建须显式 `Release + DistributionProfile=Company`，PE Comments 标记和构建前后源码/产物 receipt 同时验证；不能仅靠文件夹名判断 Release。产物仍是待验收候选，完整 ERP 迁移和 Win7 验收未完成前不得宣布正式交付。

Windows Authenticode 与现有 Flutter 生产者共用 `deploy/client/windows_authenticode.py`：默认未配置发布者时不强制签名，回执明确记录 `signatureVerified=false`；显式 `UTEN_WINDOWS_SIGNATURE_REQUIRE=true` 或开始配置公司签名后仍执行原严格签名门。无论是否签名，Company 六文件 allowlist、固定依赖原始摘要、精确源 receipt、完整载荷绑定、架构与连接配置均保持强制，不修改原编译目录、现用客户端或 Windows 系统防护。默认未签策略不改变 WPF 尚未验收的候选状态。

## 分发、下载和更新合同

Windows 按 `runtimeFamily` 区分：现有 Win10/11 为 `flutter`，Win7 WPF 为 `wpf_legacy`；旧请求和旧元数据缺字段时继续按 `flutter` 解释。WPF 的安装与 ZIP 模式分别为 `windows_wpf_setup`、`windows_wpf_archive`，不能套用 Flutter 文件集。

版本推荐、构建号、安装/更新完整配对、清理、撤回和配套备份按平台、运行时、架构隔离。工作台 Windows 下载入口明确提供版本类型及架构，兼容版没有已发布完整包时显示未发布，不放下载按钮；当前 Flutter 自动更新默认不变，不能接收 WPF 包。

部署门槛：支持 `runtimeFamily` 的新服务与新配套备份 helper 必须成组审核、验证。现役 flat UUID catalog 一旦写入 WPF 记录，不能回滚到未识别该字段的旧 JAR 后继续发布或清理；旧实现只按平台/架构分组，会破坏运行时隔离。当前任务未向现役 catalog 写入这类记录，此限制不能误报为现网已升级或可任意回滚。

正式发布须遵循 [客户端发布手册](../../deploy/client/README.zh-CN.md)及[现役手册](../../deploy/simple/RUNBOOK.zh-CN.md)，各已支持组合都交付同一审核源码、版本和构建号的 Setup.exe 与更新 ZIP。包检查或 catalog 增加类型不代表 WPF 原生更新执行器、业务全链路或 Win7 UAT 已完成。

## 验证和完成条件

最新本机草稿、单位写入与退出保护见[本轮接续](../../docs/99-项目治理/Win7兼容版/09-本机草稿与单位首批写入接续.md)。统一原生验证入口默认dry-run，显式执行：

    ./clients/windows_legacy/tools/verify_windows_wpf.ps1 -Verify -Architecture all -MsBuildPath '<已有MSBuild.exe>' -PythonPath '<已有Python.exe>'

各架构bootstrap、主runner、日志和源码前后SHA在私有build目录核验，不安装/降低SDK，不生成正式包或发布。只诊断UI时Debug测试EXE可传--ui-contracts-only，不能把它当整个runner结果。

已有货品/单位完整列表的大数据功能回归可在本机 Debug 测试 EXE 执行 `--complete-list-stress-35000` 或 `--complete-list-stress-100000`：复用真实 WPF 控件与内存 HTTP fixture，检查全部行、50次虚拟滚动、查询退休、12次重读取消及原写入边界，不连接公司服务。记录的初载时间不是低配或 Win7 真机性能验收；当前差异和结果见[本次适用性证据](progress/evidence/table-read-performance-20261110.md)。

当前检查包括双架构原生编译及 PE/CLR 位数、离线会话与存储竞态、读范围、UI 契约、精度/遮罩、真实本机 TLS/HTTP 以及安装/依赖/主题合同。测试不连接生产业务后端，也不导入系统证书。

完整完成须逐项具备：全部适用页面与流程迁移、与现有前端同源契约样例、前后端业务链回归、Win7 SP1 x86/x64 真机交互与性能证据、现有 Win10 版本独立回归、安装及原生更新双链路验收、全部受支持组合的正式双包和授权发布回执。完成状态以这些证据为准，不能以阶段性编译或截图替代。
