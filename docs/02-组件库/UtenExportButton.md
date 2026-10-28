# UtenExportButton（统一 Excel 导出）

2026-10-28：导出前置弹窗全站统一升级——文件名（必填，预填调用方默认名）与保存位置（桌面版，默认**桌面**目录、可「浏览…」另选）与可选密码合并为同一个弹窗，不再先密码后文件两步。Web 只有文件名（浏览器决定下载位置）；桌面版保存到所选目录，异步导出任务的下载同样使用所选文件名与路径。默认不覆盖同名文件（顺延 `(1)(2)`）。`saveBytes/saveStream` 新增可选 `directory` 参数，桌面端缺省目录从下载目录改为桌面（OneDrive 桌面重定向优先）。

2026-09-29：`UtenExportSelection.extension` 增加 `pdf`，与现有 `xlsx/zip` 共用选择、密码、等待与保存流程。成本调用先创建不可变快照再传快照 ID；实际核对传已展示结果的摘要。PDF 内容/密码由后端 `TabularPdfExportService` 负责，不把 xlsx 字节改扩展名。详情见[货品成本工作台](../03-页面/货品成本工作台.md)。

> 状态：已实现 · 组件：`lib/components/buttons/uten_export_button.dart` · 后端：`common/export/WorkbookDownloadService.java`

`UtenExportButton` 是报表和主档 Excel 下载的唯一交互入口。调用页只提供端点、报表键、当前筛选和文件名，不自行实现密码框、下载、权限提示或文件保存。

## 当前效果

1. 点击按钮后打开统一对话框：文件名（必填，预填默认名，后缀自动附加且重复输入时自动剥除）、保存位置（仅桌面版显示，默认桌面，可浏览另选）；密码区默认收起，点击彩色「设置密码」按钮后才显示输入框。沿用 `frontend-design`、`UtenDialogHeading`、Uten 主题及间距。
2. 文件名清空时「直接下载/加密下载」不生效并提示「请填写文件名」；取消不发请求。
3. 密码留空时显示“直接下载”，服务端返回普通 `.xlsx`；填写任意 1–128 位密码时显示“加密下载”，再次确认后由服务端使用 OOXML Agile AES-256 加密。点击「取消密码」清空两次输入并收起密码区。
4. 查询任务能力和同步导出请求期间使用共享 `runUtenBlockingTask` 显示居中的等待弹窗，按钮禁用，结束或失败后关闭；异步任务沿用 `ReportExportJobDialog` 的进度。账号、服务器或业务身份变化时移除旧等待框，旧请求结果不能写文件或解锁新操作。
5. Web 由浏览器下载；桌面端保存到所选目录（缺省桌面），移动端保存到文档目录，文件名统一清洗且不覆盖同名文件；异步导出任务弹窗的下载按钮沿用同一文件名与路径。
6. 服务端错误通过统一通知展示。

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
- 表格导出沿用当前可见列的顺序。纯展示列从导出投影剔除；没有可导出列时显示原因并停止，不能静默回退为完整列集。后端按当前权限提供列白名单并再次校验扩展列读取权限，客户端投影不授予权限。

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

## 全平台界面缩放适配（2026-10-13）

密码框已使用 UtenAlertDialog；说明、密码和确认字段可竖向滚动，窄屏动作自动换行。密码可选、128 字上限、两次一致校验、取消不发请求及导出身份栅栏保持。
