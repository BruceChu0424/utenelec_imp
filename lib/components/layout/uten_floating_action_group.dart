import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

class UtenFloatingActionGroup extends StatelessWidget {
  const UtenFloatingActionGroup({
    super.key,
    required this.children,
    this.maxWidth = 1080,
  });

  final List<Widget> children;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final availableWidth = (viewportWidth - UtenSpacing.s32)
        .clamp(0.0, maxWidth)
        .toDouble();

    return Material(
      type: MaterialType.transparency,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: availableWidth),
        child: Wrap(
          alignment: WrapAlignment.end,
          runAlignment: WrapAlignment.end,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final child in children)
              DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: UtenElevation.mid(
                    isDark: theme.brightness == Brightness.dark,
                  ),
                ),
                child: child,
              ),
          ],
        ),
      ),
    );
  }
}
