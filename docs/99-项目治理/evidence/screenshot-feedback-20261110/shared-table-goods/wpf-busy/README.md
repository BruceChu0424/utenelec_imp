# WPF 公共进度状态转换

归属 `W7-FLOW-019`；保留既有 `implemented` 状态及全部原 DoD、owner、依赖和未迁移项。只修公共控件状态，不改业务权限、命令、幂等键或真实取消能力，不开放任何尚未迁移的 WPF 业务入口。

## 同责合同及缺陷

Flutter owning 源 `UtenProgressSession.stage` 产生 `fraction=null` 的新阶段，`count(done,total>0)` 随后重新给出确定比例；`count(total≤0)` 回到未知阶段。WPF 原 `BusyWindow.Report` 只在“已有确定模式”时更新值，`Stage` 也不改模式，导致确定→未知和未知→确定都失效。

修复只在 `UtenBusyDialog.BusyWindow.Report` 统一维护模式：有真实比例就恢复确定模式并夹紧值，无比例就切回扫动条并清掉旧 Value。`Show` / `ShowProgress` 初态、窗口样式、嵌套 lease、取消回调、禁用/恢复 owner 和所有调用方的业务过程均保留。

## 本机真实控件验证

- 改前先新增控件用例、按 x64 编译并运行原实现，真实复现 `Stage withdraws the old percentage and switches to unknown` 失败，原始证据 `before-run.log` 保留。
- 改后 x86、x64 分别通过完整 .NET Framework 4.8 Debug 编译，开启 `TreatWarningsAsErrors=true`，包含真正的 XAML 代码生成，没有过滤编译错误。
- 两架构各 **65 个 STA 原生控件断言通过**：`ShowProgress → Report → Stage → Report`、`Show → Report`、未知总量、负值/超过总量、25 轮连续模式转换、嵌套一个等待窗、嵌套完成不能关闭外层等待、结束恢复 owner、原输入保留。
- `wpf_install_policy.py --verify-executable` 分别验证 x86/x64 PE 与 CLR 标志，结果见 `architecture-checks.log`。
- 新增独立 runner 参数 `--busy-dialog-progress-contracts`，也加入原完整 runner。用例只读写合成 UI 字段，不连接公司服务，不写业务或账号数据。

构建使用实际 VS `MSBuild.exe`、`UtenBuildScope=feedback-busy-20261110`，输出在 `build/windows-wpf/feedback-busy/{x86,x64}/`，未占用 Flutter `build/windows/`。本工作树初次缺私有 BouncyCastle 依赖，复用本地主工作树的已锁定 nupkg，既有 `restore_dependencies.py --restore` 重新验证 SHA-512 与两个文件 SHA-256 后只解压到本工作树；未改共享 SDK、全局 NuGet 缓存或依赖版本。

这是开发机本机控件与双架构证据；Win7 目标机、完整 ERP、正式安装/更新产物及发布仍未验收。台账状态由主任务统一追加证据，不能据此把业务 todo 或 Win7 门提升为完成。
