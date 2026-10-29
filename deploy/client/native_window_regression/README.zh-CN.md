# Windows 原生窗口回归程序

该程序复用待测项目的实际 FlutterWindow/Win32Window、插件、引擎和应用 AOT。
独立入口在自己的窗口中执行最大化、还原、最小化恢复；它不会替换生产入口或调用发布 API。
应用 AOT 会执行正常启动行为，因此只使用已批准测试后端的 payload，并由测试人员自行登录。

先完成匹配版本的 Windows Profile 构建。将 payload 复制到新的独立目录：

```powershell
python deploy/client/native_window_regression/prepare_runtime.py --project '<Flutter项目根>' --output '<新的测试目录/runtime>'
cmake -S deploy/client/native_window_regression -B '<测试目录/build>' -A x64 '-DSUT_PROJECT=<Flutter项目根>' '-DHARNESS_RUNTIME=<测试目录/runtime>' '-DHARNESS_APP_VERSION=2.5.36' '-DHARNESS_BUILD_NUMBER=2536'
cmake --build '<测试目录/build>' --config Release
```

`SUT_SOURCE_DIR` 可指向已冻结的 `windows/` 源码目录；默认只读使用待测项目的 `windows/`。
原生插件列表读取该项目生成的配置，不额外引入其他并行功能依赖。
程序的 PE 版本参数应与实际 payload 一致。它支持默认 30 步，`--extended` 为 53 步：

```text
uten_native_window_regression.exe --extended --start-delay-ms=15000 --step-ms=1000 --accessibility-mode=default --receipt-dir=<新回执目录>
```

从对应 `runtime` 启动；完成后自动退出。`steps.jsonl` 记录每步请求与实际窗口状态、样式、焦点和工作区位置；
`result.json` 记录通过、失败或原生异常。异常仍交给 Windows Error Reporting，不吞掉访问异常。

运行期间使用已授权的 UIA/MSAA 客户端持续查询无障碍树；恢复后检查可访问按钮、标签和值仍能更新。
自动窗口动作通过不代表登录后的实际交互、安装或应用内更新已经验收。
本程序及生成的测试 EXE 不属于客户端安装包或更新 ZIP。
