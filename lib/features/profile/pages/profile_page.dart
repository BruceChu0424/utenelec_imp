// ProfilePage - 我的页面（v4 — 去 AppBar 标题 + 角色徽章贴名 + 响应式分组）
// 文档：docs/03-页面/我的页.md
//
// 改造要点（vs v3）：
//   * 去掉顶部 UtenAppBar 标题，内容从状态栏下方开始，腾出首屏
//   * 角色徽章（员工 / HR / 管理员 …）紧贴名字右侧（一行 Wrap），
//     超级管理员显示实心 teal「ADMIN」，普通角色细边框中性 chip
//   * 响应式断点三档：
//       - compact (<600dp)：单列，padding 16
//       - medium  (600-840dp)：单列，padding 24，avatar 60
//       - expanded(≥840dp)：双列 max-width 1200；左 380「身份组」= Hero + 修改申请，
//         右 Expanded「档案组」= 基本信息
//   * 「我的修改申请」快捷入口贴 Hero 卡下方（属于本人身份组），
//     替代 v3 把它放到右侧栏底部被基础信息稀释的问题
//   * 按角色脱敏规则保持不变

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/role.dart';
import '../../../shared/models/user.dart';
import '../../../shared/providers/session_provider.dart';
import '../providers/profile_change_providers.dart';

class ProfilePage extends ConsumerWidget {
  const ProfilePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final session = ref.watch(sessionProvider);
    final user = session.user;
    final theme = Theme.of(context);

    if (user == null) {
      return const Scaffold(
        body: SafeArea(
          child: UtenEmpty(icon: Icons.person_outline, message: '—'),
        ),
      );
    }

    final bp = context.breakpoint;
    final horizontalPadding = bp.select<double>(
      compact: UtenSpacing.s16,
      medium: UtenSpacing.s24,
      expanded: UtenSpacing.s32,
    );

    final identityGroup = _buildIdentityGroup(context, ref, theme, l10n, user);
    final profileGroup = _buildProfileGroup(context, theme, l10n, user);

    return Scaffold(
      // 顶部无 AppBar：标题已由侧栏 / NavigationBar 高亮表达，
      // 节省首屏 56dp，主体内容直接顶到状态栏下方。
      body: SafeArea(
        bottom: false,
        child: switch (bp) {
          // ───── compact：单列垂直堆叠 ─────
          UtenBreakpoint.compact => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              UtenSpacing.s16,
              horizontalPadding,
              96, // 底部悬浮胶囊导航留白
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                identityGroup.hero,
                const SizedBox(height: UtenSpacing.s12),
                identityGroup.shortcut,
                const SizedBox(height: UtenSpacing.s24),
                profileGroup,
              ],
            ),
          ),

          // ───── medium：单列，但用更宽的内边距 + 更大头像 ─────
          UtenBreakpoint.medium => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              UtenSpacing.s24,
              horizontalPadding,
              96, // 底部悬浮胶囊导航留白
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    identityGroup.hero,
                    const SizedBox(height: UtenSpacing.s16),
                    identityGroup.shortcut,
                    const SizedBox(height: UtenSpacing.s24),
                    profileGroup,
                  ],
                ),
              ),
            ),
          ),

          // ───── expanded：双列靠左，左 380「身份组」+ 右 Expanded→≤720「档案组」 ─────
          // 不再 Center + maxWidth，让内容从左边 padding 直接起；
          // 右边 Expanded 吃掉 Row 剩余空间（视口自适应，无横向溢出），
          // 再用 ConstrainedBox(maxWidth: 720) 锁住信息行最大宽度（60-75 字符可读）。
          // ≥1196dp 浏览器时右列定宽 720 留白，是可读性设计取舍，不是溢出。
          UtenBreakpoint.expanded => SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontalPadding,
              UtenSpacing.s32,
              horizontalPadding,
              110, // 底部悬浮胶囊导航留白
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 380,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      identityGroup.hero,
                      const SizedBox(height: UtenSpacing.s16),
                      identityGroup.shortcut,
                    ],
                  ),
                ),
                const SizedBox(width: UtenSpacing.s32),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 720),
                      child: profileGroup,
                    ),
                  ),
                ),
              ],
            ),
          ),
        },
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 身份组：Hero 卡 + 我的修改申请
  // ─────────────────────────────────────────────────────────────
  _IdentityGroup _buildIdentityGroup(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    AppLocalizations l10n,
    AppUser user,
  ) {
    return _IdentityGroup(
      hero: _HeroCard(user: user, theme: theme, l10n: l10n),
      shortcut: _MyChangesShortcut(l10n: l10n),
    );
  }

  // ─────────────────────────────────────────────────────────────
  // 档案组：基本信息（按角色脱敏的字段列表）
  // ─────────────────────────────────────────────────────────────
  Widget _buildProfileGroup(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l10n,
    AppUser user,
  ) {
    return _section(l10n, l10n.profileTitle, [
      UtenInfoRow(
        label: l10n.profileEmployeeCode,
        value: user.code,
        showDivider: false,
      ),
      UtenInfoRow(label: l10n.profileChangeFieldFullName, value: user.name),
      UtenInfoRow(label: l10n.profileDepartment, value: user.department),
      UtenInfoRow(label: l10n.profilePosition, value: user.position),
      UtenInfoRow(label: l10n.profileFieldEmail, value: _notSet),
      UtenInfoRow(label: l10n.profileFieldOfficePhone, value: _notSet),
      UtenInfoRow(label: l10n.profileFieldSeatNo, value: _notSet),
      UtenInfoRow(label: l10n.profileFieldResidenceAddress, value: _notSet),
      UtenInfoRow(label: l10n.profileFieldHujiAddress, value: _notSet),
      UtenInfoRow(
        label: l10n.profileFieldEthnicity,
        value: _notSet,
        showDivider: false,
      ),
    ]);
  }

  static const _notSet = '—';

  Widget _section(AppLocalizations l10n, String title, List<Widget> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        UtenSectionHeader(title: title, subdued: true),
        const SizedBox(height: UtenSpacing.s8),
        UtenCard(
          padding: const EdgeInsets.symmetric(
            horizontal: UtenSpacing.s16,
            vertical: UtenSpacing.s4,
          ),
          child: Column(children: rows),
        ),
      ],
    );
  }
}

/// 把 Hero 卡 + 快捷入口包成一个结构体，避免 layout 里来回来回传参。
class _IdentityGroup {
  const _IdentityGroup({required this.hero, required this.shortcut});
  final Widget hero;
  final Widget shortcut;
}

/// 头部身份卡：头像 + 名字 + 角色 chip（一行）+ 部门职位 + 两个 CTA
class _HeroCard extends StatelessWidget {
  const _HeroCard({
    required this.user,
    required this.theme,
    required this.l10n,
  });

  final AppUser user;
  final ThemeData theme;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    // 大屏略放大头像，建立气场；保持 ≥44pt touch target 友好。
    final avatarSize = context.breakpoint.select<double>(
      compact: 56,
      medium: 60,
      expanded: 64,
    );
    final positionLabel = user.superAdmin
        ? '系统管理员（超级管理员）'
        : (user.position ?? '—');

    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              UtenUserAvatar(size: avatarSize, name: user.name),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 名字 + 角色徽章同行：用 Wrap 让长名字能换行时 chip 跟着换
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s4,
                      children: [
                        Text(
                          user.name,
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                        ),
                        ..._buildRoleChips(user, theme),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '${user.department ?? '—'} · $positionLabel',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          // CTA：修改我的信息 + 修改密码（全员可见；能改什么由编辑页字段策略定）
          Row(
            children: [
              Expanded(
                child: UtenButton(
                  size: UtenButtonSize.small,
                  icon: Icons.edit_outlined,
                  // go_router 14：从 /profile（ShellRoute 主 Tab）push /profile/edit 会静默失效
                  // （redirect 放行但路由未构造），改用 go；返回靠 AppBar ← 与提交后 pop。
                  onPressed: () => context.go(RouteName.profileEdit),
                  child: Text(l10n.profileChangeEditCta),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_outline_rounded,
                  onPressed: () => context.push(RouteName.changePassword),
                  child: Text(l10n.profileChangePassword),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 把角色渲染成紧贴名字的 chip。
  ///
  /// - superAdmin：实心 teal「ADMIN」徽章，最优先
  /// - 普通角色：≤2 个全展示；>2 显示前 2 +「+N」折叠
  List<Widget> _buildRoleChips(AppUser user, ThemeData theme) {
    final chips = <Widget>[];

    if (user.superAdmin) {
      chips.add(
        _RoleChip(
          label: 'ADMIN',
          icon: Icons.verified_rounded,
          background: UtenColors.teal500,
          foreground: Colors.white,
          theme: theme,
        ),
      );
    }

    const maxNormalRoles = 2;
    final roles = user.roles;
    final showRoles = roles.length > maxNormalRoles
        ? roles.take(maxNormalRoles).toList()
        : roles;
    for (final r in showRoles) {
      chips.add(
        _RoleChip(
          label: r.displayNameZh,
          icon: _iconForRole(r),
          outline: true,
          theme: theme,
        ),
      );
    }
    if (roles.length > maxNormalRoles) {
      chips.add(
        _RoleChip(
          label: '+${roles.length - maxNormalRoles}',
          outline: true,
          theme: theme,
          muted: true,
        ),
      );
    }
    return chips;
  }

  IconData _iconForRole(Role role) {
    switch (role) {
      case Role.admin:
        return Icons.admin_panel_settings_rounded;
      case Role.hr:
        return Icons.badge_rounded;
      case Role.finance:
        return Icons.account_balance_rounded;
      case Role.lab:
        return Icons.science_rounded;
      case Role.production:
        return Icons.factory_rounded;
      case Role.manager:
        return Icons.supervisor_account_rounded;
      case Role.security:
        return Icons.shield_rounded;
      case Role.employee:
        return Icons.person_rounded;
    }
  }
}

/// 角色徽章：支持实心（superAdmin）/ 描边（普通角色）/ 静音（折叠 +N）
class _RoleChip extends StatelessWidget {
  const _RoleChip({
    required this.label,
    required this.theme,
    this.icon,
    this.background,
    this.foreground,
    this.outline = false,
    this.muted = false,
  });

  final String label;
  final IconData? icon;
  final Color? background;
  final Color? foreground;
  final bool outline;
  final bool muted;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    final fg =
        foreground ??
        (muted
            ? theme.colorScheme.onSurfaceVariant
            : theme.colorScheme.primary);
    final bg =
        background ??
        (outline ? theme.colorScheme.surfaceContainer : Colors.transparent);

    final borderSide = outline
        ? BorderSide(color: theme.colorScheme.outlineVariant)
        : BorderSide.none;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: icon != null ? UtenSpacing.s8 : UtenSpacing.s12,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: UtenRadius.smAll,
        border: outline ? Border.fromBorderSide(borderSide) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: UtenSpacing.s4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}

/// 我的修改申请快捷入口：显示 pending 数 + 跳 /profile/me/changes。
class _MyChangesShortcut extends ConsumerWidget {
  const _MyChangesShortcut({required this.l10n});
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final async = ref.watch(
      myProfileChangesProvider((status: 'pending', page: 1)),
    );
    final count = async.maybeWhen(data: (page) => page.total, orElse: () => 0);

    return UtenCard(
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s4,
        ),
        leading: Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: UtenRadius.lgAll,
          ),
          child: Icon(
            Icons.assignment_outlined,
            size: 18,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        title: Text(
          l10n.profileChangeListTitle,
          style: theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          count > 0
              ? l10n.profilePendingBadge(count)
              : l10n.profileChangeListEmpty,
          style: TextStyle(
            color: count > 0
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
            fontWeight: count > 0 ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
        trailing: const Icon(Icons.chevron_right_rounded, size: 18),
        // 同上：主 Tab 前缀子路由用 go 不用 push。
        onTap: () => context.go(RouteName.profileMyChanges),
      ),
    );
  }
}
