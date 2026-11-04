# UtenWorkflowProgress

2026-11-03 从委外全链路进度的小节点条提取，设计继续使用 `frontend-design` 和既有 Uten 主题。入口：`lib/components/feedback/uten_workflow_progress.dart`。

## 与已有时间线的边界

`UtenWorkflowProgress` 表达从填报到审批、执行的前向流程，以当前节点、完成、未开始、驳回和跳过状态回答“到哪一步”。默认按可用宽度换行，事实详情保留完整内容；`horizontalScroll: true` 保留委外原有横向滚动方式。

`UtenProgressTimeline` 表达按时间排序的事件历史，原有“未开始在顶、开始在底”的快递式规则继续保留。两者语义不同，不用阶段条替代历史记录，不改变销售等现有时间线的排序。

## 使用

```dart
UtenWorkflowProgress(nodes: [
  UtenWorkflowNode(title: '部门负责人审核', state: UtenWorkflowNodeState.done),
  UtenWorkflowNode(title: '财务初核', state: UtenWorkflowNodeState.current),
  UtenWorkflowNode(title: '财务复核'),
])
```

`UtenWorkflowNode` 的 `details` 用于实际经办人、数量、驳回原因等业务事实，不放独立教学说明。说明使用相邻标题的 Uten 提示 icon。`key` 可保留原业务节点的测试与访问锚点。

## 本次迁移清单

| 调用方 | 公共入口 | 保留的业务差异 |
|---|---|---|
| 委外订货明细全链进度 | `SubcontractOrderProgressSection` → `UtenWorkflowProgress` | 节点顺序、已领数量、供应来源及 done/active/pending/skipped 均由原服务端权威提供，原 key 与横向滚动保留；删除重复 `_nodeChip` |
| 费用/出差报销新建页 | `ExpenseApprovalProgress.preview` | 仅流程预览，填报为当前节点，不能表示已发生审批 |
| 报销申请人详情、审批详情 | `ExpenseApprovalProgress` | 当前节点取 `approvalStage`；已完成只取当前轮阶段事件；驳回取本轮事件节点；撤回重填和重提不沿用旧轮完成状态 |
| 通用申请详情 | `BusinessApplicationProgress` | 按出差、付款、预付、供应商付款的不同流程、轮次及付款撤销事实投影 |

旧已批准报销如果没有分级事件，只显示原审批事实和实际付款状态，不补造部门/初核/复核/总经办签字。未来阶段到达不自动证明前级已有签字记录。原真实流转记录继续保留。

## 验证入口

`expense_approval_progress_test.dart` 覆盖当前轮、驳回节点、撤回草稿、旧审批历史及 320 宽/1.8 字号换行；既有 `subcontract_order_progress_timeline_test.dart`、`subcontract_order_progress_visibility_test.dart` 继续验证委外阶段、领料数量和权限差异。通用申请进度另有本轮与付款撤销回归。

Web 与 Flutter 桌面共享组件；WPF 对应业务仍是未迁移候选，不因公共 Flutter 组件落地而宣称已支持。
