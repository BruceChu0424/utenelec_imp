import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/gen/app_localizations.dart';
import '../network/connection_recovery.dart';

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

    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: message,
            child: AnimatedSwitcher(
              duration: disableAnimations
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              child: Material(
                key: ValueKey(state.phase),
                color: background,
                elevation: 4,
                shadowColor: theme.colorScheme.shadow.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(14),
                clipBehavior: Clip.antiAlias,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 10, 10, 10),
                      child: Row(
                        children: [
                          Icon(icon, color: foreground, size: 24),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              message,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: foreground,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (state.phase ==
                              ConnectionRecoveryPhase.disconnected) ...[
                            const SizedBox(width: 8),
                            OutlinedButton(
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
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (state.phase == ConnectionRecoveryPhase.reconnecting ||
                        state.phase == ConnectionRecoveryPhase.disconnected)
                      LinearProgressIndicator(
                        minHeight: 3,
                        color: foreground,
                        backgroundColor: Colors.transparent,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
