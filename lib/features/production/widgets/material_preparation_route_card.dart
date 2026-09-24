import 'package:flutter/material.dart';

import '../../../components/feedback/uten_in_progress_badge.dart';
import '../../../components/feedback/uten_notification_badge.dart';
import '../../../core/theme/uten_tokens.dart';

/// Compact preparation entry using the same count badges as the workbench.
class MaterialPreparationRouteCard extends StatelessWidget {
  const MaterialPreparationRouteCard({
    super.key,
    required this.routeId,
    required this.title,
    this.compactTitle,
    required this.hint,
    required this.icon,
    required this.inProgressLabel,
    required this.pendingLabel,
    required this.inProgressCount,
    required this.pendingCount,
    required this.onOpen,
    required this.onInProgress,
    required this.onPending,
  });

  final String routeId;
  final String title;
  final String? compactTitle;
  final String hint;
  final IconData icon;
  final String inProgressLabel;
  final String pendingLabel;
  final int inProgressCount;
  final int pendingCount;
  final VoidCallback? onOpen;
  final VoidCallback? onInProgress;
  final VoidCallback? onPending;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.controlAll,
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: Key('material-analysis-entry-$routeId'),
        onTap: onOpen,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: scheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Tooltip(
                    message: '$title。$hint',
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final style = theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        );
                        final measure = TextPainter(
                          text: TextSpan(text: title, style: style),
                          textDirection: Directionality.of(context),
                          textScaler: MediaQuery.textScalerOf(context),
                          maxLines: 1,
                        )..layout();
                        final label = measure.width > constraints.maxWidth
                            ? compactTitle ?? title
                            : title;
                        measure.dispose();
                        return Text(
                          label,
                          semanticsLabel: title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style,
                        );
                      },
                    ),
                  ),
                ),
                if (inProgressCount > 0 || pendingCount > 0)
                  const SizedBox(width: UtenSpacing.s8),
                // Same dimensions and scaling as WorkbenchCardBadge.
                UtenBadgeScale(
                  scale: 1.25,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (inProgressCount > 0)
                        _badgeAction(
                          status: 'in-progress',
                          label: inProgressLabel,
                          count: inProgressCount,
                          onTap: onInProgress,
                          child: UtenInProgressBadge(
                            count: inProgressCount,
                            size: 20,
                            showLabel: true,
                          ),
                        ),
                      if (inProgressCount > 0 && pendingCount > 0)
                        const SizedBox(width: UtenSpacing.s4),
                      if (pendingCount > 0)
                        _badgeAction(
                          status: 'pending',
                          label: pendingLabel,
                          count: pendingCount,
                          onTap: onPending,
                          child: UtenNotificationBadge(
                            count: pendingCount,
                            size: 20,
                            showLabel: true,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badgeAction({
    required String status,
    required String label,
    required int count,
    required VoidCallback? onTap,
    required Widget child,
  }) {
    return Tooltip(
      message: '$label $count 项',
      excludeFromSemantics: true,
      child: Semantics(
        label: '$title，$label $count',
        button: true,
        enabled: onTap != null,
        onTap: onTap,
        child: InkWell(
          key: Key('material-analysis-entry-$routeId-$status'),
          onTap: onTap,
          excludeFromSemantics: true,
          borderRadius: UtenRadius.controlAll,
          child: ExcludeSemantics(
            child: ConstrainedBox(
              constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
              child: Center(widthFactor: 1, heightFactor: 1, child: child),
            ),
          ),
        ),
      ),
    );
  }
}
