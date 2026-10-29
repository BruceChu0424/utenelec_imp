// 全平台界面大小：按用户倍率布局后等比渲染，手机/平板/桌面保持同一口径。
// 默认 100%，不按宽屏或 DPR 自动放大/缩小；系统非线性 TextScaler 原样继承。
// MediaQuery 尺寸、DPR、安全区、键盘、手势区与折叠屏特征同步转成画布坐标。
// Transform 之下 globalPosition/localToGlobal(无 ancestor) 是窗口坐标；Overlay
// Positioned 是画布坐标。浮层使用 LayerLink、ancestor 或 globalToLocal 换算。
// 滚轮只由 UtenWidgetsFlutterBinding 统一换算一次，页面不可再次补偿。
// 文档：docs/00-项目准则/04-字体与字号可调.md。

import 'dart:ui' show DisplayFeature;

import 'package:flutter/widgets.dart';

import 'display_capacity.dart';
import 'display_zoom_pointer_binding.dart';

/// 整体缩放的倍率计算(纯函数，便于单测)。
abstract final class UtenDisplayZoom {
  /// 标准档不因窗口更宽而自动放大。保留此查询供既有调用方使用。
  static double autoZoomForWidth(double windowWidth) => 1;

  /// 按窗口宽与字号档因子，拆成「整体缩放倍率」与「剩余文字缩放」。
  /// 恒有 zoom × textScale == autoZoomForWidth(windowWidth) × fontFactor。
  static UtenZoomResolution resolve({
    required double windowWidth,
    required double fontFactor,
  }) {
    assert(fontFactor > 0 && fontFactor < double.infinity);
    // 手机、平板、桌面使用同一倍率，变窄的画布由布局换行/换列处理。
    return UtenZoomResolution(zoom: fontFactor, textScale: 1);
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
/// 子树可经 [UtenDisplayScale.maybeOf] 读到本次界面倍率。
class UtenDisplayZoomBox extends StatelessWidget {
  /// 按给定因子原样缩放(不做容量钳制)。测试与需要精确倍率的场景用。
  const UtenDisplayZoomBox({
    super.key,
    required double this.fontFactor,
    required this.child,
  }) : adaptive = false,
       autoLadder = const <double>[];

  /// 应用入口用：[fontFactor] 为 null 表示「自动」(100%)；手动档原样生效。
  const UtenDisplayZoomBox.adaptive({
    super.key,
    required this.fontFactor,
    required this.autoLadder,
    required this.child,
  }) : adaptive = true;

  /// 用户字号档因子(FontScale.factor)；1 = 标准；adaptive 下 null = 自动。
  final double? fontFactor;

  /// 是否支持自动档。
  final bool adaptive;

  /// 保留调用兼容性；自动档固定 100%，不再从档位中自动缩小。
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
        final maxFactor = UtenDisplayCapacity.maxFontFactor(window: window);
        final recommended = UtenDisplayCapacity.recommendedFontFactor(
          window: window,
          devicePixelRatio: mediaQuery.devicePixelRatio,
          ladder: autoLadder.isEmpty ? const [1.0] : autoLadder,
        );
        final requested = fontFactor;
        final effective = !adaptive ? requested! : requested ?? recommended;
        final resolution = UtenDisplayZoom.resolve(
          windowWidth: window.width,
          fontFactor: effective,
        );
        final zoom = resolution.zoom;
        final canvas = Size(window.width / zoom, window.height / zoom);
        final content = UtenDisplayScale(
          window: window,
          devicePixelRatio: mediaQuery.devicePixelRatio,
          requestedFontFactor: requested,
          effectiveFontFactor: effective,
          maxFontFactor: maxFactor,
          recommendedFontFactor: recommended,
          fontZoom: zoom,
          child: MediaQuery(
            data: mediaQuery.copyWith(
              size: canvas,
              // 画布上 1 逻辑像素对应 zoom 个窗口逻辑像素：图片按更高 DPR 解码才清晰。
              devicePixelRatio: mediaQuery.devicePixelRatio * zoom,
              padding: mediaQuery.padding / zoom,
              viewPadding: mediaQuery.viewPadding / zoom,
              viewInsets: mediaQuery.viewInsets / zoom,
              systemGestureInsets: mediaQuery.systemGestureInsets / zoom,
              displayFeatures: [
                for (final feature in mediaQuery.displayFeatures)
                  DisplayFeature(
                    bounds: Rect.fromLTRB(
                      feature.bounds.left / zoom,
                      feature.bounds.top / zoom,
                      feature.bounds.right / zoom,
                      feature.bounds.bottom / zoom,
                    ),
                    type: feature.type,
                    state: feature.state,
                  ),
              ],
              // 保留系统非线性曲线，不从单个字号重建线性倍率。
              textScaler: mediaQuery.textScaler,
            ),
            child: child,
          ),
        );
        // Keep the same ancestors at 100% as at other factors. Reparenting the
        // routed Navigator during layout would also move its active overlays
        // and can discard editor focus when crossing the standard factor.
        return OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: canvas.width,
          maxWidth: canvas.width,
          minHeight: canvas.height,
          maxHeight: canvas.height,
          // 外层先按窗口坐标命中，再由 Transform 逆变换到画布。若把 OverflowBox
          // 放在 Transform 内，缩小档右/下沿的逆变换坐标会超出其窗口尺寸，
          // 造成内容看得见却点不到。此处画布布局与整窗绘制仍保持同一倍率。
          child: Transform.scale(
            scale: zoom,
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: canvas.width,
              height: canvas.height,
              child: UtenDisplayZoomPointerRegion(zoom: zoom, child: content),
            ),
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

  /// 实际生效因子(自动 = 1；手动 = 用户选择)。
  final double effectiveFontFactor;

  /// 可选界面倍率上限(所有窗口为 2)。
  final double maxFontFactor;

  /// 自动档推荐因子([UtenDisplayCapacity.recommendedFontFactor])。
  final double recommendedFontFactor;

  /// 用户选择的整体界面倍率，所有屏幕口径相同。
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
