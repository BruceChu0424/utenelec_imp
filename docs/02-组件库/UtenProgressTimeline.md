# UtenProgressTimeline（快递式进度时间线）

> **组件状态**：🟡 2026-08-19 源码候选（analyze 0 issue）。
> **源码**：[`lib/components/feedback/uten_progress_timeline.dart`](../../lib/components/feedback/uten_progress_timeline.dart)
> **数据模型**：[`lib/shared/models/progress_timeline_event.dart`](../../lib/shared/models/progress_timeline_event.dart)

## 用途

像快递物流追踪一样展示一条业务链路的履约进度：每个节点 = 阶段标题 + 责任人徽章
（如「下单人：张三」「审核人：李四」）+ 发生时间 + 补充说明 + 可选单据跳转。
用于销售订单进度详情页的「履约进度」区，也是其它单据（采购/委外/生产计划等）
接入同款进度追踪的统一组件。

## 视觉与交互约定

- **最新进展永远在最上面**：数组首节点高亮（primary 描边卡 + 「最新」徽章）；
  其后历史节点按时间倒序；PENDING（未到的未来阶段）灰色虚位垫底。
- 节点状态色：DONE=深绿勾（`UtenColors.deepGreen`）、CURRENT=tertiary 转轮、
  REJECTED=error 叉、PENDING=outline 空心圈；连接线按已完成程度着色。
- 责任人徽章：`operatorLabel + operatorName`，历史缺人显示「—」；`operatorName` 使用
  实际姓名，不展示内部员工工号或账号代号；派生聚合阶段（如生产进度）无责任人，不显示徽章。
- `onOpenDoc` 非空且事件带 `docType/docId/docNo` 时，单号渲染为可点链接；
  权限判断与路由映射由调用方负责（组件不含业务路由）。
- 颜色/字号/圆角全走主题 token；深浅色模式自适应；`IntrinsicHeight` 连接线，
  任意字号档与断点下不溢出。

## API

```dart
UtenProgressTimeline(
  events: events,                    // List<ProgressTimelineEvent>，按展示顺序（最新在最上）
  onOpenDoc: (e) => _open(e),        // 可选；单号点击回调
  emptyText: '暂无进度记录',          // 可选空态文案
)
```

`ProgressTimelineEvent` 字段：`seq/code/title/operatorLabel/operatorName/occurredAt(ISO)/
state(DONE|CURRENT|PENDING|REJECTED)/detail/docType/docId/docNo`。

> 排序约定：**服务端排好展示顺序**（已发生事件时间倒序 + 无时间当前阶段置顶 +
> PENDING 垫底），本组件按数组顺序直接渲染、不做二次排序。其它模块复用时遵守同一约定。

## 当前接入点

- [销售订单进度详情页](../03-页面/销售订单进度详情页.md)「履约进度」区
  （`GET /api/sales/orders/{id}/progress-timeline`）。
- 物料分析「供给全链路进度」对话框沿用同款视觉（该页私有 `_ProgressStepTile`，
  2026-08-19 起同步带责任人、最新在上；后续如需多处复用可下沉替换为本组件）。
