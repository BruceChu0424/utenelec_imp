// 模拟身份横幅：admin「切换人」后跨所有页面常驻，提示「正以谁的身份查看（只读）」
// + 居中剩余时间 + 切换/退出。挂在 app.dart 的 Column 顶部（占顶固定、把页面整体下推，
// 不再覆盖 AppBar/返回键），由 sessionProvider 驱动。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/session_event_bus.dart';
import '../../../core/router/app_router.dart';
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
      // 非模拟时无需倒计时刷新——会话变化由 ref.watch(sessionProvider) 自动重建。
      if (!s.isImpersonating) return;
      final exp = s.impersonationModeExpiresAt;
      if (exp != null && DateTime.now().isAfter(exp)) {
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
    final rawMinutes = expiresAt == null
        ? 0
        : expiresAt.difference(DateTime.now()).inMinutes;
    final remaining = rawMinutes < 0 ? 0 : rawMinutes;
    final name = user?.name ?? '';
    final sub = [
      user?.department,
      user?.position,
    ].whereType<String>().where((s) => s.isNotEmpty).join(' · ');
    final fg = theme.colorScheme.onErrorContainer;

    return Material(
      color: theme.colorScheme.errorContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          // 基层 Row：身份靠左 + 切换/退出靠右。名字用 Flexible 截断——按钮拿固有
          // 宽度永远完整（不会被挤掉/切半，修「有时显示一半」）。剩余时间用 Center
          // 覆盖层真·居中（胶囊非交互，点击穿透到下方按钮）。
          child: Stack(
            children: [
              Row(
                children: [
                  Icon(Icons.shield_rounded, color: fg, size: 20),
                  const SizedBox(width: 12),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          l10n.impersonationBannerTitle(name),
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: fg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (sub.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          Text(
                            sub,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: fg,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _switchToAnother,
                    style: TextButton.styleFrom(foregroundColor: fg),
                    child: Text(l10n.impersonationBannerSwitch),
                  ),
                  TextButton(
                    onPressed: _exitImpersonation,
                    style: TextButton.styleFrom(foregroundColor: fg),
                    child: Text(l10n.impersonationBannerExit),
                  ),
                ],
              ),
              // 覆盖层：剩余时间真·居中（无手势，点击穿透）
              Center(
                child: _RemainingTimePill(remaining: remaining, foreground: fg),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 「切换」到另一位员工。
  ///
  /// 必须用路由 Navigator 内的 context：横幅构建在 `MaterialApp.builder` 里、位于
  /// 路由 Navigator 之外，直接用横幅 context 调 `showDialog` / `context.go` 会取不到
  /// Navigator/GoRouter 而静默失败（曾经表现为点了没反应）。`appNavigatorKey`
  /// 指向根 Navigator，其 currentContext 即路由作用域内的合法 context。
  void _switchToAnother() {
    final navCtx = appNavigatorKey.currentContext;
    if (navCtx == null) return;
    openSwitchPerson(navCtx, ref);
  }

  /// 「退出模拟」：恢复 admin + 跳工作台 + 提示。跳转走 router 实例，不依赖横幅 context。
  Future<void> _exitImpersonation() async {
    final l10n = AppLocalizations.of(context);
    await ref.read(sessionProvider.notifier).endImpersonation();
    if (!mounted) return;
    ref.read(appRouterProvider).go('/dashboard');
    if (!mounted) return;
    context.appSuccess(l10n.impersonationExited);
  }
}

/// 居中的剩余时间胶囊（中栏）。≤3 分钟换计时结束图标提示临期。
class _RemainingTimePill extends StatelessWidget {
  const _RemainingTimePill({required this.remaining, required this.foreground});

  final int remaining;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final urgent = remaining <= 3;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            urgent ? Icons.timer_off_outlined : Icons.schedule_rounded,
            size: 14,
            color: foreground,
          ),
          const SizedBox(width: 4),
          Text(
            l10n.impersonationRemainingMinutes(remaining),
            style: theme.textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
