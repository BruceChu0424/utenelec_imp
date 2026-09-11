# DocStatusBadge（单据状态列徽章口径）

> 路径：`lib/components/data_display/doc_status_badge.dart`（函数 `docStatusBadgeType`）· 渲染组件：[`UtenStatusBadge`](../../lib/components/data_display/uten_status_badge.dart)
> 已接入（2026-09-10）：生产计划列表、生产日报列表、财务单据列表、销售单据列表、委外单据列表（含订货单「财务 / 执行状态」）、采购单据列表（含订货单财务态）。

## 一、解决什么

单据列表页的「状态」列此前全是纯文本（草稿 / 已审 / 红冲、等待财务审核…），而各详情页早已用 `UtenStatusBadge`——同一状态在列表与详情两种长相。本口径把**审批/阶段态**的列表列统一成语义徽章，草稿/已审/红冲一眼分色；数据层不变。

## 二、口径

| 状态码 / 场景 | `UtenStatusBadgeType` |
|---|---|
| 草稿 `0` | `neutral` |
| 已审 `1` | `success` |
| 红冲 `-1` | `danger` |
| 未知 / 空（列表显示「—」）| `neutral` |
| 采购订货单 · 等待财务审核 | `warning` |
| 采购订货单 · 财务退回 | `danger` |
| 采购订货单 · 财务已通过 | `success` |
| 采购订货单 · 待提交财务 | `neutral` |
| 委外订货单 · 等待财务审核 / 财务退回待修改 / 财务已通过 · 执行中 / 已红冲 / 草稿 · 待提交财务 | `warning` / `danger` / `success` / `danger` / `neutral` |
| 销售单据 · 已驳回、财务已驳回 | `danger` |
| 销售单据 · 已审 · 待财务确认 | `warning` |

生产/财务/销售/委外/采购共用同一状态机（各域 `kXxxStatusDraft/Approved/Reversed = 0/1/-1`），`docStatusBadgeType` 不依赖 feature 层，直接按值映射。

## 三、用法（列表页状态列）

```dart
MasterColumnDef(
  key: 'status',
  label: '状态',
  width: 100,
  value: (it) => productionStatusLabel(it.status),   // 仍保留：列宽/排序/筛选桶/无障碍
  cellBuilder: (_, it) => UtenStatusBadge(
    label: productionStatusLabel(it.status),
    type: docStatusBadgeType(it.status),
    size: UtenStatusBadgeSize.small,                 // small 档，不撑高行
  ),
),
```

要点：

- **保留 `value`**：徽章只是 `cellBuilder` 的展示层，`MasterDataTableView` 的列宽测量、排序、facet 桶与读屏都读 `value` 的纯文本；
- 复合文案（销售「已审 · 待财务确认 · 只读」、委外「财务已通过 / 执行中」）标签原样进徽章，类型按主导语义取（财务驳回 > 待确认 > 单据码）；
- **不适用**：基础资料主档「使用 / 停用」（不是审批态，保持文本）、物料分析历史/候选页的分析状态、进度类词表阶段（走 `ProductionFlowStageBadge`）。

## 四、边界

- 只是配色映射，不新增状态、不改变任何列表的数据或筛选；
- 深色模式配色由 `UtenStatusBadge` 自行处理（半透明底 + 亮档文字）。

**最后更新**：2026-09-10 · 新建（C06 F2e 推广）。
