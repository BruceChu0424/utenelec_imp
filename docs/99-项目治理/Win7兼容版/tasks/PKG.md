# 构建产物与可追溯打包

由唯一进度登记表生成。

## W7-PKG-001

- [ ] **六文件候选ZIP生产器** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. fixed family/platform/arch/version/显式kind和全文件哈希，与server/updater同一合同。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-PKG-002

- [ ] **源码/配置/产物receipt** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 干净commit、构建前后源码hash、批准Company配置原字节、六输出hash及marker，防混包。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-PKG-003

- [ ] **Company与Debug/LocalTest门** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. PE Comments严格Release/Company，不靠目录名；BC独立版本pin，非法输入failclosed。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-PKG-004

- [ ] **完整Setup构建器** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 同源双payload+bootstrap、经审核编译器、外层身份/版本校验，不能只交ZIP或脚本。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-PKG-005

- [ ] **冻结/二次校验/原子输出** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 候选生成时冻结输入与重验，故障/并发保持原输出，不把临时包留作正式包。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-PKG-006

- [ ] **各支持组合双包配对** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 每个runtime+arch都列版本/commit/哈希/大小/说明与安装/更新相配；未验收不能算交付。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-PKG-007

- [ ] **签名/信誉/许可与来源** — 进行中

影响：`delivery`；负责人：Codex；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 第三方license、签名条件和工具来源真实；无证书不能写已签名/消除SmartScreen。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-PKG-008

- [ ] **候选与正式输出/清理隔离** — 未开始

影响：`delivery`；负责人：待认领；依赖：W7-ENV-003, W7-ENV-005。

源入口：`clients/windows_legacy/tools/package_wpf.py`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. LocalTest/候选/正式单独命名目录，禁止上传localhost/debug；无授权不发布。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：按依赖与DoD继续，完成后登记证据。
