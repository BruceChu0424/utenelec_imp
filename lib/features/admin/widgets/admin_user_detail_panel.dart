// AdminUserDetailPanel - 员工账号、功能权限与数据范围详情。
//
// 高密度授权信息按三个页内分区呈现，默认进入功能权限。完整权限目录仍由后端动态
// 下发；前端只负责搜索、筛选、分组和把最终状态变化换算为个人 grants/revokes。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
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
import 'permission_catalog_browser.dart';

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
  static const _scopeDefs = [
    _DataScopeDefinition(
      scope: 'goods',
      label: '外贸货品可见业务员',
      description: '加看所选业务员名下的外贸货品',
    ),
    _DataScopeDefinition(
      scope: 'client',
      label: '客户资料可见业务员',
      description: '加看所选业务员名下的客户资料',
    ),
    _DataScopeDefinition(
      scope: 'sales',
      label: '销售单据可见业务员',
      description: '加看所选业务员名下的销售单据',
    ),
    _DataScopeDefinition(
      scope: 'purchase',
      label: '采购单据可见制单人',
      description: '加看所选制单人名下的采购单据（可看可改）',
    ),
    _DataScopeDefinition(
      scope: 'subcontract',
      label: '委外单据可见制单人',
      description: '加看所选制单人名下的委外单据（可看可改）',
    ),
    _DataScopeDefinition(
      scope: 'production_plan',
      label: '生产单据可见制单人',
      description: '加看所选制单人名下的生产计划/日报（可看可改）',
    ),
    _DataScopeDefinition(
      scope: 'stock_doc',
      label: '仓库单据可见制单人',
      description: '加看所选制单人名下的仓库单据（可看可改）',
    ),
  ];

  _UserDetailSection _section = _UserDetailSection.permissions;

  /// 本地待保存的加授/收回集合；null = 未做编辑（跟随服务端数据）。
  Set<String>? _localGrants;
  Set<String>? _localRevokes;
  bool _savingOverrides = false;
  bool? _lastReportedPermissionDirty;
  bool _acting = false;

  /// 数据范围按 scope 独立加载、失败和保存，避免一个范围拖垮整块。
  bool _scopesRequested = false;
  final Set<String> _scopeLoading = {};
  final Set<String> _scopeSaving = {};
  final Map<String, String> _scopeErrors = {};
  final Map<String, Set<String>> _scopeGrants = {};
  final Map<String, List<DataScopeOwner>> _scopeCandidates = {};

  @override
  void didUpdateWidget(covariant AdminUserDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id == widget.user.id &&
        oldWidget.canManageAuthorization == widget.canManageAuthorization) {
      return;
    }
    _section = _UserDetailSection.permissions;
    _localGrants = null;
    _localRevokes = null;
    _lastReportedPermissionDirty = null;
    _scopesRequested = false;
    _scopeLoading.clear();
    _scopeSaving.clear();
    _scopeErrors.clear();
    _scopeGrants.clear();
    _scopeCandidates.clear();
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
        dirtyCount > 0;

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
                        label: '功能权限',
                      ),
                      UtenSegment(
                        value: _UserDetailSection.dataScope,
                        label: '数据范围',
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
                  _UserDetailSection.dataScope => _dataScopeSection(
                    effectiveAsync!,
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
                    '已修改 $dirtyCount 项',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _savingOverrides
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
    if (section != _UserDetailSection.dataScope) return;
    final data = ref
        .read(adminEffectivePermissionsProvider(widget.user.id))
        .valueOrNull;
    if (data != null && !data.superAdmin) {
      unawaited(_loadAllScopes());
    }
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
    return PermissionCatalogBrowser(
      groups: groups,
      isEnabled: (permission) => _isEffective(data, permission.code),
      isChanged: (permission) =>
          grants.contains(permission.code) || revokes.contains(permission.code),
      changedFilterLabel: '个人覆盖',
      onEnableGroup: data.superAdmin
          ? null
          : (permissions) => _setPermissions(data, permissions, true),
      onDisableGroup: data.superAdmin
          ? null
          : (permissions) => _setPermissions(data, permissions, false),
      onEnableAll: data.superAdmin
          ? null
          : (permissions) => _setPermissionCodes(
              data,
              permissions
                  .where((p) => !kAuthorizeAllExcluded.contains(p.code))
                  .map((p) => p.code),
              true,
            ),
      onDisableAll: data.superAdmin
          ? null
          : (permissions) => _setPermissionCodes(
              data,
              permissions.map((p) => p.code),
              false,
            ),
      itemBuilder: (context, permission) => _permRow(data, permission),
    );
  }

  bool _isEffective(EffectivePermissions data, String code) {
    if (data.superAdmin) return true;
    final inherited =
        data.departmentPermissions.contains(code) ||
        data.baselinePermissions.contains(code);
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
    final inherited = {
      ...data.departmentPermissions,
      ...data.baselinePermissions,
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
    final revoked = !data.superAdmin && revokes.contains(permission.code);
    final effective = _isEffective(data, permission.code);

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          permission.name,
          style: theme.textTheme.bodyMedium?.copyWith(
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
            if (grants.contains(permission.code)) _sourceTag('个人加授'),
            if (revoked) _sourceTag('已收回', danger: true),
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
          child: Switch(
            value: effective,
            onChanged: data.superAdmin
                ? null
                : (value) => _togglePerm(data, permission.code, value),
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
    if (_savingOverrides || _dirtyCount(data) == 0) return;
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
      UtenToast.success(context, '权限调整已保存并即时生效');
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存失败，本地修改已保留，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  // ===== 数据范围 =====

  Future<void> _loadAllScopes() async {
    if (_scopesRequested) return;
    _scopesRequested = true;
    await Future.wait(_scopeDefs.map((definition) => _loadScope(definition)));
  }

  Future<void> _loadScope(_DataScopeDefinition definition) async {
    final scope = definition.scope;
    final userId = widget.user.id;
    setState(() {
      _scopeLoading.add(scope);
      _scopeErrors.remove(scope);
    });
    try {
      final repo = ref.read(adminRepositoryProvider);
      final results = await Future.wait<Object>([
        repo.getUserDataScopes(userId, scope),
        repo.dataScopeOwners(scope),
      ]);
      if (!mounted || widget.user.id != userId) return;
      setState(() {
        _scopeGrants[scope] = (results[0] as List<String>).toSet();
        _scopeCandidates[scope] = results[1] as List<DataScopeOwner>;
      });
    } catch (_) {
      if (!mounted || widget.user.id != userId) return;
      setState(() {
        _scopeErrors[scope] = '加载失败，请重试';
      });
    } finally {
      if (mounted && widget.user.id == userId) {
        setState(() => _scopeLoading.remove(scope));
      }
    }
  }

  Future<void> _saveScopeSelection(
    _DataScopeDefinition definition,
    List<UtenEmployeePickerItem> selection,
  ) async {
    final scope = definition.scope;
    if (_scopeSaving.contains(scope)) return;
    final previous = {...?_scopeGrants[scope]};
    final selected = selection.map((item) => item.id).toSet();
    setState(() {
      _scopeSaving.add(scope);
      _scopeGrants[scope] = selected;
    });
    try {
      await ref
          .read(adminRepositoryProvider)
          .updateUserDataScopes(widget.user.id, scope, selected.toList());
      if (!mounted) return;
      UtenToast.success(context, '${definition.label}已保存，即时生效');
    } catch (_) {
      if (!mounted) return;
      setState(() => _scopeGrants[scope] = previous);
      UtenToast.error(context, '保存失败，已恢复原数据范围');
    } finally {
      if (mounted) setState(() => _scopeSaving.remove(scope));
    }
  }

  List<UtenEmployeePickerItem> _scopeItems(String scope) {
    return [
      for (final candidate
          in _scopeCandidates[scope] ?? const <DataScopeOwner>[])
        UtenEmployeePickerItem(
          id: candidate.employeeId,
          name: candidate.name,
          departmentName: '归属 ${candidate.count} 条',
        ),
    ];
  }

  List<UtenEmployeePickerItem> _scopeSelection(String scope) {
    final items = {for (final item in _scopeItems(scope)) item.id: item};
    return [
      for (final id in _scopeGrants[scope] ?? const <String>{})
        items[id] ??
            UtenEmployeePickerItem(
              id: id,
              name: '未知员工',
              departmentName: '当前已授权，但暂无归属数据',
            ),
    ];
  }

  Widget _dataScopeSection(AsyncValue<EffectivePermissions> effectiveAsync) {
    final theme = Theme.of(context);
    if (effectiveAsync.hasError) {
      return UtenCard(
        child: UtenEmpty.error(
          message: '账号权限状态加载失败',
          actionLabel: '重试',
          onAction: () =>
              ref.invalidate(adminEffectivePermissionsProvider(widget.user.id)),
        ),
      );
    }
    final data = effectiveAsync.valueOrNull;
    if (data == null) {
      return const UtenCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (!data.superAdmin && !_scopesRequested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_scopesRequested) unawaited(_loadAllScopes());
      });
    }

    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '数据范围',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '默认可见公共数据和本人归属数据；可在这里加看指定业务员的归属数据。'
            '持有“查看全部”权限时，以查看全部为准。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (data.superAdmin)
            _inlineNotice(
              '该账号是超级管理员，默认可见全部数据，无需配置数据范围。',
              Icons.visibility_outlined,
              UtenColors.warning,
            )
          else
            for (final definition in _scopeDefs) ...[
              _scopeEditor(definition),
              if (definition != _scopeDefs.last)
                const SizedBox(height: UtenSpacing.s12),
            ],
        ],
      ),
    );
  }

  Widget _scopeEditor(_DataScopeDefinition definition) {
    final theme = Theme.of(context);
    final scope = definition.scope;
    if (_scopeLoading.contains(scope)) {
      return InputDecorator(
        decoration: InputDecoration(
          labelText: definition.label,
          prefixIcon: const Icon(Icons.manage_accounts_outlined),
          border: const OutlineInputBorder(),
        ),
        child: const Row(
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            SizedBox(width: UtenSpacing.s8),
            Text('正在加载可选业务员…'),
          ],
        ),
      );
    }
    final error = _scopeErrors[scope];
    if (error != null) {
      return Semantics(
        liveRegion: true,
        child: Container(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: UtenColors.error.withValues(alpha: 0.06),
            border: Border.all(color: UtenColors.error.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline_rounded, color: UtenColors.error),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      definition.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      error,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: UtenColors.error,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => unawaited(_loadScope(definition)),
                child: const Text('重试'),
              ),
            ],
          ),
        ),
      );
    }

    final items = _scopeItems(scope);
    final selection = _scopeSelection(scope);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          definition.description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        UtenEmployeeMultiPicker(
          key: ValueKey(
            'scope-$scope-${selection.map((item) => item.id).join(',')}',
          ),
          label: definition.label,
          hint: '仅本人（默认）',
          sheetTitle: '配置${definition.label}',
          searchHint: '搜索业务员姓名',
          emptyMessage: '暂无匹配且拥有归属数据的业务员',
          selectedCountLabel: (count) => '已加看 $count 人',
          initialSelection: selection,
          enabled: !_scopeSaving.contains(scope),
          loader: (keyword) async {
            final query = keyword?.trim().toLowerCase() ?? '';
            if (query.isEmpty) return items;
            return items
                .where((item) => item.name.toLowerCase().contains(query))
                .toList(growable: false);
          },
          onChanged: (next) => unawaited(_saveScopeSelection(definition, next)),
        ),
      ],
    );
  }

  Widget _inlineNotice(String message, IconData icon, Color color) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ===== 云端(外网)访问授权 =====

  /// 置于详情最顶部：授权/取消该账号在云端(外网)使用本平台。
  /// 仅超管可见可改（canManageAuthorization = 超管 + authorization:manage）；
  /// 变更由后端 V241 触发器即时 bump auth_version，旧 access token 立即失效。
  Widget _remoteAccessTile(bool remoteAccess) {
    final theme = Theme.of(context);
    final name = widget.user.employeeName ?? widget.user.loginAccount;
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
                  remoteAccess
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
            onPressed: _acting ? null : () => _toggleRemoteAccess(remoteAccess),
            child: Text(remoteAccess ? '取消授权' : '授权云端'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleRemoteAccess(bool current) async {
    final next = !current;
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
    return UtenCard(
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
          _infoRow('部门', user.departmentName ?? '—'),
          _infoRow('登录账号', user.loginAccount),
          _infoRow('上次登录', user.lastLoginAt ?? '—'),
          if (user.mustChangePassword)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Text(
                '该账号已被要求下次登录修改密码',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: UtenColors.warning,
                ),
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
                  onPressed: () => _runAccountAction(
                    label: '锁定',
                    danger: true,
                    call: (repository) => repository.lockUser(user.id),
                  ),
                  child: const Text('锁定'),
                ),
              if (user.status == 'locked')
                UtenButton(
                  type: UtenButtonType.secondary,
                  size: UtenButtonSize.small,
                  icon: Icons.lock_open_rounded,
                  isLoading: _acting,
                  onPressed: () => _runAccountAction(
                    label: '解锁',
                    danger: false,
                    call: (repository) => repository.unlockUser(user.id),
                  ),
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
                  onPressed: () => _runAccountAction(
                    label: '启用',
                    danger: false,
                    call: (repository) => repository.enableUser(user.id),
                  ),
                  child: const Text('启用'),
                ),
              UtenButton(
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                icon: Icons.key_rounded,
                isLoading: _acting,
                onPressed: _acting ? null : _resetPassword,
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
                  isSuperAdmin
                      ? '默认拥有全部功能权限、可管理他人授权。'
                      : '设为超级管理员后，该账号拥有全部功能、可管理他人授权。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          FilledButton.tonal(
            onPressed: _acting
                ? null
                : () => _toggleSuperAdmin(promote: promote),
            style: FilledButton.styleFrom(
              foregroundColor: promote
                  ? UtenColors.warning
                  : theme.colorScheme.error,
              visualDensity: VisualDensity.compact,
            ),
            child: Text(isSuperAdmin ? '取消超管' : '设为超管'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleSuperAdmin({required bool promote}) async {
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
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '$label失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<void> _resetPassword() async {
    final confirmed = await UtenDialog.show(
      context,
      title: '重置密码确认',
      content: Text(
        '确定要重置「${widget.user.employeeName ?? widget.user.loginAccount}」的登录密码吗？'
        '系统将生成仅显示一次的临时密码。',
      ),
      confirmLabel: '重置密码',
      danger: true,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      final temporaryPassword = await ref
          .read(adminRepositoryProvider)
          .resetPassword(widget.user.id);
      if (!mounted) return;
      widget.onAccountChanged();
      await _showTemporaryPassword(temporaryPassword);
    } catch (_) {
      if (mounted) UtenToast.error(context, '重置密码失败，请稍后重试');
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
            const Text('请立即安全地交给该员工。关闭此窗口后，系统不会再次显示或保存这段明文。'),
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

class _DataScopeDefinition {
  const _DataScopeDefinition({
    required this.scope,
    required this.label,
    required this.description,
  });

  final String scope;
  final String label;
  final String description;
}
