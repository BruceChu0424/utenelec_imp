# 原生外壳与通用入口

由唯一进度登记表生成。

## W7-SHELL-001

- [ ] **登录及强制改密原生外壳** — 源码已实现/待整合验证

影响：`frontend`；负责人：待认领；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 品牌45:55、窗口按钮、输入/OTP/改密，前后端错误与重开状态。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-SHELL-002

- [ ] **完整工作台权限模块导航** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 现有所有有效模块/徽章/分组/待办链接有真实能力，不能只展示货品两个按钮。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-SHELL-003

- [ ] **个人中心与偏好入口** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 员工自身档案/申请/文件/工资等来源正确，权限与生命周期一致。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-SHELL-004

- [ ] **通知及跨模块待办定位** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 未读/已读/广播/来源单据，定位参数正确、不落未迁页面或丢业务上下文。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/notice-ack-read-badge-20261103.json`。

接续/限制：2026-11-03 通知收到/未读合同增量：当前 WPF 通知列表、详情、外壳未读徽标及收到动作均未迁移；MainWindow 仅工作台/货品/单位入口，DashboardView 仅 GET /dashboard/overview，未接通知回执。后续迁移须由服务端同事务保存本人收到与已读，列表/详情/筛选/未读计数/弹窗同一权威状态；重复收到幂等，未知结果不盲重放。卡片红点与未读文字移至顶行右侧、与类型 icon 同排并放大；异步动作复用原生等待层及防连点，保留身份/权限/读取代次隔离。仅登记待迁移合同，不新增原生写入口，不提高任务状态或 Win7/完整 ERP 验收；见 E-NOTICE-ACK-READ-BADGE-20261103。。

## W7-SHELL-005

- [ ] **Windows下载原生入口** — 源码已实现/待整合验证

影响：`shared`；负责人：待认领；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 当前family/真实OS位数、已发布包筛选、保存验证、旧defaultFlutter不混用。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-SHELL-006

- [ ] **本机检查更新与草稿退出门** — 进行中

影响：`shared`；负责人：Codex；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 只查自身legacy+进程arch，更高build，编辑/下载未结束不退出，不强杀业务进程。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-SHELL-007

- [ ] **全局错误/离线/重连体验** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-CORE-004, W7-UI-001。

源入口：`clients/windows_legacy/Uten.Legacy.Desktop/MainWindow.xaml.cs`；`lib/core/router/app_router.dart`。

完成条件：

1. 错误分层、退避/只读重试、未知写不重放，保留用户输入与表格壳。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
