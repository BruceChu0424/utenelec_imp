import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../l10n/gen/app_localizations.dart';
import '../network/connection_recovery.dart';
import '../router/route_names.dart';
import '../../features/disaster_recovery/disaster_recovery_text.dart';
import '../../shared/ai/page_context/ai_page_context.dart';

/// 全局连接状态横幅：占顶「下推」的通栏，与模拟身份横幅同一形态。
///
/// 单行布局：消息靠左、「运行与灾备」内联在消息后、重试独占右端；重连/断开时
/// 底部保留自动重连进度条；恢复后整条自动收起。不再以悬浮卡片叠在页面上——
/// 悬浮卡片会盖住页面自己的搜索框/标签页，且消息+链接+按钮竖排两行、图标悬在
/// 两行中间。
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
    final disconnected = state.phase == ConnectionRecoveryPhase.disconnected;

    final row = Row(
      children: [
        Icon(icon, size: 20, color: foreground),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            message,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        // 灾备入口紧跟消息（同一句话的延伸）；重试是唯一主操作，独占右端。
        if (disconnected) ...[
          const SizedBox(width: 4),
          TextButton(
            key: const ValueKey('connection-disaster-recovery'),
            onPressed: () => context.push(RouteName.disasterRecovery),
            style: TextButton.styleFrom(
              foregroundColor: foreground,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: Text(recoveryText(context, '运行与灾备')),
          ),
        ],
        const Spacer(),
        if (disconnected)
          OutlinedButton(
            key: const ValueKey('connection-recovery-retry'),
            onPressed: () =>
                ref.read(connectionRecoveryProvider.notifier).retryNow(),
            style: OutlinedButton.styleFrom(
              foregroundColor: foreground,
              side: BorderSide(color: foreground),
              // 视觉 40 高的紧凑按钮；MaterialTapTargetSize 默认 padded，
              // 命中区仍是 48。
              minimumSize: const Size(0, 40),
            ),
            child: Text(l10n.connectionRetryNow),
          ),
      ],
    );

    Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 48),
          alignment: Alignment.center,
          padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
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
