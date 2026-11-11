# WPF 大选中导出本机回归

在已经审查并提交的候选工作树运行（示例 run-tag 每轮换新）：

```powershell
python tool/company_feedback_wpf_export/run.py --root D:/Projects/uten_imp_worktrees/feedback-remediate-20261110 --run-tag final-native-export-1 --restore-pinned-dependency
```

脚本只使用已安装 MSBuild、工作树内固定版本依赖、Debug/Unreviewed 编译与独立输出，不安装、不创建 Setup/更新 ZIP、不修改共享 SDK。输出为 `evidence/wpf-export-<run-tag>`；每轮禁止覆盖旧输出。两种架构分别执行大选中链和原完整本机契约测试，记录源码 SHA/tree、退出码、原始合成 body 与证据哈希。

`--large-unit-export-contracts` 含原 1000/1001/50001 compact body、另加超过 2MiB 的合法原选择字符串、完整受控 HTTP 编码、真实 CurrentUser DPAPI 中断后原 GET 核对、错误证明拒绝、旧 `mutations.dpapi` 兼容、16MiB/32MiB/64MiB 边界和普通写入上限、显式旧服务端下载、实际 `UnitExportWindow` 异步/取消。请求 UUID 为合成契约数据；工作簿响应为受控字节，不能写成真实库 50001 行文件验收。生产库权限、缺失与额外未选项、真实 XLSX 大规模核对由统一 Java/PG 验收提供。Win7 目标设备另验。
