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
// 滚轮 scrollDelta 不随 Transform 换算；缩放分支标记命中路径上的倍率，入口的
// UtenWidgetsFlutterBinding 在事件分发前统一换算，避免大字号让滚动距离一起放大。
//
// 坐标空间约定(写浮层/拖拽代码必读)：Transform 之下 RenderBox.localToGlobal(无 ancestor)
// 与手势事件的 globalPosition 都是**窗口坐标**(已乘 zoom)；Overlay 里 Positioned 的
// 坐标是**画布坐标**。两者混用会偏 zoom 倍。定位浮层一律走
// CompositedTransformFollower(LayerLink)，或 localToGlobal(offset, ancestor: 浮层/视口
// RenderBox)，或 overlayBox.globalToLocal(全局点)。SDK 的 ReorderableListView 拖影内部
// 就是混用的，本项目改用 Draggable 版 UtenDragReorderList。
//
// 字号档按屏幕容量钳制与自动推荐(2026-09-24)：应用入口用 [UtenDisplayZoomBox.adaptive]，
// 规则在 display_capacity.dart；生效结果经 [UtenDisplayScale] 发布给设置页、外壳与内容容器。
//
// 手机(窗口宽 < [UtenDisplayZoom.minCanvasWidth])不整体缩放：画布本就窄，再压会进入更
// 窄的布局；字号档沿用只放大文字的老口径。平板等中间宽度：整体缩放不把画布压到 600 以下，
// 不够的倍率由文字缩放补足(总放大倍数恒等于 自动倍率 × 字号档因子)。

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'display_capacity.dart';
import 'display_zoom_pointer_binding.dart';

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
/// 子树可经 [UtenDisplayScale.of] 读到本次生效的字号档因子、上限与推荐值。
class UtenDisplayZoomBox extends StatelessWidget {
  /// 按给定因子原样缩放(不做容量钳制)。测试与需要精确倍率的场景用。
  const UtenDisplayZoomBox({
    super.key,
    required double this.fontFactor,
    required this.child,
  }) : adaptive = false,
       autoLadder = const <double>[];

  /// 应用入口用：[fontFactor] 为 null 表示「自动」(按屏幕推荐)；手动档超出本窗口
  /// 容量([UtenDisplayCapacity.maxFontFactor])时按上限生效，窗口变大后自动恢复。
  const UtenDisplayZoomBox.adaptive({
    super.key,
    required this.fontFactor,
    required this.autoLadder,
    required this.child,
  }) : adaptive = true;

  /// 用户字号档因子(FontScale.factor)；1 = 标准；adaptive 下 null = 自动。
  final double? fontFactor;

  /// 是否按屏幕容量钳制并支持自动档。
  final bool adaptive;

  /// 自动档从中挑推荐值的因子全集(FontScale 各档)。
  final List<double> autoLadder;

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
        // 系统无障碍文字缩放(Android 14 起非线性，取正文 14 的倍率作代表)。
        final systemTextScale = mediaQuery.textScaler.scale(14) / 14;
        final maxFactor = UtenDisplayCapacity.maxFontFactor(
          window: window,
          systemTextScale: systemTextScale,
        );
        final recommended = UtenDisplayCapacity.recommendedFontFactor(
          window: window,
          devicePixelRatio: mediaQuery.devicePixelRatio,
          ladder: autoLadder.isEmpty ? const [1.0] : autoLadder,
          systemTextScale: systemTextScale,
        );
        final requested = fontFactor;
        final effective = !adaptive
            ? requested!
            : requested == null
            ? recommended
            : math.min(requested, maxFactor);
        final resolution = UtenDisplayZoom.resolve(
          windowWidth: window.width,
          fontFactor: effective,
        );
        final zoom = resolution.zoom;
        final canvas = Size(window.width / zoom, window.height / zoom);
        // 剩余文字缩放叠在系统文字缩放之上(保留系统无障碍设置)。
        final textScaler = resolution.textScale == 1
            ? mediaQuery.textScaler
            : TextScaler.linear(
                mediaQuery.textScaler.scale(1) * resolution.textScale,
              );
        final content = UtenDisplayScale(
          window: window,
          devicePixelRatio: mediaQuery.devicePixelRatio,
          requestedFontFactor: requested,
          effectiveFontFactor: effective,
          maxFontFactor: maxFactor,
          recommendedFontFactor: recommended,
          fontZoom: zoom / UtenDisplayZoom.autoZoomForWidth(window.width),
          child: MediaQuery(
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
          ),
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
            child: UtenDisplayZoomPointerRegion(zoom: zoom, child: content),
          ),
        );
      },
    );
  }
}

/// [UtenDisplayZoomBox] 向子树发布的本次缩放信息(设置页展示上限/推荐，外壳与容器
/// 按字号档收留白、收导航)。不在缩放容器之下时 [maybeOf] 为 null，按标准档处理。
class UtenDisplayScale extends InheritedWidget {
  const UtenDisplayScale({
    super.key,
    required this.window,
    required this.devicePixelRatio,
    required this.requestedFontFactor,
    required this.effectiveFontFactor,
    required this.maxFontFactor,
    required this.recommendedFontFactor,
    required this.fontZoom,
    required super.child,
  });

  /// 窗口逻辑尺寸(整体缩放之前)。
  final Size window;

  /// 原生设备像素比(系统缩放 × 浏览器缩放，整体缩放之前)。
  final double devicePixelRatio;

  /// 用户所选因子；null = 自动。
  final double? requestedFontFactor;

  /// 实际生效因子(自动 = 推荐值；手动超上限时 = 上限)。
  final double effectiveFontFactor;

  /// 本窗口的因子上限([UtenDisplayCapacity.maxFontFactor])。
  final double maxFontFactor;

  /// 自动档推荐因子([UtenDisplayCapacity.recommendedFontFactor])。
  final double recommendedFontFactor;

  /// 整体缩放里来自字号档的那部分倍率(不含宽屏自动放大)；手机只放大文字时为 1。
  /// 页面留白、导航宽度等「不该随字号放大」的尺寸除以它，窗口上看保持不变。
  final double fontZoom;

  /// 手动档是否因窗口容量不足被压到上限。
  bool get isCapped =>
      requestedFontFactor != null && effectiveFontFactor < requestedFontFactor!;

  static UtenDisplayScale? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UtenDisplayScale>();

  /// 字号档整体放大倍率(不在缩放容器之下为 1)。
  static double fontZoomOf(BuildContext context) =>
      maybeOf(context)?.fontZoom ?? 1;

  @override
  bool updateShouldNotify(UtenDisplayScale oldWidget) =>
      window != oldWidget.window ||
      devicePixelRatio != oldWidget.devicePixelRatio ||
      requestedFontFactor != oldWidget.requestedFontFactor ||
      effectiveFontFactor != oldWidget.effectiveFontFactor ||
      maxFontFactor != oldWidget.maxFontFactor ||
      recommendedFontFactor != oldWidget.recommendedFontFactor ||
      fontZoom != oldWidget.fontZoom;
}
