import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

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
  Widget build(BuildContext context) => trailing == null
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
