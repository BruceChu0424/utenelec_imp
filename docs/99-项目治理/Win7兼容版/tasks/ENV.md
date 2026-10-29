# 原生环境与可重复构建

由唯一进度登记表生成。

## W7-ENV-001

- [x] **net48/C#7.3双架构项目** — 本项DoD完成

影响：`frontend`；负责人：Codex；依赖：W7-GOV-001。

源入口：`clients/windows_legacy/BuildVersion.targets`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. Core/Desktop/Tests/Updater按正确目标编译；区分AnyCPU库与明确x86/x64入口。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`。

接续/限制：当前Core/Desktop/Tests/Updater均按net48/C#7.3完成x86/x64整体编译与执行；主程序/helper PE实测同架构，BC保留锁定AnyCPU。仅此项目构建DoD完成，Win7目标机另验。。

## W7-ENV-002

- [x] **任务私有依赖锁及许可** — 本项DoD完成

影响：`frontend`；负责人：Codex；依赖：W7-GOV-001。

源入口：`clients/windows_legacy/BuildVersion.targets`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. BC固定版本、包SHA512、文件SHA256、实际加载库检查、MIT许可及无全局缓存修改。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：BC私有版本/包SHA512/实际文件与运行加载SHA256/原MIT均已当前两架构整合与59工具验证；许可另随程序可查看，无全局缓存或SDK修改。仅此依赖锁DoD完成。。

## W7-ENV-003

- [x] **同源版本与构建号** — 本项DoD完成

影响：`shared`；负责人：Codex；依赖：W7-GOV-001。

源入口：`clients/windows_legacy/BuildVersion.targets`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 主/Core/Updater版本资源从pubspec唯一来源生成；BC保持自身版本；不得改低现有SDK版本。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/unit-business-installer-20261028.json`。

接续/限制：当前6件Release及两架构Debug从同pubspec生成Assembly/File/Product版本，BC保持独立供应商版本；metadata-only六件通过，未降低SDK。。

## W7-ENV-004

- [x] **共享SDK和现用版本隔离** — 本项DoD完成

影响：`documentation`；负责人：待认领；依赖：W7-GOV-001。

源入口：`clients/windows_legacy/BuildVersion.targets`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 记录SDK/主工作树只读边界，禁止降级或替换现用Win10安装/数据/更新器。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`docs/99-项目治理/Win7兼容版/00-总实施计划与交接入口.md`。

接续/限制：按依赖与DoD继续，完成后登记证据。

## W7-ENV-005

- [ ] **Release/Company身份门** — 源码已实现/待整合验证

影响：`delivery`；负责人：待认领；依赖：W7-GOV-001。

源入口：`clients/windows_legacy/BuildVersion.targets`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. PE marker、干净源码、构建前后输入/产物receipt一致；拒Debug/LocalTest/Unreviewed冒充。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：尚未登记，不得推定通过。

接续/限制：已有源码/历史局部检查；接手基线需复核当前整合，不能代替Win7或完整业务验收。。

## W7-ENV-006

- [x] **一键原生验证与失败可重现** — 本项DoD完成

影响：`delivery`；负责人：Codex；依赖：W7-GOV-001。

源入口：`clients/windows_legacy/BuildVersion.targets`；`clients/windows_legacy/tools/build_windows_wpf.ps1`。

完成条件：

1. 统一命令编译/执行双架构合同检查，错误退出码准确、产物隔离，含Updater和下载实际集成。
2. 记录适用调用方、保留差异、当前源码验证及尚未覆盖条件；不得推定其它版本已完成。

证据：`clients/windows_legacy/progress/evidence/native-checkpoint-20261028.json`；`clients/windows_legacy/progress/evidence/native-draft-package-20261028.json`。

接续/限制：统一verify_windows_wpf.ps1实际跑通all；私有GUID输出/源码前后SHA/错误码/实际bootstrap/主runner含Core与Goods24 Downloads32 Units38 Updater203 UI。缺失工具负例exit1且不编译/安装。。
