// UtenContentContainer - 自适应内容容器
// 文档：docs/00-项目准则/02-响应式与多端适配.md
//
// 页面正文始终使用父容器提供的宽度，不设置固定版心：
// - 默认、narrow 和 wide 入口均不限制页面最大宽度
// - 导航收起 / 展开时，页面正文随右侧可用空间一起伸缩
// - 水平 gutter 随可用宽度自适应（<600: 16 / <840: 24 / >=840: 32）；大字号按倍率反向收
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

import '../../core/responsive/breakpoint.dart';
import '../../core/responsive/display_zoom.dart';

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
  });

  /// 历史表单入口，保留调用兼容；与默认容器一样使用全部可用宽度。
  factory UtenContentContainer.narrow({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry? padding,
    bool center = true,
    bool selectable = true,
  }) {
    return UtenContentContainer(
      key: key,
      padding: padding,
      center: center,
      selectable: selectable,
      child: child,
    );
  }

  /// 宽内容变体：列表 / 报表页专用（不钳制最大宽度、靠左）
  ///
  /// 用于以表格为主的"数据页"，让表顶到导航侧栏右沿，避免超宽屏两侧大留白。
  /// 仍保留响应式水平 gutter（<600:16 / <840:24 / >=840:32）。
  factory UtenContentContainer.wide({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry? padding,
    bool selectable = true,
  }) {
    return UtenContentContainer(
      key: key,
      padding: padding,
      center: false,
      selectable: selectable,
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

  /// 响应式水平 gutter：<600 取 16，<840 取 24，>=840 取 32。
  ///
  /// [fontZoom] 是字号档带来的整体放大倍率（UtenDisplayScale.fontZoom）：大字号时
  /// gutter 按倍率反向收（最小 12），窗口上看留白基本不变——字放大、留白不跟着放大，
  /// 把宽度让给内容（2026-09-24，docs/00-项目准则/04-字体与字号可调.md §一.2）。
  static double gutterForWidth(double width, {double fontZoom = 1}) {
    final base = width < UtenBreakpoints.mediumStart
        ? 16.0
        : width < UtenBreakpoints.expandedStart
        ? 24.0
        : 32.0;
    if (fontZoom <= 1) return base;
    return math.max(12.0, (base / fontZoom).roundToDouble());
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用宽度（父容器实际宽度）；无界宽度场景（如横向滚动内）回退到屏幕宽度
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final gutter = gutterForWidth(
          available,
          fontZoom: UtenDisplayScale.fontZoomOf(context),
        );

        Widget content = ConstrainedBox(
          constraints: BoxConstraints(maxWidth: math.min(maxWidth, available)),
          child: SizedBox(
            width: double.infinity,
            // 局部 SelectionArea：页面正文文字可框选复制（准则 §3.4 局部包裹口径）。
            child: selectable ? SelectionArea(child: child) : child,
          ),
        );

        if (center) {
          content = Align(alignment: Alignment.topCenter, child: content);
        }

        content = Padding(
          padding: EdgeInsets.symmetric(horizontal: gutter),
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
