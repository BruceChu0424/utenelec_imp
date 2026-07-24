// AdminUserDetailPanel - 员工权限详情面板
//
// 三段：
//   1. 账号：姓名/工号/部门/状态 + 锁定/解锁/停用/启用/重置密码（危险操作二次确认）
//   2. 角色分配：角色多选 chip + 保存（PUT /admin/users/{id}/roles）
//   3. 个人权限覆盖：按 category 折叠分组的权限矩阵，三态（继承/加授/回收）
//      + 有效权限着色（有效=绿 / 回收=红 / 无关=灰）
//
// 有效权限计算（前端本地算）：
//   rolePerms = 用户直接角色 ∪ 其部门配置角色 的 permissions 并集
//   effective = rolePerms ∪ grants − revokes
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../core/theme/uten_colors.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import '../pages/admin_permissions_page.dart' show AccountStatusBadge;

/// 权限覆盖三态。
enum _OverrideState { inherit, grant, revoke }

class AdminUserDetailPanel extends ConsumerStatefulWidget {
  const AdminUserDetailPanel({
    super.key,
    required this.user,
    required this.onAccountChanged,
    this.showBack = false,
    this.onBack,
  });

  final AdminUserSummary user;

  /// 账号操作（锁定/启停/重置密码/角色保存）成功后回调，用于刷新列表。
  final VoidCallback onAccountChanged;

  final bool showBack;
  final VoidCallback? onBack;

  @override
  ConsumerState<AdminUserDetailPanel> createState() =>
      _AdminUserDetailPanelState();
}

class _AdminUserDetailPanelState extends ConsumerState<AdminUserDetailPanel> {
  late Set<String> _selectedRoles = widget.user.roles.toSet();

  /// permCode → 三态（grants→加授，revokes→回收，其余→继承）
  Map<String, _OverrideState> _overrides = {};
  bool _overridesLoading = true;
  bool _savingRoles = false;
  bool _savingOverrides = false;
  bool _acting = false;

  @override
  void initState() {
    super.initState();
    _loadOverrides();
  }

  @override
  void didUpdateWidget(covariant AdminUserDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 列表刷新后 user.roles 可能变化：同步角色选择
    if (oldWidget.user.roles.join() != widget.user.roles.join()) {
      _selectedRoles = widget.user.roles.toSet();
    }
  }

  Future<void> _loadOverrides() async {
    try {
      final o = await ref
          .read(adminRepositoryProvider)
          .getUserPermOverrides(widget.user.id);
      if (!mounted) return;
      setState(() {
        _overrides = {
          for (final c in o.grants) c: _OverrideState.grant,
          for (final c in o.revokes) c: _OverrideState.revoke,
        };
        _overridesLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _overridesLoading = false);
      UtenToast.error(context, '加载权限覆盖失败');
    }
  }

  // ===== 账号操作 =====

  Future<void> _runAccountAction({
    required String label,
    required bool danger,
    required Future<void> Function(AdminRepository repo) call,
  }) async {
    final confirmed = await UtenDialog.show(
      context,
      title: '$label确认',
      content: Text(
        '确定要对「${widget.user.employeeName ?? widget.user.loginAccount}」执行「$label」吗？',
      ),
      confirmLabel: label,
      danger: danger,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      await call(ref.read(adminRepositoryProvider));
      if (!mounted) return;
      UtenToast.success(context, '$label成功');
      widget.onAccountChanged();
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '$label失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  // ===== 角色保存 =====

  Future<void> _saveRoles() async {
    setState(() => _savingRoles = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateUserRoles(widget.user.id, _selectedRoles.toList());
      if (!mounted) return;
      UtenToast.success(context, '角色已保存');
      widget.onAccountChanged();
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存角色失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingRoles = false);
    }
  }

  // ===== 覆盖保存 =====

  Future<void> _saveOverrides() async {
    setState(() => _savingOverrides = true);
    try {
      final grants = <String>[];
      final revokes = <String>[];
      _overrides.forEach((code, state) {
        if (state == _OverrideState.grant) grants.add(code);
        if (state == _OverrideState.revoke) revokes.add(code);
      });
      await ref
          .read(adminRepositoryProvider)
          .updateUserPermOverrides(
            widget.user.id,
            grants: grants,
            revokes: revokes,
          );
      if (!mounted) return;
      UtenToast.success(context, '权限覆盖已保存');
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存覆盖失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rolesAsync = ref.watch(adminRolesProvider);
    final permsAsync = ref.watch(adminPermissionsProvider);
    final deptRolesAsync = ref.watch(adminDepartmentRolesProvider);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
      children: [
        if (widget.showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: widget.onBack,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('返回列表'),
            ),
          ),
        _accountSection(),
        const SizedBox(height: 12),
        _rolesSection(rolesAsync),
        const SizedBox(height: 12),
        _overridesSection(rolesAsync, permsAsync, deptRolesAsync),
      ],
    );
  }

  // ===== 段 1：账号 =====

  Widget _accountSection() {
    final theme = Theme.of(context);
    final u = widget.user;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '账号',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              AccountStatusBadge(status: u.status),
            ],
          ),
          const SizedBox(height: 12),
          _infoRow('姓名', u.employeeName ?? '—'),
          _infoRow('工号', u.employeeCode ?? '—'),
          _infoRow('部门', u.departmentName ?? '—'),
          _infoRow('登录账号', u.loginAccount),
          _infoRow('上次登录', u.lastLoginAt ?? '—'),
          if (u.mustChangePassword)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '该账号已被要求下次登录修改密码',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: UtenColors.warning,
                ),
              ),
            ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (u.status == 'active')
                UtenButton(
                  type: UtenButtonType.ghost,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_outline_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '锁定',
                    danger: true,
                    call: (r) => r.lockUser(u.id),
                  ),
                  child: const Text('锁定'),
                ),
              if (u.status == 'locked')
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_open_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '解锁',
                    danger: false,
                    call: (r) => r.unlockUser(u.id),
                  ),
                  child: const Text('解锁'),
                ),
              if (u.status != 'disabled')
                UtenButton(
                  type: UtenButtonType.danger,
                  size: UtenButtonSize.small,
                  icon: Icons.block_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '停用',
                    danger: true,
                    call: (r) => r.disableUser(u.id),
                  ),
                  child: const Text('停用'),
                ),
              if (u.status == 'disabled')
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.play_circle_outline_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '启用',
                    danger: false,
                    call: (r) => r.enableUser(u.id),
                  ),
                  child: const Text('启用'),
                ),
              UtenButton(
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                icon: Icons.key_rounded,
                isLoading: _acting,
                onPressed: () => _runAccountAction(
                  label: '重置密码',
                  danger: true,
                  call: (r) => r.resetPassword(u.id),
                ),
                child: const Text('重置密码'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodyMedium,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // ===== 段 2：角色分配 =====

  Widget _rolesSection(AsyncValue<List<AdminRole>> rolesAsync) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '角色分配',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 10),
          rolesAsync.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => _loadError('角色加载失败'),
            data: (roles) {
              if (roles.isEmpty) {
                return Text(
                  '暂无可分配角色',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                );
              }
              return Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final role in roles)
                    FilterChip(
                      selected: _selectedRoles.contains(role.code),
                      onSelected: (v) {
                        setState(() {
                          if (v) {
                            _selectedRoles.add(role.code);
                          } else {
                            _selectedRoles.remove(role.code);
                          }
                        });
                      },
                      label: Text(
                        role.code == 'admin'
                            ? '${role.name}（仅管理员可授予）'
                            : role.name,
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: UtenButton(
              size: UtenButtonSize.small,
              isLoading: _savingRoles,
              onPressed: _saveRoles,
              child: const Text('保存角色'),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 段 3：个人权限覆盖 =====

  Widget _overridesSection(
    AsyncValue<List<AdminRole>> rolesAsync,
    AsyncValue<List<AdminPermission>> permsAsync,
    AsyncValue<List<DepartmentRoleEntry>> deptRolesAsync,
  ) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '个人权限覆盖',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '在角色/部门继承的基础上，对单个权限点加授或回收。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          if (_overridesLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            _permMatrix(rolesAsync, permsAsync, deptRolesAsync),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerRight,
            child: UtenButton(
              size: UtenButtonSize.small,
              isLoading: _savingOverrides,
              onPressed: _overridesLoading ? null : _saveOverrides,
              child: const Text('保存覆盖'),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '权限变更将在该用户下次登录或令牌刷新后生效',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _permMatrix(
    AsyncValue<List<AdminRole>> rolesAsync,
    AsyncValue<List<AdminPermission>> permsAsync,
    AsyncValue<List<DepartmentRoleEntry>> deptRolesAsync,
  ) {
    final roles = rolesAsync.valueOrNull;
    final perms = permsAsync.valueOrNull;
    final deptRoles = deptRolesAsync.valueOrNull;
    if (rolesAsync.hasError || permsAsync.hasError || deptRolesAsync.hasError) {
      return _loadError('权限数据加载失败');
    }
    if (roles == null || perms == null || deptRoles == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (perms.isEmpty) {
      return _loadError('暂无权限点');
    }

    // ===== 有效权限计算 =====
    // rolePerms = 用户直接角色 ∪ 其部门配置角色 的 permissions 并集
    // effective = rolePerms ∪ grants − revokes
    final roleByCode = {for (final r in roles) r.code: r};
    Set<String> permsOf(Iterable<String> codes) => {
      for (final c in codes) ...?roleByCode[c]?.permissions,
    };
    final directRolePerms = permsOf(widget.user.roles);
    final deptRolePerms = permsOf(
      deptRoles
          .where((e) => e.departmentId == widget.user.departmentId)
          .expand((e) => e.roles),
    );
    final rolePerms = {...directRolePerms, ...deptRolePerms};

    // 按 category 分组
    final grouped = <String, List<AdminPermission>>{};
    for (final p in perms) {
      grouped.putIfAbsent(p.category, () => []).add(p);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in grouped.entries)
          UtenCollapsibleSection(
            title: '${entry.key}（${entry.value.length}）',
            child: Column(
              children: [
                for (final p in entry.value)
                  _permRow(
                    p,
                    inheritedViaRole: directRolePerms.contains(p.code),
                    inheritedViaDept: deptRolePerms.contains(p.code),
                    effective: _isEffective(p.code, rolePerms),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  /// 有效判定：继承所得且未回收，或被加授。
  bool _isEffective(String code, Set<String> rolePerms) {
    final state = _overrides[code] ?? _OverrideState.inherit;
    if (state == _OverrideState.revoke) return false;
    if (state == _OverrideState.grant) return true;
    return rolePerms.contains(code);
  }

  Widget _permRow(
    AdminPermission p, {
    required bool inheritedViaRole,
    required bool inheritedViaDept,
    required bool effective,
  }) {
    final theme = Theme.of(context);
    final state = _overrides[p.code] ?? _OverrideState.inherit;
    // 有效结果着色：有效=绿、回收=红、无关=灰
    final nameColor = switch (state) {
      _OverrideState.revoke => UtenColors.error,
      _ when effective => UtenColors.success,
      _ => theme.colorScheme.onSurfaceVariant,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 6,
                  children: [
                    Text(
                      p.name,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: nameColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      p.code,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    if (inheritedViaRole)
                      _inheritTag('角色继承')
                    else if (inheritedViaDept)
                      _inheritTag('部门继承'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              for (final (s, label) in const [
                (_OverrideState.inherit, '继承'),
                (_OverrideState.grant, '加授'),
                (_OverrideState.revoke, '回收'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: state == s,
                    visualDensity: VisualDensity.compact,
                    labelStyle: const TextStyle(fontSize: 12),
                    onSelected: (_) {
                      setState(() {
                        if (s == _OverrideState.inherit) {
                          _overrides.remove(p.code);
                        } else {
                          _overrides[p.code] = s;
                        }
                      });
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _inheritTag(String label) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _loadError(String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Text(
        message,
        style: Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: UtenColors.error),
      ),
    );
  }
}
