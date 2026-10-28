import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/gen/app_localizations.dart';
import '../network/connection_recovery.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

/// 全局连接状态横幅：占顶「下推」的通栏，与模拟身份横幅同一形态。
///
/// 状态图标与文案整组居中，窄屏或大字号下文案居中换行。
/// 连接恢复由公共控制器自动重试，横幅只展示状态。
/// 重连/断开时底部保留自动重连进度条，恢复后整条自动收起。
///
/// 文案刻意避开技术状态码，也不把可达性失败说成权限问题。liveRegion 让读屏
/// 在状态变化时播报而不挪动键盘焦点。
class ConnectionRecoveryBanner extends ConsumerWidget {
  const ConnectionRecoveryBanner({super.key, this.useSafeArea = true});

  final bool useSafeArea;

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
    final row = Row(
      key: const ValueKey('connection-recovery-message-group'),
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(icon, size: 20, color: foreground),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            message,
            key: const ValueKey('connection-recovery-message'),
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          child: row,
        ),
        if (state.phase == ConnectionRecoveryPhase.reconnecting ||
            state.phase == ConnectionRecoveryPhase.disconnected)
          LinearProgressIndicator(
            minHeight: 3,
            color: foreground,
            backgroundColor: Colors.transparent,
          ),
      ],
    );
    // 移动端让横幅底色铺到状态栏后面，内容再避开刘海/状态栏。
    content = useSafeArea ? SafeArea(bottom: false, child: content) : content;

    return AiPageRegistrar(
      source: AiNoticeSource(kind: AiNoticeKind.banner, text: message),
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
            child: content,
          ),
        ),
      ),
    );
  }
}
