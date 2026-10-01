import 'package:flutter/material.dart';

import '../../core/l10n/gen/app_localizations.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/capsule_nav_metrics.dart';
import '../buttons/click_guard.dart';
import 'uten_bottom_action_bar.dart';

/// The draft status owns layout space; it never floats over business actions.
/// Stable child ancestry preserves text controllers/focus as the status changes.
class UtenDraftStatusLayout extends StatelessWidget {
  const UtenDraftStatusLayout({
    super.key,
    required this.status,
    required this.isError,
    required this.child,
    this.onRetry,
  });

  final String status;
  final bool isError;
  final Widget child;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final visible = status.isNotEmpty;
    final keyboard = visible ? MediaQuery.viewInsetsOf(context).bottom : 0.0;
    final capsule = UtenCapsuleNavScope.occlusionOf(context);
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: visible,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final content = UtenCapsuleNavScope(
              // The footer already consumes this scope's lower safe space.
              occlusion: visible ? 0 : capsule,
              child: child,
            );
            final theme = Theme.of(context);
            final textHeight = constraints.hasBoundedHeight
                ? (constraints.maxHeight / 3).clamp(UtenSpacing.s48, 160.0)
                : 160.0;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (constraints.hasBoundedHeight)
                  Flexible(child: content)
                else
                  content,
                if (visible)
                  UtenBottomActionBar(
                    key: const Key('form-draft-status-bar'),
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s16,
                      vertical: UtenSpacing.s4,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: textHeight),
                            child: SingleChildScrollView(
                              child: Semantics(
                                liveRegion: isError,
                                child: Text(
                                  status,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: isError
                                        ? theme.colorScheme.error
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        if (onRetry != null) ...[
                          const SizedBox(width: UtenSpacing.s8),
                          UtenActionButton(
                            key: const Key('form-draft-save-retry'),
                            type: UtenActionButtonType.secondary,
                            size: UtenActionButtonSize.small,
                            onAction: onRetry!,
                            label: Text(
                              Localizations.of<AppLocalizations>(
                                    context,
                                    AppLocalizations,
                                  )?.commonRetry ??
                                  '重试',
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
