# 安装与运行条件

由唯一进度登记表生成。

## W7-INS-001

- [ ] **目标OS/SP/架构识别** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. Win7SP1 x86/x64，Win8.1范围明示；拒ARM/Server/Win8.0/未审核OS，准确理由。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-INS-002

- [ ] **.NET4.8检测与前置条件** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. 正确HKLM视图/Release阈值、未装运行时路径；不静默改共享环境。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-INS-003

- [ ] **两架构payload同源绑定** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. 同一版本/commit，两份真实PE/CLR与依赖一致，不能仅看目录名。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-INS-004

- [ ] **bootstrap专用安装与保护** — 进行中

影响：`delivery`；负责人：Codex；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. 安装固定client_updater EXE/config，和Update ZIP分离且不可被ZIP替换。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-INS-005

- [ ] **独立安装/profile/快捷方式** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. AppId/目录/凭据/命名隔离，/DIR及链接不能覆盖现用Win10或别的用户文件。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-INS-006

- [ ] **真实编译向导与安装重装** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. 验证Inno源码和实际向导、首次安装/覆盖/卸载、权限和路径，不是只测策略函数。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-INS-007

- [ ] **安装失败/中断/旧版保全** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. 任意组件失败保留现有安装和业务数据，重试/恢复可重复，无盲目全盘清理。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-INS-008

- [ ] **Win7两架构安装验收** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-001, W7-ENV-003。

源入口：`clients/windows_legacy/installer/windows_wpf_installer.iss`。

完成条件：

1. 真正Win7 SP1 x86及x64干净/常用环境，分别记录安装、启动、重装和卸载证据。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
