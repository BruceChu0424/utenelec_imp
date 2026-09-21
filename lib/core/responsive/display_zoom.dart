// 整体缩放(display zoom)——把整棵界面树按倍率等比放大/缩小。
// 文档：docs/00-项目准则/02-响应式与多端适配.md §3.3.1、
//       docs/00-项目准则/04-字体与字号可调.md §一
//
// 解决两件事(2026-09-20 用户反馈)：
// 1. 宽屏观感一致：窗口逻辑宽超过基准画布 [UtenDisplayZoom.designWidth](1920)时按
//    「窗口宽 / 1920」整体放大——2560/3440 宽的显示器看到的布局与 1920 完全一样，只是
//    更大。此前内容区钳在 maxWidth 1600 居中，2560 宽的屏两侧各留 480 空白(用户口径
//    「右边只占 60% 多」)，分类工具条等固定宽度控件也显得又小又靠左。
// 2. 字号档 = 整体缩放：文字、图标、内边距、卡片尺寸一起变。此前字号档只乘进
//    textScaler，文字大了容器不跟着大，放不下就截断(用户口径「卡片也要对应变大」)。
//
// 实现：Transform.scale(zoom) + OverflowBox——子树按「窗口尺寸 / zoom」的画布布局，再整体
// 放大到窗口大小；MediaQuery 的 size / padding / viewPadding / viewInsets /
// devicePixelRatio 同步换算，页面里的断点、对话框尺寸、SafeArea 都按画布尺寸算。
// zoom == 1 时不套 Transform(手机、≤1920 宽且标准字号：零开销、零行为差异)。
//
// 坐标空间约定(写浮层/拖拽代码必读)：Transform 之下 RenderBox.localToGlobal(无 ancestor)
// 与手势事件的 globalPosition 都是**窗口坐标**(已乘 zoom)；Overlay 里 Positioned 的
// 坐标是**画布坐标**。两者混用会偏 zoom 倍。定位浮层一律走
// CompositedTransformFollower(LayerLink)，或 localToGlobal(offset, ancestor: 浮层/视口
// RenderBox)，或 overlayBox.globalToLocal(全局点)。SDK 的 ReorderableListView 拖影内部
// 就是混用的，本项目改用 Draggable 版 UtenDragReorderList。
//
// 手机(窗口宽 < [UtenDisplayZoom.minCanvasWidth])不整体缩放：画布本就窄，再压会进入更
// 窄的布局；字号档沿用只放大文字的老口径。平板等中间宽度：整体缩放不把画布压到 600 以下，
// 不够的倍率由文字缩放补足(总放大倍数恒等于 自动倍率 × 字号档因子)。

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// 整体缩放的倍率计算(纯函数，便于单测)。
abstract final class UtenDisplayZoom {
  /// 基准画布宽(逻辑像素)。窗口比它宽就整体放大到「看起来像 1920 宽」。
  /// 取 1920 = 1080p@100% 与 2K/4K 常见缩放后的主流桌面逻辑宽；≤1920 的窗口不放大，
  /// 现有布局(含内容区 1600 钳制)在这些机器上保持不变。
  static const double designWidth = 1920;

  /// 自动放大上限(3840@100% 的 4K 恰好 2.0；更宽的带鱼屏不再继续放大)。
  static const double maxAutoZoom = 2.0;

  /// 整体缩放后保留的最小画布宽：不把画布压进手机布局(compact < 600)。
  static const double minCanvasWidth = 600;

  /// 宽屏自动放大倍率：窗口宽 ≤ 基准宽为 1，否则 宽/基准 并封顶。
  static double autoZoomForWidth(double windowWidth) {
    if (windowWidth <= designWidth) return 1;
    return math.min(windowWidth / designWidth, maxAutoZoom);
  }

  /// 按窗口宽与字号档因子，拆成「整体缩放倍率」与「剩余文字缩放」。
  /// 恒有 zoom × textScale == autoZoomForWidth(windowWidth) × fontFactor。
  static UtenZoomResolution resolve({
    required double windowWidth,
    required double fontFactor,
  }) {
    final total = autoZoomForWidth(windowWidth) * fontFactor;
    if (windowWidth < minCanvasWidth) {
      // 手机：画布本就窄，整体缩放只会更窄；沿用只放大文字。
      return UtenZoomResolution(zoom: 1, textScale: total);
    }
    if (total <= 1) {
      // 缩小档(字号=小)：画布变宽，无需保底。
      return UtenZoomResolution(zoom: total, textScale: 1);
    }
    // 放大档：画布不压到 600 以下，不够的倍率给文字。
    final budget = windowWidth / minCanvasWidth;
    final zoom = math.min(total, budget);
    return UtenZoomResolution(zoom: zoom, textScale: total / zoom);
  }
}

/// [UtenDisplayZoom.resolve] 的结果：整体缩放倍率 + 剩余文字缩放。
class UtenZoomResolution {
  const UtenZoomResolution({required this.zoom, required this.textScale});

  /// 整体缩放倍率(Transform.scale 与 MediaQuery 换算用)；1 = 不缩放。
  final double zoom;

  /// 剩余文字缩放(乘进 MediaQuery.textScaler)；1 = 文字不额外缩放。
  final double textScale;

  @override
  bool operator ==(Object other) =>
      other is UtenZoomResolution &&
      other.zoom == zoom &&
      other.textScale == textScale;

  @override
  int get hashCode => Object.hash(zoom, textScale);

  @override
  String toString() => 'UtenZoomResolution(zoom: $zoom, textScale: $textScale)';
}

/// 整体缩放容器：挂在 MaterialApp.builder 最外层，包住横幅、通知宿主与路由树。
///
/// 把可用尺寸按 [UtenDisplayZoom.resolve] 拆成 zoom 与文字缩放：子树按
/// 「可用尺寸 / zoom」的画布布局并等比放大到可用尺寸；MediaQuery 同步换算成画布口径。
class UtenDisplayZoomBox extends StatelessWidget {
  const UtenDisplayZoomBox({
    super.key,
    required this.fontFactor,
    required this.child,
  });

  /// 用户字号档因子(FontScale.factor)；1 = 标准。
  final double fontFactor;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final mediaQuery = MediaQuery.of(context);
        final window = Size(
          constraints.hasBoundedWidth
              ? constraints.maxWidth
              : mediaQuery.size.width,
          constraints.hasBoundedHeight
              ? constraints.maxHeight
              : mediaQuery.size.height,
        );
        final resolution = UtenDisplayZoom.resolve(
          windowWidth: window.width,
          fontFactor: fontFactor,
        );
        final zoom = resolution.zoom;
        final canvas = Size(window.width / zoom, window.height / zoom);
        // 剩余文字缩放叠在系统文字缩放之上(保留系统无障碍设置)。
        final textScaler = resolution.textScale == 1
            ? mediaQuery.textScaler
            : TextScaler.linear(
                mediaQuery.textScaler.scale(1) * resolution.textScale,
              );
        final content = MediaQuery(
          data: mediaQuery.copyWith(
            size: canvas,
            // 画布上 1 逻辑像素对应 zoom 个窗口逻辑像素：图片按更高 DPR 解码才清晰。
            devicePixelRatio: mediaQuery.devicePixelRatio * zoom,
            padding: mediaQuery.padding / zoom,
            viewPadding: mediaQuery.viewPadding / zoom,
            viewInsets: mediaQuery.viewInsets / zoom,
            systemGestureInsets: mediaQuery.systemGestureInsets / zoom,
            textScaler: textScaler,
          ),
          child: child,
        );
        if (zoom == 1) return content;
        return Transform.scale(
          scale: zoom,
          alignment: Alignment.topLeft,
          // 子树按画布尺寸布局(OverflowBox 把窗口约束换成画布约束)，再整体放大到窗口。
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: canvas.width,
            maxWidth: canvas.width,
            minHeight: canvas.height,
            maxHeight: canvas.height,
            child: content,
          ),
        );
      },
    );
  }
}
