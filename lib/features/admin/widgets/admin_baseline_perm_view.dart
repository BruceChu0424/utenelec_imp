// AdminBaselinePermView - 全员基础包：每个在职员工都默认拥有的权限。
//
// 基础包取代了原来的「全员角色」(ADR-109)：只有超级管理员能改，保存时服务端按差量落库，
// 能否放进基础包只看服务端下发的授权策略(需要逐项授予 / 只能逐人授予 / 超管专属的码不行)。
// 基础包批量操作仅选择服务端允许进入基础包的普通权限，提交仍由服务端校验。
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/network/read_scope_revision.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../components/layout/uten_section_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import 'permission_action_badge.dart';
import 'permission_catalog_browser.dart';
import 'admin_permission_editor_surface.dart';
import 'permission_draft_session.dart';
import 'admin_permission_workspace.dart';
import 'admin_permission_export_button.dart';
import 'admin_permission_transfer_actions.dart';

class AdminBaselinePermView extends ConsumerStatefulWidget {
  const AdminBaselinePermView({
    super.key,
    this.leadingHeader = const SizedBox.shrink(),
    this.onPermissionDirtyChanged,
    this.onLeaveGuardChanged,
  });

  final Widget leadingHeader;
  final ValueChanged<bool>? onPermissionDirtyChanged;
  final ValueChanged<Future<bool> Function()?>? onLeaveGuardChanged;

  @override
  ConsumerState<AdminBaselinePermView> createState() =>
      _AdminBaselinePermViewState();
}

class _AdminBaselinePermViewState extends ConsumerState<AdminBaselinePermView> {
  final _catalogMount = PermissionCatalogMount();
  Set<String>? _localChecked;
  bool _saving = false;
  bool? _lastReportedPending;
  late final PermissionDraftSession _idleSave;

  @override
  void initState() {
    super.initState();
    _idleSave = PermissionDraftSession(onIdleSave: () => _save());
    widget.onLeaveGuardChanged?.call(_confirmLeaveDrafts);
  }

  @override
  void dispose() {
    _idleSave.dispose();
    widget.onLeaveGuardChanged?.call(null);
    super.dispose();
  }

  /// 离开守卫：有草稿时三选一；保存并离开会先走一次保存（一次密码）。
  Future<bool> _confirmLeaveDrafts() async {
    if (!_isDirty) return true;
    _idleSave.pause();
    try {
      final allowed = await guardPermissionDraftLeave(
        context,
        subject: '全员基础包',
        changeCount: _dirtyCount,
        save: () => _save(),
      );
      if (allowed && mounted && _isDirty) {
        setState(() => _localChecked = null);
        _idleSave.clear();
      }
      return allowed;
    } finally {
      if (mounted) _idleSave.resume();
    }
  }

  Set<String>? get _serverChecked =>
      ref.read(adminPermissionBaselineProvider).value?.toSet();

  /// 基础包钉死码(V832/ADR-170)：体系准入权限，任何移出操作都跳过。
  Set<String> get _pinnedCodes => {
    for (final group
        in ref.read(permissionCatalogProvider).value ??
            const <PermissionCatalogGroup>[])
      for (final permission in group.permissions)
        if (permission.baselinePinned) permission.code,
  };

  Set<String> get _checked =>
      _localChecked ?? _serverChecked ?? const <String>{};

  bool get _isDirty {
    final local = _localChecked;
    final server = _serverChecked;
    return local != null && server != null && !setEquals(local, server);
  }

  int get _dirtyCount {
    final local = _localChecked;
    final server = _serverChecked;
    if (local == null || server == null) return 0;
    return {
      ...local,
      ...server,
    }.where((code) => local.contains(code) != server.contains(code)).length;
  }

  void _setPermissions(Iterable<String> codes, bool value) {
    setState(() {
      final next = {..._checked};
      if (value) {
        next.addAll(codes);
      } else {
        // 「本组/本模块全部移出」也会走到这里：钉死码必须留下，否则保存会被服务端整单拒绝。
        next.removeAll(codes.where((code) => !_pinnedCodes.contains(code)));
      }
      _localChecked = next;
    });
    _idleSave.noteEdit();
  }

  /// 保存基础包草稿；true=已落库（或本就没有改动）。
  Future<bool> _save() async {
    if (_saving || !_isDirty) return true;
    setState(() => _saving = true);
    try {
      // 钉死码恒在提交集合里：即使库被手工改坏，从这里保存也会把它们带回基础包。
      final desired = <String>{..._checked, ..._pinnedCodes};
      final change = await ref
          .read(adminRepositoryProvider)
          .updatePermissionBaseline(desired.toList());
      // All open consumers must recompute inherited sources and dependency diagnostics.
      refreshPermissionConfiguration(ref);
      if (!mounted) return true;
      setState(() => _localChecked = null);
      _idleSave.clear();
      context.appSuccess(
        '已保存全员基础包：新增 ${change.added.length} 项，'
        '移出 ${change.removed.length} 项，即时生效',
      );
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      context.appApiError(error, fallback: '保存失败，本地修改已保留，请稍后重试');
      return false;
    } catch (_) {
      if (mounted) context.appError('保存失败，本地修改已保留，请稍后重试');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pending = _isDirty || _saving;
    if (_lastReportedPending != pending) {
      _lastReportedPending = pending;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onPermissionDirtyChanged?.call(pending);
      });
    }
    return AdminPermissionWorkspace(
      navigation: widget.leadingHeader,
      leading: ListView(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
        children: const [
          UtenSectionHeader(
            key: ValueKey('admin-baseline-scope-card'),
            title: '全体在职员工',
            info: _scopeMessage,
          ),
        ],
      ),
      trailing: _details(showNotice: false),
      compact: _details(showNotice: true),
    );
  }

  static const _scopeMessage =
      '基础包内的权限由每个在职员工默认拥有，只放大家都需要的自助类权限。'
      '需要逐项授权的敏感权限请按部门或员工配置。'
      '带锁的通知与员工自助权限不能移出，个别人需要关闭时请用个人收回。';

  Widget _details({required bool showNotice}) {
    final theme = Theme.of(context);
    final baselineAsync = ref.watch(adminPermissionBaselineProvider);
    final catalogAsync = ref.watch(permissionCatalogProvider);
    final checked = _checked;

    return Column(
      children: [
        if (_saving)
          const UtenBusyOverlay(
            title: '正在保存全员基础包',
            description: '正在写入基础包变更，请勿重复提交或离开本页。',
          ),
        Expanded(
          child: UtenPageEdgePadding.scroll(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s4,
              UtenSpacing.s16,
              UtenSpacing.s32,
            ),
            preserveStart: !showNotice,
            builder: (context, pagePadding) => ListView(
              padding: pagePadding,
              children: [
                AdminPermissionEditorSurface(
                  key: const ValueKey('admin-baseline-permission-card'),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: UtenSpacing.s16,
                        runSpacing: UtenSpacing.s8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const UtenSectionHeader(
                            title: '权限明细',
                            info: _scopeMessage,
                          ),
                          AdminPermissionExportButton(
                            scope: PermissionExportScope.baseline,
                            enabled:
                                !_isDirty && !_saving && baselineAsync.hasValue,
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _isDirty
                            ? '全员基础包 · 已包含 ${checked.length} 项 · $_dirtyCount 项未保存'
                            : '全员基础包 · 已包含 ${checked.length} 项',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: _isDirty
                              ? UtenColors.warning
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s12),
                      _body(baselineAsync, catalogAsync, checked),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_isDirty)
          UtenBottomActionBar(
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s16,
              vertical: UtenSpacing.s12,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '已修改 $_dirtyCount 项',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => setState(() {
                          _localChecked = null;
                          _idleSave.clear();
                        }),
                  child: const Text('撤销'),
                ),
                const SizedBox(width: UtenSpacing.s8),
                UtenButton(
                  size: UtenButtonSize.small,
                  isLoading: _saving,
                  onPressed: _saving ? null : _save,
                  child: const Text('保存更改'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _body(
    AsyncValue<List<String>> baselineAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
    Set<String> checked,
  ) {
    if (baselineAsync.hasError || catalogAsync.hasError) {
      return UtenEmpty.error(
        message: '全员基础包加载失败',
        description: '请检查网络后重试。',
        actionLabel: '重试',
        onAction: () => ref
          ..invalidate(adminPermissionBaselineProvider)
          ..invalidate(permissionCatalogProvider),
      );
    }
    final rawGroups = catalogAsync.value;
    if (rawGroups == null || baselineAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    // 只显示能放进基础包的码；已在包里的仍显示，便于移出。
    final groups = rawGroups
        .map(
          (group) => PermissionCatalogGroup(
            module: group.module,
            category: group.category,
            permissions: group.permissions
                .where(
                  (permission) =>
                      permission.grantPolicy.baselineEligible ||
                      checked.contains(permission.code),
                )
                .toList(growable: false),
          ),
        )
        .where((group) => group.permissions.isNotEmpty)
        .toList(growable: false);
    if (groups.isEmpty) {
      return const UtenEmpty(
        icon: Icons.security_outlined,
        message: '权限目录为空',
        description: '服务器尚未返回可设置的权限。',
      );
    }
    return PermissionCatalogBrowser(
      key: _catalogMount.forOwner((
        ref.watch(sensitiveReadBoundaryProvider),
        ref.watch(readScopeRevisionProvider),
        'baseline',
      )),
      groups: groups,
      enabledFilterLabel: '已包含',
      disabledFilterLabel: '未包含',
      disableGroupLabel: '本组全部移出',
      disableModuleLabel: '本模块全部移出',
      isEnabled: (permission) => checked.contains(permission.code),
      enableAllLabel: '全部加入基础包',
      disableAllLabel: '全部移出',
      enableModuleLabel: '本模块加入基础包',
      enableGroupLabel: '本组加入基础包',
      onGrantScope: (scope) async {
        final confirmed = await UtenDialog.show(
          context,
          title: '批量设置全员基础权限',
          content: Text('将${scope.label}内允许的普通权限加入基础包，保存后对所有在职员工生效；个人取消继续优先。'),
          confirmLabel: '加入基础包',
        );
        if (!mounted || confirmed != true) return;
        _setPermissions([
          for (final group in groups)
            if ((scope.module == null || scope.module == group.module) &&
                (scope.category == null || scope.category == group.category))
              for (final permission in group.permissions)
                if (permission.grantPolicy.baselineEligible) permission.code,
        ], true);
      },
      onDisableAll: (permissions) =>
          _setPermissions(permissions.map((p) => p.code), false),
      onDisableGroup: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        false,
      ),
      itemBuilder: (context, permission) => Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
        child: Row(
          children: [
            Expanded(
              child: PermissionTitleBlock(
                name: permission.name,
                actionType: permission.actionType,
                description: permission.description,
                grantPolicy: permission.grantPolicy,
                sensitivity: permission.sensitivity,
                nameStyle: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            if (permission.baselinePinned)
              Tooltip(
                message: '体系准入权限，已锁定在全员基础包，不能移出',
                child: Icon(
                  Icons.lock_outline_rounded,
                  key: ValueKey('baseline-pinned-${permission.code}'),
                  size: 16,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            if (permission.baselinePinned)
              const SizedBox(width: UtenSpacing.s8),
            Semantics(
              label:
                  '${permission.name}${checked.contains(permission.code) ? '已包含' : '未包含'}'
                  '${permission.baselinePinned ? '，已锁定不可移出' : ''}',
              child: Switch(
                key: ValueKey('baseline-switch-${permission.code}'),
                // 钉死码按不变式恒显示为已包含(数据库 CHECK 保证 pinned ⇒ baseline)。
                value:
                    permission.baselinePinned ||
                    checked.contains(permission.code),
                onChanged: permission.baselinePinned
                    ? null
                    : (value) => _setPermissions([permission.code], value),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
