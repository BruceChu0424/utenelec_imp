import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/platform/desktop_window.dart';
import '../../components/buttons/uten_close_button.dart';

/// Keep native controls outside display zoom and keep the routed subtree in
/// the same slot while changing modes, preserving focus and form controllers.
class DesktopWindowHost extends ConsumerStatefulWidget {
  static const controlsHeight = 36.0;

  const DesktopWindowHost({
    super.key,
    required this.mode,
    required this.child,
    this.overlayControls = false,
  });

  final DesktopWindowMode mode;
  final Widget child;

  /// Full-bleed login art handles its own safe scroll viewport. Other pages,
  /// including forced password changes, reserve a native-sized control strip.
  final bool overlayControls;

  @override
  ConsumerState<DesktopWindowHost> createState() => _DesktopWindowHostState();
}

class _DesktopWindowHostState extends ConsumerState<DesktopWindowHost> {
  late DesktopWindowController _controller;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(desktopWindowControllerProvider);
    unawaited(_controller.setMode(widget.mode));
  }

  @override
  void didUpdateWidget(DesktopWindowHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mode != widget.mode) {
      unawaited(_controller.setMode(widget.mode));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_controller.enabled) return widget.child;
    final login = widget.mode == DesktopWindowMode.login;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      // Header surfaces extend above the route Navigator into this window-sized
      // overlay. Native controls expose stable semantics without tooltips.
      child: Overlay.wrap(
        child: _DesktopWindowHeaderScope(
          enabled: !login,
          child: Stack(
            children: [
              Positioned.fill(
                top: login && widget.overlayControls
                    ? 0
                    : DesktopWindowHost.controlsHeight,
                child: widget.child,
              ),
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                height: DesktopWindowHost.controlsHeight,
                child: _DesktopWindowControls(
                  controller: _controller,
                  canMaximize: !login,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DesktopWindowHeaderScope extends InheritedWidget {
  const _DesktopWindowHeaderScope({
    required this.enabled,
    required super.child,
  });

  final bool enabled;

  @override
  bool updateShouldNotify(_DesktopWindowHeaderScope oldWidget) =>
      enabled != oldWidget.enabled;
}

/// Extends a navigation surface into the native control strip without moving
/// its content or covering controls. The host belongs above the root Navigator.
/// Actual layout geometry keeps the surface aligned through rail animation,
/// window resizing and personal display zoom; no second width rule is needed.
class DesktopWindowHeaderSurface extends StatefulWidget {
  const DesktopWindowHeaderSurface({
    super.key,
    required this.decoration,
    required this.child,
  });

  final BoxDecoration decoration;
  final Widget child;

  @override
  State<DesktopWindowHeaderSurface> createState() =>
      _DesktopWindowHeaderSurfaceState();
}

class _DesktopWindowHeaderSurfaceState
    extends State<DesktopWindowHeaderSurface> {
  final _portal = OverlayPortalController()..show();

  @override
  Widget build(BuildContext context) {
    final surface = DecoratedBox(
      decoration: widget.decoration,
      child: widget.child,
    );
    final scope = context
        .dependOnInheritedWidgetOfExactType<_DesktopWindowHeaderScope>();
    if (scope == null) return surface;
    // Navigator disables tickers for maintained routes behind an opaque page.
    // Their rail stays mounted, but must not leave a surface in the root overlay.
    final visible = scope.enabled && TickerMode.valuesOf(context).enabled;
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context, info) {
        if (!visible) return const SizedBox.shrink();
        final bounds = MatrixUtils.transformRect(
          info.childPaintTransform,
          Offset.zero & info.childSize,
        );
        return Positioned(
          key: const Key('desktop-window-header-surface'),
          top: 0,
          left: bounds.left,
          width: bounds.width,
          height: DesktopWindowHost.controlsHeight,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: DecoratedBox(decoration: widget.decoration),
            ),
          ),
        );
      },
      child: surface,
    );
  }
}

class _DesktopWindowControls extends StatelessWidget {
  const _DesktopWindowControls({
    required this.controller,
    required this.canMaximize,
  });

  final DesktopWindowController controller;
  final bool canMaximize;

  @override
  Widget build(BuildContext context) {
    final controls = ValueListenableBuilder<bool>(
      valueListenable: controller.maximized,
      builder: (context, maximized, _) => UtenWindowControls(
        closeButtonKey: const Key('desktop-window-close'),
        minimizeButtonKey: const Key('desktop-window-minimize'),
        expandButtonKey: const Key('desktop-window-maximize'),
        native: true,
        expanded: maximized,
        showMinimize: true,
        showExpand: canMaximize,
        onClose: () => unawaited(controller.close()),
        onMinimize: () => unawaited(controller.minimize()),
        onExpand: () => unawaited(controller.toggleMaximize()),
      ),
    );
    final dragArea = Expanded(
      child: GestureDetector(
        key: const Key('desktop-window-drag'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => unawaited(controller.beginDrag()),
        onDoubleTap: canMaximize
            ? () => unawaited(controller.toggleMaximize())
            : null,
        child: const SizedBox.expand(),
      ),
    );
    return Material(
      color: Colors.transparent,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          textDirection: TextDirection.ltr,
          children: [dragArea, controls],
        ),
      ),
    );
  }
}
