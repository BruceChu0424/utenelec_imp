# Windows headless 草稿存储测试装置

本装置只解决 Flutter 3.44.2 Windows 自带 Web 测试服务器的路径问题，运行的是原有浏览器专属测试和原有应用代码。它不改公共 Flutter SDK、产品 Dart、测试断言或默认浏览器配置；也不等于实际应用的 Web 财务业务验收。

## 已记录的环境问题

- SDK `flutter_web_platform.dart` 的 `_localCanvasKitHandler` 先用 Windows `fromUri`，随后判断正斜杠 `canvaskit/`，实际本地 JS/wasm 请求 404。
- SDK 生成 HTML 直接把 Windows 相对测试路径插入 JS 字符串；反斜杠转义后与原编译 registry 的正斜杠键不符。
- SDK 只服务 `test` 静态目录，不直接服务应用 `web` 根或 pubspec 中的 assets HTTP 根。因此大载荷的原 codec worker 必须作为原字节测试静态资产暂存。

完整原错误在 `build/finance-final-audit/browser-v3/browser-sdk-load-failure.log`。旧装置未执行任何断言；晚挂载适配后，已经断开的 suite 没有恢复，故关闭仅该隔离浏览器，让原 runner 自然记录 0 测试、2 个加载错误。后续启动器在原 host 首次打开前安装适配，避免这种状态。

## 复现

使用独立快照 `D:/Projects/uten_imp_worktrees/finance-ui-tests-20261105-browser-v3`，保留原有 `lib/test/pubspec.lock/web`。将本仓 `tool/finance_test_sdk_windows_adapter.cjs`、`tool/finance_test_chrome_launcher.cjs` 和 `tool/finance_test_chrome_launcher.cs` 复制到该快照 `build/finance-final-audit`。

在该 build 目录执行：

```powershell
& C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe /nologo /target:exe /platform:x64 /reference:System.Web.Extensions.dll /out:finance_test_chrome_launcher.exe finance_test_chrome_launcher.cs
```

在快照根执行：

```powershell
Copy-Item -LiteralPath web/uten_data_codec_worker.js -Destination test/shared/drafts/uten_data_codec_worker.js
# 两个文件须先比较 SHA256；本次均为 50e4bdc01c37a43ddd11c3d424616b589a002eafecd701d18b4844d4d3570041。
$env:UTEN_TEST_REAL_CHROME='C:/Program Files/Google/Chrome/Application/chrome.exe'
$env:UTEN_TEST_NODE_EXE=(Get-Command node).Source
$env:UTEN_TEST_CANVASKIT='D:/Software/Flutter/flutter/bin/cache/flutter_web_sdk/canvaskit'
$env:CHROME_EXECUTABLE=(Join-Path (Get-Location) 'build/finance-final-audit/finance_test_chrome_launcher.exe')
flutter test test/shared/drafts/form_draft_storage_browser_test.dart test/shared/drafts/form_draft_history_browser_test.dart --platform chrome --no-pub --reporter expanded
```

启动器仅接受 Flutter 自建 `flutter_tools_chrome_device` 临时 profile 与 `--headless` 参数。参数以 Base64 JSON 通过 PE/Node 边界传递，Chrome 使用原参数数组启动，不经 shell 拼接；仅初始地址暂置空白，适配准备好后打开原测试 host。Windows job 关闭时仅回收本启动器的 Node/Chrome 后代。

最终 `final-browser-drafts-v6-adapted.log` 为 17/17，包括超过 localStorage 容量的原负载、跨连接 CAS 单赢家、UTF-8/JSON 原文、原升级事务回滚和终态。之前 15/2 的缺 worker 两轮保留，未用 inline 或替代算法消音。源码、原 worker 和只读 SDK 文件 SHA 见同名 JSON。
