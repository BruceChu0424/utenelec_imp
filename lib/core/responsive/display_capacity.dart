// 界面大小的可选范围。窗口容量由响应式布局处理，不降低用户选择。
import 'package:flutter/widgets.dart';

abstract final class UtenDisplayCapacity {
  static const double maxManualFactor = 2;

  /// 所有窗口都可选到 200%；系统字号不占用应用缩放的预算。
  static double maxFontFactor({
    required Size window,
    double systemTextScale = 1,
  }) => maxManualFactor;

  /// 自动档沿用系统基线，不按窗口/DPR抵消系统显示或无障碍设置。
  static double recommendedFontFactor({
    required Size window,
    required double devicePixelRatio,
    required Iterable<double> ladder,
    double systemTextScale = 1,
  }) => 1;
}
