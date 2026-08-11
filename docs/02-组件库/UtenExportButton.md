# UtenExportButton（统一 Excel 导出）

> 状态：已实现 · 组件：`lib/components/buttons/uten_export_button.dart` · 后端：`common/export/WorkbookDownloadService.java`

`UtenExportButton` 是报表和主档 Excel 下载的唯一交互入口。调用页只提供端点、报表键、当前筛选和文件名，不自行实现密码框、下载、权限提示或文件保存。

## 当前效果

1. 点击按钮后打开统一对话框。
2. 密码留空时显示“直接下载”，服务端返回普通 `.xlsx`。
3. 填写任意 1–128 位密码时显示“加密下载”，再次确认后由服务端使用 OOXML Agile AES-256 加密。
4. 请求期间按钮禁用并显示加载状态，避免重复提交。
5. Web 由浏览器下载；桌面和移动端通过 `saveBytes` 保存，文件名统一清洗且不覆盖同名文件。
6. 取消对话框不发请求；服务端错误通过统一通知展示。

## 用法

```dart
UtenExportButton(
  endpoint: '/purchase/reports/export',
  report: 'order/detail',
  queryParams: {
    'dateFrom': '2026-07-09',
    'dateTo': '2026-08-09',
    'sort': 'billDate',
    'order': 'desc',
  },
  filename: '采购订货明细报表',
  requiredPermission: Perm.purchaseReportExport,
  enabled: true,
)
```

- `queryParams` 必须与当前列表筛选、排序一致，不包含分页参数。
- `requiredPermission` 只控制前端可见性；后端 `@PreAuthorize` 是最终授权边界。
- `enabled=false` 用于查询快照等前置条件尚未建立的页面。

## 请求与服务端处理

```text
POST <endpoint>?report=<report>&...
Content-Type: application/json

{"password":""}      // 普通 Excel
{"password":"1"}     // 密码加密 Excel
```

所有端点使用 `@Valid ExportPasswordRequest` 和 `WorkbookDownloadService.protect(...)`。密码只在 body 中传输；字段缺失、`null` 或空字符串表示不加密，非空值原样作为文件密码，最大 128 位。

## 不可绕过的边界

- 独立 `*:export` 权限，不复用查看权限。
- 用户级频率限制、进程内并发闸门和导出行数上限。
- 服务端权威列定义、参数化过滤和排序白名单。
- 字符串单元格按文本写入，避免公式注入。
- 导出操作写审计，但密码和请求正文不得进入审计或日志。
- 生产环境必须使用 HTTPS。

弱密码和无密码只适用于下载文件；登录、首登改密和高危操作的密码策略不受影响。决策见 [ADR-032](../99-决策记录-ADR/ADR-032-导出文件可选密码保护.md)。

**最后同步**：2026-08-09
