import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/gen/app_localizations.dart';
import '../network/connection_recovery.dart';
import 'uten_top_banner_card.dart';

/// One app-wide connection message with a single recovery action.
///
/// It deliberately avoids technical status codes and does not claim that a
/// reachability failure is a permission problem. The live region lets screen
/// readers announce state changes without moving keyboard focus.
class ConnectionRecoveryBanner extends ConsumerWidget {
  const ConnectionRecoveryBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(connectionRecoveryProvider);
    if (state.phase == ConnectionRecoveryPhase.connected) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final disableAnimations = MediaQuery.disableAnimationsOf(context);
    final (message, icon, background, foreground) = switch (state.phase) {
      ConnectionRecoveryPhase.reconnecting => (
        l10n.connectionReconnecting,
        Icons.sync_rounded,
        theme.colorScheme.secondaryContainer,
        theme.colorScheme.onSecondaryContainer,
      ),
      ConnectionRecoveryPhase.disconnected => (
        l10n.connectionDisconnected,
        Icons.cloud_off_outlined,
        theme.colorScheme.errorContainer,
        theme.colorScheme.onErrorContainer,
      ),
      ConnectionRecoveryPhase.restored => (
        l10n.connectionRestored,
        Icons.cloud_done_outlined,
        theme.colorScheme.tertiaryContainer,
        theme.colorScheme.onTertiaryContainer,
      ),
      ConnectionRecoveryPhase.connected => throw StateError(
        'Connected state is handled before rendering',
      ),
    };

    return AnimatedSwitcher(
      duration: disableAnimations
          ? Duration.zero
          : const Duration(milliseconds: 200),
      child: UtenTopBannerCard(
        key: ValueKey(state.phase),
        background: background,
        foreground: foreground,
        icon: icon,
        semanticLabel: message,
        progress: state.phase == ConnectionRecoveryPhase.reconnecting ||
            state.phase == ConnectionRecoveryPhase.disconnected,
        content: Text(
          message,
          style: theme.textTheme.bodyLarge?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: state.phase == ConnectionRecoveryPhase.disconnected
            ? OutlinedButton(
                key: const ValueKey('connection-recovery-retry'),
                onPressed: () => ref
                    .read(connectionRecoveryProvider.notifier)
                    .retryNow(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: foreground,
                  side: BorderSide(color: foreground),
                  minimumSize: const Size(0, 48),
                ),
                child: Text(l10n.connectionRetryNow),
              )
            : null,
      ),
    );
  }
}
