# 公共客户端与业务安全

由唯一进度登记表生成。

## W7-CORE-001

- [ ] **服务器配置和来源绑定** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 只允许审核HTTPS /api；切服失败UI与真实传输来源一致，密码和令牌不跨源。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-002

- [ ] **托管TLS及公司CA** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. Win7不依赖缺失Schannel套件；固定CA、SAN/EKU/时间/链、RSA-GCM真实本机握手及错证拒绝。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-003

- [ ] **统一有界HTTP传输** — 源码已实现/待整合验证

影响：`frontend`；负责人：Codex category/table reads；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 唯一framing reader；CL/TE、重复头、chunk/trailer、压缩/解压、连接/超时/取消均有界。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/category-loading-20261101.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-01 分类/表格公共读取优化：托管 TLS 保留原 8 连接上限，facets/lookup/dict 最多占 2 条；队列继续沿用会话取消、来源和 read proof。当前源码 x86/x64 公共门及既有完整 runner 通过，证据 E-CATEGORY-LOADING-20261101。只验证本次传输增量；本工作包其余 DoD、完整 ERP 和 Win7 真机验收未完成，原 implemented 状态保留。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-004

- [ ] **员工登录和初始OTP** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 与现有登录DTO一致，错误/锁定/MFA挑战/账户切换不串状态，不记录凭据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-005

- [ ] **恢复会话和持久来源** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. DPAPI独立profile，恢复仅向原审核issuer；损坏、fence或不同端点不复活旧账号。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/login-session-lifecycle-20261103.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；2026-11-03 登录会话生命周期局部修复：新进程不再用旧 refresh 自动恢复登录；正常主窗关闭先经草稿保护并立即退役本机会话，原 issuer 注销有界等待及持久重试，最小化保留登录；已登录窗口新增自动 session/watch 与缺接口时的 3 秒 me 回退，权威替换统一按登录代次清理并显示设备原因，不等人工刷新。x86/x64 Debug 零警告及完整离线 Core/业务/实际 WPF UI/Updater runner 通过；Win7 真机、完整 ERP、正式交付未验，原状态保留。W7-BIZ-016 仍未完整迁移；存量原生登录壳提示/等待按钮全面整改不在本证据完成范围。见 E-LOGIN-SESSION-LIFECYCLE-WPF-20261103。；2026-11-03 真人活动续期补齐：主窗口生命周期订阅 InputManager.PreProcessInput 并在退出时解除；仅本窗口及 owned dialogs 的键盘/IME/鼠标/触摸/笔输入记录时间，最近 30 秒有输入才按 30 秒节拍以当前 staff /auth/me 续期，复用同一认证入口并保持单飞；空闲时 watch 和兼容探测不续期。不保存输入内容。双架构定向合同覆盖实际 InputManager、所属/非所属窗口、过期输入和快速重复 tick；完整回归准确结果见同一回执，原工作包状态不变。；2026-11-03 最终原生局部回归：双架构 /warnaserror 构建、定向合同和完整离线 runner 均通过（Publish113，含 prepare/upload/publish 晚成功/失败六组）。实际发布页后台 watch 下线仍保全防抖间隙最新输入，存储锁定时阻止主窗口关闭，重试使用自有等待窗/防重复/后台 I/O；原 lease 不串新 owner，已发单位写的 Unknown 原编号/正文及草稿保留；会话监听异常隔离不阻断其他清理和 SessionEnded。单位/导出/草稿/inline/发布与更新完整既有套件通过；Win7 真机与完整 ERP 未验，原状态保留。。

## W7-CORE-006

- [ ] **刷新单飞及晚到认证响应** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 普通刷新不换业务owner；页面取消不终止已开始的共享刷新；成功头交接后晚token有回收。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/login-session-lifecycle-20261103.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；2026-11-03 登录会话生命周期局部修复：新进程不再用旧 refresh 自动恢复登录；正常主窗关闭先经草稿保护并立即退役本机会话，原 issuer 注销有界等待及持久重试，最小化保留登录；已登录窗口新增自动 session/watch 与缺接口时的 3 秒 me 回退，权威替换统一按登录代次清理并显示设备原因，不等人工刷新。x86/x64 Debug 零警告及完整离线 Core/业务/实际 WPF UI/Updater runner 通过；Win7 真机、完整 ERP、正式交付未验，原状态保留。W7-BIZ-016 仍未完整迁移；存量原生登录壳提示/等待按钮全面整改不在本证据完成范围。见 E-LOGIN-SESSION-LIFECYCLE-WPF-20261103。；2026-11-03 真人活动续期补齐：主窗口生命周期订阅 InputManager.PreProcessInput 并在退出时解除；仅本窗口及 owned dialogs 的键盘/IME/鼠标/触摸/笔输入记录时间，最近 30 秒有输入才按 30 秒节拍以当前 staff /auth/me 续期，复用同一认证入口并保持单飞；空闲时 watch 和兼容探测不续期。不保存输入内容。双架构定向合同覆盖实际 InputManager、所属/非所属窗口、过期输入和快速重复 tick；完整回归准确结果见同一回执，原工作包状态不变。；2026-11-03 最终原生局部回归：双架构 /warnaserror 构建、定向合同和完整离线 runner 均通过（Publish113，含 prepare/upload/publish 晚成功/失败六组）。实际发布页后台 watch 下线仍保全防抖间隙最新输入，存储锁定时阻止主窗口关闭，重试使用自有等待窗/防重复/后台 I/O；原 lease 不串新 owner，已发单位写的 Unknown 原编号/正文及草稿保留；会话监听异常隔离不阻断其他清理和 SessionEnded。单位/导出/草稿/inline/发布与更新完整既有套件通过；Win7 真机与完整 ERP 未验，原状态保留。。

## W7-CORE-007

- [ ] **注销与待撤销队列** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 离线/存储失败先退役内存、恢复fence、原issuer无Bearer撤销；不能注销新会话。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`；`clients/windows_legacy/progress/evidence/login-session-lifecycle-20261103.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。；2026-11-03 登录会话生命周期局部修复：新进程不再用旧 refresh 自动恢复登录；正常主窗关闭先经草稿保护并立即退役本机会话，原 issuer 注销有界等待及持久重试，最小化保留登录；已登录窗口新增自动 session/watch 与缺接口时的 3 秒 me 回退，权威替换统一按登录代次清理并显示设备原因，不等人工刷新。x86/x64 Debug 零警告及完整离线 Core/业务/实际 WPF UI/Updater runner 通过；Win7 真机、完整 ERP、正式交付未验，原状态保留。W7-BIZ-016 仍未完整迁移；存量原生登录壳提示/等待按钮全面整改不在本证据完成范围。见 E-LOGIN-SESSION-LIFECYCLE-WPF-20261103。；2026-11-03 真人活动续期补齐：主窗口生命周期订阅 InputManager.PreProcessInput 并在退出时解除；仅本窗口及 owned dialogs 的键盘/IME/鼠标/触摸/笔输入记录时间，最近 30 秒有输入才按 30 秒节拍以当前 staff /auth/me 续期，复用同一认证入口并保持单飞；空闲时 watch 和兼容探测不续期。不保存输入内容。双架构定向合同覆盖实际 InputManager、所属/非所属窗口、过期输入和快速重复 tick；完整回归准确结果见同一回执，原工作包状态不变。；2026-11-03 最终原生局部回归：双架构 /warnaserror 构建、定向合同和完整离线 runner 均通过（Publish113，含 prepare/upload/publish 晚成功/失败六组）。实际发布页后台 watch 下线仍保全防抖间隙最新输入，存储锁定时阻止主窗口关闭，重试使用自有等待窗/防重复/后台 I/O；原 lease 不串新 owner，已发单位写的 Unknown 原编号/正文及草稿保留；会话监听异常隔离不阻断其他清理和 SessionEnded。单位/导出/草稿/inline/发布与更新完整既有套件通过；Win7 真机与完整 ERP 未验，原状态保留。。

## W7-CORE-008

- [ ] **数据集/权限/读范围栅栏** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. opaque proof、乱序/头体冲突/身份隔离；读revision独立于认证，403退役旧数据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/2026-11-02-成本预算读取范围误报修复.md`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：公共读取层已修复货品与预算成本证明混用；Dart/C#/Java 同组路由样例及本项回归见证据。维持 implemented：完整 DoD、成本 WPF 页面迁移和 Win7 真机验收仍未完成。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-009

- [ ] **强制改密和认证意图** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 改密不自动重放，旧结果不能覆盖新意图，首次改密前不能进工作区。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-010

- [ ] **精确JSON与数值契约** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 所有业务数字保留精度/尾零/未知，建立跨语言样例；不能仅依赖货品私有parser。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-011

- [ ] **通用业务提交入口** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 动作配置表达真实method/path/body/version/idempotency/回执；写不自动重放，身份校验和并发策略统一。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/02-业务流程迁移与验收矩阵.md`；`clients/windows_legacy/progress/evidence/native-checkpoint-20261028.json`；`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：受控1至16动作真实接单位/历史/导出/平台写，原body/预算/权限/row版本/receipt差异保持，current root两arch全部通过；其它模块迁移/目标环境未完。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-012

- [ ] **敏感操作再认证与后续MFA** — 未开始

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. X-Uten-Step-Up绑定同一用户/issuer/会话，空闲5分钟失效、连续操作按服务端校验续期并可复用；原冻结请求的受控继续至多一次不等于token单次消费；MFA未知写不自动重放。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`server/src/main/java/com/uten/imp/security/RequiresStepUp.java`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：合同订正：以RequiresStepUp/StepUpInterceptor/StepUpService实际执行为准，凭证同会话5分钟空闲续期复用；受控原请求继续一次不能误解为token一次消费。完整UI/恢复仍待实施。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-013

- [ ] **草稿持久化与恢复** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 绑定用户/issuer/dataset/实体/版本；取消、切页、断网、重启和升级不丢输入或串他人草稿。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：独立DPAPI草稿/owner namespace/CAS/retired lease已接单位编辑恢复；实际HWND父Close+阻塞store和双arch整体通过。其它调用方/升级与目标机仍待。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-014

- [ ] **未知提交和命令回执核对** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 逐动作接真实receipt/查询；未知不得报失败后盲目重提，未提供回执的动作明确保守恢复。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：Sending先持久化、跨store未知及新UUID重提保护、Confirmed本机失败不改Outcome、原目标UUID/路径只读核对已验证。无服务端receipt明确人工核对；其它动作/核对说明UI待补。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-015

- [ ] **公共分页/筛选/排序/facets** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 状态/空值/范围/序号完整，切筛选取消旧读、保留壳，不截断全量或错误本地重排。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-016

- [ ] **附件上传与原件生命周期** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. multipart、SHA/来源、取消/重试/未知完成、权限及预览原件边界一致；不丢原字节。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-017

- [x] **有界流式软件包保存** — 本项DoD完成

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 512MiB独立sink、长度/哈希/来源校验、身份取消、原子final、只清自己的temp且内存有界。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：当前两架构真实Core整体含512MiB独立软件包sink/已知长度SHA来源/owner取消/atomic final/仅本GUID temp/有界流读取；新增导出unknown长度capability独立且旧known包不能借此绕过长度。范围限此流式能力，非Win7目标或完整更新验收。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-018

- [ ] **加密导出及报告任务** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. POST密码仅body，过滤/列投影/权限一致，下载绑定上下文、流式/完整性和未知结果处理。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/11-业务与安装链路增量阶段.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：原请求proof后端与投影null等价修复45项、旧Flutter21项；原生任务/丢响应核对/同key显式确认/取消/密码下载落盘/legacy capability fallback UI16两arch通过。尚无真实目标机/正式交付。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-019

- [ ] **PDF预览和原生打印** — 本机验证/待本项最终验收

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 字体/分页/纸张/选中范围与完整快照，打印取消和重复点击；x86/x64 provider均可用。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/11-业务与安装链路增量阶段.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：完整分页、同屏幕projection、A4纸面/全中文/选择器取消/范围退役/队列适配21两arch通过；WPF原生打印内部非PDF，未实际物理打印或交付独立PDF，不能标此大能力done。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-020

- [ ] **会话快照与委派/单据能力** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 消费auth/me.session、权限范围和allowedActions，不能仅靠全局permissions推断写能力。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-021

- [ ] **设备审计与原生上下文** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 设备身份/平台/OS信息来源真实，审计不承载伪造安全边界，不发送额外敏感数据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-022

- [ ] **偏好、账号/服务器历史与语言** — 本机验证/待本项最终验收

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 独立profile；保留现有选择/重开行为、多语言及公司品牌配置，不复用Flutter凭据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/11-业务与安装链路增量阶段.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`；`clients/windows_legacy/progress/evidence/platform-search-20261103.json`；`clients/windows_legacy/progress/evidence/platform-search-integration-20261104.json`。

接续/限制：master.unit表头/自设列/偏好/真实定义与整行version写、恢复、同投影已接，columns46+UI9/common16两arch通过；语言/账号服务器历史以及更多scope仍未完。；2026-11-04 搜索契约及c8eb95cb1合成双架构读取/草稿fixture证据追加；仅证明当前读取增量，原status、owner、DoD和依赖保留，未声明原生业务迁移、Win7真机或正式交付完成。。

## W7-CORE-023

- [ ] **客户端发布批设置与原编号恢复合同增量（下一版）** — 源码已实现/待整合验证

影响：`frontend+shared-contract`；负责人：release_inventory；依赖：W7-BIZ-215, W7-CORE-014。

源入口：`lib/features/client_update/client_release_publish_queue.dart`；`lib/features/client_update/client_release_publish_drafts.dart`；`lib/features/client_update/client_release_publish_page.dart`；`test/features/client_update/client_release_publish_queue_test.dart`；`test/features/client_update/client_release_publish_drafts_test.dart`；`test/features/client_update/client_release_publish_test.dart`；`test/fixtures/client_release_publish_defaults_v1.json`。

完成条件：

1. 按公共发布合同迁移批默认的有限字段归属：未提交且未手动覆盖才联动，设备与版本成组；绑定requestId/releaseId/SHA及已发布项目永不改写元数据。
2. 原编号批量只读核对与草稿恢复不创建、不重传、不重发未知命令；已成功和已上传分支沿原身份继续，回归晚到结果及身份/服务器/权限变化。
3. 区分尚未读取的验证失败和已消耗的一次性文件流，减少无谓重选；浏览器刷新不保存无授权文件，WPF文件来源按原生授权合同保留必要平台差异，同SHA约束不变。
4. 在x86/x64执行合同及真实调用方回归，并完成Win7目标机适用验收；旧215本机证据不代替此新增差异，全部适用DoD满足前保持未完成。

证据：`docs/99-项目治理/2026-11-01-客户端发布工作台批设置与恢复.md`；`clients/windows_legacy/progress/evidence/client-publish-integration-20261101.json`。

接续/限制：2.5.42适用发布合同已同步；当前Flutter79/分析0/页面28绿，x86发布95及实际View布局绿，x64既有runner待自然结束，不计done，Win7目标机和完整ERP未验收。原877完整DoD和历史单列保留。。

## W7-CORE-024

- [ ] **内置可复制运行日志与加载中断压力回归** — 本机验证/待本项最终验收

影响：`frontend+shared-contract`；负责人：windows_stability；依赖：W7-ENV-001, W7-CORE-003, W7-UPD-006。

源入口：`lib/core/diagnostics/diagnostic_log.dart`；`lib/core/performance/data_work_queue.dart`；`windows/runner/native_diagnostics.cpp`；`test/fixtures/client_diagnostics_v1.json`。

完成条件：

1. Flutter与WPF原生入口默认持久化版本/异常/无响应/更新日志，用户可直接复制.log；按运行时、架构、配置隔离，日志不含凭据或业务正文，限量且不碰业务/恢复资料。
2. 共用日志schema/路径脱敏样例；覆盖x86/x64本机编译、异常落盘、日志风暴、加载中断/旧结果隔离及实际入口交互；不弱化未知提交或原始输入保全。
3. Win7目标机适用启动、异常/卡顿和更新日志验收；未验收前不标done，不以源码存在或现代Windows本机runner替代目标机验收。

证据：`docs/99-项目治理/2026-11-01-极端负载中断与内置日志.md`。

接续/限制：本机WPF x86/x64与Flutter/Windows内置日志和压力合同已验证；Win7真机、正式安装/更新及完整ERP仍未验收，不标done。。
