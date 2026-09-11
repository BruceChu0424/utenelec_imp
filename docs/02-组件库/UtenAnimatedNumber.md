# UtenAnimatedNumber（数字滚动文本）

> **组件状态**：🟡 2026-09-10 重新引入（analyze 0 issue，widget 测试
> [`test/components/data_display/uten_animated_number_test.dart`](../../test/components/data_display/uten_animated_number_test.dart) 6 例）。
> **源码**：[`lib/components/data_display/uten_animated_number.dart`](../../lib/components/data_display/uten_animated_number.dart)
>
> 同名组件曾于 2026-07-30 作为零调用死码删除（见[组件总览](组件总览.md) §五）。
> 本次随[服务器状态页](../03-页面/服务器状态页.md)圆环仪表落地，有真实调用方、
> 降级路径与测试，不是「先建组件再找用途」。

## 用途

数值变化时从旧值一次性滚动到新值，用于 15 秒刷新一次的监控数字、KPI 大数字等
「同一个数字反复更新」的场景。列表单元格、表格数字、金额明细不要用——
逐格滚动只会让人读不准。

## 行为约定

- **一次性过渡，不是循环跳动**：只在 `value` 变更时跑一次 `TweenAnimationBuilder`；
  没有常驻 ticker，符合 07-性能自适应 §七「禁止无意义的无限循环动画」。
- `value` 为 null 显示 `placeholder`（默认 `—`）；**不用 0 填空**。
  从 null 切回数值时直接显示终值，不从 0 滚上去。
- 数字统一 `FontFeature.tabularFigures()`，滚动过程中宽度不抖。
- 格式化默认「整数不带小数、其余保留 1 位」，可用 `format` 覆盖（如 `'1234.50 ms'`）。

| 档位 / 环境 | 行为 |
|---|---|
| rich（`tier.enableNumberAnimation`） | 滚动 `duration × durationFactor`（默认 `UtenAnim.slow`） |
| standard / lite | 直接显示终值 |
| 系统「减少动画」、`TickerMode` 关闭 | 直接显示终值 |

## API

```dart
UtenAnimatedNumber(
  value: 42.5,                        // null → placeholder
  format: (v) => v.toStringAsFixed(1),// 可选
  placeholder: '—',
  style: theme.textTheme.headlineMedium,
  duration: UtenAnim.slow,
  curve: UtenAnim.standard,
)
```

## 当前接入点

- [`UtenGaugeRing`](UtenGaugeRing.md) 的环心数字。
- [服务器状态页](../03-页面/服务器状态页.md)数据库响应耗时、在线会话等大数字卡。
