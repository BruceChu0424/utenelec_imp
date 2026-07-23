// ProfilePage - 我的页面（v2 - 大厂范）
// 文档：docs/03-页面/我的页.md
//
// 设计：中性卡 + 品牌色点缀（头像方块用渐变）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../shared/models/user.dart';
import '../../../shared/providers/session_provider.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionProvider);
    final user = session.user;
    final theme = Theme.of(context);

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bp = context.breakpoint;
          final isWide = bp.atLeastMedium;

          final leftColumn = _buildLeftColumn(theme, user);
          final rightColumn = _buildRightColumn(context, theme, l10n, user);

          if (isWide) {
            // 大屏：左右双栏，占满宽度
            return SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1400),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 左栏：用户卡 + 快捷入口（约 360 固定宽）
                    SizedBox(width: 360, child: leftColumn),
                    const SizedBox(width: 24),
                    // 右栏：详细信息 + 设置（占满剩余）
                    Expanded(child: rightColumn),
                  ],
                ),
              ),
            );
          }

          // 小屏：单栏
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [leftColumn, const SizedBox(height: 16), rightColumn],
            ),
          );
        },
      ),
    );
  }

  /// 左栏：用户卡 + 快捷入口
  Widget _buildLeftColumn(ThemeData theme, AppUser? user) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 用户卡
        UtenCard(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              UtenUserAvatar(size: 56, name: user?.name),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?.name ?? '—',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${user?.department ?? '—'} · ${user?.position ?? '—'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      children: user != null
                          ? user.roles.map<Widget>((r) {
                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.surfaceContainer,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: theme.colorScheme.outlineVariant,
                                  ),
                                ),
                                child: Text(
                                  r.displayNameZh,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              );
                            }).toList()
                          : [],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // 快捷入口
        const _QuickEntries(),
      ],
    );
  }

  /// 右栏：信息详情 + 设置入口 + 版本号
  Widget _buildRightColumn(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l10n,
    AppUser? user,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 信息详情
        const _SectionLabel(label: '个人信息'),
        const SizedBox(height: 8),
        UtenCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _InfoTile(
                icon: Icons.badge_outlined,
                label: l10n.profileEmployeeCode,
                value: user?.code ?? '—',
              ),
              const Divider(height: 1, indent: 56),
              _InfoTile(
                icon: Icons.groups_outlined,
                label: l10n.profileDepartment,
                value: user?.department ?? '—',
              ),
              const Divider(height: 1, indent: 56),
              _InfoTile(
                icon: Icons.work_outline_rounded,
                label: l10n.profilePosition,
                value: user?.position ?? '—',
              ),
              const Divider(height: 1, indent: 56),
              _InfoTile(
                icon: Icons.phone_outlined,
                label: '联系电话',
                value: user != null ? '138****1234' : '—',
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        // 设置入口
        const _SectionLabel(label: '账号与设置'),
        const SizedBox(height: 8),
        UtenCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              _NavTile(
                icon: Icons.settings_outlined,
                label: '应用设置',
                description: '主题、语言、字号、性能档',
                onTap: () => context.go(RouteName.settings),
              ),
              const Divider(height: 1, indent: 56),
              _NavTile(
                icon: Icons.lock_outline_rounded,
                label: '修改密码',
                onTap: () {},
              ),
              const Divider(height: 1, indent: 56),
              _NavTile(
                icon: Icons.help_outline_rounded,
                label: '帮助与反馈',
                onTap: () {},
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'Uten IMP v0.1.0',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(height: 20),
      ],
    );
  }
}

/// 区块标题
class _SectionLabel extends StatelessWidget {
  const _SectionLabel({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _QuickEntries extends StatelessWidget {
  const _QuickEntries();

  @override
  Widget build(BuildContext context) {
    final entries = <_Entry>[
      const _Entry(
        icon: Icons.account_balance_wallet_rounded,
        label: '工资条',
        color: UtenColors.teal600,
        path: RouteName.payrollSlipList,
      ),
      const _Entry(
        icon: Icons.receipt_long_rounded,
        label: '我的报销',
        color: UtenColors.info,
        path: RouteName.expense,
      ),
      const _Entry(
        icon: Icons.campaign_rounded,
        label: '公司通知',
        color: UtenColors.warning,
        path: RouteName.notice,
      ),
      const _Entry(
        icon: Icons.lightbulb_outline_rounded,
        label: '建议箱',
        color: UtenColors.success,
        path: RouteName.suggestion,
      ),
    ];

    return UtenCard(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          for (final e in entries) ...[
            Expanded(child: _EntryTile(entry: e)),
            if (e != entries.last)
              Container(
                width: 1,
                height: 32,
                color: Theme.of(context).dividerColor,
              ),
          ],
        ],
      ),
    );
  }
}

class _Entry {
  const _Entry({
    required this.icon,
    required this.label,
    required this.color,
    required this.path,
  });
  final IconData icon;
  final String label;
  final Color color;
  final String path;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});
  final _Entry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => context.go(entry.path),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: entry.color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(entry.icon, color: entry.color, size: 18),
              ),
              const SizedBox(height: 8),
              Text(
                entry.label,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
      title: Text(label),
      trailing: Text(
        value,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    this.description,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final String? description;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      type: MaterialType.transparency,
      child: ListTile(
        onTap: onTap,
        leading: Icon(
          icon,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        title: Text(label),
        subtitle: description != null
            ? Text(
                description!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            : null,
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
      ),
    );
  }
}
