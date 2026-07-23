// Uten 动画 token - 统一管理时长和曲线
// 文档：docs/00-项目准则/06-动画规范.md

import 'package:flutter/animation.dart';

/// Uten 动画统一 token
///
/// 所有动画必须从这里取时长和曲线，禁止散落硬编码。
abstract final class UtenAnim {
  // ===== 时长（毫秒） =====

  /// 快速反馈（按钮点击、开关切换）
  static const Duration fast = Duration(milliseconds: 150);

  /// 标准动画（页面转场、卡片入场）
  static const Duration normal = Duration(milliseconds: 300);

  /// 慢速动画（进场强调、数字滚动）
  static const Duration slow = Duration(milliseconds: 500);

  // ===== 曲线 =====

  /// 标准曲线（大部分场景）
  static const Curve standard = Curves.easeOutCubic;

  /// 进场曲线
  static const Curve enter = Curves.easeInOut;

  /// 退场曲线
  static const Curve exit = Curves.easeIn;

  /// 弹性反馈（卡片按下）
  static const Curve bounce = Curves.easeOutBack;

  /// 列表 stagger 间隔
  static const Duration staggerInterval = Duration(milliseconds: 50);

  /// 性能档为 lite 时，时长压缩比例
  static const double liteDurationFactor = 0.5;
}
