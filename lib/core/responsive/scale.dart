// 等比缩放扩展：让图标 size / 固定间距与"字号档"一起放大缩小。
// 背景：MediaQuery.textScaler 只放大 Text，不放大 Icon(size:)。
// 用 context.scaled(基准值) 取代写死的 size，保证字号=超大时图标也等比变大。
// 文档：docs/00-项目准则/04-字体与字号可调.md
import 'package:flutter/material.dart';

extension ScaledSizeContext on BuildContext {
  /// 当前生效的文本缩放系数（系统设置 × 用户字号档）。1.0 = 标准。
  double get textScaleFactor => MediaQuery.textScalerOf(this).scale(1.0);

  /// 按当前缩放系数等比放大一个基准尺寸。
  /// 用于图标 size、固定间距等需要与文字一起缩放的数值。
  ///
  /// 例：`Icon(Icons.x, size: context.scaled(24))`
  double scaled(num base) => base * textScaleFactor;
}
