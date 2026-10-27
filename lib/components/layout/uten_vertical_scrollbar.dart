import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_scrollbar_style.dart';
import '../feedback/uten_motion.dart';
import 'uten_scrollbar_arrow_buttons.dart';
import 'uten_scrollbar_rail_delegate.dart';

/// A visible capsule thumb inside a fixed, separate vertical track. The SDK
/// owns scrolling/dragging and paints neither thumb nor track without overflow.
/// Callers reserve the existing trailing lane with UtenScrollGutter.
class UtenVerticalScrollbar extends StatefulWidget {
  const UtenVerticalScrollbar({
    super.key,
    required this.controller,
    required this.child,
    this.thumbVisibility = true,
    this.interactive = true,
    this.visible = true,
    this.notificationPredicate,
  });

  final ScrollController controller;
  final Widget child;
  final bool thumbVisibility;
  final bool interactive;

  /// A page host can take over painting without replacing this scroll subtree.
  final bool visible;
  final ScrollNotificationPredicate? notificationPredicate;

  @override
  State<UtenVerticalScrollbar> createState() => _UtenVerticalScrollbarState();
}

class _UtenVerticalScrollbarState extends State<UtenVerticalScrollbar> {
  bool _hovered = false;
  bool _pressed = false;
  bool _overflow = false;
  bool _metricsCheckScheduled = false;
  double _viewportExtent = 0;
  Set<LogicalKeyboardKey> _axisModifiers = const {};
  bool _axisModifierPressed = false;

  double get _currentViewportExtent =>
      widget.controller.positions.length == 1 &&
          widget.controller.position.hasViewportDimension
      ? widget.controller.position.viewportDimension
      : 0;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_handleKey);
    _scheduleMetricsCheck();
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
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleKey);
    super.dispose();
  }

  bool get _hasOverflow {
    if (widget.controller.positions.length != 1) return false;
    final position = widget.controller.position;
    return position.hasContentDimensions &&
        position.axis == Axis.vertical &&
        position.maxScrollExtent.isFinite &&
        position.minScrollExtent.isFinite &&
        position.maxScrollExtent > position.minScrollExtent;
  }

  void _scheduleMetricsCheck() {
    if (_metricsCheckScheduled) return;
    _metricsCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _metricsCheckScheduled = false;
      if (mounted &&
          (_overflow != _hasOverflow ||
              _viewportExtent != _currentViewportExtent)) {
        setState(() {
          _overflow = _hasOverflow;
          _viewportExtent = _currentViewportExtent;
        });
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _inLane(PointerEvent event) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return false;
    final local = event.localPosition;
    return local.dx >= box.size.width - UtenScrollbarStyle.laneWidth &&
        local.dx <= box.size.width &&
        local.dy >= 0 &&
        local.dy <= box.size.height;
  }

  void _hover(PointerEvent event) {
    final hovered = widget.visible && _inLane(event);
    if (hovered != _hovered) setState(() => _hovered = hovered);
  }

  void _release(PointerEvent event) {
    // Pointer-up/cancel can follow the cached down-event route after unmount.
    if (!mounted || !_pressed) return;
    setState(() {
      _pressed = false;
      _hovered = _inLane(event);
    });
  }

  void _wheel(PointerSignalEvent event) {
    if (!widget.visible || !widget.interactive || !_inLane(event)) return;
    final position = UtenScrollbarRailTarget.resolve(
      controller: widget.controller,
    );
    if (position == null) return;
    position.handlePointerSignal(
      context,
      event,
      isCurrent: () =>
          mounted &&
          identical(
            position.identity,
            UtenScrollbarRailTarget.resolve(
              controller: widget.controller,
            )?.identity,
          ),
    );
  }

  @override
  void didUpdateWidget(covariant UtenVerticalScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        !widget.interactive ||
        !widget.visible) {
      _pressed = false;
    }
    if (!widget.visible) _hovered = false;
    if (oldWidget.controller != widget.controller) _scheduleMetricsCheck();
  }

  @override
  Widget build(BuildContext context) {
    final originalTheme = ScrollbarTheme.of(context);
    final platform = Theme.of(context).platform;
    final brightness = Theme.of(context).brightness;
    bool accepts(ScrollNotification notification) =>
        widget.notificationPredicate?.call(notification) ??
        (notification.depth == 0 && notification.metrics.axis == Axis.vertical);

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        if (notification.metrics.axis == Axis.vertical &&
            (_overflow != _hasOverflow ||
                _viewportExtent != _currentViewportExtent)) {
          _scheduleMetricsCheck();
        }
        return false;
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerSignal: _wheel,
        onPointerDown: (event) {
          if (widget.visible && widget.interactive && _inLane(event)) {
            setState(() => _pressed = true);
          }
        },
        onPointerUp: _release,
        onPointerCancel: _release,
        child: MouseRegion(
          opaque: false,
          onEnter: _hover,
          onHover: _hover,
          onExit: (_) {
            if (_hovered) setState(() => _hovered = false);
          },
          child: UtenMotion(
            duration: UtenScrollbarStyle.hoverDuration,
            builder: (context, duration) => TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: _hovered || _pressed ? 1 : 0),
              duration: duration,
              curve: UtenScrollbarStyle.hoverCurve,
              // Restore the inherited theme below the scrollbar itself. Nested
              // horizontal bars and dropdown menus must not inherit this style.
              child: ScrollbarTheme(data: originalTheme, child: widget.child),
              builder: (context, emphasis, child) {
                final visual = UtenScrollbarStyle.visuals(
                  brightness,
                  emphasis: emphasis,
                  dragging: _pressed,
                );
                final arrowExtent = _viewportExtent > 0
                    ? UtenScrollbarStyle.arrowExtentForTrack(_viewportExtent)
                    : UtenScrollbarStyle.arrowExtent;
                final railVisible =
                    widget.visible && widget.thumbVisibility && _overflow;
                final surface = Stack(
                  // A single-child viewport may shrink to its child's intrinsic
                  // width under loose constraints. Keep the caller's original
                  // tight viewport bounds for both content and SDK painting.
                  fit: StackFit.passthrough,
                  children: [
                    child!,
                    if (railVisible)
                      Positioned(
                        top: 0,
                        right: 0,
                        bottom: 0,
                        width: UtenScrollbarStyle.laneWidth,
                        child: IgnorePointer(
                          child: ClipRect(
                            child: CustomPaint(
                              painter: UtenScrollbarTrackPainter(visual),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
                late final Widget sdkScrollbar;
                if (platform == TargetPlatform.iOS) {
                  // Material Scrollbar's Cupertino adaptation discards
                  // interactive. Keep RawScrollbar to preserve Shift pass-through.
                  sdkScrollbar = RawScrollbar(
                    controller: widget.controller,
                    thumbVisibility: widget.visible && widget.thumbVisibility,
                    trackVisibility: false,
                    interactive:
                        widget.visible &&
                        widget.interactive &&
                        !_axisModifierPressed,
                    notificationPredicate: accepts,
                    thumbColor: widget.visible
                        ? visual.thumbColor
                        : Colors.transparent,
                    trackColor: visual.trackColor,
                    trackBorderColor: visual.borderColor,
                    thickness: visual.thickness,
                    radius: Radius.circular(visual.thickness / 2),
                    crossAxisMargin: visual.crossAxisMargin,
                    mainAxisMargin: arrowExtent,
                    minThumbLength: UtenScrollbarStyle.minimumThumbLength,
                    scrollbarOrientation: ScrollbarOrientation.right,
                    child: surface,
                  );
                } else {
                  sdkScrollbar = ScrollbarTheme(
                    data: visual.theme.copyWith(
                      mainAxisMargin: arrowExtent,
                      thumbColor: WidgetStatePropertyAll(
                        widget.visible ? visual.thumbColor : Colors.transparent,
                      ),
                    ),
                    child: Scrollbar(
                      controller: widget.controller,
                      thumbVisibility: widget.visible && widget.thumbVisibility,
                      trackVisibility: false,
                      interactive:
                          widget.visible &&
                          widget.interactive &&
                          !_axisModifierPressed,
                      notificationPredicate: accepts,
                      scrollbarOrientation: ScrollbarOrientation.right,
                      child: surface,
                    ),
                  );
                }
                return Stack(
                  fit: StackFit.passthrough,
                  children: [
                    sdkScrollbar,
                    Positioned(
                      top: 0,
                      right: 0,
                      bottom: 0,
                      width: UtenScrollbarStyle.laneWidth,
                      child: UtenScrollbarArrowButtons(
                        controller: widget.controller,
                        visual: visual,
                        visible: railVisible,
                        interactive: widget.visible && widget.interactive,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
