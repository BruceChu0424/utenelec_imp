import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../components/layout/uten_scroll_gutter.dart';
import 'uten_colors.dart';

/// One visual contract for SDK and custom vertical scrollbars. Horizontal bars
/// and scrollbar-free dropdown scopes retain their own existing themes.
abstract final class UtenScrollbarStyle {
  static const double laneWidth = UtenScrollGutter.trackWidth;
  static const double thumbWidth = 10;
  static const double activeThumbWidth = 12;
  static const double minimumThumbLength = 32;
  static const double arrowExtent = 16;
  static const double arrowStepWindowPixels = 32;
  static const Duration arrowRepeatDelay = Duration(milliseconds: 300);
  static const Duration arrowRepeatInterval = Duration(milliseconds: 50);
  static const Duration hoverDuration = Duration(milliseconds: 160);
  static const Curve hoverCurve = Curves.easeOut;

  static double arrowExtentForTrack(double height) =>
      math.min(arrowExtent, math.max(0, height) / 3);

  static void paintTrack(
    Canvas canvas,
    Size size,
    UtenScrollbarVisuals visual, {
    double unitScale = 1,
  }) {
    canvas.drawRect(Offset.zero & size, Paint()..color = visual.trackColor);
    canvas.drawLine(
      Offset(.5 * unitScale, 0),
      Offset(.5 * unitScale, size.height),
      Paint()
        ..color = visual.borderColor
        ..strokeWidth = unitScale,
    );
  }

  static UtenScrollbarVisuals visuals(
    Brightness brightness, {
    double emphasis = 0,
    bool dragging = false,
  }) {
    final dark = brightness == Brightness.dark;
    final t = emphasis.clamp(0.0, 1.0);
    final idleThumb = dark ? UtenColors.slate400 : UtenColors.slate500;
    final activeThumb = dragging
        ? (dark ? UtenColors.teal300 : UtenColors.teal700)
        : (dark ? UtenColors.slate200 : UtenColors.slate700);
    return UtenScrollbarVisuals(
      thickness: thumbWidth + (activeThumbWidth - thumbWidth) * t,
      thumbColor: Color.lerp(idleThumb, activeThumb, t)!,
      trackColor: Color.lerp(
        dark ? UtenColors.darkSurfaceLow : UtenColors.slate100,
        dark ? UtenColors.darkSurfaceHigh : UtenColors.slate200,
        t,
      )!,
      borderColor: dark
          ? UtenColors.slate500.withValues(alpha: .6)
          : UtenColors.slate300,
    );
  }
}

/// The leading edge is drawn inside the lane. The SDK's centered border stroke
/// would otherwise antialias half a pixel into the content on hover.
class UtenScrollbarTrackPainter extends CustomPainter {
  const UtenScrollbarTrackPainter(this.visual);

  final UtenScrollbarVisuals visual;

  @override
  void paint(Canvas canvas, Size size) =>
      UtenScrollbarStyle.paintTrack(canvas, size, visual);

  @override
  bool shouldRepaint(UtenScrollbarTrackPainter oldDelegate) =>
      oldDelegate.visual.trackColor != visual.trackColor ||
      oldDelegate.visual.borderColor != visual.borderColor;
}

@immutable
class UtenScrollbarVisuals {
  const UtenScrollbarVisuals({
    required this.thickness,
    required this.thumbColor,
    required this.trackColor,
    required this.borderColor,
  });

  final double thickness;
  final Color thumbColor;
  final Color trackColor;
  final Color borderColor;

  double get crossAxisMargin => (UtenScrollbarStyle.laneWidth - thickness) / 2;

  ScrollbarThemeData get theme => ScrollbarThemeData(
    thumbColor: WidgetStatePropertyAll(thumbColor),
    trackColor: WidgetStatePropertyAll(trackColor),
    trackBorderColor: WidgetStatePropertyAll(borderColor),
    thickness: WidgetStatePropertyAll(thickness),
    radius: Radius.circular(thickness / 2),
    crossAxisMargin: crossAxisMargin,
    mainAxisMargin: 0,
    minThumbLength: UtenScrollbarStyle.minimumThumbLength,
  );
}
