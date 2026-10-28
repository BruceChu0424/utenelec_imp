import '../../../shared/search/keyword_search.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../components/layout/uten_section_header.dart';
import 'admin_account_lifecycle_text.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_employee_multi_picker.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../models/admin_models.dart';
import '../repositories/admin_repository.dart';
import 'admin_data_handover_panel.dart';
import 'permission_draft_session.dart';
import 'admin_permission_editor_surface.dart';

/// 宿主持有的分区句柄： ValueKey 重建分区时新 State 自动重新挂接，
/// 宿主不必用 GlobalKey（与「按 (user, revision) 重建」的既有口径共存）。
class AdminDataScopeSectionHandle {
  AdminDataScopeSectionState? _state;

  bool get hasDrafts => _state?.hasDrafts ?? false;
  Future<bool> saveDrafts() => _state?.saveDrafts() ?? Future.value(true);
  void discardDrafts() => _state?.discardDrafts();
  void pauseAutoSave() => _state?.pauseAutoSave();
  void resumeAutoSave() => _state?.resumeAutoSave();

  void _attach(AdminDataScopeSectionState state) => _state = state;
  void _detach(AdminDataScopeSectionState state) {
    if (identical(_state, state)) _state = null;
  }
}

/// 服务端 catalog 驱动的“可查看数据”配置。
///
/// 编辑一律先落本地草稿（[_drafts]），停止操作一段时间后自动保存、
/// 离开前由宿主统一询问；保存走批量端点，一次再认证（一次密码）覆盖
/// 本次全部范围的修改（ADR-110 凭证一次性，逐范围保存会反复要密码）。
class AdminDataScopeSection extends ConsumerStatefulWidget {
  const AdminDataScopeSection({
    super.key,
    required this.user,
    required this.effectiveAsync,
    this.onAccountChanged,
    this.onDirtyChanged,
    this.handle,
    this.viewAllPermissions,
    this.showHandover = true,
  });

  final AdminUserSummary user;
  final AsyncValue<EffectivePermissions> effectiveAsync;
  final VoidCallback? onAccountChanged;

  /// 草稿状态变化时上报（含保存中）；宿主据此守卫分区/员工切换与页面离开。
  final ValueChanged<bool>? onDirtyChanged;

  /// 宿主持有的句柄；不传则宿主自行用 onDirtyChanged 管理。
  final AdminDataScopeSectionHandle? handle;

  /// Restrict an in-page editor to scopes advertised by that page's permissions.
  /// Scope definitions and all authorization checks remain server-authoritative.
  final Set<String>? viewAllPermissions;
  final bool showHandover;

  @override
  ConsumerState<AdminDataScopeSection> createState() =>
      AdminDataScopeSectionState();
}

class AdminDataScopeSectionState extends ConsumerState<AdminDataScopeSection> {
  List<DataScopeCatalogItem> _catalog = const [];
  bool _requested = false;
  bool _catalogLoading = false;
  String? _catalogError;
  final Set<String> _loading = {};
  final Map<String, String> _errors = {};
  bool _saving = false;

  /// 服务端当前授权（加载/保存成功后更新）；同时是批量保存的 CAS 基线。
  final Map<String, Set<String>> _grants = {};

  /// 本地待保存草稿：scope → 期望集合；与 [_grants] 相同的条目自动移除。
  final Map<String, Set<String>> _drafts = {};
  final Map<String, List<DataScopeOwner>> _candidates = {};
  final Map<String, int> _revisions = {};
  int _generation = 0;
  bool? _lastReportedDirty;
  late final PermissionDraftSession _idleSave;

  @override
  void initState() {
    super.initState();
    _idleSave = PermissionDraftSession(onIdleSave: () => saveDrafts());
    widget.handle?._attach(this);
  }

  bool _active(String userId, int generation) =>
      mounted && widget.user.id == userId && generation == _generation;

  @override
  void didUpdateWidget(covariant AdminDataScopeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.user.id != widget.user.id ||
        oldWidget.user.status != widget.user.status ||
        oldWidget.user.currentEmployee != widget.user.currentEmployee ||
        !setEquals(oldWidget.viewAllPermissions, widget.viewAllPermissions)) {
      _reset();
    }
  }

  @override
  void dispose() {
    widget.handle?._detach(this);
    _idleSave.dispose();
    super.dispose();
  }

  void _reset() {
    _generation++;
    _requested = false;
    _catalog = const [];
    _catalogLoading = false;
    _catalogError = null;
    _loading.clear();
    _errors.clear();
    _saving = false;
    _grants.clear();
    _drafts.clear();
    _candidates.clear();
    _revisions.clear();
    _idleSave.clear();
    _reportDirty(false);
  }

  void _reportDirty(bool dirty) {
    if (_lastReportedDirty == dirty) return;
    _lastReportedDirty = dirty;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onDirtyChanged?.call(dirty);
    });
  }

  /// 有待保存的数据范围草稿。
  bool get hasDrafts => _drafts.isNotEmpty;

  /// 宿主在离开确认等弹框期间暂停闲置自动保存。
  void pauseAutoSave() => _idleSave.pause();

  void resumeAutoSave() => _idleSave.resume();

  Future<void> _loadAll(EffectivePermissions permissions) async {
    if (_requested) return;
    _requested = true;
    setState(() {
      _catalogLoading = true;
      _catalogError = null;
    });
    final userId = widget.user.id;
    final generation = _generation;
    try {
      final allScopes = await ref
          .read(adminRepositoryProvider)
          .dataScopeCatalog();
      if (!mounted || !_active(userId, generation)) return;
      final catalog = allScopes
          .where(
            (item) =>
                widget.viewAllPermissions == null ||
                widget.viewAllPermissions!.contains(item.viewAllPermission),
          )
          .toList();
      setState(() {
        _catalog = catalog;
        _catalogLoading = false;
      });
      final effective = permissions.effective.toSet();
      await Future.wait(
        catalog
            .where(
              (item) =>
                  item.enabled &&
                  (item.viewAllPermission.isEmpty ||
                      !effective.contains(item.viewAllPermission)),
            )
            .map(_loadScope),
      );
    } catch (_) {
      if (!mounted || !_active(userId, generation)) return;
      setState(() {
        _catalogLoading = false;
        _catalogError = '可查看数据目录加载失败，请重试';
      });
    }
  }

  Future<void> _retryCatalog(EffectivePermissions permissions) async {
    setState(() {
      _reset();
    });
    await _loadAll(permissions);
  }

  Future<void> _loadScope(DataScopeCatalogItem definition) async {
    final scope = definition.scope;
    final userId = widget.user.id;
    final generation = _generation;
    setState(() {
      _loading.add(scope);
      _errors.remove(scope);
    });
    try {
      final repository = ref.read(adminRepositoryProvider);
      final results = await Future.wait<Object>([
        repository.getUserDataScopes(userId, scope),
        repository.dataScopeOwners(scope),
      ]);
      if (!mounted || !_active(userId, generation)) return;
      setState(() {
        _grants[scope] = (results[0] as List<String>).toSet();
        _candidates[scope] = results[1] as List<DataScopeOwner>;
        // 重新加载后若草稿与服务器一致（别处已保存），顺手清掉。
        final draft = _drafts[scope];
        if (draft != null && setEquals(draft, _grants[scope])) {
          _drafts.remove(scope);
        }
      });
    } catch (_) {
      if (!mounted || !_active(userId, generation)) return;
      setState(() {
        // 加载失败的范围不显示选择器：拿不到服务器基线就不能安全改草稿。
        _grants.remove(scope);
        _drafts.remove(scope);
        _errors[scope] = '加载失败，请重试';
      });
    } finally {
      if (mounted && widget.user.id == userId && generation == _generation) {
        setState(() => _loading.remove(scope));
      }
    }
  }

  /// 选择器改动：只写本地草稿，不立即保存。
  void _draftSelection(
    DataScopeCatalogItem definition,
    List<UtenEmployeePickerItem> selection,
  ) {
    final scope = definition.scope;
    final selected = selection.map((item) => item.id).toSet();
    final blocked =
        !widget.user.authorizationGrantAllowed && selected.isNotEmpty;
    if (blocked) {
      UtenToast.info(
        context,
        adminAuthorizationRestrictionText(context, widget.user),
      );
      setState(() => _bumpRevision(scope));
      return;
    }
    setState(() {
      final server = _grants[scope];
      if (server != null && setEquals(selected, server)) {
        _drafts.remove(scope);
      } else {
        _drafts[scope] = selected;
      }
    });
    if (_drafts.isNotEmpty) {
      _idleSave.noteEdit();
    } else {
      _idleSave.clear();
    }
    _reportDirty(_drafts.isNotEmpty || _saving);
  }

  /// 撤销全部草稿。
  void discardDrafts() {
    if (_drafts.isEmpty) return;
    setState(() => _drafts.clear());
    _idleSave.clear();
    _reportDirty(false);
  }

  /// 批量保存全部草稿（一次请求、一次再认证）。true=草稿已清（或本就没有）。
  Future<bool> saveDrafts() async {
    if (_saving || _drafts.isEmpty) return _drafts.isEmpty;
    final generation = _generation;
    final userId = widget.user.id;
    setState(() => _saving = true);
    _reportDirty(true);
    try {
      final result = await ref
          .read(adminRepositoryProvider)
          .updateUserDataScopesBatch(userId, {
            for (final entry in _drafts.entries)
              entry.key: (
                entry.value.toList()..sort(),
                _sortedIdsOf(entry.key),
              ),
          });
      if (!mounted || !_active(userId, generation)) return false;
      setState(() => _drafts.clear());
      _idleSave.clear();
      final changedScopes = result.$1;
      // 保存后按服务器真相刷新各范围（候选数量/状态可能随之变化）。
      await Future.wait(
        _catalog.where((item) => item.scope.isNotEmpty).map(_loadScope),
      );
      if (!mounted || !_active(userId, generation)) return true;
      UtenToast.success(
        context,
        changedScopes == 0 ? '可查看数据没有变化' : '已保存 $changedScopes 个范围的额外查看，即时生效',
      );
      widget.onAccountChanged?.call();
      return true;
    } on ApiException catch (error) {
      if (!mounted || !_active(userId, generation)) return false;
      if (error.code == 'CONFLICT') {
        // 服务器端已被他人修改：按个人覆盖的既有口径丢弃草稿并刷新真相。
        setState(() => _drafts.clear());
        _idleSave.clear();
        UtenToast.error(
          context,
          '${error.message.isEmpty ? '账号或数据范围已变化' : error.message}；已恢复最新设置',
        );
        await Future.wait(
          _catalog.where((item) => item.scope.isNotEmpty).map(_loadScope),
        );
        widget.onAccountChanged?.call();
      } else {
        UtenToast.error(
          context,
          error.message.isNotEmpty ? error.message : '保存失败，本地修改已保留，请稍后重试',
        );
      }
      return false;
    } catch (_) {
      if (!mounted || !_active(userId, generation)) return false;
      UtenToast.error(context, '保存失败，本地修改已保留，请稍后重试');
      return false;
    } finally {
      if (mounted && widget.user.id == userId && generation == _generation) {
        setState(() => _saving = false);
        _reportDirty(_drafts.isNotEmpty);
      }
    }
  }

  List<String> _sortedIdsOf(String scope) {
    final ids = _grants[scope] ?? const <String>{};
    return ids.toList()..sort();
  }

  void _bumpRevision(String scope) {
    _revisions[scope] = (_revisions[scope] ?? 0) + 1;
  }

  List<UtenEmployeePickerItem> _scopeItems(String scope) => [
    for (final candidate in _candidates[scope] ?? const <DataScopeOwner>[])
      UtenEmployeePickerItem(
        id: candidate.employeeId,
        name: candidate.name,
        employeeCode: candidate.code,
        departmentId: candidate.departmentId,
        departmentName: candidate.departmentName,
        accountStatus: candidate.accountStatus,
        employmentStatus: candidate.employmentStatus,
        subtitle: candidate.historicalOnly
            ? '历史只读 · 原负责人名下 ${candidate.count} 条数据'
            : '负责 ${candidate.count} 条数据',
      ),
  ];

  List<UtenEmployeePickerItem> _selection(String scope) {
    final items = {for (final item in _scopeItems(scope)) item.id: item};
    return [
      for (final id in _drafts[scope] ?? _grants[scope] ?? const <String>{})
        items[id] ??
            UtenEmployeePickerItem(
              id: id,
              name: '未知员工',
              subtitle: '已授权，但当前没有归属数据',
            ),
    ];
  }

  bool _viewAllActive(
    DataScopeCatalogItem definition,
    EffectivePermissions permissions,
  ) =>
      definition.viewAllPermission.isNotEmpty &&
      permissions.effective.contains(definition.viewAllPermission);

  void _ensureScopeLoaded(DataScopeCatalogItem definition) {
    final scope = definition.scope;
    if (_grants.containsKey(scope) ||
        _loading.contains(scope) ||
        _errors.containsKey(scope)) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          _grants.containsKey(scope) ||
          _loading.contains(scope) ||
          _errors.containsKey(scope)) {
        return;
      }
      unawaited(_loadScope(definition));
    });
  }

  Future<void> _openHandover(EffectivePermissions permissions) async {
    final employeeId = widget.user.employeeId;
    if (employeeId == null || employeeId.isEmpty) return;
    if (!widget.user.authorizationGrantAllowed) {
      UtenToast.info(
        context,
        adminAuthorizationRestrictionText(context, widget.user),
      );
      return;
    }
    _idleSave.pause();
    try {
      final result = await showAdminDataHandoverPanel(
        context: context,
        ref: ref,
        targetEmployeeId: employeeId,
        targetName: widget.user.employeeName ?? widget.user.loginAccount,
      );
      if (!mounted || result == null) return;
      setState(_reset);
      await _loadAll(permissions);
    } finally {
      _idleSave.resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = widget.effectiveAsync.value;
    if (widget.effectiveAsync.hasError) {
      return UtenCard(child: UtenEmpty.error(message: '账号权限状态加载失败'));
    }
    if (permissions == null) {
      return const UtenCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
    }
    if (!permissions.superAdmin && !_requested) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_requested) unawaited(_loadAll(permissions));
      });
    }
    _reportDirty(_drafts.isNotEmpty || _saving);

    final theme = Theme.of(context);
    final canHandover =
        widget.showHandover &&
        (ref.watch(isSuperAdminProvider) ||
            ref
                .watch(currentPermissionsProvider)
                .contains(Perm.employeeHandover));
    final canReceiveHandover = widget.user.authorizationGrantAllowed;
    final authorizationBlocked = !widget.user.authorizationGrantAllowed;
    return AdminPermissionEditorSurface(
      key: const ValueKey('admin-data-scope-editor'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 保存数据范围网络段的全屏加载遮罩（root Overlay 传送门，不占布局）。
          if (_saving)
            const UtenBusyOverlay(
              title: '正在保存可查看数据',
              description: '正在写入额外查看范围，请勿重复提交或离开本页。',
            ),
          const UtenSectionHeader(
            title: '可查看数据',
            info:
                '默认只查看本人负责的数据。可按模块额外查看指定负责人的数据；'
                '额外查看不改变负责人，默认只读。离职原负责人会标记“历史只读”，'
                '只增加其原历史数据，不会随当前接手人的新增数据扩大。',
          ),
          if (authorizationBlocked && !permissions.superAdmin) ...[
            const SizedBox(height: UtenSpacing.s12),
            _notice(
              '${adminAuthorizationRestrictionText(context, widget.user)}。'
              '不能新增额外查看范围；已有范围仍可一键清空。',
              Icons.lock_person_outlined,
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          if (canHandover &&
              widget.user.employeeId?.isNotEmpty == true &&
              canReceiveHandover &&
              !permissions.superAdmin) ...[
            Align(
              alignment: Alignment.centerRight,
              child: UtenButton(
                key: const ValueKey('admin-data-handover-entry'),
                type: UtenButtonType.secondary,
                icon: Icons.swap_horiz_rounded,
                onPressed: () => _openHandover(permissions),
                child: const Text('人员数据交接'),
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          if (canHandover &&
              widget.user.employeeId?.isNotEmpty == true &&
              !canReceiveHandover &&
              !permissions.superAdmin) ...[
            _notice(
              widget.user.currentEmployee
                  ? '当前账号未启用，不能作为数据接手人；可先启用账号，或选择其他在职接手人。'
                  : '${widget.user.employeeStatusLabel}员工不能作为数据接手人；'
                        '如需交出其历史数据，请使用离职办理，或从在职接手人的权限页发起人员数据交接。',
              Icons.lock_outline_rounded,
            ),
            const SizedBox(height: UtenSpacing.s12),
          ],
          if (permissions.superAdmin)
            _notice('该账号是超级管理员，默认查看全部数据，无需配置。', Icons.visibility_outlined)
          else if (_catalogLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_catalogError != null)
            UtenEmpty.error(
              message: _catalogError,
              actionLabel: '重试',
              onAction: () => unawaited(_retryCatalog(permissions)),
            )
          else if (_catalog.isEmpty)
            const UtenEmpty(
              icon: Icons.visibility_off_outlined,
              message: '当前没有可配置的数据范围',
            )
          else ...[
            ..._groupedSections(permissions),
            _saveBar(theme),
          ],
        ],
      ),
    );
  }

  /// 底部保存条：有草稿才出现（与按员工/按部门/基础包同一口径）。
  Widget _saveBar(ThemeData theme) {
    if (_drafts.isEmpty && !_saving) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: UtenSpacing.s12),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s12,
          vertical: UtenSpacing.s8,
        ),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _saving ? '正在保存…' : '已修改 ${_drafts.length} 个范围的额外查看',
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: _saving ? null : discardDrafts,
              child: const Text('撤销'),
            ),
            const SizedBox(width: UtenSpacing.s8),
            UtenButton(
              size: UtenButtonSize.small,
              isLoading: _saving,
              onPressed: _saving ? null : () => saveDrafts(),
              child: const Text('保存更改'),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _groupedSections(EffectivePermissions permissions) {
    final theme = Theme.of(context);
    final groups = <String, List<DataScopeCatalogItem>>{};
    for (final item in _catalog) {
      groups.putIfAbsent(item.group, () => []).add(item);
    }
    return [
      for (final entry in groups.entries) ...[
        Padding(
          padding: const EdgeInsets.only(
            top: UtenSpacing.s8,
            bottom: UtenSpacing.s8,
          ),
          child: Text(
            entry.key,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        for (final definition in entry.value) ...[
          _scopeCard(definition, permissions),
          const SizedBox(height: UtenSpacing.s8),
        ],
      ],
    ];
  }

  Widget _scopeCard(
    DataScopeCatalogItem definition,
    EffectivePermissions permissions,
  ) {
    final theme = Theme.of(context);
    final scope = definition.scope;
    final viewAll = _viewAllActive(definition, permissions);
    if (definition.enabled && !viewAll) {
      _ensureScopeLoaded(definition);
    }
    final pending = _drafts.containsKey(scope);
    final count = (_drafts[scope] ?? _grants[scope])?.length ?? 0;
    // 档位（ADR-169 锚定）：仅本人=绿（最小权限常态）/ 额外查看=蓝（信息性
    // 扩展）/ 查看全部=橙（数据面最大的常驻注意点——不是等待外部，原黄档
    // 语义不符）/ 功能未启用=灰。
    final (statusLabel, statusType) = !definition.enabled
        ? ('功能未启用', UtenStatusBadgeType.neutral)
        : viewAll
        ? ('可查看全部', UtenStatusBadgeType.orange)
        : count > 0
        ? (pending ? '待保存 $count 人' : '额外查看 $count 人', UtenStatusBadgeType.info)
        : (pending ? '待保存 仅本人' : '仅本人', UtenStatusBadgeType.success);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(
          color: pending
              ? theme.colorScheme.primary.withValues(alpha: 0.5)
              : theme.colorScheme.outlineVariant,
        ),
        borderRadius: UtenRadius.mdAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  definition.displayLabel,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: UtenSpacing.s8),
              UtenStatusBadge(
                label: statusLabel,
                type: statusType,
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          if (definition.displayDescription.trim().isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              definition.displayDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          if (!definition.enabled)
            _notice(
              definition.disabledReason?.trim().isNotEmpty == true
                  ? definition.disabledReason!.trim()
                  : '该功能当前未启用，现有设置不会生效。',
              Icons.pause_circle_outline_rounded,
            )
          else if (viewAll)
            _notice('已拥有查看全部数据的权限，无需再选择负责人范围。', Icons.visibility_outlined)
          else if (_loading.contains(scope))
            const Row(
              children: [
                SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: UtenSpacing.s8),
                Text('正在加载负责人…'),
              ],
            )
          else if (_errors[scope] != null)
            Row(
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(child: Text(_errors[scope]!)),
                TextButton(
                  onPressed: () => _loadScope(definition),
                  child: const Text('重试'),
                ),
              ],
            )
          else
            _picker(definition),
        ],
      ),
    );
  }

  Widget _picker(DataScopeCatalogItem definition) {
    final scope = definition.scope;
    final items = _scopeItems(scope);
    final selected = _selection(scope);
    final granted = _grants[scope] ?? const <String>{};
    final historicalSelected = (_candidates[scope] ?? const <DataScopeOwner>[])
        .where(
          (candidate) =>
              candidate.historicalOnly &&
              granted.contains(candidate.employeeId),
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (historicalSelected > 0) ...[
          _notice(
            '已包含 $historicalSelected 位历史只读原负责人；仅查看其原历史数据，不随当前接手人的范围扩大。',
            Icons.history_rounded,
          ),
          const SizedBox(height: UtenSpacing.s8),
        ],
        UtenEmployeeMultiPicker(
          key: ValueKey(
            'scope-$scope-${_revisions[scope] ?? 0}-'
            '${selected.map((item) => item.id).join(',')}',
          ),
          label: '额外查看哪些负责人的数据',
          hint: '仅本人负责的数据',
          sheetTitle: '配置${definition.displayLabel}',
          searchHint: '搜索负责人姓名 / 工号 / 部门',
          emptyMessage: '暂无匹配且拥有归属数据的负责人',
          selectedCountLabel: (count) => '额外查看 $count 人',
          initialSelection: selected,
          enabled: widget.user.authorizationGrantAllowed && !_saving,
          loader: (keyword) async {
            final query = keyword?.trim().toLowerCase() ?? '';
            if (query.isEmpty) return items;
            final result = items
                .where(
                  (item) => matchesKeywordSearch([
                    item.name,
                    item.employeeCode,
                    item.departmentName,
                  ], query),
                )
                .toList();
            final order = {
              for (var index = 0; index < items.length; index++)
                items[index].id: index,
            };
            result.sort((left, right) {
              final rankLeft = keywordSearchRankWithPrimary(
                [left.name],
                [left.employeeCode, left.departmentName],
                query,
              )!;
              final rankRight = keywordSearchRankWithPrimary(
                [right.name],
                [right.employeeCode, right.departmentName],
                query,
              )!;
              final rank = rankLeft.compareTo(rankRight);
              return rank != 0
                  ? rank
                  : order[left.id]!.compareTo(order[right.id]!);
            });
            return result;
          },
          onChanged: (next) => _draftSelection(definition, next),
        ),
        if (!widget.user.authorizationGrantAllowed && granted.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s8),
          Align(
            alignment: Alignment.centerRight,
            child: UtenButton(
              key: ValueKey('clear-data-scope-$scope'),
              type: UtenButtonType.ghost,
              size: UtenButtonSize.small,
              icon: Icons.delete_sweep_outlined,
              onPressed: _saving
                  ? null
                  : () => _draftSelection(
                      definition,
                      const <UtenEmployeePickerItem>[],
                    ),
              child: const Text('清空额外查看'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _notice(String message, IconData icon) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: UtenRadius.mdAll,
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
