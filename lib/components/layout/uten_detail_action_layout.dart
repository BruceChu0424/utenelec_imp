import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import 'uten_floating_action_group.dart';

/// Detail actions float over the content without reserving a painted footer.
/// Scrollable bodies must include [UtenFloatingActionGroup.scrollClearance].
class UtenDetailActionLayout extends StatelessWidget {
  const UtenDetailActionLayout({
    super.key,
    required this.body,
    required this.actions,
  });

  final Widget body;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(child: body),
      if (actions.isNotEmpty)
        Positioned(
          left: UtenSpacing.s16,
          right: UtenSpacing.s16,
          bottom: UtenSpacing.s16,
          child: Align(
            alignment: Alignment.bottomRight,
            child: UtenFloatingActionGroup(children: actions),
          ),
        ),
    ],
  );
}
