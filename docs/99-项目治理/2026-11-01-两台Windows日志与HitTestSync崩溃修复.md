# 两台 Windows 现场日志与 HitTestSync 崩溃修复

本记录承接[首轮 38/43 排查](2026-11-01-Windows38与43无响应及退出排查.md)。用户随后提供了两份故障电脑的实际诊断包，明确第二台没有快速连续操作，尚未出现退出，但点击更新完全没有反应。基线为独立分支 `uimp/windows-stability-2538-2543-20261102` 的 `5f1c8cf3f`；本轮不合主链、不推送、不部署、不生成正式客户端双包。

## 两台电脑的事实

| 项目 | 第一台 | 第二台 |
|---|---|---|
| 系统 | Windows 11 Pro，10.0.26300，x64 | Windows 10 Pro，10.0.19045，x64 |
| 实际 EXE 版本 | **2.5.37+2537**，修正最初口述的 38 | **2.5.43+2543** |
| EXE SHA-256 | `7810a8746afcc1f9c7c8efa43abe56fabf59f0ee95089e3b9c9cd94c30a13385` | `20389bb6e222d057e9474c459b30c50f44ab534f976bd2e057d1bc4ad2765864` |
| 引擎 SHA-256 | 两台均为 `011e87e890b7bfbac89f63c763341ffb8393d2b4a617dd836c471a0cdaa1346f`，21,284,352 bytes | 同左，亦与此前 38/43 正式 ZIP 和 SDK Release DLL 一致 |
| 崩溃证据 | 两次不同进程生命周期的 APPCRASH，均为引擎 RVA `0xF5D3` | 没有采到 43 版 APPCRASH / Application Hang |
| 其他记录 | 每次先为 `C0000005`，随后同一进程为 `C000041D`，共 8 条 1000/1001 事件 | 仅一条旧 **2.5.34.2534** 的 `RADAR_PRE_LEAK_64`，不是 43 崩溃证明 |
| dump | 元信息列出 4 个文件；ZIP 没有包含其字节 | 未列出 dump |
| 用户补充 | 快速操作曾无响应并退出 | 未做快速连续操作，暂时未退出；**点击更新完全没反应** |

第一台两次事故时间按本聊天时区 America/Denver 为 2026-10-31 01:38（UTC-6）及 2026-11-01 19:36（UTC-7）；原始事件 UTC 分别为 `2026-10-31T07:38:*Z`、`2026-11-02T02:36:*Z`。同一进程的两种异常不能重复统计为两次退出。

两份 ZIP SHA-256 分别为 `6729c24bdf57a73cdd201a71b1dffcc38da6eca5b0eb920698271a39d0a73540`、`11b573fdfdae3489c9136400e2544ce458e41e935158961f05d33836bbbe23d9`。原包保留原位置，仅将 JSON 和分析回执复制到任务 `build/stability-native/customer-evidence-20261101/` 与 `customer-evidence-pc2-20261101/`；这些含现场路径的资料不进入 Git。

## 故障函数与可复现缺陷

以第一台引擎的精确 SHA-256 和 PE 时间戳 `0x6A29D48A` 匹配本机 SDK Release DLL。DLL CodeView 的 PDB GUID 与所用 PDB 完全一致：`015D6F44-47AA-4576-B919-626F55044F87`、Age 1。由此将 `0xF5D3` 解析为：

```text
FlutterPlatformNodeDelegateWindows::HitTestSync(int, int) const
shell/platform/windows/flutter_platform_node_delegate_windows.cc:69
内联 std::weak_ptr<FlutterPlatformNodeDelegate>::lock / _Incref_nz
故障指令：mov eax, dword ptr [rcx+8]
```

对应源代码在遍历 AX 子节点时查询其 Windows delegate，仅用 `FML_DCHECK` 检查，然后无条件调用子 delegate 的 `HitTestSync`。发布构建没有有效的运行时空值保护。树仍列出子节点、其平台 delegate 已缺失的状态会进入无效访问；编译内联后的故障位置落在 weak_ptr 引用计数读取，不能据此把问题归咎于智能指针库本身。

新增原生 C++ 用例使用真实 AXTree、Windows delegate 和真实 bridge，构造“AX 子节点仍存在、delegate 不存在”的边界。原方法稳定产生 **SEH `0xc0000005`**；仅补上命中保护后通过。保留匹配 PDB、反汇编、修复前失败及修复后日志。[Flutter 上游同类缺陷记录](https://github.com/flutter/flutter/issues/192180)具有相同函数、源码行及 Release `0xF5D3` 特征；该 issue 被作为重复关闭，不表示本次旧二进制已经修复。

这比首轮仅凭源码指出风险更进一步：第一台真实事故已定位到故障函数和指令，并有原生红绿回归支持对应缺陷路径。当前 ZIP 没有 dump 内容，尚不能读取事故当时 RCX 值、完整调用链或确认具体哪个 Windows 无障碍客户端发起查询；不能把别人的 dump 寄存器值当作这台电脑的证据，也没有复现用户完整快速操作序列。

## 公共修复与适用范围

原 `flutter-3.44.2-safe-accessibility-tree.patch` 保留为公共树、空子项和 reparent 修复。新增 **`flutter-3.44.2-windows-hit-test-lifecycle.patch`**，按同一精确引擎 revision 应用，Windows 原生命中测试只有这一处维护入口：

- 几何查询前锁定 bridge 的强引用，bridge 或 AXNode 已退场时返回空。
- 子 delegate 缺失时继续检查有效兄弟，全部未命中时保留可访问的父节点；有效命中和范围外行为不变。
- 不屏蔽 UIA/MSAA、不关闭语义、不移除业务控件，不在生产代码捕获访问异常。
- 新增 4 项：缺子代理返回父节点、缺代理不阻断有效兄弟、失效 bridge 返回空、范围外返回空。

该补丁只涉及 Flutter Windows 原生 UIA/MSAA 路径；Web、macOS/Linux/移动端不编译此 Windows 类，Win7/8.1 的独立 WPF 候选也不使用 Flutter AXTree。各端原有共享焦点、草稿、权限、数量、来源及业务计算未改动，不把候选端未迁移业务标成完成。

公共打包策略按本轮证据更新分类：正式 Release `011e87...1346f` 进入“现场崩溃已确认”；上一轮只补 common tree 的 Profile `f10968...df634` 进入“源码确认仍缺 Windows 命中保护”。两类仍共用 `reject_known_unsafe_engine`，覆盖 Setup/ZIP 生成与独立 ZIP 复验；没有修改或删除用户既有安装及包文件。

## 回归与失败分类

| 检查 | 结果与边界 |
|---|---|
| 原方法 + 新用例 | 缺子 delegate 时 SEH `C0000005`；修正测试 AOT fixture 后再次得到同样失败，排除假 AOT 路径作为此用例失败原因 |
| 新保护 4 项 | 通过，包含有效兄弟仍命中，验证没有关闭整个无障碍功能 |
| Windows accessibility 组 | **22/22 通过**，包含上述 4 项，不重复相加；最终日志没有 AOT 路径错误 |
| common C++ | **242/242 通过**；公共树源未改变，原验证继续成立 |
| 初次 Windows 组的 18 个失败 | Profile 构建下旧测试 helper 使用假的 `C:\\foo\\aot.so`，在已 mock Run 前被 AOT 检查挡住。helper 现按同组其他测试的方式 mock `RunsAOTCompiledDartCode=false`，不改生产 AOT 校验或断言；原失败日志保留 |
| Python 客户端策略全集 | **105 cases：94 通过、11 跳过、0 失败**；跳过为显式 ISCC/Linux/Bash/目录锁或权限环境项。日志中故意缺参数/缺端点的拒绝属于反例验证 |
| 重新核查更新点击链 | **52 个实际 Flutter 交互/状态用例通过**，加载项不计入；尚未在第二台电脑复现其完全无反应，不能以此宣布现场更新成功 |
| 新引擎实际 Windows fixture | 53/53 窗口动作通过，内部 Timer 到至少 8,675 次节点/弹窗切换、框架异常 0、原始输入保留、32 次非法更新请求明确拒绝。单次 UIA 查询可读，但该次可访问树标签计数与 Timer 计数不一致，尚不能宣称无障碍树持续刷新验收；纳入后续极端压力阶段继续核查 |

新增补丁 `e0dee46d8cee8f7273b550b691b51410c3b7198eecd28bf3a5e9119256288733`；当前内部 Profile 引擎为 `681bdffd8d8179eb4227f0c84c7ad61923fc21fb5c57ed04832f09588c013089`，与同 revision 的 gen_snapshot/SDK 重编测试入口。补丁可反向 apply 检查到实际构建源码，来源登记在 `patch-provenance.json`。没有替换公共 Flutter SDK。

## 第二台更新问题的剩余证据

现有第二台 ZIP 不包含 `client-updates/last-update.log`、`last-update-result.json`，也没有固定 updater 是否存在及暂存包元信息。因此不能确定点击停在 UI/下载校验、安全状态等待、原生通道，还是 helper 启动/握手阶段。上一轮发现并修复的同步握手阻塞仍是实际缺陷，但目前没有证据证明它就是第二台这次无反应的原因。

已扩展同一只读采集脚本，限定读取 Flutter 固定更新器摘要、最近 64 KiB 更新日志、16 KiB 结果及最多 5 个暂存 ZIP 元信息，不读取账号配置、业务附件或 dump 内容，不修改系统或上传。WPF 的该项诊断明确不适用，不把缺少 Flutter 脚本判成 WPF 故障。用户随后明确不再继续手动采集，改为大数据/频繁中断等极端压力验证，并要求各安装版本内置可直接复制的 `.log`；后续不再要求故障电脑运行采集工具，本轮现有工具仅作可选历史能力保留。

本轮现状：第一台的可复现原生缺陷已补充修复；第二台更新故障仍待新版现场证据。正式 Release 运行时、全绿 CI、同源双包及两台机器的安装/更新/快速操作验收尚未完成，现有 37/43 安装没有被本任务替换。
