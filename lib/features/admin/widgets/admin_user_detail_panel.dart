// AdminUserDetailPanel - 员工账号、功能权限与数据范围详情。
//
// 高密度授权信息按三个页内分区呈现，默认进入功能权限。完整权限目录仍由后端动态
// 下发；前端只负责搜索、筛选、分组和把最终状态变化换算为个人 grants/revokes。
// 「全部授权 / 本模块 / 本组」交给服务端按授权策略补齐(ADR-109)，本页不维护排除名单。

import 'dart:math' as math;
import 'dart:async';

import 'package:flutter/material.dart';
import '../../../core/network/read_scope_revision.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/utils/display_datetime.dart';
import '../../../core/l10n/remote_access_text.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_page_layout.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/permission_action_type.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../models/admin_models.dart';
import '../pages/admin_permissions_page.dart' show AccountStatusBadge;
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import '../repositories/permission_configuration_repository.dart';
import '../../employee/widgets/employee_credential_dialog.dart';
import 'admin_data_scope_section.dart';
import 'admin_permission_transfer_actions.dart';
import 'admin_permission_templates.dart';
import 'admin_permission_export_button.dart';
import 'permission_catalog_browser.dart';
import 'admin_permission_editor_surface.dart';
import 'permission_action_badge.dart';
import 'permission_draft_session.dart';
import 'permission_template_binding_strip.dart';
import 'set_temporary_password_dialog.dart';
import 'admin_account_lifecycle_text.dart';

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
      AdminUserDetailPanelState();
}

class AdminUserDetailPanelState extends ConsumerState<AdminUserDetailPanel> {
  final _catalogMount = PermissionCatalogMount();
  _UserDetailSection _section = _UserDetailSection.permissions;

  /// 本地待保存的加授/收回集合；null = 未做编辑（跟随服务端数据）。
  Set<String>? _localGrants;
  Set<String>? _localRevokes;
  bool _savingOverrides = false;
  bool? _lastReportedPermissionDirty;
  bool _acting = false;
  bool _confirmingAccountAction = false;
  bool get _networkActing => _acting && !_confirmingAccountAction;
  int _accountOperation = 0;
  final _credentialOwner = ValueNotifier<int>(0);

  /// 可查看数据分区的草稿句柄（闲置自动保存/批量保存由分区自管，这里只取句柄）。
  final _dataScopeHandle = AdminDataScopeSectionHandle();
  bool _dataScopeDirty = false;
  late final PermissionDraftSession _idleSave;

  @override
  void initState() {
    super.initState();
    _idleSave = PermissionDraftSession(onIdleSave: () => _saveOverrides());
  }

  @override
  void dispose() {
    _accountOperation++;
    _credentialOwner.value++;
    _credentialOwner.dispose();
    _idleSave.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AdminUserDetailPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final identityChanged =
        oldWidget.user.id != widget.user.id ||
        oldWidget.canManageAuthorization != widget.canManageAuthorization;
    final lifecycleChanged =
        oldWidget.user.status != widget.user.status ||
        oldWidget.user.employeeStatus != widget.user.employeeStatus ||
        oldWidget.user.currentEmployee != widget.user.currentEmployee ||
        oldWidget.user.accountSupportAllowed !=
            widget.user.accountSupportAllowed;
    if (!identityChanged && !lifecycleChanged) {
      return;
    }
    if (identityChanged) {
      _section = _UserDetailSection.permissions;
    }
    _accountOperation++;
    _credentialOwner.value++;
    _acting = false;
    _confirmingAccountAction = false;
    _localGrants = null;
    _localRevokes = null;
    _dataScopeDirty = false;
    _idleSave.clear();
    _lastReportedPermissionDirty = null;
    if (lifecycleChanged) {
      // didUpdateWidget 处于 build 期；Riverpod 3 的 provider 刷新经 vsync 在
      // ProviderScope 上 setState，直接 invalidate 会触发 "markNeedsBuild
      // called during build" 断言，推迟到本帧结束后再失效。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
        }
      });
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
    ref.watch(currentPermissionsProvider);
    ref.watch(authenticatedScopeProvider);
    ref.listen(sensitiveReadBoundaryProvider, (previous, next) {
      if (previous != null && previous != next) {
        _accountOperation++;
        _credentialOwner.value++;
        setState(() {
          _acting = false;
          _confirmingAccountAction = false;
        });
      }
    });
    final effectiveAsync = widget.canManageAuthorization
        ? ref.watch(adminEffectivePermissionsProvider(widget.user.id))
        : null;
    final data = effectiveAsync?.value;
    final dirtyCount = data == null ? 0 : _dirtyCount(data);
    final legacyUnknownCount = data == null
        ? 0
        : {...data.legacyUnknownGrants, ...data.legacyUnknownRevokes}.length;
    final permissionDirty =
        dirtyCount > 0 || _savingOverrides || _acting || _dataScopeDirty;
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
        // 个人数据权限保存/恢复默认网络段的全屏加载遮罩（root Overlay 传送门）。
        if (_savingOverrides)
          const UtenBusyOverlay(
            title: '正在保存个人数据权限',
            description: '正在保存个人权限设置，请勿重复提交或离开本页。',
          ),
        Expanded(
          child: UtenPageEdgePadding.scroll(
            // compact 悬浮胶囊避让：滚到底末行要能越过胶囊
            padding: EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s4,
              UtenSpacing.s16,
              math.max(
                UtenSpacing.s32,
                UtenCapsuleNavScope.occlusionOf(context),
              ),
            ),
            preserveStart: !widget.showBack,
            builder: (context, pagePadding) => ListView(
              padding: pagePadding,
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
                _userSummary(data),
                if (!widget.user.currentEmployee) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  _employmentRestrictionNotice(),
                ],
                if (widget.canManageAuthorization) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  // 云端访问授权置于最顶部（用户要求「权限设置最顶部」），与超管身份并排一行；
                  // 窄屏自动回退竖排。
                  LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth >= 640) {
                        // ListView 子项高度无界，stretch 须先经 IntrinsicHeight 定高。
                        return IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Expanded(
                                child: _remoteAccessTile(
                                  widget.user.remoteAccess,
                                ),
                              ),
                              const SizedBox(width: UtenSpacing.s12),
                              Expanded(child: _superAdminTile(data)),
                            ],
                          ),
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _remoteAccessTile(widget.user.remoteAccess),
                          const SizedBox(height: UtenSpacing.s12),
                          _superAdminTile(data),
                        ],
                      );
                    },
                  ),
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
                      key: ValueKey((
                        widget.user.id,
                        ref.watch(permissionConfigurationRevisionProvider),
                      )),
                      user: widget.user,
                      effectiveAsync: effectiveAsync!,
                      onAccountChanged: widget.onAccountChanged,
                      handle: _dataScopeHandle,
                      onDirtyChanged: (dirty) {
                        if (_dataScopeDirty == dirty || !mounted) return;
                        setState(() => _dataScopeDirty = dirty);
                      },
                    ),
                    _UserDetailSection.account => _accountSection(),
                  },
              ],
            ),
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
                        : '有 $legacyUnknownCount 项历史权限设置待超级管理员确认',
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
                          _idleSave.clear();
                        }),
                  child: const Text('撤销'),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  size: UtenButtonSize.small,
                  isLoading: _savingOverrides,
                  onPressed: _savingOverrides ? null : () => _saveOverrides(),
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
    unawaited(
      _guardDraftsBeforeLeave().then((allowed) {
        if (allowed && mounted) setState(() => _section = section);
      }),
    );
  }

  // ===== 草稿（操作权限覆盖 + 可查看数据）对宿主页面的统一出口 =====

  /// 是否有待保存的本地修改（供员工切换/页面离开守卫判断）。
  bool get hasDrafts =>
      (_localGrants != null || _localRevokes != null) ||
      _dataScopeHandle.hasDrafts;

  /// 保存全部草稿（覆盖 + 可查看数据）；true=已全部落库。
  Future<bool> saveDrafts() async {
    final overridesSaved = await _saveOverrides();
    if (!overridesSaved) return false;
    if (_dataScopeHandle.hasDrafts) {
      return _dataScopeHandle.saveDrafts();
    }
    return true;
  }

  /// 离开前三选一：保存并离开 / 不保存（丢弃） / 继续编辑。true=允许离开。
  Future<bool> confirmLeaveDrafts() async {
    if (!hasDrafts || !mounted) return true;
    _idleSave.pause();
    _dataScopeHandle.pauseAutoSave();
    try {
      final data = _currentEffective;
      final count =
          (data == null ? 0 : _dirtyCount(data)) +
          (_dataScopeHandle.hasDrafts ? 1 : 0);
      final allowed = await guardPermissionDraftLeave(
        context,
        subject: '${widget.user.employeeName ?? widget.user.loginAccount}：',
        changeCount: count,
        save: () => saveDrafts(),
      );
      if (allowed && mounted) _discardDrafts();
      return allowed;
    } finally {
      if (mounted) {
        _idleSave.resume();
        _dataScopeHandle.resumeAutoSave();
      }
    }
  }

  /// 丢弃全部本地草稿（不落库）。
  void _discardDrafts() {
    _localGrants = null;
    _localRevokes = null;
    _idleSave.clear();
    _dataScopeHandle.discardDrafts();
  }

  Future<bool> _guardDraftsBeforeLeave() => confirmLeaveDrafts();

  Widget _userSummary(EffectivePermissions? data) {
    final theme = Theme.of(context);
    final user = widget.user;
    final displayName = user.employeeName ?? user.loginAccount;
    final initial = displayName.trim().isEmpty
        ? '?'
        : displayName.trim().substring(0, 1).toUpperCase();
    final subtitle = [
      user.loginAccount,
      if ((user.employeeCode ?? '').trim().isNotEmpty)
        user.employeeCode!.trim(),
      if ((user.departmentName ?? '').trim().isNotEmpty)
        user.departmentName!.trim(),
      if ((user.positionName ?? '').trim().isNotEmpty)
        user.positionName!.trim(),
    ].join(' · ');
    final headerActions = _accountHeaderActions(data);
    return UtenCard(
      key: const ValueKey('admin-user-summary-card'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final inlineActions =
              headerActions.isNotEmpty && constraints.maxWidth >= 800;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
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
                          subtitle,
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
                  if (inlineActions) ...[
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Wrap(
                        alignment: WrapAlignment.end,
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s8,
                        children: headerActions,
                      ),
                    ),
                  ],
                ],
              ),
              if (headerActions.isNotEmpty && !inlineActions) ...[
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: headerActions,
                ),
              ],
            ],
          );
        },
      ),
    );
  }

  bool get _hasAccountSupport =>
      widget.canManageAuthorization ||
      ref.read(currentPermissionsProvider).contains(Perm.accountSupport);

  bool _supportTargetAllowed(EffectivePermissions? data) =>
      _hasAccountSupport &&
      widget.user.accountSupportAllowed != false &&
      ref.read(authenticatedScopeProvider)?.userId != widget.user.id &&
      data?.superAdmin != true;

  List<Widget> _accountHeaderActions(EffectivePermissions? data) {
    final user = widget.user;
    final actions = <Widget>[];
    // 本面板只管理已有登录账号，操作按账号当前状态提供。
    if (!_supportTargetAllowed(data)) return actions;
    if (!user.knownAccountState) return actions;
    final locked = user.status == 'locked';
    final disabled = user.status == 'disabled';
    final label = locked
        ? '解锁账号'
        : disabled
        ? '启用账号'
        : '锁定账号';
    actions.add(
      UtenButton(
        key: const ValueKey('admin-header-account-status'),
        size: UtenButtonSize.small,
        type: locked || disabled
            ? UtenButtonType.secondary
            : UtenButtonType.danger,
        icon: locked || disabled
            ? Icons.lock_open_rounded
            : Icons.lock_outline_rounded,
        isLoading: _networkActing,
        onPressed: _acting || !user.currentEmployee
            ? null
            : () => _runAccountAction(
                label: label,
                danger: !locked && !disabled,
                call: (repository) => locked
                    ? repository.unlockUser(user.id)
                    : disabled
                    ? repository.enableUser(user.id)
                    : repository.lockUser(user.id),
              ),
        onDisabledTap: _acting || user.currentEmployee
            ? null
            : _explainLifecycleRestriction,
        child: Text(label),
      ),
    );
    if (!disabled) {
      actions.add(
        UtenButton(
          size: UtenButtonSize.small,
          type: UtenButtonType.secondary,
          icon: Icons.block_rounded,
          onPressed: _acting
              ? null
              : () => _runAccountAction(
                  label: '停用账号',
                  danger: true,
                  call: (repository) => repository.disableUser(user.id),
                ),
          child: const Text('停用账号'),
        ),
      );
    }
    return actions;
  }

  /// 权限明细「全部收回」：把整个目录的权限码全部标记为个人收回（本地暂存），
  /// 并跳回操作权限分区露出保存条；实际生效仍走「保存更改」。
  Future<void> _confirmRevokeAll(EffectivePermissions data) async {
    if (!widget.user.authorizationGrantAllowed) {
      _explainAuthorizationRestriction();
      return;
    }
    final catalog = ref.read(permissionCatalogProvider).value;
    final codes = [
      for (final group in catalog ?? const <PermissionCatalogGroup>[])
        for (final permission in group.permissions) permission.code,
    ];
    if (codes.isEmpty) return;
    final name = widget.user.employeeName ?? widget.user.loginAccount;
    final confirmed = await UtenDialog.show(
      context,
      title: '全部收回权限',
      content: Text(
        '将把「$name」的全部 ${codes.length} 项权限设为未授权（含部门与基础权限，'
        '仅对该账号个人收回），点击下方「保存更改」后生效。',
      ),
      confirmLabel: '确认收回',
      danger: true,
    );
    if (!mounted || confirmed != true) return;
    _setPermissionCodes(data, codes, false);
    if (_section != _UserDetailSection.permissions) {
      setState(() => _section = _UserDetailSection.permissions);
    }
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
    final reason = adminAuthorizationRestrictionText(context, widget.user);
    if (reason.isNotEmpty) UtenToast.info(context, reason);
  }

  void _explainLifecycleRestriction() {
    final reason = widget.user.knownAccountState
        ? widget.user.lifecycleRestrictionReason
        : adminAuthorizationRestrictionText(context, widget.user);
    if (reason.isNotEmpty) UtenToast.info(context, reason);
  }

  // ===== 功能权限 =====

  Widget _permSection(
    AsyncValue<EffectivePermissions> effectiveAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
  ) {
    final theme = Theme.of(context);
    final data = effectiveAsync.value;
    return AdminPermissionEditorSurface(
      key: const ValueKey('admin-user-permission-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _permissionHeading(data, catalogAsync.value),
          PermissionTemplateBindingStrip(
            kind: 'user',
            targetId: widget.user.id,
            enabled:
                data != null && _dirtyCount(data) == 0 && !_savingOverrides,
          ),
          if (!widget.user.authorizationGrantAllowed) ...[
            const SizedBox(height: UtenSpacing.s8),
            _authorizationRestrictionCard(data),
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
          if (data != null &&
              data.missingDependencies.isNotEmpty &&
              !data.superAdmin) ...[
            Text(
              '有 ${data.missingDependencies.length} 项授权尚缺对应页面所需的查看权限，请补齐后再从该页面操作。',
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed:
                    _savingOverrides || !widget.user.authorizationGrantAllowed
                    ? null
                    : () => _repairMissingDependencies(data),
                child: const Text('补齐所需查看权限'),
              ),
            ),
          ],
          _permMatrix(effectiveAsync, catalogAsync),
        ],
      ),
    );
  }

  Widget _permissionHeading(
    EffectivePermissions? data,
    List<PermissionCatalogGroup>? catalog,
  ) {
    final bulkEnabled =
        data != null &&
        catalog != null &&
        !data.superAdmin &&
        widget.user.authorizationGrantAllowed &&
        !_savingOverrides &&
        !_acting;
    final actions = <Widget>[
      AdminPermissionExportButton(
        scope: PermissionExportScope.employee,
        sourceId: widget.user.id,
        sourceName: widget.user.employeeName ?? widget.user.loginAccount,
        disabledReason: data?.superAdmin == true
            ? '超级管理员默认拥有全部权限，不能导出为普通员工的可恢复权限文件'
            : null,
        enabled:
            data != null &&
            !data.superAdmin &&
            _dirtyCount(data) == 0 &&
            !_savingOverrides &&
            !_acting,
      ),
      AdminPermissionTemplateActions(
        user: widget.user,
        enabled: bulkEnabled && _dirtyCount(data) == 0,
        onApplied: () {
          if (!mounted) return;
          _discardPermissionDraftAfterAccountAction();
          ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
          widget.onAccountChanged();
        },
      ),
      AdminPermissionCopyActions(
        user: widget.user,
        enabled: bulkEnabled && _dirtyCount(data) == 0,
        onApplied: () {
          if (!mounted) return;
          _discardPermissionDraftAfterAccountAction();
          ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
          widget.onAccountChanged();
        },
      ),
      if (data?.superAdmin != true) ...[
        UtenButton(
          key: const ValueKey('admin-grant-all-permissions'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.small,
          icon: Icons.done_all_rounded,
          isLoading: _networkActing,
          onPressed: bulkEnabled
              ? () => _grantScope(data, PermissionBulkScope.everything)
              : null,
          onDisabledTap: widget.user.authorizationGrantAllowed
              ? null
              : _explainAuthorizationRestriction,
          child: const Text('全部授权'),
        ),
        UtenButton(
          key: const ValueKey('admin-revoke-all-permissions'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.small,
          icon: Icons.remove_done_outlined,
          isLoading: _networkActing,
          onPressed: bulkEnabled ? () => _confirmRevokeAll(data) : null,
          onDisabledTap: widget.user.authorizationGrantAllowed
              ? null
              : _explainAuthorizationRestriction,
          child: const Text('全部收回'),
        ),
      ],
    ];
    final title = Text(
      '权限明细',
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
    );
    final actionBar = Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      children: actions,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >=
            MediaQuery.textScalerOf(context).scale(720)) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              title,
              const SizedBox(width: UtenSpacing.s16),
              Expanded(child: actionBar),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            title,
            const SizedBox(height: UtenSpacing.s8),
            actionBar,
          ],
        );
      },
    );
  }

  bool _hasPersonalOverrides(EffectivePermissions data) =>
      data.grants.isNotEmpty ||
      data.revokes.isNotEmpty ||
      data.legacyUnknownGrants.isNotEmpty ||
      data.legacyUnknownRevokes.isNotEmpty;

  Widget _authorizationRestrictionCard(EffectivePermissions? data) {
    final theme = Theme.of(context);
    final reason = adminAuthorizationRestrictionText(context, widget.user);
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
                  '$reason。不能新增或调整个人授权；可清空已有个人权限设置。',
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
    final data = effectiveAsync.value;
    final groups = catalogAsync.value;
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
        description: '服务器尚未返回可设置的权限。',
      );
    }

    final grants = _pendingGrants(data);
    final revokes = _pendingRevokes(data);
    final canEdit = !data.superAdmin && widget.user.authorizationGrantAllowed;
    return PermissionCatalogBrowser(
      key: _catalogMount.forOwner((
        ref.watch(sensitiveReadBoundaryProvider),
        ref.watch(readScopeRevisionProvider),
        widget.user.id,
      )),
      groups: groups,
      isEnabled: (permission) => _switchValue(data, permission.code),
      isChanged: (permission) =>
          grants.contains(permission.code) || revokes.contains(permission.code),
      changedFilterLabel: '个人单独设置',
      // 全量操作位于权限明细标题旁；目录里只保留模块/子类分组批量。
      showGlobalBulkActions: false,
      onGrantScope: canEdit ? (scope) => _grantScope(data, scope) : null,
      onDisableGroup: canEdit
          ? (permissions) => _setPermissions(data, permissions, false)
          : null,
      itemBuilder: (context, permission) => _permRow(data, permission),
    );
  }

  bool _isPermissionChanged(EffectivePermissions data, String code) =>
      _pendingGrants(data).contains(code) != data.grants.contains(code) ||
      _pendingRevokes(data).contains(code) != data.revokes.contains(code);

  bool _switchValue(EffectivePermissions data, String code) {
    if (data.superAdmin) return true;
    if (!_isPermissionChanged(data, code)) {
      return data.effective.contains(code);
    }
    final inherited =
        data.departmentPermissions.contains(code) ||
        data.baselinePermissions.contains(code) ||
        data.managerGrants.contains(code) ||
        data.templatePermissions.contains(code);
    // A local switch previews only the requested configuration. The server
    // computes effective authority and required reads after saving.
    return !_pendingRevokes(data).contains(code) &&
        (inherited || _pendingGrants(data).contains(code));
  }

  Set<String> _repairableReads(EffectivePermissions data) {
    final catalog = ref.read(permissionCatalogProvider).value;
    if (catalog == null) return const {};
    final byCode = {
      for (final group in catalog)
        for (final permission in group.permissions) permission.code: permission,
    };
    final held = <String>{
      ...data.departmentPermissions,
      ...data.baselinePermissions,
      ...data.managerGrants,
      ...data.templatePermissions,
      ..._pendingGrants(data),
    }..removeAll(_pendingRevokes(data));
    final codes = <String>{};
    for (final entry in data.missingDependencies.entries) {
      if (_isPermissionChanged(data, entry.key) &&
          !_switchValue(data, entry.key)) {
        continue;
      }
      for (final code in entry.value) {
        if (held.contains(code)) continue;
        final dependency = byCode[code];
        if (_pendingRevokes(data).contains(code) ||
            dependency == null ||
            dependency.actionType != PermissionActionType.view ||
            dependency.sensitivity != 'NORMAL' ||
            !dependency.grantPolicy.individuallyGrantable ||
            !dependency.grantPolicy.bulkEligible) {
          continue;
        }
        codes.add(code);
      }
    }
    return codes;
  }

  void _repairMissingDependencies(EffectivePermissions data) {
    final codes = _repairableReads(data);
    if (codes.isEmpty) {
      context.appInfo('没有可自动补齐的普通查看权限；已收回或敏感的权限请在允许的授权入口逐项处理。');
      return;
    }
    _setPermissionCodes(data, codes, true);
  }

  /// 「全部授权 / 本模块 / 本组」：服务端按授权策略补齐个人加授并立即生效。
  /// 与本地暂存的逐项修改分开：有未保存修改时先让管理员保存或撤销。
  Future<void> _grantScope(
    EffectivePermissions data,
    PermissionBulkScope scope,
  ) async {
    if (_savingOverrides) return;
    if (!widget.user.authorizationGrantAllowed) {
      _explainAuthorizationRestriction();
      return;
    }
    if (_dirtyCount(data) > 0) {
      context.appWarning('请先保存或撤销当前的逐项修改，再做批量授权');
      return;
    }
    final name = widget.user.employeeName ?? widget.user.loginAccount;
    final confirmed = await UtenDialog.show(
      context,
      title: '批量授权',
      content: Text(
        '将把${scope.label}里可以批量授予的权限加授给「$name」，保存后立即生效。'
        '需要逐项勾选的敏感权限不会带上。',
      ),
      confirmLabel: '确认授权',
    );
    if (!mounted || confirmed != true) return;
    setState(() => _savingOverrides = true);
    try {
      final change = await ref
          .read(adminRepositoryProvider)
          .grantAllToUser(widget.user.id, scope);
      ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
      if (!mounted) return;
      context.appSuccess(
        change.added.isEmpty
            ? '没有新增：可批量授予的权限都已生效'
            : '已为「$name」加授 ${change.added.length} 项权限，即时生效',
      );
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appApiError(error, fallback: '批量授权失败，请稍后重试');
    } catch (_) {
      if (mounted) context.appError('批量授权失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  Future<void> _togglePerm(
    EffectivePermissions data,
    AdminPermission permission,
    bool value,
  ) async {
    if (value &&
        !permission.grantPolicy.bulkEligible &&
        !_switchValue(data, permission.code)) {
      final confirmed = await UtenDialog.show(
        context,
        title: '确认单项授权',
        content: Text(
          [
            '“',
            permission.name,
            '”会开放',
            permission.sensitivity == 'SENSITIVE_COMMERCIAL'
                ? '商业敏感数据'
                : '高风险操作',
            '。该权限不会被批量授权带入，请确认该员工确需访问。',
          ].join(),
        ),
        confirmLabel: '确认授权',
        danger: true,
      );
      if (!mounted || confirmed != true) return;
    }
    _setPermissionCodes(data, {permission.code}, value);
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
      ...data.templatePermissions,
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
    // 本地草稿：闲置一分钟自动保存，离开/切员工前统一询问。
    _idleSave.noteEdit();
  }

  Widget _permRow(EffectivePermissions data, AdminPermission permission) {
    final theme = Theme.of(context);
    final grants = _pendingGrants(data);
    final revokes = _pendingRevokes(data);
    final viaDept = data.departmentPermissions.contains(permission.code);
    final viaBaseline = data.baselinePermissions.contains(permission.code);
    final viaManager = data.managerGrants.contains(permission.code);
    final viaTemplate = data.templatePermissions.contains(permission.code);
    final revoked = !data.superAdmin && revokes.contains(permission.code);
    final pending = _isPermissionChanged(data, permission.code);
    final enabled = _switchValue(data, permission.code);
    final effective =
        data.superAdmin || data.effective.contains(permission.code);
    final incomplete =
        data.missingDependencies.containsKey(permission.code) && !pending;
    // 只随超级管理员身份生效的码不能逐人加授(授权策略由服务端下发)；已生效的仍可收回。
    final policyAllows =
        permission.grantPolicy.individuallyGrantable || effective;
    final canEdit =
        !data.superAdmin &&
        widget.user.authorizationGrantAllowed &&
        policyAllows;
    final editRestriction = data.superAdmin
        ? '超级管理员默认拥有全部权限，不能逐项调整'
        : !policyAllows
        ? '这项权限只随超级管理员身份生效，不能逐人授予'
        : adminAuthorizationRestrictionText(context, widget.user);

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PermissionTitleBlock(
          name: permission.name,
          actionType: permission.actionType,
          description: permission.description,
          grantPolicy: permission.grantPolicy,
          baseline: permission.baseline,
          sensitivity: permission.sensitivity,
          nameStyle: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: revoked ? UtenColors.error : null,
            decoration: revoked ? TextDecoration.lineThrough : null,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        if (incomplete)
          Text(
            '尚缺对应页面所需的查看权限',
            style: theme.textTheme.bodySmall?.copyWith(color: UtenColors.error),
          ),
        Wrap(
          spacing: UtenSpacing.s4,
          runSpacing: UtenSpacing.s4,
          children: [
            if (viaDept) _sourceTag('部门'),
            if (viaBaseline) _sourceTag('基础'),
            if (viaManager) _sourceTag('负责人授权'),
            if (viaTemplate) _sourceTag('模板'),
            if (grants.contains(permission.code)) _sourceTag('个人单独授权'),
            if (data.legacyUnknownGrants.contains(permission.code))
              _sourceTag('历史授权待确认', danger: true),
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
          label: pending
              ? '待保存'
              : effective
              ? '已授权'
              : incomplete
              ? '未完整生效'
              : '未授权',
          type: effective
              ? UtenStatusBadgeType.success
              : UtenStatusBadgeType.neutral,
          size: UtenStatusBadgeSize.small,
        ),
        const SizedBox(width: UtenSpacing.s4),
        Semantics(
          label:
              '${permission.name}${pending
                  ? '待保存'
                  : enabled
                  ? '已授权'
                  : '未授权'}',
          enabled: canEdit,
          hint: canEdit ? null : editRestriction,
          child: Switch(
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            value: enabled,
            onChanged: canEdit
                ? (value) => _togglePerm(data, permission, value)
                : null,
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 370) {
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
        borderRadius: BorderRadius.circular(UtenRadius.xs),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: danger ? UtenColors.error : theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  /// 保存个人覆盖草稿；true=已落库（或本就没有待保存内容）。
  Future<bool> _saveOverrides() async {
    final data = _currentEffective;
    if (data == null) return false;
    final hasLegacyUnknown =
        data.legacyUnknownGrants.isNotEmpty ||
        data.legacyUnknownRevokes.isNotEmpty;
    if (_savingOverrides || (_dirtyCount(data) == 0 && !hasLegacyUnknown)) {
      return _dirtyCount(data) == 0;
    }
    if (!widget.user.authorizationGrantAllowed &&
        (_pendingGrants(data).isNotEmpty || _pendingRevokes(data).isNotEmpty)) {
      _explainAuthorizationRestriction();
      return false;
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
      if (!mounted) return true;
      setState(() {
        _localGrants = null;
        _localRevokes = null;
      });
      _idleSave.clear();
      UtenToast.success(
        context,
        hasLegacyUnknown ? '历史权限来源已确认并即时生效' : '权限调整已保存并即时生效',
      );
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      if (error.code == 'CONFLICT') {
        setState(() {
          _localGrants = null;
          _localRevokes = null;
        });
        _idleSave.clear();
        ref.invalidate(adminEffectivePermissionsProvider(widget.user.id));
        widget.onAccountChanged();
      }
      UtenToast.error(
        context,
        error.message.isNotEmpty ? error.message : '保存失败，本地修改已保留，请稍后重试',
      );
      return false;
    } catch (_) {
      if (!mounted) return false;
      UtenToast.error(context, '保存失败，本地修改已保留，请稍后重试');
      return false;
    } finally {
      if (mounted) setState(() => _savingOverrides = false);
    }
  }

  Future<void> _clearOverrides(EffectivePermissions data) async {
    if (_savingOverrides || !_hasPersonalOverrides(data)) return;
    final confirmed = await UtenDialog.show(
      context,
      title: '清空个人授权？',
      content: const Text(
        '将清空此人的单独授权、单独收回和待确认历史设置；之后按部门、全员基础、关联模板和仍有效的负责人授权重新计算权限。',
      ),
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
        borderRadius: BorderRadius.circular(UtenRadius.control),
        border: Border.all(
          color: remoteAccess
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Row(
        children: [
          Icon(
            remoteAccess ? Icons.cloud_done_rounded : Icons.cloud_off_rounded,
            size: 20,
            color: remoteAccess
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  remoteAccessText(
                    context,
                    remoteAccess ? 'granted' : 'notGranted',
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  !remoteAccess && !grantAllowed
                      ? '${adminAuthorizationRestrictionText(context, widget.user)}，不能开放外网访问。'
                      : '$name：${remoteAccessText(context, 'grantHint')}',
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
            isLoading: _networkActing,
            onPressed: _acting || !grantAllowed
                ? null
                : () => _toggleRemoteAccess(remoteAccess),
            onDisabledTap: _acting || grantAllowed
                ? null
                : _explainAuthorizationRestriction,
            child: Text(
              remoteAccessText(context, remoteAccess ? 'revoke' : 'grant'),
            ),
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
      title: '$name：${remoteAccessText(context, next ? 'grant' : 'revoke')}',
      content: Text(
        remoteAccessText(context, next ? 'grantConfirm' : 'revokeConfirm'),
      ),
      confirmLabel: remoteAccessText(context, next ? 'grant' : 'revoke'),
      danger: !next,
    );
    if (confirmed != true || !mounted) return;
    setState(() => _acting = true);
    try {
      await ref
          .read(adminRepositoryProvider)
          .setRemoteAccess(widget.user.id, remoteAccess: next);
      if (!mounted) return;
      UtenToast.success(
        context,
        remoteAccessText(context, next ? 'granted' : 'notGranted'),
      );
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
    final expiry = DisplayDateTime.instantOf(user.tempPasswordExpiresAt);
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
              if (user.mustChangePassword) ...[
                _tempPasswordPendingNotice(expiry, expiryExpired),
                const SizedBox(height: UtenSpacing.s12),
              ],
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.small,
                icon: Icons.key_rounded,
                isLoading: _networkActing,
                onPressed:
                    _acting ||
                        !user.passwordResetAllowed ||
                        !_supportTargetAllowed(_currentEffective)
                    ? null
                    : _openSetTemporaryPassword,
                onDisabledTap:
                    _acting ||
                        user.passwordResetAllowed ||
                        !_supportTargetAllowed(_currentEffective)
                    ? null
                    : _explainLifecycleRestriction,
                child: Text(user.mustChangePassword ? '重新设置临时密码' : '设置临时密码'),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenCard(
          child: Row(
            children: [
              const Expanded(child: Text('账号状态')),
              AccountStatusBadge(status: user.status),
            ],
          ),
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
        borderRadius: BorderRadius.circular(UtenRadius.control),
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
                      : '临时密码有效期至 ${DisplayDateTime.beijing(expiry.toIso8601String())}，逾期自动失效',
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

  Widget _superAdminTile(EffectivePermissions? data) {
    final theme = Theme.of(context);
    final isSuperAdmin = data?.superAdmin ?? false;
    final promote = !isSuperAdmin;
    // 生效权限未加载完成前先禁用按钮，避免普通账号状态闪现可点的「设为超管」。
    final toggleAllowed =
        data != null && (!promote || widget.user.authorizationGrantAllowed);
    final promoteBlocked = promote && data != null && !toggleAllowed;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(UtenRadius.control),
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
                  promoteBlocked
                      ? '${adminAuthorizationRestrictionText(context, widget.user)}，不能授予超级管理员。'
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
            isLoading: _networkActing,
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
                  '之后按普通账号的权限设置使用。',
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
    final user = widget.user;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    if (_acting || !_supportTargetAllowed(_currentEffective)) return;
    final discardWarning = _permissionDiscardWarning;
    final operation = ++_accountOperation;
    setState(() {
      _acting = true;
      _confirmingAccountAction = true;
    });
    try {
      final confirmed = await UtenDialog.show(
        context,
        title: '$label确认',
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('确定要对「${user.employeeName ?? user.loginAccount}」执行「$label」吗？'),
            if (discardWarning != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                discardWarning,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
        confirmLabel: label,
        danger: danger,
      );
      if (confirmed != true ||
          !mounted ||
          !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      setState(() => _confirmingAccountAction = false);
      await call(ref.read(adminRepositoryProvider));
      if (!mounted || !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      if (discardWarning != null) _discardPermissionDraftAfterAccountAction();
      UtenToast.success(context, '$label成功');
      widget.onAccountChanged();
    } on ApiException catch (error) {
      if (!mounted || !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      if (error.code == 'CONFLICT') widget.onAccountChanged();
      UtenToast.error(
        context,
        error.message.isNotEmpty ? error.message : '$label失败，请刷新状态后重试',
      );
    } catch (_) {
      if (!mounted || !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      UtenToast.error(context, '$label失败，请稍后重试');
    } finally {
      if (mounted && operation == _accountOperation) {
        setState(() {
          _acting = false;
          _confirmingAccountAction = false;
        });
      }
    }
  }

  String? get _permissionDiscardWarning {
    final data = _currentEffective;
    final count = data == null ? 0 : _dirtyCount(data);
    return count == 0 ? null : '执行后会丢弃 $count 项尚未保存的权限修改。你可以取消并先保存或撤销修改。';
  }

  void _discardPermissionDraftAfterAccountAction() {
    setState(() {
      _localGrants = null;
      _localRevokes = null;
      _lastReportedPermissionDirty = false;
    });
    widget.onPermissionDirtyChanged?.call(false);
  }

  EffectivePermissions? get _currentEffective => widget.canManageAuthorization
      ? ref.read(adminEffectivePermissionsProvider(widget.user.id)).value
      : null;

  bool _accountActionCurrent(
    int operation,
    String userId,
    SensitiveReadBoundary boundary,
  ) =>
      mounted &&
      operation == _accountOperation &&
      widget.user.id == userId &&
      ref.read(sensitiveReadBoundaryProvider) == boundary &&
      _supportTargetAllowed(_currentEffective);

  /// 设置临时密码：先确认，再调端点 (服务端要求再认证，统一密码框)，最后一次性展示明文。
  Future<void> _openSetTemporaryPassword() async {
    final user = widget.user;
    if (_acting ||
        !user.passwordResetAllowed ||
        !_supportTargetAllowed(_currentEffective)) {
      return;
    }
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final discardWarning = _permissionDiscardWarning;
    final operation = ++_accountOperation;
    setState(() {
      _acting = true;
      _confirmingAccountAction = true;
    });
    try {
      final confirmed = await showSetTemporaryPasswordDialog(
        context,
        displayName: user.employeeName ?? user.loginAccount,
        loginAccount: user.loginAccount,
        permissionDiscardWarning: discardWarning,
      );
      if (confirmed != true ||
          !mounted ||
          !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      setState(() => _confirmingAccountAction = false);
      final temporaryPassword = await ref
          .read(adminRepositoryProvider)
          .resetPassword(user.id);
      if (!mounted || !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      if (discardWarning != null) _discardPermissionDraftAfterAccountAction();
      setState(() => _acting = false);
      await showAccountCredentialDialog(
        context,
        title: '一次性临时密码',
        temporaryPassword: temporaryPassword,
        loginAccount: user.loginAccount,
        employeeName: user.employeeName,
        employeeCode: user.employeeCode,
        isCurrent: () => _accountActionCurrent(operation, user.id, boundary),
        ownerChanges: _credentialOwner,
      );
      if (mounted && _accountActionCurrent(operation, user.id, boundary)) {
        widget.onAccountChanged();
      }
    } on ApiException catch (error) {
      if (!mounted || !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      if (error.code == 'CONFLICT') widget.onAccountChanged();
      UtenToast.error(
        context,
        error.message.isNotEmpty ? error.message : '设置临时密码失败，请稍后重试',
      );
    } catch (_) {
      if (!mounted || !_accountActionCurrent(operation, user.id, boundary)) {
        return;
      }
      UtenToast.error(context, '设置临时密码失败，请稍后重试');
    } finally {
      if (mounted && operation == _accountOperation) {
        setState(() {
          _acting = false;
          _confirmingAccountAction = false;
        });
      }
    }
  }
}

enum _UserDetailSection { permissions, dataScope, account }
