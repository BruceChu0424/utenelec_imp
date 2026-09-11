// 入口选择页（登录前）：内部人员 / 访客。
// v2：响应式入口卡片网格——UtenContentContainer.narrow 收敛 +
// UtenResponsiveGrid（compact 1 列 / medium+ 2 列），
// 统一卡片设计（teal 图标容器 + 标题 + 副标题 + chevron）。
// 页面底与登录页同款（浅色 teal50 / 深色 darkBackground，窄屏同样生效），
// 底部固定版权行（与登录页同款文案，年份动态）。
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/brand/uten_wordmark_logo.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';

class EntrySelectionPage extends StatelessWidget {
  const EntrySelectionPage({super.key, this.returnTo});

  final String? returnTo;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // 品牌锁版按断点放大（窄屏 280 / 大屏 360），入口页以品牌识别为主视觉
    final logoWidth = context.breakpoint.isCompact ? 280.0 : 360.0;

    return Scaffold(
      // 页面底与内部人员登录页同款：浅色 teal 调 / 深色 darkBackground（窄屏同样生效）
      backgroundColor: isDark ? UtenColors.darkBackground : UtenColors.teal50,
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: LayoutBuilder(
                builder: (context, c) {
                  return SingleChildScrollView(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(minHeight: c.maxHeight),
                      child: Center(
                        child: UtenContentContainer.narrow(
                          padding: const EdgeInsets.symmetric(
                            vertical: UtenSpacing.s32,
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              UtenWordmarkLogo(
                                width: logoWidth,
                                height: logoWidth / (405 / 74),
                              ),
                              const SizedBox(height: UtenSpacing.s32),
                              // 两张入口卡片：限宽 720，避免宽屏下卡片被拉得过长
                              ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 720,
                                ),
                                child: UtenResponsiveGrid(
                                  itemCount: 2,
                                  columns: const UtenResponsiveColumns(
                                    expanded: 2,
                                  ),
                                  itemBuilder: (context, i, itemWidth) {
                                    final entries = [
                                      (
                                        icon: Icons.badge_rounded,
                                        title: l10n.entryStaff,
                                        subtitle: '员工工号登录，进入工作台',
                                        location: RoutePath.login(
                                          returnTo: returnTo,
                                        ),
                                      ),
                                      (
                                        icon: Icons.qr_code_2_rounded,
                                        title: l10n.entryVisitor,
                                        subtitle: '访客扫码登记，快速通行',
                                        location: RoutePath.visitorLogin(
                                          returnTo: returnTo,
                                        ),
                                      ),
                                    ];
                                    final e = entries[i];
                                    return _EntryCard(
                                      icon: e.icon,
                                      title: e.title,
                                      subtitle: e.subtitle,
                                      onTap: () => context.go(e.location),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // 底部版权：与登录页同款文案，年份随当前时间自动前进
            Padding(
              padding: const EdgeInsets.only(
                left: UtenSpacing.s24,
                right: UtenSpacing.s24,
                bottom: UtenSpacing.s16,
              ),
              child: Text(
                l10n.loginFooter(DateTime.now().year),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 入口卡片：teal 图标容器 + 标题 + 副标题 + chevron
class _EntryCard extends StatelessWidget {
  const _EntryCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return UtenCard(
      onTap: onTap,
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isDark
                  ? UtenColors.teal900.withValues(alpha: 0.4)
                  : UtenColors.tealSurface,
              borderRadius: UtenRadius.lgAll,
            ),
            child: Icon(
              icon,
              size: 22,
              color: isDark ? UtenColors.teal400 : UtenColors.teal600,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.4,
                    color: theme.colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  subtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Icon(
            Icons.chevron_right_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ],
      ),
    );
  }
}
