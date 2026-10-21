# PurchaseOrderPrintPreview

源码：`lib/features/purchase/widgets/purchase_order_print_preview.dart`。

采购订货单详情页右上角的“打印单据”仅在订单已生效且最新财务审核通过时可用，先用 `UtenDialog` 弹出“确认打印采购单”，列出单号，确认后打开 A4 纵向采购单，取消或关闭不请求打印数据。屏幕预览采用全屏纸面，窄屏横向滚动；工具栏适配当前窗口，纸面字号不受界面倍率影响。界面调整遵守 `frontend-design`，复用 Uten 顶栏、按钮和主题。

公司名称与电话来自平台设置；供应商、联系人和电话按订单供应商解析。交货地点显示订单仓库名称和已维护的位置，没有登记时显示短横，不把供应商地址当作本公司收货地址。货品编号和名称优先使用订单留存快照，型号、规格、材质、颜色和单位从对应主档解析。单据每一条明细独立显示，行交期和额外赠品写入备注，数量使用实际实物数量，历史数量语义不重复加赠品。

预览和 PDF 使用同一份 `/api/purchase/orders/{id}/print-data` 数据。端点先经过订单详情的可见范围和财务待审任务检查，再强制校验订单 `status=1` 且最新财务审批为 `APPROVED`。草稿、待审、退回、改量待复核及复核退回、取消、反审、缺少财务通过证据的历史单均不可导出或打印，直接请求接口同样被拒绝。商业金额和结算方式遵守服务端价格脱敏。金额保持十进制原文，不以数量乘参考价重算。人民币金额支持精确到分的大写；金额实际包含分以下小数时保留小写原值并说明大写不适用，禁止擅自舍入。其他币种不套用人民币大写。

审核签名只取订单最新财务审批 case 的真实 `decided_by_employee_id`，包括改量复核的实际审核人。按预览中的“打印”时重新读取数据，服务端再次检查当前财务状态；若单据变化则刷新纸面并要求再次点击，不输出旧版。前端预览及 PDF 生成也拒绝未通过财务审核的快照。最终打印复用 `printPdfBytes`，Web 仍使用同源 PDF，字体使用本地完整中文字体。

采购工作台批量导出共用该数据与 PDF：先按订单 ID 去重，弹出“确认导出采购单”，列出实际份数及单号；确认后逐单取当前快照，取消或关闭不请求数据、不生成文件。单份保存 PDF，多份打包 ZIP；财务状态在确认后变化时显示服务端拒绝原因，该单不输出。确认期间身份或服务器变化也中止导出。此规则针对采购单据 PDF，表格数据导出继续走既有权限和流程。

PDF 自动分页，每页重复公司、单号、表头和页码；不限制为当前屏幕可见的行。回归：`purchase_order_print_test.dart`、`purchase_order_batch_export_test.dart`、`purchase_order_finance_decision_test.dart`、`operations_workbench_batch_export_test.dart`、`PurchaseOrderPrintServiceTest`、`ProcurementFinanceReviewReadOnlyEndToEndTest`。

纸质明细和业务信息使用 9pt，表头 8pt，辅助页码 7pt；长规格和备注自然换行，不以压缩字号塞进固定页数。中文字体沿用已有 `NotoSansSCFull.ttf`，不改变全局字体。
