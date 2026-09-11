# UtenGaugeRing（270° 圆环仪表）

> **组件状态**：🟡 2026-09-10 新增（analyze 0 issue，widget 测试
> [`test/components/data_display/uten_gauge_ring_test.dart`](../../test/components/data_display/uten_gauge_ring_test.dart) 11 例）。
> **源码**：[`lib/components/data_display/uten_gauge_ring.dart`](../../lib/components/data_display/uten_gauge_ring.dart)

## 用途

把「当前值 / 阈值」这类监控数字画成一眼可读的圆环：占用率、连接数、积压条数、
备份已过小时数等。目前唯一接入点是[服务器状态页](../03-页面/服务器状态页.md)，
其它页面若有同类「值 + 黄红阈值」指标可直接复用，不要私造圆形进度条。

**不是进度条**：加载/保存进度仍用 `CircularProgressIndicator`；
本组件表达的是一个已经采集到的量值，不表示「还要等多久」。

## 视觉与交互约定

- 270°（起点 135°）圆弧，圆头；轨道 `colorScheme.surfaceContainerHighest`。
- 进度色 = 语义状态色（与 `UtenStatusBadge`、服务器状态页 `_statusColor` 同源
  token）：normal→success、warning→warning、critical→error，深浅色各一套。
- `unknown` 不画实心弧，改画一圈虚线轨道并用 `outlineVariant`，中心显示 `—`；
  **读不到的值永远不画成 0，也不保留上一次的绿色**。
- 预警/告警阈值在环外画短刻度；阈值为空或超出满量程时不画，不编造刻度位置。
- 中心：`headlineMedium` + `tabularFigures` 数字（走 `UtenAnimatedNumber`）+ 单位小字；
  超大字号时中心整体 `FittedBox(scaleDown)`，不截断也不溢出。
- 尺寸 = `min(父约束宽, (size ?? 140) × 字号倍率.clamp(1, 1.6))`，正方形。
  内部用 `ConstrainedBox + AspectRatio` 而不是 `LayoutBuilder`——`LayoutBuilder`
  不支持 intrinsic 测量，会让外层等高卡片行（`IntrinsicHeight`）直接抛断言。
- 无障碍：整环是一个语义节点，朗读「标签 值单位，状态」，内部文字 `excludeSemantics`。

## 性能档行为（07-性能自适应 §七）

| 档位 / 环境 | 弧线过渡 |
|---|---|
| rich / standard | `UtenAnim.slow × durationFactor` 一次性过渡到新值 |
| lite | `Duration.zero`，直接跳到新值 |
| 系统「减少动画」`MediaQuery.disableAnimations` | 同 lite |
| `TickerMode` 关闭（保活页离屏、`Offstage`） | 同 lite，不排帧 |

值不变不重绘：`shouldRepaint` 只比较 fraction 与各颜色；非循环动画，没有常驻 ticker。

## API

```dart
UtenGaugeRing(
  value: 85,                        // null = 读不到，显示占位符与虚线环
  status: UtenGaugeStatus.warning,  // normal / warning / critical / unknown
  label: '系统内存',                 // 只进无障碍朗读，不画在环里
  unit: '%',                        // 默认 '%'，空字符串则不显示单位
  max: 100,                         // 满环对应值，≤0 按 100
  warning: 80, critical: 90,        // 环外刻度，可空
  statusText: '留意',                // 朗读用状态词，可空
  valueText: null,                  // 覆盖中心文本（如字节格式化），给定后不滚动
  caption: '12 / 100',              // 环下方小字，可空
  size: 140,                        // 期望直径
  placeholder: '—',
)
```

`utenGaugeStatusColor(context, status)` 对外公开，供同卡片内的大数字取同一状态色。
`UtenGaugeRingPainter` 也公开，仅为 widget 测试可断言 `fraction/progressColor`。
