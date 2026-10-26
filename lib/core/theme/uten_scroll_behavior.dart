// UtenScrollBehavior - 全局滚动行为
//
// 竖向内容超出视口时常显可拖动滚动条。直接使用 Scrollable 提供的实际
// controller，独立面板不会错误借用页面 PrimaryScrollController。
// 已有显式滚动条的区域声明所有权，避免同一视口重复绘制。

import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart' show CupertinoScrollbar;
import 'package:flutter/services.dart';

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
    return Scrollbar(
      controller: details.controller,
      thumbVisibility: true,
      interactive: true,
      // 只接受本视口的竖向通知，横滚/嵌套列表不得改变滑块长度。
      notificationPredicate: (notification) =>
          notification.depth == 0 && notification.metrics.axis == Axis.vertical,
      child: child,
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
  Set<LogicalKeyboardKey> _axisModifiers = const {};
  bool _axisModifierPressed = false;

  @override
  void initState() {
    super.initState();
    _controller.attach(widget.position);
    HardwareKeyboard.instance.addHandler(_handleKey);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _axisModifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    _axisModifierPressed = _hasAxisModifier;
  }

  bool get _hasAxisModifier =>
      HardwareKeyboard.instance.logicalKeysPressed.any(_axisModifiers.contains);

  bool _handleKey(KeyEvent _) {
    final pressed = _hasAxisModifier;
    if (pressed != _axisModifierPressed) {
      setState(() => _axisModifierPressed = pressed);
    }
    return false;
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
    HardwareKeyboard.instance.removeHandler(_handleKey);
    _controller.detach(widget.position);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The SDK scrollbar's own wheel handler does not apply axis modifiers.
    // While Shift (or the configured modifier) is held, make its painter pass
    // input through to the original Scrollable, which owns the native policy.
    // Trackpads retain their native axes there too; no delta is transformed here.
    final interactive = !_axisModifierPressed;
    bool accepts(ScrollNotification notification) =>
        notification.depth == 0 && notification.metrics.axis == Axis.vertical;
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      // Material Scrollbar's Cupertino adaptation discards `interactive`.
      // Keep a stable standard RawScrollbar on iOS so modifier changes never
      // replace the business subtree or lose an editor's focus.
      final theme = ScrollbarTheme.of(context);
      return RawScrollbar(
        controller: _controller,
        thumbVisibility: true,
        interactive: interactive,
        thumbColor:
            theme.thumbColor?.resolve(const {}) ??
            Theme.of(
              context,
            ).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
        thickness:
            theme.thickness?.resolve(const {}) ??
            CupertinoScrollbar.defaultThickness,
        radius: theme.radius ?? CupertinoScrollbar.defaultRadius,
        notificationPredicate: accepts,
        child: widget.child,
      );
    }
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      interactive: interactive,
      notificationPredicate: accepts,
      child: widget.child,
    );
  }
}

/// 显式覆盖层拥有的控制器。只跳过该控制器，保留内部独立列表的自动滚动条。
class UtenScrollbarOwnerScope extends InheritedWidget {
  const UtenScrollbarOwnerScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final ScrollController controller;

  static bool owns(BuildContext context, ScrollController controller) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<UtenScrollbarOwnerScope>();
    return scope != null && identical(scope.controller, controller);
  }

  @override
  bool updateShouldNotify(UtenScrollbarOwnerScope oldWidget) =>
      !identical(oldWidget.controller, controller);
}
