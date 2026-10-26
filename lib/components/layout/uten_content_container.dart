// UtenContentContainer - 自适应内容容器
// 文档：docs/00-项目准则/02-响应式与多端适配.md
//
// 页面正文始终使用父容器提供的宽度，不设置固定版心：
// - 默认、narrow 和 wide 入口均不限制页面最大宽度
// - 导航收起 / 展开时，页面正文随右侧可用空间一起伸缩
// - 页面边距按可用窗口宽度取 16 / 24dp，封顶 24，不按固定比例缩小正文
// - 页面外壳已经提供 gutter 时，页面内部容器不重复叠加；与工作台使用同一正文边缘
//
// 注意：gutter 基于 LayoutBuilder 拿到的"可用宽度"（父容器实际宽度），
// 而不是屏幕宽度——桌面端被侧边栏挤窄的内容区也能正确取 gutter。
//
// 文字框选：默认把 child 包一层局部 SelectionArea（页面正文文字可拖选复制，
// 悬停自动变文本光标；手机长按弹复制工具条）。是页面级选择区的标准挂点——
// 局部而非全局，外壳轮询（徽章/通知）在选择区外，不触发框架 CME（准则 §3.4）。
// 页内自动轮询做结构重建的页面（如生产物料分析）必须传 selectable:false 退出。
//
// 用法：
//   UtenContentContainer(child: 页面内容)         // 页面正文随可用宽度伸缩
//   UtenContentContainer.narrow(child: 表单)      // 兼容历史入口，同样不限制宽度
//   UtenContentContainer.wide(child: 列表/报表)   // 全宽、靠左

import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../data_display/uten_selection_lifecycle.dart';

import '../../core/responsive/display_zoom.dart';
import '../../core/theme/uten_tokens.dart';
import 'uten_scroll_gutter.dart';
import 'uten_page_layout.dart';

/// Uten 自适应内容容器
///
/// 页面级内容的标准外壳：使用可用宽度并保留响应式水平 gutter。
class UtenContentContainer extends StatelessWidget {
  const UtenContentContainer({
    super.key,
    required this.child,
    this.maxWidth = double.infinity,
    this.padding,
    this.center = true,
    this.selectable = true,
    this.applyGutter = true,
  });

  /// 历史表单入口，保留调用兼容；与默认容器一样使用全部可用宽度。
  factory UtenContentContainer.narrow({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry? padding,
    bool center = true,
    bool selectable = true,
    bool applyGutter = true,
  }) {
    return UtenContentContainer(
      key: key,
      padding: padding,
      center: center,
      selectable: selectable,
      applyGutter: applyGutter,
      child: child,
    );
  }

  /// 宽内容变体：列表 / 报表页专用（不钳制最大宽度、靠左）
  ///
  /// 用于以表格为主的"数据页"，让表顶到导航侧栏右沿，避免超宽屏两侧大留白。
  /// 两侧保留克制的 16 / 24dp 边距，宽屏内容继续随窗口扩宽。
  factory UtenContentContainer.wide({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry? padding,
    bool selectable = true,
    bool applyGutter = true,
  }) {
    return UtenContentContainer(
      key: key,
      padding: padding,
      center: false,
      selectable: selectable,
      applyGutter: applyGutter,
      child: child,
    );
  }

  /// 内容
  final Widget child;

  /// 可选的显式上限，供认证卡等局部内容使用；页面正文默认不设上限。
  final double maxWidth;

  /// 额外内边距（在响应式水平 gutter 之外叠加，如垂直 padding）
  final EdgeInsetsGeometry? padding;

  /// 设置显式上限时是否居中（false 时内容靠左）。
  final bool center;

  /// 是否把 child 包一层局部 SelectionArea（文字框选复制；页内有结构重建轮询的
  /// 页面传 false 退出，见类注释）。
  final bool selectable;

  /// False keeps this container and its children mounted while delegating the
  /// horizontal page margins to an inner content container. Useful when the
  /// page's scroll viewport must reach the outer edge of the available area.
  final bool applyGutter;

  /// 页面水平边距：窗口中可用宽度不足 1440 时取 16，否则取 24。
  ///
  /// [fontZoom] 是字号档带来的整体放大倍率（UtenDisplayScale.fontZoom）：大字号时
  /// 档位按窗口口径选择，再换算成画布尺寸；字放大时装饰留白不额外膨胀。
  /// 极窄的局部容器最多让出单侧 10%，避免边距挤掉正文。
  static double gutterForWidth(double width, {double fontZoom = 1}) {
    assert(fontZoom > 0 && fontZoom.isFinite);
    final windowWidth = width * fontZoom;
    final base = windowWidth < 1440 ? UtenSpacing.s16 : UtenSpacing.s24;
    return math.min(base / fontZoom, math.max(0, width) * .1);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用宽度（父容器实际宽度）；无界宽度场景（如横向滚动内）回退到屏幕宽度
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final inheritedInsets = UtenContentInsetsScope.isPresentOf(context);
        final gutter = !applyGutter || inheritedInsets
            ? 0.0
            : gutterForWidth(
                available,
                fontZoom: UtenDisplayScale.fontZoomOf(context),
              );
        final page = UtenPageScrollRoleScope.isPageOf(context);
        final end = gutter > 0 && page
            ? UtenPageChromeMetrics.endOf(context)
            : gutter;

        Widget content = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(maxWidth, available)),
          child: SizedBox(
            width: double.infinity,
            // 局部 SelectionArea：页面正文文字可框选复制（准则 §3.4 局部包裹口径）。
            child: UtenContentInsetsScope(
              ownsInsets: inheritedInsets || gutter > 0,
              child: selectable ? UtenSelectionArea(child: child) : child,
            ),
          ),
        );

        if (center) {
          content = Align(alignment: Alignment.topCenter, child: content);
        }

        content = Padding(
          padding: EdgeInsets.only(left: gutter, right: end),
          child: content,
        );

        if (padding != null) {
          content = Padding(padding: padding!, child: content);
        }

        // 占满父容器宽度，保证居中生效
        return SizedBox(width: double.infinity, child: content);
      },
    );
  }
}
