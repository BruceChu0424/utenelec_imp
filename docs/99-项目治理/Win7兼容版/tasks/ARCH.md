# 目标机与平台兼容

由唯一进度登记表生成。

## W7-ARCH-001

- [ ] **当前源码x86完整本机套件** — 进行中

影响：`delivery`；负责人：Codex；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 显式PE32/32BITREQUIRED、Core/UI/download/updater完整runner，不以孤立harness替代。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-002

- [ ] **当前源码x64完整本机套件** — 进行中

影响：`delivery`；负责人：Codex；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 显式PE32+、全部公共/业务/安装更新测试，和x86同一输入源码。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-003

- [ ] **Win7 x86运行环境实测** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. SP1/NET4.8/补丁/CPU/RAM/GPU/DPI/TLS/打印真实记录与启动运行。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-004

- [ ] **Win7 x64运行环境实测** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 与x86独立记录，不能以Win11运行x64/32兼容进程当Win7验收。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-005

- [ ] **Win8.1适用范围验证** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 只有宣称支持的组合测试、NET和TLS/UI行为；不顺带宣称Win8.0或ARM。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-006

- [ ] **长时间/低内存/旧GPU响应性** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 大表/树/批量/附件/后台恢复，观察帧/内存/句柄，不能用截断业务降负载。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-007

- [ ] **DPI/IME/多屏/输入设备** — 未开始

影响：`frontend`；负责人：待认领；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 100/125/150%、中文输入、键盘/鼠标/焦点和窗口切换，保留输入。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ARCH-008

- [ ] **外网/VPN/证书/断网组合** — 未开始

影响：`shared`；负责人：待认领；依赖：W7-ENV-006。

源入口：`clients/windows_legacy/Uten.Legacy.Tests/Program.cs`；`clients/windows_legacy/installer/wpf_install_policy.py`。

完成条件：

1. 审核端点、TLS/CA/主机名/MFA及错误拒绝；不降低现网cipher或跟随坏证书传密码。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
