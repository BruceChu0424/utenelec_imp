// AdminUserDetailPanel - 员工账号、功能权限与数据范围详情。
//
// 高密度授权信息按三个页内分区呈现，默认进入功能权限。完整权限目录仍由后端动态
// 下发；前端只负责搜索、筛选、分组和把最终状态变化换算为个人 grants/revokes。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../authorize_all_excluded.dart';
import '../models/admin_models.dart';
import '../pages/admin_permissions_page.dart' show AccountStatusBadge;
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import 'admin_data_scope_section.dart';
import 'permission_catalog_browser.dart';
import 'permission_action_badge.dart';
import 'set_temporary_password_dialog.dart';

class AdminUserDetailPanel extends ConsumerStatefulWidget {
  const AdminUserDetailPanel({
    super.key,
    required this.user,
    required this.onAccountChanged,
    required this.canManageAuthorization,
    this.showBack = false,
    this.onBack,
    this.onPermissionDirtyChanged,
  });

  final AdminUserSummary user;
  final VoidCallback onAccountChanged;

  /// true 时才请求和呈现超级管理员授权端点。
  final bool canManageAuthorization;
  final bool showBack;
  final VoidCallback? onBack;
  final ValueChanged<bool>? onPermissionDirtyChanged;

  @override
  ConsumerState<AdminUserDetailPanel> createState() =>
      _AdminUserDetailPanelState();
}

class _AdminUserDetailPanelState extends ConsumerState<AdminUserDetailPanel> {
  _UserDetailSection _section = _UserDetailSection.permissions;

  /// 本地待保存的加授/收回集合；null = 未做编辑（跟随服务端数据）。
  Set<String>? _localGrants;
  Set<String>? _localRevokes;
  bool _savingOverrides = false;
  bool? _lastReportedPermissionDirty;
  bool _acting = false;

  @override
  void didUpdateWidget(covariant AdminUserDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.user.id != widget.user.id ||
        oldWidget.canManageAuthorization != widget.canManageAuthorization;
    final lifecycleChanged =
        oldWidget.user.status != widget.user.status ||
        oldWidget.user.employeeStatus != widget.user.employeeStatus ||
        oldWidget.user.currentEmployee != widget.user.currentEmployee;
    if (!identityChanged && !lifecycleChanged) {
      return;
    }
    if (identityChanged) _section = _UserDetailSection.permissions;
    _localGrants = null;
    _localRevokes = null;
    _lastReportedPermissionDirty = null;
    if (lifecycleChanged) {
      ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
    }
  }

  Set<String> _pendingGrants(EffectivePermissions data) =>
      _localGrants ?? data.grants.toSet();

  Set<String> _pendingRevokes(EffectivePermissions data) =>
      _localRevokes ?? data.revokes.toSet();

  int _dirtyCount(EffectivePermissions data) {
    if (_localGrants == null && _localRevokes == null) return 0;
    final savedGrants = data.grants.toSet();
    final savedRevokes = data.revokes.toSet();
    final pendingGrants = _pendingGrants(data);
    final pendingRevokes = _pendingRevokes(data);
    final codes = {
      ...savedGrants,
      ...savedRevokes,
      ...pendingGrants,
      ...pendingRevokes,
    };
    return codes.where((code) {
      return savedGrants.contains(code) != pendingGrants.contains(code) ||
          savedRevokes.contains(code) != pendingRevokes.contains(code);
    }).length;
  }

  @override
  Widget build(BuildContext context) {
    final effectiveAsync = widget.canManageAuthorization
        ? ref.watch(adminEffectivePermissionsProvider(widget.user.id))
        : null;
    final data = effectiveAsync?.valueOrNull;
    final dirtyCount = data == null ? 0 : _dirtyCount(data);
    final legacyUnknownCount = data == null
        ? 0
        : {...data.legacyUnknownGrants, ...data.legacyUnknownRevokes}.length;
    final permissionDirty = dirtyCount > 0;
    if (_lastReportedPermissionDirty != permissionDirty) {
      _lastReportedPermissionDirty = permissionDirty;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          widget.onPermissionDirtyChanged?.call(permissionDirty);
        }
      });
    }
    final showSaveBar =
        widget.canManageAuthorization &&
        _section == _UserDetailSection.permissions &&
        data != null &&
        !data.superAdmin &&
        widget.user.authorizationGrantAllowed &&
        (dirtyCount > 0 || legacyUnknownCount > 0);

    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s4,
              UtenSpacing.s16,
              UtenSpacing.s32,
            ),
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
              _userSummary(),
              if (!widget.user.currentEmployee) ...[
                const SizedBox(height: UtenSpacing.s12),
                _employmentRestrictionNotice(),
              ],
              if (widget.canManageAuthorization) ...[
                const SizedBox(height: UtenSpacing.s12),
                // 云端访问授权置于最顶部（用户要求「权限设置最顶部」），最显眼。
                _remoteAccessTile(widget.user.remoteAccess),
                const SizedBox(height: UtenSpacing.s12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: UtenSegmentedFilter<_UserDetailSection>(
                    segments: const [
                      UtenSegment(
                        value: _UserDetailSection.permissions,
                        label: '操作权限',
                      ),
                      UtenSegment(
                        value: _UserDetailSection.dataScope,
                        label: '可查看数据',
                      ),
                      UtenSegment(
                        value: _UserDetailSection.account,
                        label: '账号安全',
                      ),
                    ],
                    selected: _section,
                    onChanged: _changeSection,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
              if (!widget.canManageAuthorization)
                _accountSection()
              else
                switch (_section) {
                  _UserDetailSection.permissions => _permSection(
                    effectiveAsync!,
                    ref.watch(permissionCatalogProvider),
                  ),
                  _UserDetailSection.dataScope => AdminDataScopeSection(
                    user: widget.user,
                    effectiveAsync: effectiveAsync!,
                    onAccountChanged: widget.onAccountChanged,
                  ),
                  _UserDetailSection.account => _accountSection(),
                },
            ],
          ),
        ),
        if (showSaveBar)
          UtenBottomActionBar(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    dirtyCount > 0
                        ? '已修改 $dirtyCount 项'
                        : '有 $legacyUnknownCount 项历史覆盖待超级管理员确认',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _savingOverrides || dirtyCount == 0
                      ? null
                      : () => setState(() {
                          _localGrants = null;
                          _localRevokes = null;
                        }),
                  child: const Text('撤销'),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  size: UtenButtonSize.small,
                  isLoading: _savingOverrides,
                  onPressed: _savingOverrides
                      ? null
                      : () => _saveOverrides(data),
                  child: const Text('保存更改'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _changeSection(_UserDetailSection section) {
    if (_section == section) return;
    setState(() => _section = section);
  }

  Widget _userSummary() {
    final theme = Theme.of(context);
    final user = widget.user;
    final displayName = user.employeeName ?? user.loginAccount;
    final initial = displayName.trim().isEmpty
        ? '?'
        : displayName.trim().substring(0, 1).toUpperCase();
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            child: Text(
              initial,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${user.loginAccount}'
                  '${user.departmentName == null ? '' : ' · ${user.departmentName}'}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          AccountStatusBadge(status: user.status),
        ],
      ),
    );
  }

  Widget _employmentRestrictionNotice() {
    final theme = Theme.of(context);
    final user = widget.user;
    final message =
        '${user.employeeStatusLabel}：${user.lifecycleRestrictionReason}。'
        '当前仅可执行停用、撤销授权、清空个人设置，以及已停用账号的临时密码重置。';
    return Semantics(
      container: true,
      label: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.errorContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.35),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              Icons.person_off_outlined,
              size: 20,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _explainAuthorizationRestriction() {
    final reason = widget.user.authorizationRestrictionReason;
    if (reason.isNotEmpty) UtenToast.info(context, reason);
  }

  void _explainLifecycleRestriction() {
    final reason = widget.user.lifecycleRestrictionReason;
    if (reason.isNotEmpty) UtenToast.info(context, reason);
  }

  // ===== 功能权限 =====

  Widget _permSection(
    AsyncValue<EffectivePermissions> effectiveAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
  ) {
    final theme = Theme.of(context);
    final data = effectiveAsync.valueOrNull;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '权限明细',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '完整权限不会减少。先按分组浏览，或搜索名称、代码和分组；'
            '个人调整保存后会即时生效。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          if (!widget.user.authorizationGrantAllowed) ...[
            const SizedBox(height: UtenSpacing.s8),
            _authorizationRestrictionCard(data),
          ],
          if (widget.canManageAuthorization) ...[
            const SizedBox(height: UtenSpacing.s8),
            _superAdminTile(data?.superAdmin ?? false),
          ],
          if (data?.departmentName != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '部门：${data!.departmentName} · '
              '部门已配 ${data.departmentPermissions.length} 项权限',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          _permMatrix(effectiveAsync, catalogAsync),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            '整组批量操作位于分组右侧菜单；操作完整分组，不受当前搜索结果影响。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  bool _hasPersonalOverrides(EffectivePermissions data) =>
      data.grants.isNotEmpty ||
      data.revokes.isNotEmpty ||
      data.legacyUnknownGrants.isNotEmpty ||
      data.legacyUnknownRevokes.isNotEmpty;

  Widget _authorizationRestrictionCard(EffectivePermissions? data) {
    final theme = Theme.of(context);
    final reason = widget.user.authorizationRestrictionReason;
    final canClear = data != null && _hasPersonalOverrides(data);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.lock_person_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  '$reason。不能新增或调整个人授权；可清空已有个人授权覆盖。',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                ),
              ),
            ],
          ),
          if (canClear) ...[
            const SizedBox(height: UtenSpacing.s8),
            Align(
              alignment: Alignment.centerRight,
              child: UtenButton(
                key: const ValueKey('admin-clear-personal-overrides'),
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                icon: Icons.delete_sweep_outlined,
                isLoading: _savingOverrides,
                onPressed: _savingOverrides
                    ? null
                    : () => _clearOverrides(data),
                child: const Text('清空个人授权'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _permMatrix(
    AsyncValue<EffectivePermissions> effectiveAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
  ) {
    if (effectiveAsync.hasError || catalogAsync.hasError) {
      return UtenEmpty.error(
        message: '权限数据加载失败',
        description: '请检查网络后重试，已做的本地调整不会自动提交。',
        actionLabel: '重试',
        onAction: () {
          ref
            ..invalidate(adminEffectivePermissionsProvider(widget.user.id))
            ..invalidate(permissionCatalogProvider);
        },
      );
    }
    final data = effectiveAsync.valueOrNull;
    final groups = catalogAsync.valueOrNull;
    if (data == null || groups == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (groups.isEmpty) {
      return const UtenEmpty(
        icon: Icons.security_outlined,
        message: '权限目录为空',
        description: '后端尚未返回可配置的权限点。',
      );
    }

    final grants = _pendingGrants(data);
    final revokes = _pendingRevokes(data);
    final canEdit = !data.superAdmin && widget.user.authorizationGrantAllowed;
    return PermissionCatalogBrowser(
      groups: groups,
      isEnabled: (permission) => _isEffective(data, permission.code),
      isChanged: (permission) =>
          grants.contains(permission.code) || revokes.contains(permission.code),
      changedFilterLabel: '个人覆盖',
      onEnableGroup: canEdit
          ? (permissions) => _setPermissions(data, permissions, true)
          : null,
      onDisableGroup: canEdit
          ? (permissions) => _setPermissions(data, permissions, false)
          : null,
      onEnableAll: canEdit
          ? (permissions) => _setPermissionCodes(
              data,
              permissions
                  .where((p) => !kAuthorizeAllExcluded.contains(p.code))
                  .map((p) => p.code),
              true,
            )
          : null,
      onDisableAll: canEdit
          ? (permissions) =>
                _setPermissionCodes(data, permissions.map((p) => p.code), false)
          : null,
      itemBuilder: (context, permission) => _permRow(data, permission),
    );
  }

  bool _isEffective(EffectivePermissions data, String code) {
    if (data.superAdmin) return true;
    final inherited =
        data.departmentPermissions.contains(code) ||
        data.baselinePermissions.contains(code) ||
        data.managerGrants.contains(code);
    return inherited && !_pendingRevokes(data).contains(code) ||
        _pendingGrants(data).contains(code);
  }

  void _togglePerm(EffectivePermissions data, String code, bool value) {
    _setPermissionCodes(data, [code], value);
  }

  void _setPermissions(
    EffectivePermissions data,
    List<AdminPermission> permissions,
    bool value,
  ) {
    _setPermissionCodes(
      data,
      permissions.map((permission) => permission.code),
      value,
    );
  }

  void _setPermissionCodes(
    EffectivePermissions data,
    Iterable<String> codes,
    bool value,
  ) {
    if (!widget.user.authorizationGrantAllowed) {
      _explainAuthorizationRestriction();
      return;
    }
    final inherited = {
      ...data.departmentPermissions,
      ...data.baselinePermissions,
      ...data.managerGrants,
    };
    final grants = {..._pendingGrants(data)};
    final revokes = {..._pendingRevokes(data)};
    for (final code in codes) {
      if (value) {
        revokes.remove(code);
        inherited.contains(code) ? grants.remove(code) : grants.add(code);
      } else {
        grants.remove(code);
        inherited.contains(code) ? revokes.add(code) : revokes.remove(code);
      }
    }
    setState(() {
      _localGrants = grants;
      _localRevokes = revokes;
    });
  }

  Widget _permRow(EffectivePermissions data, AdminPermission permission) {
    final theme = Theme.of(context);
    final grants = _pendingGrants(data);
    final revokes = _pendingRevokes(data);
    final viaDept = data.departmentPermissions.contains(permission.code);
    final viaBaseline = data.baselinePermissions.contains(permission.code);
    final viaManager = data.managerGrants.contains(permission.code);
    final revoked = !data.superAdmin && revokes.contains(permission.code);
    final effective = _isEffective(data, permission.code);
    final canEdit = !data.superAdmin && widget.user.authorizationGrantAllowed;
    final editRestriction = data.superAdmin
        ? '超级管理员默认拥有全部权限，不能逐项调整'
        : widget.user.authorizationRestrictionReason;

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PermissionTitleBlock(
          name: permission.name,
          actionType: permission.actionType,
          description: permission.description,
          nameStyle: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: revoked ? UtenColors.error : null,
            decoration: revoked ? TextDecoration.lineThrough : null,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Wrap(
          spacing: UtenSpacing.s4,
          runSpacing: UtenSpacing.s4,
          children: [
            if (viaDept) _sourceTag('部门'),
            if (viaBaseline) _sourceTag('基础'),
            if (viaManager) _sourceTag('负责人委派'),
            if (grants.contains(permission.code)) _sourceTag('个人加授'),
            if (data.legacyUnknownGrants.contains(permission.code))
              _sourceTag('历史加授待确认', danger: true),
            if (revoked) _sourceTag('已收回', danger: true),
            if (data.legacyUnknownRevokes.contains(permission.code))
              _sourceTag('历史收回待确认', danger: true),
          ],
        ),
      ],
    );
    final controls = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        UtenStatusBadge(
          label: effective ? '已授权' : '未授权',
          type: effective
              ? UtenStatusBadgeType.success
              : UtenStatusBadgeType.neutral,
          size: UtenStatusBadgeSize.small,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Semantics(
          label: '${permission.name}${effective ? '已授权' : '未授权'}',
          enabled: canEdit,
          hint: canEdit ? null : editRestriction,
          child: Switch(
            value: effective,
            onChanged: canEdit
                ? (value) => _togglePerm(data, permission.code, value)
                : null,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 500) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                details,
                const SizedBox(height: UtenSpacing.s4),
                Align(alignment: Alignment.centerRight, child: controls),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: details),
              const SizedBox(width: UtenSpacing.s8),
              controls,
            ],
          );
        },
      ),
    );
  }

  Widget _sourceTag(String label, {bool danger = false}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: danger
            ? UtenColors.error.withValues(alpha: 0.1)
            : theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: danger ? UtenColors.error : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Future<void> _saveOverrides(EffectivePermissions data) async {
    final hasLegacyUnknown =
        data.legacyUnknownGrants.isNotEmpty ||
        data.legacyUnknownRevokes.isNotEmpty;
    if (_savingOverrides || (_dirtyCount(data) == 0 && !hasLegacyUnknown)) {
      return;
    }
    if (!widget.user.authorizationGrantAllowed &&
        (_pendingGrants(data).isNotEmpty || _pendingRevokes(data).isNotEmpty)) {
      _explainAuthorizationRestriction();
      return;
    }
    setState(() => _savingOverrides = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateUserPermOverrides(
            widget.user.id,
            grants: _pendingGrants(data).toList(),
            revokes: _pendingRevokes(data).toList(),
          );
      ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
      if (!mounted) return;
      setState(() {
        _localGrants = null;
        _localRevokes = null;
      });
      UtenToast.success(
        context,
        hasLegacyUnknown ? '历史权限来源已确认并即时生效' : '权限调整已保存并即时生效',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        setState(() {
          _localGrants = null;
          _localRevokes = null;
        });
        ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
        widget.onAccountChanged();
      }
      UtenToast.error(
        context,
        error.message.isNotEmpty ? error.message : '保存失败，本地修改已保留，请稍后重试',
      );
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存失败，本地修改已保留，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  Future<void> _clearOverrides(EffectivePermissions data) async {
    if (_savingOverrides || !_hasPersonalOverrides(data)) return;
    final confirmed = await UtenDialog.show(
      context,
      title: '清空个人授权？',
      content: const Text('将移除全部个人加授、个人收回和待确认历史覆盖。部门权限、基础权限不会改变。'),
      confirmLabel: '清空授权',
      danger: true,
    );
    if (!mounted || confirmed != true) return;
    setState(() => _savingOverrides = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateUserPermOverrides(
            widget.user.id,
            grants: const [],
            revokes: const [],
          );
      ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
      if (!mounted) return;
      setState(() {
        _localGrants = null;
        _localRevokes = null;
      });
      UtenToast.success(context, '个人授权已清空');
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
        widget.onAccountChanged();
      }
      UtenToast.error(
        context,
        error.message.isNotEmpty ? error.message : '清空失败，请刷新后重试',
      );
    } catch (_) {
      if (mounted) UtenToast.error(context, '清空失败，请刷新后重试');
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  // ===== 云端(外网)访问授权 =====

  /// 置于详情最顶部：授权/取消该账号在云端(外网)使用本平台。
  /// 仅超管可见可改（canManageAuthorization = 超管 + authorization:manage）；
  /// 变更由后端触发器即时 bump auth_version，旧 access token 立即失效。
  Widget _remoteAccessTile(bool remoteAccess) {
    final theme = Theme.of(context);
    final name = widget.user.employeeName ?? widget.user.loginAccount;
    final grantAllowed = remoteAccess || widget.user.authorizationGrantAllowed;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: remoteAccess
              ? UtenColors.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          Icon(
            remoteAccess ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            size: 20,
            color: remoteAccess
                ? UtenColors.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  remoteAccess ? '已授权云端访问' : '未授权云端访问',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  !remoteAccess && !grantAllowed
                      ? '${widget.user.authorizationRestrictionReason}，不能开放外网访问。'
                      : remoteAccess
                      ? '「$name」可在外网(云端)登录使用；居家/出差可用。'
                      : '「$name」仅可在公司内网使用。授权云端后该账号需重新登录。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          UtenButton(
            type: remoteAccess
                ? UtenButtonType.ghost
                : UtenButtonType.secondary,
            size: UtenButtonSize.small,
            icon: remoteAccess
                ? Icons.remove_circle_outline_rounded
                : Icons.cloud_upload_outlined,
            isLoading: _acting,
            onPressed: _acting || !grantAllowed
                ? null
                : () => _toggleRemoteAccess(remoteAccess),
            onDisabledTap: _acting || grantAllowed
                ? null
                : _explainAuthorizationRestriction,
            child: Text(remoteAccess ? '取消授权' : '授权云端'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleRemoteAccess(bool current) async {
    final next = !current;
    if (next && !widget.user.authorizationGrantAllowed) {
      _explainAuthorizationRestriction();
      return;
    }
    final name = widget.user.employeeName ?? widget.user.loginAccount;
    final confirmed = await UtenDialog.show(
      context,
      title: next ? '授权云端访问' : '取消云端访问',
      content: Text(
        next
            ? '授权「$name」在外网(云端)使用本平台？授权后该账号需重新登录。'
            : '取消「$name」的云端访问授权？该账号在外网的会话将立即失效。',
      ),
      confirmLabel: next ? '授权' : '取消授权',
      danger: !next,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .setRemoteAccess(widget.user.id, remoteAccess: next);
      if (!mounted) return;
      UtenToast.success(context, next ? '已授权云端访问' : '已取消云端访问');
      widget.onAccountChanged();
    } on ApiException catch (e) {
      if (mounted) {
        if (e.code == 'CONFLICT') widget.onAccountChanged();
        UtenToast.error(
          context,
          e.message.isNotEmpty ? e.message : '远程访问授权变更失败，请稍后重试',
        );
      }
    } catch (_) {
      if (mounted) UtenToast.error(context, '远程访问授权变更失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  // ===== 账号安全 =====

  Widget _accountSection() {
    final theme = Theme.of(context);
    final user = widget.user;
    final expiry = user.tempPasswordExpiresAt == null
        ? null
        : DateTime.tryParse(user.tempPasswordExpiresAt!)?.toLocal();
    final expiryExpired = expiry != null && expiry.isBefore(DateTime.now());
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '账号安全',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  AccountStatusBadge(status: user.status),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              _infoRow('姓名', user.employeeName ?? '—'),
              _infoRow('工号', user.employeeCode ?? '—'),
              _infoRow('任职状态', user.employeeStatusLabel),
              _infoRow('部门', user.departmentName ?? '—'),
              _infoRow('登录账号', user.loginAccount),
              _infoRow('上次登录', user.lastLoginAt ?? '—'),
              const Divider(height: UtenSpacing.s24),
              Text(
                '密码与登录',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (user.mustChangePassword)
                _tempPasswordPendingNotice(expiry, expiryExpired)
              else
                Text(
                  '员工忘记密码时，可为其设置一次性临时密码；'
                  '员工用临时密码登录后，系统会强制其设置新密码。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              const SizedBox(height: UtenSpacing.s12),
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.small,
                icon: Icons.key_rounded,
                isLoading: _acting,
                onPressed: _acting || !user.passwordResetAllowed
                    ? null
                    : _openSetTemporaryPassword,
                onDisabledTap: _acting || user.passwordResetAllowed
                    ? null
                    : _explainLifecycleRestriction,
                child: Text(user.mustChangePassword ? '重新设置临时密码' : '设置临时密码'),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '账号状态',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '锁定或停用后该账号立即无法登录，全部会话失效；'
                '解锁/启用前请确认员工档案仍在职有效。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  if (user.status == 'active')
                    UtenButton(
                      type: UtenButtonType.ghost,
                      size: UtenButtonSize.small,
                      icon: Icons.lock_outline_rounded,
                      isLoading: _acting,
                      onPressed: _acting || !user.currentEmployee
                          ? null
                          : () => _runAccountAction(
                              label: '锁定',
                              danger: true,
                              call: (repository) =>
                                  repository.lockUser(user.id),
                            ),
                      onDisabledTap: _acting || user.currentEmployee
                          ? null
                          : _explainLifecycleRestriction,
                      child: const Text('锁定'),
                    ),
                  if (user.status == 'locked')
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.small,
                      icon: Icons.lock_open_rounded,
                      isLoading: _acting,
                      onPressed: _acting || !user.currentEmployee
                          ? null
                          : () => _runAccountAction(
                              label: '解锁',
                              danger: false,
                              call: (repository) =>
                                  repository.unlockUser(user.id),
                            ),
                      onDisabledTap: _acting || user.currentEmployee
                          ? null
                          : _explainLifecycleRestriction,
                      child: const Text('解锁'),
                    ),
                  if (user.status != 'disabled')
                    UtenButton(
                      type: UtenButtonType.danger,
                      size: UtenButtonSize.small,
                      icon: Icons.block_rounded,
                      isLoading: _acting,
                      onPressed: () => _runAccountAction(
                        label: '停用',
                        danger: true,
                        call: (repository) => repository.disableUser(user.id),
                      ),
                      child: const Text('停用'),
                    ),
                  if (user.status == 'disabled')
                    UtenButton(
                      type: UtenButtonType.secondary,
                      size: UtenButtonSize.small,
                      icon: Icons.play_circle_outline_rounded,
                      isLoading: _acting,
                      onPressed: _acting || !user.currentEmployee
                          ? null
                          : () => _runAccountAction(
                              label: '启用',
                              danger: false,
                              call: (repository) =>
                                  repository.enableUser(user.id),
                            ),
                      onDisabledTap: _acting || user.currentEmployee
                          ? null
                          : _explainLifecycleRestriction,
                      child: const Text('启用'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Row(
          children: [
            Icon(
              Icons.fact_check_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                '所有账号操作均记录审计日志，可追溯操作人、时间与结果。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// 已设置临时密码的状态提示：等待员工改密 + 有效期（逾期自动失效）。
  Widget _tempPasswordPendingNotice(DateTime? expiry, bool expiryExpired) {
    final theme = Theme.of(context);
    final color = expiryExpired ? UtenColors.error : UtenColors.warning;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.pending_actions_rounded, size: 20, color: color),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已设置临时密码，等待员工登录后设置新密码',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  expiry == null
                      ? '员工首次登录时需设置新密码'
                      : expiryExpired
                      ? '临时密码已过期，员工无法再用它登录，请重新设置'
                      : '临时密码有效期至 ${DateFormat('yyyy-MM-dd HH:mm').format(expiry)}，逾期自动失效',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }

  Widget _superAdminTile(bool isSuperAdmin) {
    final theme = Theme.of(context);
    final promote = !isSuperAdmin;
    final toggleAllowed = !promote || widget.user.authorizationGrantAllowed;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isSuperAdmin
              ? UtenColors.warning.withValues(alpha: 0.6)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          Icon(
            isSuperAdmin ? Icons.verified_user_rounded : Icons.shield_outlined,
            size: 20,
            color: isSuperAdmin
                ? UtenColors.warning
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isSuperAdmin ? '超级管理员' : '普通账号',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  promote && !toggleAllowed
                      ? '${widget.user.authorizationRestrictionReason}，不能授予超级管理员。'
                      : isSuperAdmin
                      ? '默认拥有全部功能权限、可管理他人授权。'
                      : '设为超级管理员后，该账号拥有全部功能、可管理他人授权。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          UtenButton(
            type: promote ? UtenButtonType.secondary : UtenButtonType.danger,
            size: UtenButtonSize.small,
            icon: promote
                ? Icons.add_moderator_outlined
                : Icons.shield_outlined,
            isLoading: _acting,
            onPressed: _acting || !toggleAllowed
                ? null
                : () => _toggleSuperAdmin(promote: promote),
            onDisabledTap: _acting || toggleAllowed
                ? null
                : _explainAuthorizationRestriction,
            child: Text(isSuperAdmin ? '取消超管' : '设为超管'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleSuperAdmin({required bool promote}) async {
    if (promote && !widget.user.authorizationGrantAllowed) {
      _explainAuthorizationRestriction();
      return;
    }
    final name = widget.user.employeeName ?? widget.user.loginAccount;
    final confirmed = await UtenDialog.show(
      context,
      title: promote ? '设为超级管理员' : '取消超级管理员',
      content: Text(
        promote
            ? '确定把「$name」设为超级管理员吗？\n设成后该账号拥有全部功能、可管理他人授权。'
            : '确定取消「$name」的超级管理员吗？\n取消后该账号将失去默认全部权限与授权管理能力，'
                  '仅保留已显式配置的权限。',
      ),
      confirmLabel: promote ? '设为超管' : '取消超管',
      danger: !promote,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .setSuperAdmin(widget.user.id, superAdmin: promote);
      if (!mounted) return;
      ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
      widget.onAccountChanged();
      UtenToast.success(context, promote ? '已设为超级管理员' : '已取消超级管理员');
    } on ApiException catch (e) {
      // 透出后端具体拦截原因（不能降本人 / 至少保留一位超管 等）。
      if (!mounted) return;
      if (e.code == 'CONFLICT') widget.onAccountChanged();
      UtenToast.error(
        context,
        e.message.isNotEmpty
            ? e.message
            : (promote ? '设为超管失败，请稍后重试' : '取消超管失败，请稍后重试'),
      );
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, promote ? '设为超管失败，请稍后重试' : '取消超管失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _runAccountAction({
    required String label,
    required bool danger,
    required Future<void> Function(AdminRepository repository) call,
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
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') widget.onAccountChanged();
      UtenToast.error(
        context,
        error.message.isNotEmpty ? error.message : '$label失败，请刷新状态后重试',
      );
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '$label失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  /// 设置临时密码：先弹模式选择（系统生成/自定义），再调端点，最后一次性展示明文。
  Future<void> _openSetTemporaryPassword() async {
    final user = widget.user;
    final choice = await showSetTemporaryPasswordDialog(
      context,
      displayName: user.employeeName ?? user.loginAccount,
      loginAccount: user.loginAccount,
    );
    if (choice == null || !mounted) return;
    setState(() => _acting = true);
    try {
      final temporaryPassword = await ref
          .read(adminRepositoryProvider)
          .resetPassword(user.id, temporaryPassword: choice.customPassword);
      if (!mounted) return;
      widget.onAccountChanged();
      await _showTemporaryPassword(temporaryPassword);
    } on ApiException catch (e) {
      // 透出后端强度校验等具体原因（如「临时密码需同时包含字母和数字」）。
      if (mounted) {
        if (e.code == 'CONFLICT') widget.onAccountChanged();
        UtenToast.error(
          context,
          e.message.isNotEmpty ? e.message : '设置临时密码失败，请稍后重试',
        );
      }
    } catch (_) {
      if (mounted) UtenToast.error(context, '设置临时密码失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _showTemporaryPassword(String temporaryPassword) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.key_rounded),
            SizedBox(width: UtenSpacing.s8),
            Text('一次性临时密码'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '请立即通过安全渠道告知该员工：临时密码 72 小时内有效，'
              '员工登录后须设置新密码。关闭此窗口后，系统不会再次显示或保存这段明文。',
            ),
            const SizedBox(height: UtenSpacing.s16),
            Container(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              decoration: BoxDecoration(
                color: Theme.of(
                  dialogContext,
                ).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(10),
              ),
              child: SelectableText(
                temporaryPassword,
                textAlign: TextAlign.center,
                style: Theme.of(dialogContext).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ],
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: temporaryPassword));
              if (dialogContext.mounted) {
                UtenToast.success(dialogContext, '临时密码已复制');
              }
            },
            icon: const Icon(Icons.copy_rounded),
            label: const Text('复制'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('我已妥善保存'),
          ),
        ],
      ),
    );
  }
}

enum _UserDetailSection { permissions, dataScope, account }
