# 公共客户端与业务安全

由唯一进度登记表生成。

## W7-CORE-001

- [ ] **服务器配置和来源绑定** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 只允许审核HTTPS /api；切服失败UI与真实传输来源一致，密码和令牌不跨源。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-002

- [ ] **托管TLS及公司CA** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. Win7不依赖缺失Schannel套件；固定CA、SAN/EKU/时间/链、RSA-GCM真实本机握手及错证拒绝。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-003

- [ ] **统一有界HTTP传输** — 源码已实现/待整合验证

影响：`frontend`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 唯一framing reader；CL/TE、重复头、chunk/trailer、压缩/解压、连接/超时/取消均有界。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-004

- [ ] **员工登录和初始OTP** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 与现有登录DTO一致，错误/锁定/MFA挑战/账户切换不串状态，不记录凭据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-005

- [ ] **恢复会话和持久来源** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. DPAPI独立profile，恢复仅向原审核issuer；损坏、fence或不同端点不复活旧账号。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-006

- [ ] **刷新单飞及晚到认证响应** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 普通刷新不换业务owner；页面取消不终止已开始的共享刷新；成功头交接后晚token有回收。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-007

- [ ] **注销与待撤销队列** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 离线/存储失败先退役内存、恢复fence、原issuer无Bearer撤销；不能注销新会话。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-008

- [ ] **数据集/权限/读范围栅栏** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. opaque proof、乱序/头体冲突/身份隔离；读revision独立于认证，403退役旧数据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-009

- [ ] **强制改密和认证意图** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 改密不自动重放，旧结果不能覆盖新意图，首次改密前不能进工作区。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-CORE-010

- [ ] **精确JSON与数值契约** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 所有业务数字保留精度/尾零/未知，建立跨语言样例；不能仅依赖货品私有parser。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-CORE-011

- [ ] **通用业务提交入口** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 动作配置表达真实method/path/body/version/idempotency/回执；写不自动重放，身份校验和并发策略统一。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/02-业务流程迁移与验收矩阵.md`；`clients/windows_legacy/progress/evidence/native-checkpoint-20261028.json`；`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：受控1至16动作真实接单位/历史/导出/平台写，原body/预算/权限/row版本/receipt差异保持，current root两arch全部通过；其它模块迁移/目标环境未完。。

## W7-CORE-012

- [ ] **敏感操作再认证与后续MFA** — 未开始

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. X-Uten-Step-Up绑定同一用户/issuer/会话，空闲5分钟失效、连续操作按服务端校验续期并可复用；原冻结请求的受控继续至多一次不等于token单次消费；MFA未知写不自动重放。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`server/src/main/java/com/uten/imp/security/RequiresStepUp.java`。

接续/限制：合同订正：以RequiresStepUp/StepUpInterceptor/StepUpService实际执行为准，凭证同会话5分钟空闲续期复用；受控原请求继续一次不能误解为token一次消费。完整UI/恢复仍待实施。。

## W7-CORE-013

- [ ] **草稿持久化与恢复** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 绑定用户/issuer/dataset/实体/版本；取消、切页、断网、重启和升级不丢输入或串他人草稿。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`。

接续/限制：独立DPAPI草稿/owner namespace/CAS/retired lease已接单位编辑恢复；实际HWND父Close+阻塞store和双arch整体通过。其它调用方/升级与目标机仍待。。

## W7-CORE-014

- [ ] **未知提交和命令回执核对** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 逐动作接真实receipt/查询；未知不得报失败后盲目重提，未提供回执的动作明确保守恢复。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`。

接续/限制：Sending先持久化、跨store未知及新UUID重提保护、Confirmed本机失败不改Outcome、原目标UUID/路径只读核对已验证。无服务端receipt明确人工核对；其它动作/核对说明UI待补。。

## W7-CORE-015

- [ ] **公共分页/筛选/排序/facets** — 进行中

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 状态/空值/范围/序号完整，切筛选取消旧读、保留壳，不截断全量或错误本地重排。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-CORE-016

- [ ] **附件上传与原件生命周期** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. multipart、SHA/来源、取消/重试/未知完成、权限及预览原件边界一致；不丢原字节。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-CORE-017

- [x] **有界流式软件包保存** — 本项DoD完成

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 512MiB独立sink、长度/哈希/来源校验、身份取消、原子final、只清自己的temp且内存有界。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：当前两架构真实Core整体含512MiB独立软件包sink/已知长度SHA来源/owner取消/atomic final/仅本GUID temp/有界流读取；新增导出unknown长度capability独立且旧known包不能借此绕过长度。范围限此流式能力，非Win7目标或完整更新验收。。

## W7-CORE-018

- [ ] **加密导出及报告任务** — 本机验证/待本项最终验收

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. POST密码仅body，过滤/列投影/权限一致，下载绑定上下文、流式/完整性和未知结果处理。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/11-业务与安装链路增量阶段.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：原请求proof后端与投影null等价修复45项、旧Flutter21项；原生任务/丢响应核对/同key显式确认/取消/密码下载落盘/legacy capability fallback UI16两arch通过。尚无真实目标机/正式交付。。

## W7-CORE-019

- [ ] **PDF预览和原生打印** — 本机验证/待本项最终验收

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 字体/分页/纸张/选中范围与完整快照，打印取消和重复点击；x86/x64 provider均可用。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/11-业务与安装链路增量阶段.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：完整分页、同屏幕projection、A4纸面/全中文/选择器取消/范围退役/队列适配21两arch通过；WPF原生打印内部非PDF，未实际物理打印或交付独立PDF，不能标此大能力done。。

## W7-CORE-020

- [ ] **会话快照与委派/单据能力** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 消费auth/me.session、权限范围和allowedActions，不能仅靠全局permissions推断写能力。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-CORE-021

- [ ] **设备审计与原生上下文** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 设备身份/平台/OS信息来源真实，审计不承载伪造安全边界，不发送额外敏感数据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-CORE-022

- [ ] **偏好、账号/服务器历史与语言** — 本机验证/待本项最终验收

影响：`frontend`；负责人：Codex；依赖：W7-ENV-001。

源入口：`clients/windows_legacy/Uten.Legacy.Core/SessionCoordinator.cs`；`lib/core/network/api_client.dart`。

完成条件：

1. 独立profile；保留现有选择/重开行为、多语言及公司品牌配置，不复用Flutter凭据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/11-业务与安装链路增量阶段.md`；`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：master.unit表头/自设列/偏好/真实定义与整行version写、恢复、同投影已接，columns46+UI9/common16两arch通过；语言/账号服务器历史以及更多scope仍未完。。
