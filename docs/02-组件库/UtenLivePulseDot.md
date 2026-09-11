# UtenLivePulseDot（采样脉冲点）

> **组件状态**：🟡 2026-09-10 新增（analyze 0 issue，widget 测试
> [`test/components/feedback/uten_live_pulse_dot_test.dart`](../../test/components/feedback/uten_live_pulse_dot_test.dart) 7 例）。
> **源码**：[`lib/components/feedback/uten_live_pulse_dot.dart`](../../lib/components/feedback/uten_live_pulse_dot.dart)

## 用途

一个 8px 圆点，表示「这块数据还在按周期更新」。每次**采样成功**扩散一圈光晕，
数据过期后变灰不再脉冲。用于轮询型只读页面（当前：[服务器状态页](../03-页面/服务器状态页.md)
总览卡标题右侧）。

**不是加载指示器**：请求进行中仍用 `CircularProgressIndicator`；本组件只在
「拿到新数据」的那一刻响应一次，不表示忙碌。

## 行为约定

- 脉冲由调用方的**计数器**驱动（`pulse`），不自己起 Timer 造节拍：
  `pulse` 变化才播一次，首帧不播，普通重建不播。
- 一次脉冲 = `UtenAnim.normal` 的 scale 1→2.2 + 透明度衰减，非循环动画。
- `stale: true`（数据已过期）→ 圆点变 `colorScheme.outline` 灰色且不再脉冲，
  不能继续用「在线色」误导用户。
- lite 档、系统「减少动画」、`TickerMode` 关闭 → 永远只画静态圆点。
- 默认是装饰元素（`ExcludeSemantics`）；给 `semanticsLabel` 才进语义树。

## API

```dart
UtenLivePulseDot(
  pulse: _successfulSamples,   // 采样成功次数；+1 播一次
  stale: !_fresh,              // 过期 → 灰且静止
  color: _statusColor(...),    // 默认 colorScheme.primary
  staleColor: null,            // 默认 colorScheme.outline
  size: 8,
  semanticsLabel: null,
)
```
