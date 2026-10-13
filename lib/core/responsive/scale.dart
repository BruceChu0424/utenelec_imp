// 等比缩放扩展：让图标 size / 固定间距与"文字缩放"一起放大缩小。
// 背景：MediaQuery.textScaler 只放大 Text，不放大 Icon(size:)。
// 用 context.scaled(基准值) 取代写死的 size，保证文字放大时图标也等比变大。
//
// 应用界面倍率在所有屏幕经整体缩放生效，不在这里再乘。
// 系统 TextScaler 独立继承；用正文 14 的倍率让邻近图标跟随无障碍设置，
// 避免把非线性策略的 scale(1) 当成所有字号的比例。
// 文档：docs/00-项目准则/04-字体与字号可调.md
import 'package:flutter/material.dart';

extension ScaledSizeContext on BuildContext {
  /// 系统正文 14 的缩放比例，不包含应用整体界面倍率。
  double get textScaleFactor => MediaQuery.textScalerOf(this).scale(14) / 14;

  /// 按当前缩放系数等比放大一个基准尺寸。
  /// 用于图标 size、固定间距等需要与文字一起缩放的数值。
  ///
  /// 例：`Icon(Icons.x, size: context.scaled(24))`
  double scaled(num base) => base * textScaleFactor;
}
