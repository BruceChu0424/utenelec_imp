import 'package:flutter/material.dart';

import '../../core/theme/uten_colors.dart';
import '../../core/theme/uten_tokens.dart';

enum ClientPublishTone { neutral, success, attention, active }

/// Shared queue/ledger status presentation; lifecycle decisions stay in the queue.
class ClientPublishStatus extends StatelessWidget {
  const ClientPublishStatus(
    this.label, {
    super.key,
    this.tone = ClientPublishTone.neutral,
  });
  final String label;
  final ClientPublishTone tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final foreground = switch (tone) {
      ClientPublishTone.success || ClientPublishTone.active => colors.primary,
      ClientPublishTone.attention =>
        dark ? UtenColors.onBroadcastContainerDark : UtenColors.warningText,
      ClientPublishTone.neutral => colors.onSurfaceVariant,
    };
    final background = switch (tone) {
      ClientPublishTone.success ||
      ClientPublishTone.active => colors.primary.withValues(alpha: 0.08),
      ClientPublishTone.attention =>
        dark ? UtenColors.broadcastContainerDark : UtenColors.warningBg,
      ClientPublishTone.neutral => colors.surfaceContainerLow,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s4,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.pillAll,
      ),
      child: Text(
        label,
        style: theme.textTheme.labelMedium?.copyWith(color: foreground),
      ),
    );
  }
}

class ClientPublishSectionHeading extends StatelessWidget {
  const ClientPublishSectionHeading({
    super.key,
    required this.title,
    required this.icon,
    this.description,
  });
  final String title;
  final IconData icon;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s2),
          child: Icon(
            icon,
            size: UtenSpacing.s20,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(width: UtenSpacing.s12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.textTheme.titleMedium),
              if (description != null) ...[
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  description!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
