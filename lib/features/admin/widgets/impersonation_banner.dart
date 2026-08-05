// 模拟身份横幅：跨所有页面常驻，提示「正以谁的身份查看（只读）」+ 剩余时间 + 切换/退出。
// 挂在 app.dart 的 Stack 顶层（与 ConnectionRecoveryBanner 同位），由 sessionProvider 驱动。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/session_event_bus.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/session_provider.dart';
import 'impersonation_actions.dart';

class ImpersonationBanner extends ConsumerStatefulWidget {
  const ImpersonationBanner({super.key});

  @override
  ConsumerState<ImpersonationBanner> createState() =>
      _ImpersonationBannerState();
}

class _ImpersonationBannerState extends ConsumerState<ImpersonationBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // 倒计时每 30s 刷新一次「剩余分钟」；窗口到期则主动触发恢复 admin
    //（覆盖用户不发任何请求、光停在页面上的情形）。
    _tick = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      final s = ref.read(sessionProvider);
      final exp = s.impersonationModeExpiresAt;
      if (s.isImpersonating &&
          exp != null &&
          DateTime.now().isAfter(exp)) {
        SessionEventBus.instance.impersonationExpired();
      }
      setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionProvider);
    if (!session.isImpersonating) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final user = session.user;
    final expiresAt = session.impersonationModeExpiresAt;
    final remaining = expiresAt == null
        ? 0
        : (expiresAt.difference(DateTime.now()).inMinutes < 0
            ? 0
            : expiresAt.difference(DateTime.now()).inMinutes);
    final name = user?.name ?? '';
    final sub = [user?.department, user?.position]
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .join(' · ');
    final fg = theme.colorScheme.onErrorContainer;

    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          child: Row(
            children: [
              Icon(Icons.shield_rounded, color: fg, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      l10n.impersonationBannerTitle(name),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: fg,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (sub.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        sub,
                        style: theme.textTheme.labelSmall?.copyWith(color: fg),
                      ),
                    ],
                    Text(
                      l10n.impersonationRemainingMinutes(remaining),
                      style: theme.textTheme.labelSmall?.copyWith(color: fg),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => openSwitchPerson(context, ref),
                style: TextButton.styleFrom(foregroundColor: fg),
                child: Text(l10n.impersonationBannerSwitch),
              ),
              TextButton(
                onPressed: () async {
                  await ref.read(sessionProvider.notifier).endImpersonation();
                  if (context.mounted) {
                    context.appSuccess(l10n.impersonationExited);
                    context.go('/dashboard');
                  }
                },
                style: TextButton.styleFrom(foregroundColor: fg),
                child: Text(l10n.impersonationBannerExit),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
