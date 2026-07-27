# UtenExportButton（加密 Excel 导出按钮）

> 一键把当前表格（报表 / 主档）导出为**加密 .xlsx**：点击 → 设密码 → POST 后端生成 → 跨端下载。
> 位置：`lib/components/buttons/uten_export_button.dart`
> 后端配套：`common/export/`（`XlsxExportService` SXSSF + `EncryptedWorkbookService` Agile AES-256）+ 各 `*ReportController POST /export`。

---

## 一、为什么需要它

- 公司年长用户多，**文字按钮**（"下载表格"）比纯图标易懂。
- 导出含财务/客户等机密数据，必须**加密**（用户设密码，Excel/WPS 打开时输入）+ **过审计**（谁下了什么）。
- 跨端：Web 浏览器直接下载、桌面/移动写下载/文档目录（`lib/core/io/file_saver.dart` 条件导入）。

---

## 二、API

```dart
UtenExportButton(
  endpoint: '/purchase/reports/export',   // 后端 POST 导出端点
  report: 'order/detail',                  // 报表 key（与 GET 路径一致）
  queryParams: {                           // 过滤 + 排序（与列表 _load 的 query 一致，不含 page/size）
    'dateFrom': '2026-06-27', 'dateTo': '2026-07-27',
    'keyword': '...', 'f.supplierName': '...', 'sort': 'billDate', 'order': 'desc',
  },
  filename: '采购订货明细报表',             // 下载文件名（不含 .xlsx，自动追加）
  label: '下载表格',                       // 按钮文字，默认"下载表格"，可覆盖如"下载货品表"
)
```

点击流程：弹密码对话框（密码 ≥6 位 + 确认一致）→ `apiClient.downloadBytes(endpoint, body:{password}, query:{report,...queryParams})` → `file_saver.saveBytes(bytes, filename.xlsx)` → 成功 toast（Web"已开始下载"/IO"已保存：路径"）。

内置：防连点、loading（按钮自带转圈并禁用）、`context.mounted` 守卫、`ApiException`/兜底错误 toast。

---

## 三、安全（见 [00-项目准则/10-安全准则.md](../00-项目准则/10-安全准则.md)）

- **密码入 body**，不入 URL/query/日志；prod 须 HTTPS。
- 后端 `report` 参数 **switch 白名单**（非法值抛异常）；过滤/排序走**参数化绑定 + 列 key 白名单**（`ReportSort`/`TableSort`），无 SQL 注入。
- Excel 单元格 `setCellValue` 写**文本**，防 `=CMD()` 公式注入。
- 每次导出**过审计**：`audit.logExplicit(uid, account, "export_<module>_report", "<module>_reports", "<report>/<行数>rows", "success")`——工作台/系统管理可查。
- **行数上限 10 万**：超限后端拒绝并提示收窄筛选/分批（防 OOM + 防批量拖库）。
- 权限：`@PreAuthorize('..._report:export')` 独立权限点（V71 迁移新增 6 个 `*_report:export` + 回填给所有有 `:view` 的部门；「能查看」≠「能导出」）。权限在 JWT claim，**改后用户须重登**新 token 才带 `:export`（超管恒有）。

---

## 四、放置位置

- **报表页**：`UtenAppBar.actions` 加一个（一处覆盖该页所有卡）。范式见 `purchase_report_table_page.dart` 的 `_exportReport`/`_exportQuery` getter。
- **主档页**：标题行（如货品 `(N)` 那行）或 `AppBar.actions`。

---

## 五、后端新增导出端点（报表范式，复制即可）

1. `*ReportService.export(report, allParams, sort, order)`：switch 分发到各报表方法 + `paginateAll`（循环 size=500 累积全部行，>10 万抛错）→ `ExportPayload`（列映射 `ReportColumn→ExportColumn`）。参考 `PurchaseReportService.export`。
2. `*ReportController POST /export`：注入 `XlsxExportService`+`EncryptedWorkbookService`+`AuditService`+`SecurityContextCurrentUser`；`@RequestBody ExportPasswordRequest{password}`；过滤/排序 `@RequestParam`；`ResponseEntity<byte[]>` + `Content-Disposition: filename*=UTF-8''<encoded>.xlsx`；`audit.logExplicit("export_<module>_report", ...)`。

主档导出为变体：列定义服务端权威（不信前端），循环既有 `list` 分页累积，名称在 `toList` 已解析。

---

**最后更新**：2026-07-27 · 组件建成（文字按钮 + 密码弹窗 + 跨端下载），采购报表端到端验证通过；其余报表族 + 主档导出推广中。
