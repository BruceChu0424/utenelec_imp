import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import 'uten_empty.dart';

/// Keeps the primary create action mutually exclusive across list states:
/// the empty state owns the CTA, while a non-empty list owns the FAB.
@immutable
class UtenListCreateAction {
  const UtenListCreateAction({
    required this.emptyIcon,
    required this.emptyMessage,
    required this.emptyDescription,
    required this.emptyActionLabel,
    required this.fabLabel,
    required this.actionIcon,
    required this.onPressed,
  });

  final IconData emptyIcon;
  final String emptyMessage;
  final String emptyDescription;
  final String emptyActionLabel;
  final String fabLabel;
  final IconData actionIcon;
  final VoidCallback onPressed;

  Widget emptyState({
    double topSpacing = UtenSpacing.s48,
    double horizontalActionPadding = UtenSpacing.s40,
  }) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: topSpacing),
        UtenEmpty(
          icon: emptyIcon,
          message: emptyMessage,
          description: emptyDescription,
        ),
        const SizedBox(height: UtenSpacing.s24),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalActionPadding),
          child: UtenButton(
            isExpanded: true,
            icon: actionIcon,
            onPressed: onPressed,
            child: Text(emptyActionLabel),
          ),
        ),
      ],
    );
  }

  Widget? floatingActionButton(BuildContext context, {required bool hasItems}) {
    if (!hasItems) return null;
    final colors = Theme.of(context).colorScheme;
    return FloatingActionButton.extended(
      onPressed: onPressed,
      backgroundColor: colors.primary,
      foregroundColor: colors.onPrimary,
      icon: Icon(actionIcon),
      label: Text(fabLabel),
    );
  }
}
