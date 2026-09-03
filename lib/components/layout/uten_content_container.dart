// UtenContentContainer - 内容宽度收敛容器
// 文档：docs/00-项目准则/02-响应式与多端适配.md
//
// 解决超宽屏下内容被无限拉宽的问题：
// - 内容最大宽度钳制在 maxWidth（默认 UtenBreakpoints.maxContentWidth = 1600）
// - 居中显示，两侧留白
// - 水平 gutter 随可用宽度自适应（<600: 16 / <840: 24 / >=840: 32）
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
//   UtenContentContainer(child: 页面内容)          // 列表/工作台等宽页面
//   UtenContentContainer.narrow(child: 表单)       // 表单/详情等窄页面（maxWidth 1120）
//   UtenContentContainer.wide(child: 列表/报表)    // 数据页全宽（不钳制、靠左顶满侧栏右沿）

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/responsive/breakpoint.dart';

/// Uten 内容宽度收敛容器
///
/// 居中 + 最大宽度钳制 + 响应式水平 gutter 三合一，
/// 是页面级内容的标准外壳。
class UtenContentContainer extends StatelessWidget {
  const UtenContentContainer({
    super.key,
    required this.child,
    this.maxWidth = UtenBreakpoints.maxContentWidth,
    this.padding,
    this.center = true,
    this.selectable = true,
  });

  /// 窄内容变体：表单 / 详情页专用（maxWidth 1120）
  factory UtenContentContainer.narrow({
    Key? key,
    required Widget child,
    EdgeInsetsGeometry? padding,
    bool center = true,
    bool selectable = true,
  }) {
    return UtenContentContainer(
      key: key,
      maxWidth: narrowMaxWidth,
      padding: padding,
      center: center,
      selectable: selectable,
      child: child,
    );
  }

  /// 宽内容变体：列表 / 报表页专用（实质不钳制最大宽度、靠左顶满侧栏右沿）
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
      maxWidth: wideMaxWidth,
      padding: padding,
      center: false,
      selectable: selectable,
      child: child,
    );
  }

  /// 窄内容变体的最大宽度（表单 / 详情页）
  static const double narrowMaxWidth = 1120;

  /// 宽内容变体的最大宽度（实质不钳制：超过任何常见显示器宽度即可）
  static const double wideMaxWidth = 4000;

  /// 内容
  final Widget child;

  /// 内容最大宽度（默认 [UtenBreakpoints.maxContentWidth] = 1600）
  final double maxWidth;

  /// 额外内边距（在响应式水平 gutter 之外叠加，如垂直 padding）
  final EdgeInsetsGeometry? padding;

  /// 是否居中（false 时内容靠左，仅钳制最大宽度）
  final bool center;

  /// 是否把 child 包一层局部 SelectionArea（文字框选复制；页内有结构重建轮询的
  /// 页面传 false 退出，见类注释）。
  final bool selectable;

  /// 响应式水平 gutter：<600 取 16，<840 取 24，>=840 取 32
  static double gutterForWidth(double width) {
    if (width < UtenBreakpoints.mediumStart) return 16;
    if (width < UtenBreakpoints.expandedStart) return 24;
    return 32;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 可用宽度（父容器实际宽度）；无界宽度场景（如横向滚动内）回退到屏幕宽度
        final available = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width;
        final gutter = gutterForWidth(available);

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
