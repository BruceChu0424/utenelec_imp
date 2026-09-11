# UtenBatchRejectDialog

> 实现：`lib/components/feedback/uten_batch_reject_dialog.dart`（2026-09-10 从报销审批列表页私有
> `_BatchRejectDialog` 升位为公共组件）
> 上层：[组件总览](组件总览.md) · 相关：[UtenReviewerResponsibilityNotice](UtenReviewerResponsibilityNotice.md)、
> [MasterDataTableView](MasterDataTableView.md)

## 一、用途

审批队列多选后点「批量驳回(N)」时弹出的**统一驳回原因对话框**：一次填写原因、逐单应用到所选
全部单据。解决三个一致性问题：

1. 每个审批页各写一份原因弹窗，文案、必填校验与责任提示各不相同；
2. 批量驳回属于正式审核事实，必须显示 [`UtenReviewerResponsibilityNotice`](UtenReviewerResponsibilityNotice.md)；
3. 原因必填的失败反馈要留在对话框内（不能关闭后才提示）。

## 二、API

```dart
final reason = await showUtenBatchRejectDialog(
  context,
  count: ids.length,              // 所选单据数（标题与说明文案用）
  actionLabel: '报销审批',          // 责任提示中的动作名
  subjectLabel: '报销单',          // 单据名词，默认「单据」
  title: '批量拒绝(N)',            // 可选，默认「批量驳回(N)」
  description: '……',              // 可选，默认「驳回原因将同步给 N 位申请人，请说明具体问题。」
  confirmLabel: '确认拒绝',        // 可选，默认「确认驳回」
);
if (reason == null) return;       // 取消 = null；返回值是已 trim 的非空原因
```

- 组件本体 `UtenBatchRejectDialog` 也可直接 `showDialog` 使用（通常走上面的便捷函数）。
- 输入框 `Key('uten-batch-reject-reason')`、确认按钮 `Key('uten-batch-reject-confirm')`，
  供 widget 测试定位。

## 三、行为契约

- 结构自上而下固定：**责任提示 → 影响说明 → 原因输入框**；`actionsAlignment: center`（全站弹窗口径）。
- 原因**必填**：空提交只在字段上显示 `请填写驳回原因`（`UtenInputDecoration` + `utenFieldError`），
  **不关闭对话框**、不返回值；用户开始输入即清除错误。
- `TextEditingController` 由对话框自持并在 `dispose` 释放——关闭退出动画期间仍会重建 TextField，
  外层提前 dispose 会触发 "used after being disposed" 断言。
- 对话框只负责拿到原因；**逐单循环调用单审 API、失败聚合提示由调用页负责**
  （后端没有批量端点，服务端逐单事务 + 状态/认领守卫仍是权威）。

## 四、当前接入方

| 页面 | 动作 | actionLabel / subjectLabel |
|---|---|---|
| 报销审批列表 `/expense/approval` | 批量驳回(N) | 报销审批 / 报销单 |
| HR 信息变更队列 `/hr/profile-changes` | 批量驳回(N) | 信息变更审核 / 修改申请 |
| 访客审批列表 `/visitor-approval` | 批量拒绝(N) | 访客审批 / 访客申请 |

## 五、使用边界

- 只用于**批量**驳回/拒绝；单单驳回仍在详情页表单内完成（那里通常还要选具体明细/附件）。
- 不承担权限门控：按钮显隐与动作权限由调用页判断，服务端独立鉴权。
- 单次批量上限由调用页守卫（当前各页 50 条），超限提示分批，不在组件内写死。
