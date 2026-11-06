import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

/// The same window controls on native, web and mobile surfaces. Only native
/// title bars use the smaller geometry required by their fixed-height strip.
enum UtenWindowControl { close, minimize, expand }

class UtenWindowControlButton extends StatefulWidget {
  const UtenWindowControlButton.close({
    super.key,
    required this.onPressed,
    this.tooltip,
    this.native = false,
    this.desktopHitExtent = UtenControlMetrics.standardHeight,
    this.showTooltip = true,
  }) : control = UtenWindowControl.close,
       expanded = false;

  const UtenWindowControlButton.minimize({
    super.key,
    required this.onPressed,
    this.tooltip,
    this.native = false,
    this.desktopHitExtent = UtenControlMetrics.standardHeight,
    this.showTooltip = true,
  }) : control = UtenWindowControl.minimize,
       expanded = false;

  const UtenWindowControlButton.expand({
    super.key,
    required this.onPressed,
    this.expanded = false,
    this.tooltip,
    this.native = false,
    this.desktopHitExtent = UtenControlMetrics.standardHeight,
    this.showTooltip = true,
  }) : control = UtenWindowControl.expand;

  final UtenWindowControl control;
  final FutureOr<void> Function()? onPressed;
  final String? tooltip;
  final bool expanded;
  final bool native;
  final double desktopHitExtent;
  final bool showTooltip;

  static const double circleExtent = 28;
  static const double nativeCircleExtent = 22;
  static const double nativeWidth = 30;
  static const double nativeHeight = 36;

  /// Native windows sit flush with the physical screen top when maximized, so
  /// the glyph keeps extra clearance there (11px instead of a dead-centered 7)
  /// while the full-height hit target and strip layout stay untouched.
  static const double nativeGlyphTopInset = 8;

  String _label(BuildContext context) {
    if (tooltip != null) return tooltip!;
    if (control == UtenWindowControl.close) {
      return MaterialLocalizations.of(context).closeButtonTooltip;
    }
    final language = Localizations.localeOf(context).languageCode;
    return switch ((control, language)) {
      (UtenWindowControl.minimize, 'zh') => '最小化',
      (UtenWindowControl.minimize, 'ko') => '최소화',
      (UtenWindowControl.minimize, _) => 'Minimize',
      (_, 'zh') => expanded ? '还原' : '最大化',
      (_, 'ko') => expanded ? '복원' : '최대화',
      _ => expanded ? 'Restore' : 'Maximize',
    };
  }

  @override
  State<UtenWindowControlButton> createState() =>
      _UtenWindowControlButtonState();
}

class _UtenWindowControlButtonState extends State<UtenWindowControlButton> {
  bool _running = false;

  Future<void> _invoke() async {
    final action = widget.onPressed;
    if (_running || action == null) return;
    // Native window actions resize/rebuild the whole accessibility tree. Keep
    // their accessible enabled state stable while retaining the duplicate
    // activation guard. Business dismissers still advertise their busy state.
    if (widget.native) {
      _running = true;
    } else {
      setState(() => _running = true);
    }
    try {
      // Await draft-exit confirmation, preventing a second activation from
      // dismissing the underlying page after the same confirmation resolves.
      await Future<void>.sync(action);
    } finally {
      if (mounted) {
        if (widget.native) {
          _running = false;
        } else {
          setState(() => _running = false);
        }
      }
    }
  }

  /// Native glyphs drop below the strip's centered line so a maximized window
  /// flush with the screen top cannot visually clip them. Other surfaces keep
  /// the plain centered circle.
  Widget _nativeGlyph({required Widget circle}) {
    if (!widget.native) return circle;
    return SizedBox(
      width: UtenWindowControlButton.nativeWidth,
      height: UtenWindowControlButton.nativeHeight,
      child: Padding(
        padding: const EdgeInsets.only(
          top: UtenWindowControlButton.nativeGlyphTopInset,
        ),
        child: Center(child: circle),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onPressed != null && (widget.native || !_running);
    final color = switch (widget.control) {
      UtenWindowControl.close => UtenColors.error,
      UtenWindowControl.minimize => UtenColors.warning,
      UtenWindowControl.expand => UtenColors.success,
    };
    final icon = switch (widget.control) {
      UtenWindowControl.close => Icons.close_rounded,
      UtenWindowControl.minimize => Icons.remove_rounded,
      UtenWindowControl.expand =>
        widget.expanded
            ? Icons.filter_none_rounded
            : Icons.open_in_full_rounded,
    };
    final extent = UtenControlMetrics.minimumHitExtent(
      context,
      desktop: widget.desktopHitExtent,
    );
    final size = widget.native
        ? const Size(
            UtenWindowControlButton.nativeWidth,
            UtenWindowControlButton.nativeHeight,
          )
        : Size.square(extent);
    final label = widget._label(context);
    // A native resize must not insert/remove an OverlayPortal tooltip while
    // Windows accessibility clients enumerate this same control strip. Native
    // controls expose one explicit actionable node, retaining screen-reader
    // labels and keyboard/pointer activation without a transient tooltip tree.
    final showTooltip = widget.showTooltip && !widget.native;
    return SizedBox.fromSize(
      size: size,
      child: Semantics(
        container: widget.native,
        excludeSemantics: widget.native,
        button: widget.native ? true : null,
        enabled: widget.native ? enabled : null,
        onTap: widget.native && enabled ? _invoke : null,
        label: showTooltip ? null : label,
        child: IconButton(
          tooltip: showTooltip ? label : null,
          onPressed: enabled ? _invoke : null,
          padding: EdgeInsets.zero,
          constraints: BoxConstraints.tight(size),
          visualDensity: VisualDensity.standard,
          style: ButtonStyle(
            minimumSize: WidgetStatePropertyAll(size),
            maximumSize: WidgetStatePropertyAll(size),
            fixedSize: WidgetStatePropertyAll(size),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            shape: WidgetStatePropertyAll(
              widget.native
                  ? const _NativeWindowControlBorder()
                  : const CircleBorder(),
            ),
            foregroundColor: const WidgetStatePropertyAll(Colors.white),
            overlayColor: WidgetStateProperty.resolveWith(
              (states) => scheme.onSurface.withValues(
                alpha: states.contains(WidgetState.focused) ? 0.20 : 0.12,
              ),
            ),
            side: WidgetStateProperty.resolveWith(
              (states) => states.contains(WidgetState.focused)
                  ? BorderSide(color: scheme.onSurface, width: 2)
                  : BorderSide.none,
            ),
          ),
          icon: _nativeGlyph(
            circle: Container(
              width: widget.native
                  ? UtenWindowControlButton.nativeCircleExtent
                  : UtenWindowControlButton.circleExtent,
              height: widget.native
                  ? UtenWindowControlButton.nativeCircleExtent
                  : UtenWindowControlButton.circleExtent,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: enabled
                    ? color
                    : scheme.onSurface.withValues(alpha: 0.12),
              ),
              child: Icon(
                icon,
                size: widget.native ? 14 : 18,
                color: enabled
                    ? Colors.white
                    : scheme.onSurface.withValues(alpha: 0.38),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Paint native hover, pressed and focus feedback around the same padded
/// content as the glyph, while the button retains its full strip hit target.
class _NativeWindowControlBorder extends OutlinedBorder {
  const _NativeWindowControlBorder({super.side});

  Rect _circle(Rect rect) {
    final content = Rect.fromLTRB(
      rect.left,
      rect.top +
          math.min(UtenWindowControlButton.nativeGlyphTopInset, rect.height),
      rect.right,
      rect.bottom,
    );
    return Rect.fromCircle(
      center: content.center,
      radius: math.min(content.width, content.height) / 2,
    );
  }

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  _NativeWindowControlBorder copyWith({BorderSide? side}) =>
      _NativeWindowControlBorder(side: side ?? this.side);

  @override
  _NativeWindowControlBorder scale(double t) =>
      _NativeWindowControlBorder(side: side.scale(t));

  @override
  ShapeBorder? lerpFrom(ShapeBorder? a, double t) =>
      a is _NativeWindowControlBorder
      ? _NativeWindowControlBorder(side: BorderSide.lerp(a.side, side, t))
      : super.lerpFrom(a, t);

  @override
  ShapeBorder? lerpTo(ShapeBorder? b, double t) =>
      b is _NativeWindowControlBorder
      ? _NativeWindowControlBorder(side: BorderSide.lerp(side, b.side, t))
      : super.lerpTo(b, t);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addOval(_circle(rect));

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Path()..addOval(_circle(rect).deflate(side.width));

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.solid && side.width > 0) {
      canvas.drawOval(_circle(rect).deflate(side.width / 2), side.toPaint());
    }
  }
}

/// Closing always uses the red circle and white cross. The owner supplies the
/// callback (including unsaved-change checks, result values and busy guards).
class UtenCloseButton extends UtenWindowControlButton {
  const UtenCloseButton({
    super.key,
    required super.onPressed,
    super.tooltip,
    super.native,
    super.desktopHitExtent,
    super.showTooltip,
  }) : super.close();
}

/// Window controls are one compact, indivisible group on every platform.
/// Close is always the rightmost control, after minimize and expand. Business
/// actions stay outside this group. Nullable callbacks disable a control.
class UtenWindowControls extends StatelessWidget {
  const UtenWindowControls({
    super.key,
    required this.onClose,
    this.onMinimize,
    this.onExpand,
    this.showMinimize = false,
    this.showExpand = false,
    this.expanded = false,
    this.native = false,
    this.closeTooltip,
    this.minimizeTooltip,
    this.expandTooltip,
    this.closeButtonKey,
    this.minimizeButtonKey,
    this.expandButtonKey,
  });

  final FutureOr<void> Function()? onClose;
  final FutureOr<void> Function()? onMinimize;
  final FutureOr<void> Function()? onExpand;
  final bool showMinimize;
  final bool showExpand;
  final bool expanded;
  final bool native;
  final String? closeTooltip;
  final String? minimizeTooltip;
  final String? expandTooltip;
  final Key? closeButtonKey;
  final Key? minimizeButtonKey;
  final Key? expandButtonKey;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    textDirection: TextDirection.ltr,
    children: [
      if (showMinimize)
        UtenWindowControlButton.minimize(
          key: minimizeButtonKey,
          onPressed: onMinimize,
          tooltip: minimizeTooltip,
          native: native,
          desktopHitExtent: UtenControlMetrics.compactHeight,
        ),
      if (showExpand)
        UtenWindowControlButton.expand(
          key: expandButtonKey,
          onPressed: onExpand,
          tooltip: expandTooltip,
          native: native,
          expanded: expanded,
          desktopHitExtent: UtenControlMetrics.compactHeight,
        ),
      UtenCloseButton(
        key: closeButtonKey,
        onPressed: onClose,
        tooltip: closeTooltip,
        native: native,
        desktopHitExtent: UtenControlMetrics.compactHeight,
      ),
    ],
  );
}
