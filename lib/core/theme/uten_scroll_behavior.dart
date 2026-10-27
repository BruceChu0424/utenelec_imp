// UtenScrollBehavior - 全局滚动行为
//
// 竖向内容超出视口时常显可拖动滚动条。直接使用 Scrollable 提供的实际
// controller，独立面板不会错误借用页面 PrimaryScrollController。
// 已有显式滚动条的区域声明所有权，避免同一视口重复绘制。

import 'package:flutter/material.dart';
import '../../components/layout/uten_scroll_gutter.dart';
import '../../components/layout/uten_vertical_scrollbar.dart';
import '../../components/layout/uten_page_scrollbar_host.dart';

/// 各平台统一提供可发现、可拖动的竖向滚动条。
class UtenScrollBehavior extends MaterialScrollBehavior {
  const UtenScrollBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    if (axisDirectionToAxis(details.direction) != Axis.vertical ||
        details.controller == null ||
        UtenScrollbarOwnerScope.owns(context, details.controller!)) {
      return child;
    }
    // Material/RawScrollbar 已显式包住同一个滚动控制器时复用它。
    var explicitlyOwned = false;
    context.visitAncestorElements((element) {
      final ancestor = element.widget;
      if (ancestor is RawScrollbar &&
          identical(
            ancestor.controller ?? PrimaryScrollController.maybeOf(context),
            details.controller,
          )) {
        explicitlyOwned = true;
        return false;
      }
      return true;
    });
    if (explicitlyOwned) return child;
    // 手机同一路由的两个列表可能共享 PrimaryScrollController。滚动条只绑定
    // 当前 Scrollable 的 position，拖一个面板不会带动另一个或触发多位置断言。
    final state = context is StatefulElement ? context.state : null;
    if (state is ScrollableState) {
      return _UtenPositionScrollbar(position: state.position, child: child);
    }
    return UtenPageScrollbarSource(
      controller: details.controller!,
      debugLabel: 'automatic-vertical-viewport',
      builder: (context, localVisible) => UtenVerticalScrollbar(
        controller: details.controller!,
        visible: localVisible,
        // 只接受本视口的竖向通知，横滚/嵌套列表不得改变滑块长度。
        notificationPredicate: (notification) =>
            notification.depth == 0 &&
            notification.metrics.axis == Axis.vertical,
        child: UtenScrollGutter(child: child),
      ),
    );
  }
}

class _UtenPositionScrollbar extends StatefulWidget {
  const _UtenPositionScrollbar({required this.position, required this.child});

  final ScrollPosition position;
  final Widget child;

  @override
  State<_UtenPositionScrollbar> createState() => _UtenPositionScrollbarState();
}

class _UtenPositionScrollbarState extends State<_UtenPositionScrollbar> {
  final _controller = ScrollController(debugLabel: 'uten-scrollbar');

  @override
  void initState() {
    super.initState();
    _controller.attach(widget.position);
  }

  @override
  void didUpdateWidget(covariant _UtenPositionScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.position, widget.position)) {
      _controller.detach(oldWidget.position);
      _controller.attach(widget.position);
    }
  }

  @override
  void dispose() {
    _controller.detach(widget.position);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    bool accepts(ScrollNotification notification) =>
        notification.depth == 0 && notification.metrics.axis == Axis.vertical;
    return UtenPageScrollbarSource(
      controller: _controller,
      debugLabel: 'automatic-position-viewport',
      builder: (context, localVisible) => UtenVerticalScrollbar(
        controller: _controller,
        visible: localVisible,
        notificationPredicate: accepts,
        child: UtenScrollGutter(child: widget.child),
      ),
    );
  }
}

/// 显式覆盖层拥有的控制器。只跳过该控制器，保留内部独立列表的自动滚动条。
class UtenScrollbarOwnerScope extends StatelessWidget {
  const UtenScrollbarOwnerScope({
    super.key,
    required this.controller,
    required this.child,
  });

  final ScrollController controller;
  final Widget child;

  static bool owns(BuildContext context, ScrollController controller) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_UtenScrollbarOwner>();
    return scope != null && identical(scope.controller, controller);
  }

  @override
  Widget build(BuildContext context) => _UtenScrollbarOwner(
    controller: controller,
    // This observer bridges both ScrollNotification and ScrollMetricsNotification
    // to listeners. Custom overlay bars live beside, not inside, the viewport.
    child: ScrollNotificationObserver(child: child),
  );
}

class _UtenScrollbarOwner extends InheritedWidget {
  const _UtenScrollbarOwner({required this.controller, required super.child});

  final ScrollController controller;

  @override
  bool updateShouldNotify(_UtenScrollbarOwner oldWidget) =>
      !identical(oldWidget.controller, controller);
}
