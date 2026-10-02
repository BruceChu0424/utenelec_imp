import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';

/// Shared, keyboard-safe shell for column selection, formulas and cell editing.
/// The body has one scroll region; actions remain reachable on small screens.
class ColumnEditorDialog extends StatelessWidget {
  const ColumnEditorDialog({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
    this.actions = const [],
    this.icon = Icons.view_column_outlined,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final List<Widget> actions;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final availableHeight = math.max(
      0.0,
      media.size.height -
          media.viewInsets.vertical -
          media.padding.vertical -
          32,
    );
    return Dialog(
      insetPadding: const EdgeInsets.all(UtenSpacing.s16),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 680,
          maxHeight: math.min(800, availableHeight),
        ),
        child: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(UtenSpacing.s24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DecoratedBox(
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primaryContainer,
                              borderRadius: UtenRadius.lgAll,
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(UtenSpacing.s12),
                              child: Icon(
                                icon,
                                color: theme.colorScheme.onPrimaryContainer,
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: theme.textTheme.titleLarge),
                                const SizedBox(height: UtenSpacing.s4),
                                Text(
                                  subtitle,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s24),
                      child,
                    ],
                  ),
                ),
              ),
              if (actions.isNotEmpty) ...[
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(UtenSpacing.s16),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: UtenSpacing.s12,
                    runSpacing: UtenSpacing.s8,
                    children: actions,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class ColumnEditorSection extends StatelessWidget {
  const ColumnEditorSection({
    super.key,
    required this.title,
    this.description,
    required this.child,
  });
  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          if (description != null) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              description!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          child,
        ],
      ),
    );
  }
}

class ColumnEditorNotice extends StatelessWidget {
  const ColumnEditorNotice({
    super.key,
    required this.icon,
    required this.text,
    this.error = false,
  });
  final IconData icon;
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = error
        ? colors.onErrorContainer
        : colors.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: error ? colors.errorContainer : colors.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: error ? colors.error : colors.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: foreground),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: foreground),
            ),
          ),
        ],
      ),
    );
  }
}
