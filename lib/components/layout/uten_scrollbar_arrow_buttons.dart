import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../../core/responsive/display_zoom.dart';
import '../../core/theme/uten_scrollbar_style.dart';
import 'uten_scrollbar_rail_delegate.dart';

/// The only repeating arrow implementation for SDK and custom vertical rails.
/// Overlay it above the thumb's gesture detector, so arrow clicks never also
/// become SDK track-page taps. Its empty center remains pointer-transparent.
class UtenScrollbarArrowButtons extends StatefulWidget {
  const UtenScrollbarArrowButtons({
    super.key,
    required this.controller,
    required this.visual,
    this.visible = true,
    this.interactive = true,
    this.onPointerSignal,
    this.railDelegate,
    this.windowSizedChrome = false,
  });

  final ScrollController controller;
  final UtenScrollbarVisuals visual;
  final bool visible;
  final bool interactive;
  final ValueChanged<PointerSignalEvent>? onPointerSignal;
  final UtenScrollbarRailDelegate? railDelegate;
  final bool windowSizedChrome;

  @override
  State<UtenScrollbarArrowButtons> createState() =>
      _UtenScrollbarArrowButtonsState();
}

class _UtenScrollbarArrowButtonsState extends State<UtenScrollbarArrowButtons>
    with WidgetsBindingObserver {
  Timer? _delay;
  Timer? _repeat;
  int? _activeDirection;
  int? _activePointer;
  int? _hoveredDirection;
  bool _positionRebuildScheduled = false;
  ScrollNotificationObserverState? _observer;
  late final _upFocus = FocusNode(debugLabel: 'uten-scroll-up')
    ..addListener(_focusChanged);
  late final _downFocus = FocusNode(debugLabel: 'uten-scroll-down')
    ..addListener(_focusChanged);

  Listenable get _updates => widget.railDelegate ?? widget.controller;

  UtenScrollbarRailTarget? get _position => UtenScrollbarRailTarget.resolve(
    controller: widget.controller,
    delegate: widget.railDelegate,
    visible: widget.visible,
  );

  bool _canScroll(int direction) {
    final position = _position;
    if (!widget.interactive ||
        position == null ||
        !position.acceptsUserOffset) {
      return false;
    }
    final forward = position.axisDirection == AxisDirection.up
        ? -direction
        : direction;
    return forward < 0
        ? position.pixels > position.minScrollExtent
        : position.pixels < position.maxScrollExtent;
  }

  bool _step(int direction) {
    final position = _position;
    if (position == null || !_canScroll(direction)) return false;
    final zoom = UtenDisplayScale.fontZoomOf(context);
    final delta =
        direction *
        UtenScrollbarStyle.arrowStepWindowPixels /
        (zoom > 0 ? zoom : 1);
    position.pointerScroll(
      position.axisDirection == AxisDirection.up ? -delta : delta,
    );
    return true;
  }

  void _stop({bool notify = true}) {
    _delay?.cancel();
    _repeat?.cancel();
    _delay = null;
    _repeat = null;
    final wasPressed = _activeDirection != null;
    _activeDirection = null;
    _activePointer = null;
    if (notify && wasPressed && mounted) setState(() {});
  }

  void _press(PointerDownEvent event, int direction) {
    if (event.buttons != kPrimaryButton || !_canScroll(direction)) return;
    _stop(notify: false);
    setState(() {
      _activeDirection = direction;
      _activePointer = event.pointer;
    });
    if (!_step(direction) || _activeDirection == null) return;
    _delay = Timer(UtenScrollbarStyle.arrowRepeatDelay, () {
      if (!mounted || _activeDirection != direction || !_canScroll(direction)) {
        _stop();
        return;
      }
      _step(direction);
      if (_activeDirection == null) return;
      _repeat = Timer.periodic(UtenScrollbarStyle.arrowRepeatInterval, (_) {
        if (!mounted || _activeDirection != direction || !_step(direction)) {
          _stop();
        }
      });
    });
  }

  void _positionChanged() {
    if (_activeDirection case final direction?) {
      if (!_canScroll(direction)) _stop(notify: false);
    }
    if (!mounted) return;
    // Content contraction can correct the offset and dispatch notifications
    // during layout. Repaint the final boundary state after that frame.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_positionRebuildScheduled) return;
      _positionRebuildScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _positionRebuildScheduled = false;
        if (mounted) setState(() {});
      });
      return;
    }
    setState(() {});
  }

  void _observedMetrics(ScrollNotification notification) {
    final context = notification.context;
    if (context == null || notification.metrics.axis != Axis.vertical) return;
    final position = Scrollable.maybeOf(context)?.position;
    if (widget.railDelegate != null ||
        widget.controller.positions.contains(position)) {
      _positionChanged();
    }
  }

  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _updates.addListener(_positionChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final observer = ScrollNotificationObserver.maybeOf(context);
    if (identical(observer, _observer)) return;
    _observer?.removeListener(_observedMetrics);
    _observer = observer;
    observer?.addListener(_observedMetrics);
  }

  @override
  void didUpdateWidget(covariant UtenScrollbarArrowButtons oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldUpdates = oldWidget.railDelegate ?? oldWidget.controller;
    if (!identical(oldUpdates, _updates)) {
      oldUpdates.removeListener(_positionChanged);
      _updates.addListener(_positionChanged);
      _stop(notify: false);
    }
    if (!widget.visible || !widget.interactive) _stop(notify: false);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stop();
  }

  @override
  void dispose() {
    _stop(notify: false);
    _updates.removeListener(_positionChanged);
    _observer?.removeListener(_observedMetrics);
    WidgetsBinding.instance.removeObserver(this);
    _upFocus.dispose();
    _downFocus.dispose();
    super.dispose();
  }

  void _wheel(PointerSignalEvent event) {
    widget.onPointerSignal?.call(event);
    final position = _position;
    if (event is PointerScrollInertiaCancelEvent &&
        position != null &&
        widget.interactive) {
      position.pointerScroll(0);
      return;
    }
    if (event is! PointerScrollEvent ||
        position == null ||
        !widget.interactive ||
        !position.acceptsUserOffset) {
      return;
    }
    final modifiers = ScrollConfiguration.of(context).pointerAxisModifiers;
    final flipped =
        event.kind == PointerDeviceKind.mouse &&
        HardwareKeyboard.instance.logicalKeysPressed.any(modifiers.contains);
    var delta = flipped ? event.scrollDelta.dx : event.scrollDelta.dy;
    if (position.axisDirection == AxisDirection.up) delta = -delta;
    final target = (position.pixels + delta).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (delta == 0 || target == position.pixels) return;
    GestureBinding.instance.pointerSignalResolver.register(event, (event) {
      if (!mounted || !identical(position.identity, _position?.identity)) {
        return;
      }
      position.pointerScroll(delta);
      (event as PointerScrollEvent).respond(allowPlatformDefault: false);
    });
  }

  Widget _button(int direction, double extent, double width) {
    final enabled = _canScroll(direction);
    final focus = direction < 0 ? _upFocus : _downFocus;
    final label = direction < 0 ? '向上滚动' : '向下滚动';
    return Semantics(
      key: ValueKey(
        direction < 0 ? 'uten-scrollbar-up' : 'uten-scrollbar-down',
      ),
      button: true,
      enabled: enabled,
      label: label,
      onTap: enabled ? () => _step(direction) : null,
      child: ExcludeSemantics(
        child: FocusableActionDetector(
          focusNode: focus,
          enabled: enabled,
          mouseCursor: enabled
              ? SystemMouseCursors.basic
              : SystemMouseCursors.forbidden,
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.arrowUp): _ArrowStepIntent(-1),
            SingleActivator(LogicalKeyboardKey.arrowDown): _ArrowStepIntent(1),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                _step(direction);
                return null;
              },
            ),
            _ArrowStepIntent: CallbackAction<_ArrowStepIntent>(
              onInvoke: (intent) {
                _step(intent.direction);
                return null;
              },
            ),
          },
          child: MouseRegion(
            onEnter: (_) => setState(() => _hoveredDirection = direction),
            onExit: (_) {
              if (_activeDirection == direction) _stop();
              if (mounted) setState(() => _hoveredDirection = null);
            },
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _press(event, direction),
              onPointerUp: (event) {
                if (event.pointer == _activePointer) _stop();
              },
              onPointerCancel: (event) {
                if (event.pointer == _activePointer) _stop();
              },
              onPointerMove: (event) {
                if (event.pointer == _activePointer &&
                    !Rect.fromLTWH(
                      0,
                      0,
                      width,
                      extent,
                    ).contains(event.localPosition)) {
                  _stop();
                }
              },
              onPointerSignal: _wheel,
              child: CustomPaint(
                painter: _ArrowPainter(
                  unitScale: widget.windowSizedChrome
                      ? 1 / UtenDisplayScale.fontZoomOf(context)
                      : 1,
                  direction: direction,
                  visual: widget.visual,
                  enabled: enabled,
                  active: _activeDirection == direction,
                  hovered: _hoveredDirection == direction,
                  focused: focus.hasFocus,
                ),
                child: SizedBox(width: width, height: extent),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_position == null) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final unit = widget.windowSizedChrome
            ? 1 / UtenDisplayScale.fontZoomOf(context)
            : 1.0;
        final extent = (UtenScrollbarStyle.arrowExtent * unit)
            .clamp(0, constraints.maxHeight / 3)
            .toDouble();
        if (extent <= 0 || !constraints.maxHeight.isFinite) {
          return const SizedBox.shrink();
        }
        return Stack(
          children: [
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: extent,
              child: _button(-1, extent, constraints.maxWidth),
            ),
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              height: extent,
              child: _button(1, extent, constraints.maxWidth),
            ),
          ],
        );
      },
    );
  }
}

class _ArrowStepIntent extends Intent {
  const _ArrowStepIntent(this.direction);
  final int direction;
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter({
    required this.direction,
    required this.visual,
    required this.enabled,
    required this.active,
    required this.hovered,
    required this.focused,
    required this.unitScale,
  });
  final int direction;
  final UtenScrollbarVisuals visual;
  final bool enabled;
  final bool active;
  final bool hovered;
  final bool focused;
  final double unitScale;

  @override
  void paint(Canvas canvas, Size size) {
    if (enabled && (active || hovered)) {
      canvas.drawRect(
        Offset.zero & size,
        Paint()..color = visual.thumbColor.withValues(alpha: active ? .2 : .1),
      );
    }
    if (focused) {
      canvas.drawRect(
        Rect.fromLTWH(
          unitScale,
          unitScale,
          (size.width - 2 * unitScale).clamp(0, double.infinity),
          (size.height - 2 * unitScale).clamp(0, double.infinity),
        ),
        Paint()
          ..color = visual.thumbColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = unitScale,
      );
    }
    final x = size.width / 2;
    final y = size.height / 2;
    final path = Path()
      ..moveTo(x - 3 * unitScale, y - direction * 1.5 * unitScale)
      ..lineTo(x, y + direction * 1.5 * unitScale)
      ..lineTo(x + 3 * unitScale, y - direction * 1.5 * unitScale);
    canvas.drawPath(
      path,
      Paint()
        ..color = visual.thumbColor.withValues(alpha: enabled ? 1 : .32)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 * unitScale
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) =>
      unitScale != oldDelegate.unitScale ||
      direction != oldDelegate.direction ||
      visual.thumbColor != oldDelegate.visual.thumbColor ||
      enabled != oldDelegate.enabled ||
      active != oldDelegate.active ||
      hovered != oldDelegate.hovered ||
      focused != oldDelegate.focused;
}
