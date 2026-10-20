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
/// The logical last cell (including a trailing action cell) owns its visible
/// right border; the surface does not add a decorative frame around the table.
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

/// Header corners belong to the header viewport, independently of any toolbar
/// above it. Clipping the full table alone leaves picker headers square when
/// that table has an empty toolbar or a pager before the header.
class UtenTableHeaderSurface extends StatelessWidget {
  const UtenTableHeaderSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: const BorderRadius.vertical(
      top: Radius.circular(UtenRadius.table),
    ),
    child: child,
  );
}
