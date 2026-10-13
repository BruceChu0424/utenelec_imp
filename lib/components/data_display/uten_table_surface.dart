import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// Table-owned cards retain their theme's shape without a decorative outer line.
OutlinedBorder utenTableCardShape(BuildContext context) {
  final shape = Theme.of(context).cardTheme.shape;
  if (shape is OutlinedBorder) return shape.copyWith(side: BorderSide.none);
  return const RoundedRectangleBorder(borderRadius: UtenRadius.tableAll);
}

/// A rounded table viewport without an outer stroke. Cells stay rectangular so
/// their internal dividers remain aligned while scrolling, pinning and resizing.
class UtenTableSurface extends StatelessWidget {
  const UtenTableSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: const BoxDecoration(borderRadius: UtenRadius.tableAll),
    child: ClipRRect(borderRadius: UtenRadius.tableAll, child: child),
  );
}
