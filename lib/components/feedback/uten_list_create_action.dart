import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import '../layout/uten_floating_action_group.dart';
import 'uten_empty.dart';

/// Keeps the primary create action in the bottom-right corner across list states.
@immutable
class UtenListCreateAction {
  const UtenListCreateAction({
    required this.emptyIcon,
    required this.emptyMessage,
    required this.emptyDescription,
    required this.fabLabel,
    required this.actionIcon,
    required this.onPressed,
  });

  final IconData emptyIcon;
  final String emptyMessage;
  final String emptyDescription;
  final String fabLabel;
  final IconData actionIcon;
  final VoidCallback onPressed;

  Widget emptyState({double topSpacing = UtenSpacing.s48}) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: topSpacing),
        UtenEmpty(
          icon: emptyIcon,
          message: emptyMessage,
          description: emptyDescription,
        ),
      ],
    );
  }

  Widget floatingActionButton(BuildContext context) {
    return UtenFloatingActionGroup(
      children: [
        UtenButton(
          size: UtenButtonSize.large,
          icon: actionIcon,
          onPressed: onPressed,
          child: Text(fabLabel),
        ),
      ],
    );
  }
}
