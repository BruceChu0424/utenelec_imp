# 真实 Windows / 本地 HTTP 反馈验收

默认使用 `frontend-design` 并沿用 Uten 组件/主题。本入口只改测试与隔离设施；通过生产 `bootstrapUtenApp`、router、provider、repository 和真实 `SessionNotifier.login` 访问本地 Spring/PostgreSQL。Windows engine、Flutter VM、合成 API 和真实 Web 分栏，不能互相冒充。

先等统一候选后端/普通合成账号就绪。`run_feedback_actual_windows.py build --run-tag <新标识> --runtime-config <私有runtime.json>` 只编译，不启动客户端。`run` 使用同参数并须显式 `--runtime-ready`；它拒绝未提交源代码、已运行过的私有 prefs 根或已存在的同阶段证据。不把密码写进 define/命令/日志，测试运行时仅从指定私有 JSON 读取 `syntheticAccountPassword`。账号通过 `--account`，可选两类退货账号通过 `--returns-account` 配置；应使用独立普通账号避免替换其它正在验收的登录会话。

每轮目录为本工作树 `evidence/<run-tag>/private/windows-runtime`，所有旧轮保留。真实 Windows DPAPI `.dat` 使用 `PathProviderPlatform` 指定根；真实 SharedPreferencesWindows/AsyncWindows 自带独立 `PathProviderWindows`，必须在第一次读取前同样指定该根，并检查真实插件已注册，绝不读已安装 Uten/Local Test 的 prefs、凭据或草稿。两种真实 JSON 后端及 fail-closed 合同见 `test/tool/windows_acceptance_preferences_test.dart`；默认旧 finance 接受入口路径字符串保留，纠正原来的隔离缺口。四个测试平台依赖仅将现有锁定 transitives 声明为 direct dev，版本、哈希与其它 lock 内容保留。

原生诊断在 Dart 启动前开启，所以另使用既有 `StartNativeDiagnostics(test_directory)`。生成工具只接受 LocalTest、现存的绝对私有 evidence 根；C++ 使用还同时要求 `_DEBUG` 和 `UTEN_LOCAL_TEST_BUILD`。普通正式构建及任何 Release 配置保持原日志规则，不接受业务输入或普通运行参数改目录。该测试 hook 与源码一并审查/整合，不临时改 runner 冒充同一 SHA。临时文件、生成头、manifest、截图、客户端原生/HTTP `.log` 均有本轮独立路径；不安装或正式打包，不改 SDK。

当前 smoke 覆盖完整1626模具、列头套数升序（首行AU-01626/1.125）、完整纸面预览、预览内及普通导出弹窗取消，并从真实客户端诊断日志核对冷读/排序到达 HTTP、取消后0个导出作业创建。可选普通 maker 对采购/委外退货真实页面各打开/取消货品选择器3次，保留7.125。只点击取消不生成文件，实际下载/入账链由统一 Web 验收承接。

路径/原runtime合同准备轮10/10、定向 Dart 分析0问题。准备期 Debug编译不等于真实 HTTP验收；最终必须在统一冻结 SHA重新构建/实跑，检查 `run-receipt.json`、`result.json`、截图和原始日志。私有配置和存储文件不得提交。
