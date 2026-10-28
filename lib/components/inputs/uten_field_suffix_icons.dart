import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'uten_table_cell_hints.dart';
import 'uten_table_cell_spec.dart';

/// Adjacent field icons share compact horizontal slots while retaining the
/// field's existing height. Labels, units and custom decorations keep their
/// natural width; a business widget is never scaled or clipped into an icon.
class UtenFieldSuffixIcons extends StatelessWidget {
  const UtenFieldSuffixIcons({super.key, required this.children});

  final List<Widget> children;

  static bool _spacing(Widget child) =>
      child is SizedBox &&
      child.child == null &&
      child.height == null &&
      child.width != null &&
      child.width! <= UtenSpacing.s12;

  static bool _plainIcon(Widget? child) => switch (child) {
    Icon(:final size) => size == null || size <= UtenFieldSuffixIcon.width,
    ImageIcon(:final size) => size == null || size <= UtenFieldSuffixIcon.width,
    _ => false,
  };

  /// Only known icon-only adornments are adapted automatically. Opaque picker
  /// widgets can explicitly opt in with [UtenFieldSuffixIcon].
  static bool canCompact(Widget? child) {
    if (child == null) return false;
    if (child is UtenFieldSuffixIcons || child is UtenFieldSuffixIcon) {
      return true;
    }
    if (_plainIcon(child)) return true;
    if (child is Tooltip) return canCompact(child.child);
    if (child is IconButton && _plainIcon(child.icon)) {
      if (child.selectedIcon != null && !_plainIcon(child.selectedIcon)) {
        return false;
      }
      final visualSize = switch (child.icon) {
        Icon(:final size) => size ?? child.iconSize ?? 24,
        ImageIcon(:final size) => size ?? child.iconSize ?? 24,
        _ => 24.0,
      };
      final padding = child.padding?.resolve(TextDirection.ltr).horizontal;
      // Explicit large padding can be intentional, e.g. a branded button. Do
      // not shrink its icon to make it fit the compact role.
      if (padding != null && visualSize + padding > UtenFieldSuffixIcon.width) {
        return false;
      }
      for (final states in <Set<WidgetState>>[
        {},
        {WidgetState.disabled},
        {WidgetState.hovered},
        {WidgetState.focused},
        {WidgetState.pressed},
        {WidgetState.selected},
      ]) {
        final explicitPadding = child.style?.padding
            ?.resolve(states)
            ?.resolve(TextDirection.ltr)
            .horizontal;
        if (explicitPadding != null &&
            visualSize + explicitPadding > UtenFieldSuffixIcon.width) {
          return false;
        }
      }
      return true;
    }
    return child is Row &&
        child.mainAxisSize == MainAxisSize.min &&
        child.children.every((part) => _spacing(part) || canCompact(part));
  }

  static bool _inCell(BuildContext context) =>
      UtenTableCellInputTheme.contains(context) ||
      UtenTableCellHints.contains(context);

  Iterable<Widget> _compact(Widget child) sync* {
    if (child is UtenFieldSuffixIcons) {
      for (final part in child.children) {
        yield* _compact(part);
      }
    } else if (child is Row && canCompact(child)) {
      for (final part in child.children) {
        if (!_spacing(part)) yield* _compact(part);
      }
    } else if (child is UtenFieldSuffixIcon) {
      yield child;
    } else if (canCompact(child)) {
      yield UtenFieldSuffixIcon(child: child);
    } else {
      yield child;
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: _inCell(context)
        ? children
        : [for (final child in children) ..._compact(child)],
  );
}

/// Explicit opt-in for a custom icon-only field action, such as a record picker
/// whose button owns its loading state. The original child, callbacks, focus
/// node and state remain intact.
class UtenFieldSuffixIcon extends StatelessWidget {
  const UtenFieldSuffixIcon({super.key, required this.child});

  static const double width = 32;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (UtenFieldSuffixIcons._inCell(context)) return child;
    final original = IconButtonTheme.of(context).style ?? const ButtonStyle();
    return SizedBox(
      width: width,
      child: IconButtonTheme(
        data: IconButtonThemeData(
          style: original.copyWith(
            padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          ),
        ),
        child: Center(heightFactor: 1, child: child),
      ),
    );
  }
}
