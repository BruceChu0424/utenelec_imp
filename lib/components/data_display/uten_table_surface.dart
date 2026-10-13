import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// A single frame around the table viewport, including connected toolbars and
/// footers. Cells stay rectangular so column boundaries remain aligned while
/// scrolling, pinning and resizing. Foreground decoration changes no geometry.
class UtenTableSurface extends StatelessWidget {
  const UtenTableSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    position: DecorationPosition.foreground,
    decoration: BoxDecoration(
      borderRadius: UtenRadius.tableAll,
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: ClipRRect(borderRadius: UtenRadius.tableAll, child: child),
  );
}
