// 屏幕容量——按窗口大小决定字号档「最大能放多大」与「自动档推荐多大」。
// 文档：docs/00-项目准则/04-字体与字号可调.md §一.1
//
// 背景(2026-09-24 用户反馈)：字号档是整体缩放倍率，叠在系统缩放之上。1920×1080 的
// 笔记本开 Windows 150% 后逻辑宽只有 1280，再选「超超大 1.5」画布只剩 853×440，
// 一屏只能看几行；而 4K / 5K 大屏其实还放得下更大的档。所以档位不再固定五个，而是
// 像 Windows「缩放」下拉框那样**每台机器的选项数不同**：放得下才出现。
//
// 规则(全是逻辑像素，已含系统缩放与浏览器缩放)：
// - 上限：整体缩放后的画布不小于 [comfortCanvasWidth]×[comfortCanvasHeight]——
//   再小就是表格只剩两三列、筛选栏折行、一屏不到十行。系统文字放大(无障碍)
//   原样保留，但它占用同一份预算(文字已被系统放大，应用档就少放一些)。
//   标准档(1.0)永远可用，缩小档永远可用。
// - 手机(< 600 宽)只放大文字：应用档 × 系统文字 ≤ [compactMaxTextScale]。
// - 推荐(自动档)：标准档画布够 [recommendedCanvasWidth]×[recommendedCanvasHeight]
//   就用标准；不够(系统缩放开得大、屏小)就往下找小一档，但物理尺寸
//   (因子 × 设备像素比)不低于 100% 基准——只收回被系统放大的部分，不会把字缩得比
//   一台 100% 缩放的普通显示器还小。

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'display_zoom.dart';

/// 屏幕容量计算(纯函数，便于单测)。
abstract final class UtenDisplayCapacity {
  /// 字号档上限对应的最小画布宽：再窄表格与筛选栏明显挤压。
  static const double comfortCanvasWidth = 1200;

  /// 字号档上限对应的最小画布高：再矮一屏不到十行表格。
  static const double comfortCanvasHeight = 620;

  /// 手机(只放大文字)的应用档 × 系统文字总倍率上限。
  static const double compactMaxTextScale = 1.5;

  /// 自动档希望达到的画布宽(低于它说明系统缩放把工作区压小了)。
  static const double recommendedCanvasWidth = 1360;

  /// 自动档希望达到的画布高。
  static const double recommendedCanvasHeight = 700;

  /// 自动档往下收时物理尺寸下限(因子 × 设备像素比)：不小于 100% 缩放的普通屏。
  static const double minPhysicalScale = 1.0;

  /// 该窗口下字号档因子的上限；恒 ≥ 1(标准档永远可用)。
  ///
  /// [systemTextScale] 是系统无障碍文字缩放(整体缩放之外的那部分)，占用同一份预算。
  static double maxFontFactor({
    required Size window,
    double systemTextScale = 1,
  }) {
    final system = math.max(1.0, systemTextScale);
    if (window.width < UtenDisplayZoom.minCanvasWidth) {
      return math.max(1.0, compactMaxTextScale / system);
    }
    final auto = UtenDisplayZoom.autoZoomForWidth(window.width);
    final byWidth = window.width / (auto * comfortCanvasWidth);
    final byHeight = window.height / (auto * comfortCanvasHeight);
    return math.max(1.0, math.min(byWidth, byHeight) / system);
  }

  /// 自动档的推荐因子，取自 [ladder](字号档因子全集，任意顺序)。
  ///
  /// [devicePixelRatio] 取整体缩放之前的原生设备像素比(系统缩放 × 浏览器缩放)。
  static double recommendedFontFactor({
    required Size window,
    required double devicePixelRatio,
    required Iterable<double> ladder,
    double systemTextScale = 1,
  }) {
    if (window.width < UtenDisplayZoom.minCanvasWidth) return 1;
    final system = math.max(1.0, systemTextScale);
    final auto = UtenDisplayZoom.autoZoomForWidth(window.width);
    bool fits(double factor) {
      final total = auto * factor * system;
      return window.width / total >= recommendedCanvasWidth &&
          window.height / total >= recommendedCanvasHeight;
    }

    final candidates = ladder.where((f) => f <= 1).toList()
      ..sort((a, b) => b.compareTo(a));
    var best = 1.0;
    for (final factor in candidates) {
      // 标准档不受物理下限约束；更小的档只收回被系统放大的部分。
      if (factor < 1 && factor * devicePixelRatio < minPhysicalScale) break;
      best = factor;
      if (fits(factor)) break;
    }
    return best;
  }
}
