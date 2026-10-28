# UtenBackButton

全系统页面标题栏的唯一返回按钮入口，默认使用 `frontend-design`，保留 Uten 主题及来源感知返回规则。

## 2026-10-28 选定样式

用户从四款预览中选定 **B：实心青圆**，并明确要求按钮只占可见圆形图标本身的范围，图标与标题之间的空隙单独留白，不再扩大返回按钮的可点击宽度。

- 形状：32dp 实心圆；内部20dp `arrow_back_rounded`，使用字体图标的方向适配。
- 色彩：现有主题 `primary` / `onPrimary`；默认亮色品牌青 `#0F766E`、白色箭头，暗色使用主题青色与相应对比前景；禁用使用主题中性色。延续 `#FFFFFF`、`#0F172A`、`#F1F5F9` 中性表面。
- 排列：按钮在标题栏左端垂直居中；标题与圆形右缘间隔16dp，空隙不响应返回点击。
- 交互：hover/按下有主题反馈，键盘聚焦有可见描边，提交禁用不执行返回。
- 主题字体和标题层级不变。突出返回入口，不为标题栏添加额外装饰或阴影。

```text
[ 32dp 圆形返回 ]   16dp留白   页面标题
     可点击          不可点击
```

设计复核：保留选定B的清晰度；将旧实现把标题间隙计入命中范围的做法改为独立间距，按用户本次明确要求执行。这里不再使用旧的40/48dp水平加宽合同；本规则仅针对该返回按钮，不改变其他控件的触控规范。

## 公共入口与职责

- `lib/components/buttons/uten_back_button.dart`：图标、圆形、交互状态、按钮尺寸、默认返回行为。
- `lib/components/layout/uten_app_bar.dart`：复用按钮槽宽，并单独提供标题间距。业务页不另加透明可点击留白。
- 默认返回继续调用 `backTo`：优先返回上一页，无栈读取来源，再回工作台。业务页可以传入 `onPressed`、`enabled` 或 `tooltip`，不改变原草稿/权限/提交守卫。
- 原生错误/空态AppBar需要返回时也接入该组件；分页、日期切换、关闭X及局部文字返回不是本合同。

已审查直接调用与自动返回入口；验证及例外迁移结果见本轮输出 `output/back-button-options-20261028/`。本地UI变更不等于已经打包、部署或完成员工客户端现场验收。

## 接入与验证

原有172处直接调用和55处自动返回（共227个源码入口，非独立页面数）通过公共按钮继承新样式。补齐6处原生标题栏返回：

| 文件 | 入口与保留差异 |
|---|---|
| `lib/core/router/app_router.dart` | 页面不存在、无权访问两处；无可返回路由时不新增返回键 |
| `lib/features/finance/widgets/ar_ap_picker_dialog.dart` | 读取范围变化页；保留原Navigator返回 |
| `lib/features/finance/payables/widgets/supplier_credit_apply_panel.dart` | 读取范围变化页；保留原Navigator返回 |
| `lib/features/warehouse/pages/warehouse_task_center_page.dart` | 无授权空态；保留原可返回性 |
| `lib/features/sales/pages/sales_task_center_page.dart` | 无授权空态；保留原可返回性 |
| `lib/features/client_update/client_update_page.dart` | 已用公共返回键，补外部16dp标题间隔，保留24dp页边距 |

原生入口保留`impliesAppBarDismissal`和fullscreenDialog的关闭X语义，不把无栈空态变成新的业务导航。分页、日期、局部文字返回及弹窗关闭仍保持各自合同。

定向回归：公共按钮/标题栏/销售保存返回4文件15项通过；例外页面既有回归5文件62项通过；实际选定B渲染1项通过，浅色与深色截图已目检。定向Dart分析无问题，diff检查通过。

首次加载测试时，其他并行工作正在新增表格读状态公共组件，出现瞬时缺失文件编译错误；该文件正常落地后重跑通过，本任务未修改或回退该并行实现。测试证明32dp按钮四个边缘可点击、独立标题间隙不响应返回、显示缩放不额外扩宽、禁用态不执行返回，以及原保存/来源导航仍有效。
