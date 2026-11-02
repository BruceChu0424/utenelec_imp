# Windows 无障碍子节点保护

## 2026-11-02：桌面 43 正式版实际复现与跨平台范围

直接运行桌面快捷方式指向的 `2.5.43+2543`，确认 EXE、引擎摘要与正式双包一致；
由用户手动登录后，只进入钱流模块并读取界面状态即退出，没有输入或提交业务数据。
匹配 PDB 的新 dump 指向 `AXPlatformNodeWin::get_accValue` →
`AXNodeData::GetString16Attribute/GetStringAttribute` → 字符串复制访问无效内存，
Release RVA `0xF8B44C`。它与此前现场 `HitTestSync/0xF5D3` 是不同的原生查询入口，
不能只修 Windows HitTest 或某个财务页面。

公共树补丁的节点重挂载/重建后重新绑定能力是本次对应的公共修复入口。
Windows 与 macOS 的 GN 依赖均引用 `common_cpp_accessibility`；公共树补丁必须进入
这两个平台各自重建的引擎。Windows 命中补丁仍只适用于 Windows。Linux GTK、Android
Java、iOS Objective-C、Web DOM 和 WPF 各有对应实现，不以类名相似推定它们已发生
相同 native 故障，也不把 Windows 内部 Profile 结果当作这些平台或正式 Release 验收。

再应用测试增量（只修改 C++ 回归，不改变生产代码）：

```text
git apply --check --unidiff-zero /path/to/flutter-3.44.2-retained-text-value-regression.patch
git apply --unidiff-zero /path/to/flutter-3.44.2-retained-text-value-regression.patch
```

它将保留值改成 35 字节堆分配字符串，并在重挂载后实际读取 UTF-16 值，覆盖本次
`get_accValue` 的字符串复制路径。公共 242 项与两项生命周期场景重复 1,000 轮均通过；
该测试增量需要在公共树补丁之后应用。验证旧公共补丁的 reverse-apply 时，先反向
移除此测试增量。源码摘要及证据见 `patch-provenance.json` 和
[桌面 43 实际复现记录](../../../docs/99-项目治理/2026-11-02-43正式版实际闪退与跨平台公共根因.md)。
正式 Release 引擎重建、各原生系统实机和整合发布仍须单独完成。

## 2026-11-01 现场日志补充：Windows 命中测试

两台电脑日志复核与匹配 Release PDB 将第一台两次退出定位到
`FlutterPlatformNodeDelegateWindows::HitTestSync`（RVA `0xF5D3`）。原公共树补丁不含
这一 Windows 特有路径，旧候选 DLL `f10968fa...13df634` 已按“源码确认未修复”拒绝继续打包。

在下述公共树补丁后，继续应用 `flutter-3.44.2-windows-hit-test-lifecycle.patch`：

```text
git apply --check --unidiff-zero /path/to/flutter-3.44.2-windows-hit-test-lifecycle.patch
git apply --unidiff-zero /path/to/flutter-3.44.2-windows-hit-test-lifecycle.patch
```

增量补丁仅修改 Windows 原生 delegate 和同文件组 C++ 回归：命中前保留 bridge 强引用，
失效 bridge/AXNode 返回空，缺少子 delegate 时继续命中仍有效的兄弟/父节点。无障碍接口
继续可用，不捕获/吞掉原生访问异常。测试使用真实 AXTree 和 Windows delegate，旧方法
稳定产生 `0xc0000005`；保护后新增 4 项与该组共 22 项通过，common 242 项另行通过。
Profile 模式的测试 helper 明确 mock `RunsAOTCompiledDartCode=false`，与其既有假的 Run
和 dummy 路径合同一致；未更改生产 AOT 策略或放宽断言。

增量补丁 SHA-256、重建引擎与测试边界见 `patch-provenance.json` 及
[两台电脑现场核对](../../../docs/99-项目治理/2026-11-01-两台Windows日志与HitTestSync崩溃修复.md)。
这些都是内部候选验证，不表示已有正式 Release 安装包/更新 ZIP 或现网已更新。

## 原公共树补丁与历史证据

`flutter-3.44.2-safe-accessibility-tree.patch` 针对本地已符号化的两条窗口恢复崩溃：
空子节点访问，以及树提交/重挂载后 delegate 指向旧 AXNode 导致字符串读取失效。
补丁保护子项查询、预检拓扑提交并补全缺失的重挂载子树，重挂载后只重绑 AXNode、保留原生对象身份。
属性和几何更新保留快速路径；不完整批次不污染 live tree，后续合法更新仍能继续提交。
不屏蔽无障碍接口，不修改已编译 DLL，不吞掉进程访问异常。

## 源码与检查

- 基础 SDK：Flutter 3.44.2 / Dart 3.12.2。
- 精确引擎源码 revision：`77e2e94772b6eb43759e34ed1ad7da4674e19cab`。
- 补丁 SHA-256：`8f9150a212cecf5899fce6139b92d1f3a92a5efe5a940af1c4e2f34a98af9882`。
- 修改仅包含 common bridge、delegate 及针对性 C++ 回归。
- 已编译运行：3 项新增生命周期回归、Bridge/Delegate 33 项，以及完整 common_cpp_unittests 242/242。
- 先前仅保护空子节点的候选已在正常客户端中失败，不能继续用于交付。

应用到独立、精确 revision 的源码 checkout；先完成标准 gclient 依赖同步，再应用补丁。
不要修改公共 Flutter SDK 或用不同版本的引擎 DLL 替换已有 AOT。
构建工具链与 SDK 路径按实际安装配置；本机遇到的 VS/DIA、SDK 版本和 debugger 工具兼容处理
只在独立构建目录执行，不属于本运行时补丁，也不能把工具目录的 System32 DLL 带进客户端。

独立源码中的构建入口：

```text
python engine/src/flutter/tools/gn --target-dir uimp_host_profile --runtime-mode profile --no-lto --no-goma --enable-unittests
ninja -C engine/src/out/uimp_host_profile common_cpp_unittests
engine/src/out/uimp_host_profile/common_cpp_unittests.exe --gtest_filter=FlutterPlatformNodeDelegateChildAtIndexTest.*
engine/src/out/uimp_host_profile/common_cpp_unittests.exe --gtest_filter=FlutterPlatformNodeDelegate*
engine/src/out/uimp_host_profile/common_cpp_unittests.exe --gtest_filter=AccessibilityBridge*
engine/src/out/uimp_host_profile/common_cpp_unittests.exe
ninja -C engine/src/out/uimp_host_profile windows gen_snapshot flutter/build/archives:windows_flutter
```

单测执行目录、工具路径及 GN SDK 参数须与该次 checkout 相符；保留完整日志与源码/产物摘要。
受控 Windows archive 不包含构建工具临时复制的系统 CRT/UCRT 或 debugger DLL。
客户端 VC 运行库继续由现有 CMake 从正式 MSVC redist 目录复制，并由公共打包器检查依赖闭合。

## 客户端与交付边界

使用同一基础 SDK、该本地引擎和匹配的 `gen_snapshot` 重新编译整个 Windows 客户端，
检查 bundle 的引擎摘要与构建回执一致。`Profile` 的本地 HTTP 测试包与公司 HTTPS 正式包分离。
本次补丁没有授予正式发布、替换公共 SDK 或上传 localhost 包到公司服务的授权。

引擎单测通过不能代替实际验收。交付前仍须使用真实客户端 AOT/引擎运行：

1. 反复展开/还原、最小化恢复、从最大化恢复，以及离散尺寸变化。
2. 同时持续遍历原生 UIA/MSAA 树；恢复后确认可继续定位并操作按钮，不能只检查进程存活。
3. 核对 WER、客户端和原生测试日志，没有同类崩溃；保留每步窗口状态与样式证据。
4. 从同一已验收 payload 生成安装包与更新 ZIP，并核对目标客户端原位更新、固定 updater 和 AppData 保留。

当前实际运行与发布状态以[本次排查记录](../../../docs/99-项目治理/2026-10-28-Windows窗口缩放闪退排查.md)为准；
本说明本身不表示已完成客户端运行验收或发布。


## 公网源码检查点与可重建补丁

Git 版本使用 LF、零上下文 unified diff，避免补丁上下文空行的格式空格被当作源码尾空格。
在上述精确引擎 revision 完成依赖同步后执行：

```text
git apply --check --unidiff-zero /path/to/flutter-3.44.2-safe-accessibility-tree.patch
git apply --unidiff-zero /path/to/flutter-3.44.2-safe-accessibility-tree.patch
```

零上下文版本与已编译版本的每个 Git 源文件 before/after blob ID 完全一致，并已对实际构建源码
执行 reverse-apply 检查；换行和上下文格式变化不表示重跑或新增运行时验证。
原始构建补丁摘要及便携补丁摘要见 `patch-provenance.json`。

构建适配单独提供：`windows-sdk-version-override.patch` 在引擎根应用，支持任务进程环境变量
`UTEN_ENGINE_WINDOWS_SDK_VERSION`，默认上游版本保持不变；
`dart-clang-cl-frame-pointer.patch` 在该引擎 DEPS 指定的 Dart checkout 根应用，
为 Windows clang-cl 正确透传 frame-pointer 参数。两者同样使用 `--unidiff-zero`。
Windows 引擎构建选择已安装且兼容该脚本的 Visual Studio 工具链；不修改公共 SDK、全局 Git 配置或系统设置。

`flutter-skcms-language-flags.patch` 在上述精确 revision 的引擎根应用，
修改实际被编译的 `engine/src/flutter/skia/modules/skcms/BUILD.gn`，不修改未被此构建调用的
第三方 Skia GN。skcms 已使用 C++ `.cc` 源，原 Flutter GN 包装器却将 C11 标准放进通用
`cflags`，导致 Windows clang-cl 明确忽略 `-std=c11` 并告警。
补丁将三处同类配置改为仅对 C 源生效的 `cflags_c`，Windows clang-cl 使用其透传语法；
不修改 C++ 语言标准或运行时算法，不关闭任何告警。应用同样使用 `git apply --unidiff-zero`。

此源码检查点只保存可独立合并的核心修补。测试包应用 AOT 来自当时包含并行改动的冻结工作树，
此分支不冒充该整合工作树的逐字源码；公共窗口控件迁移、导航表面及业务改动仍由对应并行任务整合。
源码提交不包含引擎二进制、客户端安装包、本机路径配置、凭据、完整日志或崩溃内存。
