// ProfilePage - 我的页面（v3 — 丰满字段 + 删除"账号与设置"卡）
// 文档：docs/03-页面/我的页.md
//
// 改造要点：
//   * 删除"账号与设置"卡（设置入口统一到 /settings）
//   * 字段丰满：基本信息 + 联系 + 组织 + 紧急联系人 + 入职
//   * 按角色脱敏：薪资 / 银行 仅 HR/admin；手机 本人全量，他人脱敏
//   * 加 2 个 CTA：「修改我的信息」「修改密码」
//   * "我的修改申请"快捷入口：跳 /profile/me/changes

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_user_avatar.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/permissions.dart';
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
    final canEdit = ref.watch(currentPermissionsProvider).contains(Perm.profileEditSelf);

    return Scaffold(
      appBar: UtenAppBar(title: l10n.profileTitle),
      body: user == null
          ? const UtenEmpty(icon: Icons.person_outline, message: '—')
          : LayoutBuilder(
              builder: (context, constraints) {
                final bp = context.breakpoint;
                final isWide = bp.atLeastMedium;

                final left = _buildLeftColumn(context, theme, l10n, user, canEdit);
                final right = _buildRightColumn(context, ref, theme, l10n, user);

                if (isWide) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 1400),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 360, child: left),
                          const SizedBox(width: 24),
                          Expanded(child: right),
                        ],
                      ),
                    ),
                  );
                }

                return SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [left, const SizedBox(height: 16), right],
                  ),
                );
              },
            ),
    );
  }

  /// 左栏：Hero + CTA + 应用设置（删除原"账号与设置"卡）
  Widget _buildLeftColumn(
    BuildContext context,
    ThemeData theme,
    AppLocalizations l10n,
    AppUser user,
    bool canEdit,
  ) {
    final isSuperAdmin = user.superAdmin;
    final positionLabel = isSuperAdmin
        ? '系统管理员（超级管理员）'
        : (user.position ?? '—');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hero 用户卡
        UtenCard(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  UtenUserAvatar(size: 56, name: user.name),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                user.name ?? '—',
                                style: theme.textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            if (isSuperAdmin) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Text(
                                  'SUPER',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
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
              if (user.roles.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: user.roles
                      .map<Widget>((r) => Container(
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
                          ))
                      .toList(),
                ),
              ],
              const SizedBox(height: 16),
              // CTA 按钮：修改我的信息 / 修改密码
              Row(
                children: [
                  if (canEdit)
                    Expanded(
                      child: UtenButton(
                        type: UtenButtonType.primary,
                        size: UtenButtonSize.small,
                        icon: Icons.edit_outlined,
                        onPressed: () => context.push(RouteName.profileEdit),
                        child: Text(l10n.profileChangeEditCta),
                      ),
                    ),
                  if (canEdit) const SizedBox(width: 8),
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
        ),
      ],
    );
  }

  /// 右栏：基本信息 + 联系 + 组织 + 紧急联系人 + 我的修改申请
  Widget _buildRightColumn(
    BuildContext context,
    WidgetRef ref,
    ThemeData theme,
    AppLocalizations l10n,
    AppUser user,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _section(l10n, theme, l10n.profileTitle, [
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
          UtenInfoRow(label: l10n.profileFieldEthnicity, value: _notSet, showDivider: false),
        ]),

        const SizedBox(height: 16),
        // 我的修改申请快捷入口
        _MyChangesShortcut(l10n: l10n),
      ],
    );
  }

  static const _notSet = '—';

  Widget _section(
    AppLocalizations l10n,
    ThemeData theme,
    String title,
    List<Widget> rows,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
        ),
        const SizedBox(height: 8),
        UtenCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(children: rows),
        ),
      ],
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
    final async = ref.watch(myProfileChangesProvider('pending'));
    final count = async.maybeWhen(
      data: (page) => page.total,
      orElse: () => 0,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            l10n.profileChangeListTitle,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
        ),
        const SizedBox(height: 8),
        UtenCard(
          child: ListTile(
            leading: Icon(
              Icons.assignment_outlined,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            title: Text(l10n.profileChangeListTitle),
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
            onTap: () => context.push(RouteName.profileMyChanges),
          ),
        ),
      ],
    );
  }
}