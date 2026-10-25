import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/uten_page_prefs_notifier.dart';

/// Presentation preferences only. Offsets follow the field when its row moves.
class UtenDropdownMenuGeometry {
  const UtenDropdownMenuGeometry({
    required this.width,
    required this.height,
    required this.offset,
  });

  final double width;
  final double height;
  final Offset offset;

  Rect resolve(Rect anchor, Rect bounds, Size minimum) {
    final w = width
        .clamp(math.min(minimum.width, bounds.width), bounds.width)
        .toDouble();
    final h = height
        .clamp(math.min(minimum.height, bounds.height), bounds.height)
        .toDouble();
    return Rect.fromLTWH(
      (anchor.left + offset.dx).clamp(bounds.left, bounds.right - w),
      (anchor.top + offset.dy).clamp(bounds.top, bounds.bottom - h),
      w,
      h,
    );
  }

  static UtenDropdownMenuGeometry fromRect(Rect rect, Rect anchor) =>
      UtenDropdownMenuGeometry(
        width: rect.width,
        height: rect.height,
        offset: rect.topLeft - anchor.topLeft,
      );

  Map<String, double> toJson() => {
    'w': width,
    'h': height,
    'x': offset.dx,
    'y': offset.dy,
  };

  static UtenDropdownMenuGeometry? decode(Object? value) {
    if (value is! Map) return null;
    double? number(String key) {
      final v = value[key];
      return v is num && v.isFinite ? v.toDouble() : null;
    }

    final w = number('w'), h = number('h');
    final x = number('x'), y = number('y');
    if (w == null || h == null || x == null || y == null || w <= 0 || h <= 0) {
      return null;
    }
    return UtenDropdownMenuGeometry(width: w, height: h, offset: Offset(x, y));
  }
}

class DropdownGeometryPrefsNotifier
    extends UtenPagePrefsNotifier<Map<String, UtenDropdownMenuGeometry>> {
  @override
  String get prefKey => 'ui.dropdownGeometry';
  @override
  Map<String, UtenDropdownMenuGeometry> get defaultValue => const {};

  @override
  Map<String, UtenDropdownMenuGeometry>? decode(Object? raw) {
    if (raw is String) {
      try {
        raw = jsonDecode(raw);
      } on FormatException {
        return null;
      }
    }
    if (raw is! Map) return null;
    final result = <String, UtenDropdownMenuGeometry>{};
    for (final entry in raw.entries) {
      if (entry.key is! String) continue;
      final key = entry.key as String;
      final geometry = UtenDropdownMenuGeometry.decode(entry.value);
      if (key.isNotEmpty && key.length <= 160 && geometry != null) {
        result[key] = geometry;
      }
    }
    _limit(result);
    return Map.unmodifiable(result);
  }

  @override
  Object encode(Map<String, UtenDropdownMenuGeometry> value) => {
    for (final entry in value.entries) entry.key: entry.value.toJson(),
  };

  void _limit(Map<String, UtenDropdownMenuGeometry> value) {
    while (value.length > 64 ||
        utf8.encode(jsonEncode(encode(value))).length > 15 * 1024) {
      value.remove(value.keys.first);
    }
  }

  void updateFor(String key, UtenDropdownMenuGeometry? value) {
    if (key.isEmpty || key.length > 160) return;
    if (value != null &&
        UtenDropdownMenuGeometry.decode(value.toJson()) == null) {
      return;
    }
    final next = Map<String, UtenDropdownMenuGeometry>.of(state)..remove(key);
    if (value != null) next[key] = value;
    _limit(next);
    update(Map.unmodifiable(next));
  }
}

final dropdownGeometryPrefsProvider =
    NotifierProvider<
      DropdownGeometryPrefsNotifier,
      Map<String, UtenDropdownMenuGeometry>
    >(DropdownGeometryPrefsNotifier.new);

/// Hosts custom inline editors without adding row identity to a preference key.
class UtenDropdownPreferenceScope extends InheritedWidget {
  const UtenDropdownPreferenceScope({
    super.key,
    required this.preferenceKey,
    required super.child,
  });
  final String preferenceKey;

  static String? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<UtenDropdownPreferenceScope>()
      ?.preferenceKey;

  @override
  bool updateShouldNotify(UtenDropdownPreferenceScope oldWidget) =>
      preferenceKey != oldWidget.preferenceKey;
}

enum UtenDropdownEdge {
  move,
  top,
  bottom,
  left,
  right,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

Rect resizeDropdownRect(
  Rect start,
  Offset delta,
  UtenDropdownEdge edge,
  Rect bounds,
  Size minimum,
) {
  // A keyboard or viewport change can arrive between pointer events.
  start = UtenDropdownMenuGeometry.fromRect(start, Rect.zero).resolve(
    Rect.zero,
    bounds,
    Size(
      math.min(minimum.width, start.width),
      math.min(minimum.height, start.height),
    ),
  );
  if (edge == UtenDropdownEdge.move) {
    return Rect.fromLTWH(
      (start.left + delta.dx).clamp(bounds.left, bounds.right - start.width),
      (start.top + delta.dy).clamp(bounds.top, bounds.bottom - start.height),
      start.width,
      start.height,
    );
  }
  var left = start.left, right = start.right;
  var top = start.top, bottom = start.bottom;
  final minW = math.min(minimum.width, math.min(start.width, bounds.width));
  final minH = math.min(minimum.height, math.min(start.height, bounds.height));
  if (const {
    UtenDropdownEdge.left,
    UtenDropdownEdge.topLeft,
    UtenDropdownEdge.bottomLeft,
  }.contains(edge)) {
    left = (left + delta.dx).clamp(bounds.left, right - minW);
  }
  if (const {
    UtenDropdownEdge.right,
    UtenDropdownEdge.topRight,
    UtenDropdownEdge.bottomRight,
  }.contains(edge)) {
    right = (right + delta.dx).clamp(left + minW, bounds.right);
  }
  if (const {
    UtenDropdownEdge.top,
    UtenDropdownEdge.topLeft,
    UtenDropdownEdge.topRight,
  }.contains(edge)) {
    top = (top + delta.dy).clamp(bounds.top, bottom - minH);
  }
  if (const {
    UtenDropdownEdge.bottom,
    UtenDropdownEdge.bottomLeft,
    UtenDropdownEdge.bottomRight,
  }.contains(edge)) {
    bottom = (bottom + delta.dy).clamp(top + minH, bounds.bottom);
  }
  return Rect.fromLTRB(left, top, right, bottom);
}

typedef DropdownGestureStart = void Function(UtenDropdownEdge edge);
typedef DropdownGestureUpdate =
    void Function(Offset delta, UtenDropdownEdge edge);

class UtenDropdownGeometryHandle extends StatefulWidget {
  const UtenDropdownGeometryHandle({
    super.key,
    required this.edge,
    required this.cursor,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.child,
  });
  final UtenDropdownEdge edge;
  final MouseCursor cursor;
  final DropdownGestureStart onStart;
  final DropdownGestureUpdate onUpdate;
  final VoidCallback onEnd;
  final Widget child;

  @override
  State<UtenDropdownGeometryHandle> createState() => _GeometryHandleState();
}

class _GeometryHandleState extends State<UtenDropdownGeometryHandle> {
  Offset _start = Offset.zero;
  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: widget.cursor,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (details) {
        _start = details.globalPosition;
        widget.onStart(widget.edge);
      },
      onPanUpdate: (details) =>
          widget.onUpdate(details.globalPosition - _start, widget.edge),
      onPanEnd: (_) => widget.onEnd(),
      onPanCancel: widget.onEnd,
      child: widget.child,
    ),
  );
}

/// Handles live outside the content, keeping search, rows and scrollbars free.
class UtenDropdownResizeFrame extends StatelessWidget {
  const UtenDropdownResizeFrame({
    super.key,
    required this.fieldKey,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
    required this.child,
    required this.resizeLabel,
  });
  final Key? fieldKey;
  final DropdownGestureStart onStart;
  final DropdownGestureUpdate onUpdate;
  final VoidCallback onEnd;
  final Widget child;
  final String resizeLabel;

  @override
  Widget build(BuildContext context) {
    Widget handle(UtenDropdownEdge edge, MouseCursor cursor) => Tooltip(
      message: resizeLabel,
      child: UtenDropdownGeometryHandle(
        key: ValueKey(('uten-dropdown-resize', fieldKey, edge)),
        edge: edge,
        cursor: cursor,
        onStart: onStart,
        onUpdate: onUpdate,
        onEnd: onEnd,
        child: const SizedBox.expand(),
      ),
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: const EdgeInsets.all(8), child: child),
        Positioned(
          left: 12,
          right: 12,
          top: 0,
          height: 8,
          child: handle(UtenDropdownEdge.top, SystemMouseCursors.resizeUpDown),
        ),
        Positioned(
          left: 12,
          right: 12,
          bottom: 0,
          height: 8,
          child: handle(
            UtenDropdownEdge.bottom,
            SystemMouseCursors.resizeUpDown,
          ),
        ),
        Positioned(
          top: 12,
          bottom: 12,
          left: 0,
          width: 8,
          child: handle(
            UtenDropdownEdge.left,
            SystemMouseCursors.resizeLeftRight,
          ),
        ),
        Positioned(
          top: 12,
          bottom: 12,
          right: 0,
          width: 8,
          child: handle(
            UtenDropdownEdge.right,
            SystemMouseCursors.resizeLeftRight,
          ),
        ),
        Positioned(
          left: 0,
          top: 0,
          width: 16,
          height: 16,
          child: handle(
            UtenDropdownEdge.topLeft,
            SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          width: 16,
          height: 16,
          child: handle(
            UtenDropdownEdge.topRight,
            SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
        Positioned(
          left: 0,
          bottom: 0,
          width: 16,
          height: 16,
          child: handle(
            UtenDropdownEdge.bottomLeft,
            SystemMouseCursors.resizeUpRightDownLeft,
          ),
        ),
        Positioned(
          right: 0,
          bottom: 0,
          width: 16,
          height: 16,
          child: handle(
            UtenDropdownEdge.bottomRight,
            SystemMouseCursors.resizeUpLeftDownRight,
          ),
        ),
      ],
    );
  }
}
