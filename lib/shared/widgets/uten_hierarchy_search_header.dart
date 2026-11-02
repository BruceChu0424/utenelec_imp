import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/responsive/compact_presentation.dart';
import '../../components/layout/uten_compact_toolbar.dart';

/// A category/directory search field with an optional, separate trailing action.
/// The field retains its input decoration and the action retains its hit target.
class UtenHierarchySearchHeader extends StatelessWidget {
  const UtenHierarchySearchHeader({
    super.key,
    required this.search,
    this.trailing,
  });

  final Widget search;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) =>
      UtenCompactPresentation.iconSearchOf(context)
      ? Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            utenCompactToolbarChild(context, search),
            if (trailing != null) ...[
              const SizedBox(width: UtenSpacing.s4),
              trailing!,
            ],
          ],
        )
      : trailing == null
      ? search
      : IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: search),
              const SizedBox(width: UtenSpacing.s8),
              AspectRatio(aspectRatio: 1, child: trailing!),
            ],
          ),
        );
}
