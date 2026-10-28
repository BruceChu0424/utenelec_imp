// AdminDepartmentPermView - 按部门配置动态权限目录。
//
// 部门配置保留完整权限点，使用搜索、状态筛选、默认折叠和整组批量操作降低
// 高密度目录的设置成本；未保存修改通过固定底部操作栏统一提交（本地草稿，
// 停止操作一段时间后自动保存，切换部门/离开页面前三选一）。
// 能否配给部门、能否随批量带上只看服务端下发的授权策略(ADR-109)，
// 「全部授权 / 本模块 / 本组」直接交给服务端按策略补齐，本页不维护任何排除名单。
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../core/network/read_scope_revision.dart';
import '../../../components/layout/uten_section_header.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_toast.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/auth/permission_action_type.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../department/widgets/uten_department_tree_view.dart';
import '../models/admin_models.dart';
import '../providers/admin_providers.dart';
import '../repositories/admin_repository.dart';
import 'permission_catalog_browser.dart';
import 'admin_permission_editor_surface.dart';
import 'permission_action_badge.dart';
import 'permission_draft_session.dart';
import 'admin_permission_workspace.dart';
import 'admin_permission_export_button.dart';
import 'admin_permission_transfer_actions.dart';
import 'permission_batch_dialog.dart';
import 'permission_template_binding_strip.dart';

class AdminDepartmentPermView extends ConsumerStatefulWidget {
  const AdminDepartmentPermView({
    super.key,
    this.initialDepartmentId,
    this.leadingHeader = const SizedBox.shrink(),
    this.onPermissionDirtyChanged,
    this.onLeaveGuardChanged,
  });

  final String? initialDepartmentId;
  final Widget leadingHeader;
  final ValueChanged<bool>? onPermissionDirtyChanged;
  final ValueChanged<Future<bool> Function()?>? onLeaveGuardChanged;

  @override
  ConsumerState<AdminDepartmentPermView> createState() =>
      _AdminDepartmentPermViewState();
}

class _AdminDepartmentPermViewState
    extends ConsumerState<AdminDepartmentPermView> {
  final _catalogMount = PermissionCatalogMount();
  DeptSelection? _dept;
  bool _multiSelection = false;
  bool _batchBusy = false;
  final _batchDepartments = <String, DeptSelection>{};
  Set<String>? _localChecked;
  bool _saving = false;
  bool _showDetail = false;
  bool _changingDepartment = false;
  bool? _lastReportedPending;
  late final PermissionDraftSession _idleSave;

  @override
  void initState() {
    super.initState();
    _idleSave = PermissionDraftSession(onIdleSave: () => _save());
    widget.onLeaveGuardChanged?.call(_confirmLeaveDrafts);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _resolveInitialDepartment();
    });
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
        subject: '「${_dept?.name ?? ''}」的部门权限',
        changeCount: _dirtyCount,
        save: () => _save(),
      );
      if (allowed && mounted && _isDirty) {
        // 不保存离开：丢弃本地草稿。
        setState(() => _localChecked = null);
        _idleSave.clear();
      }
      return allowed;
    } finally {
      if (mounted) _idleSave.resume();
    }
  }

  Future<void> _resolveInitialDepartment() async {
    final id = widget.initialDepartmentId;
    if (id == null || id.isEmpty) return;
    try {
      final tree = await ref.read(adminDepartmentTreeProvider.future);
      final selection = buildDeptSelectionMap(tree)[id];
      if (!mounted || selection == null || _dept != null) return;
      setState(() {
        _dept = selection;
        _showDetail = true;
      });
    } catch (_) {
      // 选择器仍可手动使用；路由中的失效部门 id 不阻塞权限页。
    }
  }

  Set<String>? get _serverChecked {
    final department = _dept;
    if (department == null) return null;
    return ref
        .read(adminDepartmentPermissionsProvider(department.id))
        .value
        ?.toSet();
  }

  Set<String> get _checked =>
      _localChecked ?? _serverChecked ?? const <String>{};

  DepartmentPermissionCodes? get _dependencyState {
    final department = _dept;
    if (department == null) return null;
    final response = ref
        .read(adminDepartmentPermissionsProvider(department.id))
        .value;
    return response is DepartmentPermissionCodes ? response : null;
  }

  Map<String, List<String>> get _missingDependencies =>
      _dependencyState?.missingDependencies ?? const {};

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

  Future<void> _onDeptChanged(List<DeptSelection> selection) async {
    if (_saving || _changingDepartment) return;
    final next = selection.firstOrNull;
    if (next?.id == _dept?.id) {
      setState(() => _showDetail = next != null);
      return;
    }
    if (_isDirty) {
      _changingDepartment = true;
      // 三选一：保存并离开 / 不保存切换 / 继续编辑（保存需一次密码）。
      final allowed = await _confirmLeaveDrafts();
      _changingDepartment = false;
      if (!mounted) return;
      if (!allowed) return;
    }
    setState(() {
      _dept = next;
      _localChecked = null;
      _idleSave.clear();
      _showDetail = next != null;
    });
  }

  /// 保存当前部门的权限草稿；true=已落库（或本就没有改动）。
  Future<bool> _save() async {
    final department = _dept;
    if (department == null ||
        _saving ||
        (!_isDirty && _missingDependencies.isEmpty)) {
      return true;
    }
    final submitted = <String>{..._checked};
    if (!_isDirty) {
      final repair = _repairableReads();
      if (repair.isEmpty) {
        context.appInfo('没有可自动补齐的普通查看权限；敏感权限请在允许的授权入口逐项处理。');
        return false;
      }
      submitted.addAll(repair);
    }
    setState(() => _saving = true);
    try {
      final change = await ref
          .read(adminRepositoryProvider)
          .updateDepartmentPermissions(department.id, submitted.toList());
      refreshPermissionConfiguration(ref);
      if (!mounted) return true;
      setState(() => _localChecked = null);
      _idleSave.clear();
      UtenToast.success(
        context,
        change.isEmpty
            ? '「${department.name}」的权限没有变化'
            : '已保存「${department.name}」的权限：新增 ${change.added.length} 项，'
                  '收回 ${change.removed.length} 项，即时生效',
      );
      return true;
    } on ApiException catch (error) {
      if (!mounted) return false;
      context.appApiError(error, fallback: '保存失败，本地修改已保留，请稍后重试');
      return false;
    } catch (_) {
      if (!mounted) return false;
      UtenToast.error(context, '保存失败，本地修改已保留，请稍后重试');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _setPermissions(Iterable<String> codes, bool value) {
    setState(() {
      final next = {..._checked};
      value ? next.addAll(codes) : next.removeAll(codes);
      _localChecked = next;
    });
    _idleSave.noteEdit();
  }

  Set<String> _repairableReads() {
    final catalog = ref.read(permissionCatalogProvider).value;
    if (catalog == null) return const {};
    final byCode = {
      for (final group in catalog)
        for (final permission in group.permissions) permission.code: permission,
    };
    final removed = {...?_serverChecked}..removeAll(_checked);
    final held = {
      ..._checked,
      ...?_dependencyState?.inheritedPermissions,
      ...?_dependencyState?.templatePermissions,
    };
    return {
      for (final code in _missingDependencies.values.expand((reads) => reads))
        if (!held.contains(code) &&
            !removed.contains(code) &&
            byCode[code]?.actionType == PermissionActionType.view &&
            byCode[code]?.sensitivity == 'NORMAL' &&
            byCode[code]?.grantPolicy.departmentGrantable == true &&
            byCode[code]?.grantPolicy.bulkEligible == true)
          code,
    };
  }

  /// 「全部授权 / 本模块 / 本组」：服务端按授权策略补齐并立即生效。
  /// 与本地暂存的逐项修改分开：有未保存修改时先让管理员保存或撤销，避免两路写入互相覆盖。
  Future<void> _grantScope(PermissionBulkScope scope) async {
    final department = _dept;
    if (department == null || _saving) return;
    if (_isDirty) {
      context.appWarning('请先保存或撤销当前的逐项修改，再做批量授权');
      return;
    }
    final confirmed = await UtenDialog.show(
      context,
      title: '批量授权',
      content: Text(
        '将把${scope.label}里可以批量授予的权限配置给「${department.name}」，'
        '保存后立即生效。只能逐人授予或需要逐项勾选的权限不会带上。',
      ),
      confirmLabel: '确认授权',
    );
    if (!mounted || confirmed != true) return;
    setState(() => _saving = true);
    try {
      final change = await ref
          .read(adminRepositoryProvider)
          .grantAllToDepartment(department.id, scope);
      refreshPermissionConfiguration(ref);
      if (!mounted) return;
      context.appSuccess(
        change.added.isEmpty
            ? '没有新增：可批量授予的权限都已配置'
            : '已为「${department.name}」新增 ${change.added.length} 项权限，即时生效',
      );
    } catch (_) {
      if (!mounted) return;
      context.appError('批量授权失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggle(AdminPermission permission, bool value) async {
    if (value &&
        !permission.grantPolicy.bulkEligible &&
        !_checked.contains(permission.code)) {
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
            '。该权限不会被批量配置带入，请确认确需授予当前部门。',
          ].join(),
        ),
        confirmLabel: '确认授权',
        danger: true,
      );
      if (!mounted || confirmed != true) return;
    }
    _setPermissions({permission.code}, value);
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
      leading: _departmentDirectory(),
      trailing: _multiSelection
          ? _batchSummary()
          : _details(preserveStart: true),
      compact: _multiSelection && _showDetail
          ? _batchSummary(showBack: true)
          : _showDetail && _dept != null
          ? Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    key: const ValueKey('admin-department-back-to-directory'),
                    onPressed: _saving
                        ? null
                        : () => setState(() => _showDetail = false),
                    icon: const Icon(Icons.arrow_back),
                    label: const Text('部门目录'),
                  ),
                ),
                Expanded(child: _details(preserveStart: false)),
              ],
            )
          : _departmentDirectory(),
    );
  }

  Future<void> _toggleMulti() async {
    if (_saving || _batchBusy || !await _confirmLeaveDrafts() || !mounted) {
      return;
    }
    setState(() {
      _multiSelection = !_multiSelection;
      _batchDepartments.clear();
      _showDetail = false;
    });
  }

  Future<void> _applyBatch(bool templateMode, {bool single = false}) async {
    if (_batchBusy || _saving || _isDirty) return;
    final ids = single ? [?_dept?.id] : _batchDepartments.keys.toList();
    if (ids.isEmpty) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    setState(() => _batchBusy = true);
    try {
      final applied = await showPermissionBatchDialog(
        context,
        templateMode: templateMode,
        departmentIds: ids,
        targetLabel: single ? _dept?.name : '已选 ${ids.length} 个部门',
      );
      if (!mounted || boundary != ref.read(sensitiveReadBoundaryProvider)) {
        return;
      }
      if (applied == true) {
        for (final id in ids) {
          ref.invalidate(adminDepartmentPermissionsProvider(id));
        }
        context.appSuccess('已更新 ${ids.length} 个部门的权限');
      }
    } finally {
      if (mounted && boundary == ref.read(sensitiveReadBoundaryProvider)) {
        setState(() => _batchBusy = false);
      }
    }
  }

  Widget _batchSummary({bool showBack = false}) => Padding(
    padding: const EdgeInsets.all(12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showBack)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _batchBusy
                  ? null
                  : () => setState(() => _showDetail = false),
              icon: const Icon(Icons.arrow_back),
              label: const Text('返回部门目录'),
            ),
          ),
        UtenSectionHeader(
          title: '已选 ${_batchDepartments.length} 个部门',
          info: '部门权限会按组织关系继承到员工；个人取消仍优先。',
        ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton.tonalIcon(
              onPressed: _batchDepartments.isEmpty || _batchBusy
                  ? null
                  : () => _applyBatch(true),
              icon: const Icon(Icons.link_rounded, size: 18),
              label: const Text('应用模板'),
            ),
            OutlinedButton.icon(
              onPressed: _batchDepartments.isEmpty || _batchBusy
                  ? null
                  : () => _applyBatch(false),
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: const Text('批量设置权限'),
            ),
          ],
        ),
        Expanded(
          child: ListView(
            children: [
              for (final dept in _batchDepartments.values)
                ListTile(
                  dense: true,
                  title: Text(dept.name),
                  trailing: IconButton(
                    tooltip: '移出选择',
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: _batchBusy
                        ? null
                        : () =>
                              setState(() => _batchDepartments.remove(dept.id)),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );

  Widget _departmentDirectory() {
    final departments = ref.watch(adminDepartmentTreeProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            TextButton.icon(
              key: const ValueKey('permission-department-multi-select'),
              onPressed: _saving || _batchBusy ? null : _toggleMulti,
              icon: Icon(
                _multiSelection ? Icons.close_rounded : Icons.checklist_rounded,
                size: 18,
              ),
              label: Text(_multiSelection ? '结束多选' : '多选'),
            ),
            if (_multiSelection) ...[
              Text('已选 ${_batchDepartments.length} 部门'),
              TextButton(
                onPressed: _batchBusy
                    ? null
                    : () => setState(_batchDepartments.clear),
                child: const Text('清空'),
              ),
              TextButton(
                onPressed: _batchDepartments.isEmpty
                    ? null
                    : () => setState(() => _showDetail = true),
                child: const Text('批量设置'),
              ),
            ],
          ],
        ),
        Expanded(
          child: departments.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, _) => UtenEmpty.error(
              message: '部门目录加载失败',
              description: '请检查网络后重试。',
              actionLabel: '重试',
              onAction: () => ref.invalidate(adminDepartmentTreeProvider),
            ),
            data: (nodes) {
              if (nodes.isEmpty) {
                return const UtenEmpty(
                  icon: Icons.account_tree_outlined,
                  message: '暂无可设置权限的部门',
                  description: '请先在人事部门管理中建立组织架构。',
                );
              }
              final selections = buildDeptSelectionMap(nodes);
              return UtenDepartmentTreeView(
                key: const ValueKey('admin-permission-department-tree'),
                nodes: nodes,
                mode: _multiSelection
                    ? UtenDepartmentTreeMode.multi
                    : UtenDepartmentTreeMode.single,
                flatLevelColors: true,
                selectedIds: _multiSelection
                    ? _batchDepartments.keys.toSet()
                    : {?_dept?.id},
                searchHint: '搜索部门名称 / 编号',
                searchFieldKey: const ValueKey(
                  'admin-permission-department-search',
                ),
                nodeEnabledPredicate: (node) =>
                    !_saving &&
                    !_batchBusy &&
                    isOperationalDepartmentNode(node),
                onToggleSelect: (node) {
                  final next = selections[node.id];
                  if (next == null) return;
                  if (!_multiSelection) {
                    _onDeptChanged([next]);
                    return;
                  }
                  if (!_batchDepartments.containsKey(next.id) &&
                      _batchDepartments.length >= 500) {
                    context.appWarning('一次最多选择 500 个部门');
                    return;
                  }
                  setState(() {
                    _batchDepartments.containsKey(next.id)
                        ? _batchDepartments.remove(next.id)
                        : _batchDepartments[next.id] = next;
                  });
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _details({required bool preserveStart}) {
    final theme = Theme.of(context);
    final department = _dept;
    final showSaveBar =
        department != null && (_isDirty || _missingDependencies.isNotEmpty);

    return Column(
      children: [
        // 保存权限网络段的全屏加载遮罩（root Overlay 传送门，不占布局）。
        if (_saving)
          const UtenBusyOverlay(
            title: '正在保存部门权限',
            description: '正在写入部门页面权限变更，请勿重复提交或离开本页。',
          ),
        Expanded(
          child: UtenPageEdgePadding.scroll(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              UtenSpacing.s4,
              UtenSpacing.s16,
              UtenSpacing.s32,
            ),
            preserveStart: preserveStart,
            builder: (context, pagePadding) => ListView(
              padding: pagePadding,
              children: [
                if (department == null)
                  _emptyGuide(theme)
                else
                  _catalogCard(theme, department),
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
                    _isDirty
                        ? '已修改 $_dirtyCount 项'
                        : '有 ${_missingDependencies.length} 项动作缺少所需查看权限',
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
                  child: Text(_isDirty ? '保存更改' : '补齐所需查看权限'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _emptyGuide(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.domain_outlined,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              '先选择一个部门，再为其设置权限',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _catalogCard(ThemeData theme, DeptSelection department) {
    final permissionsAsync = ref.watch(
      adminDepartmentPermissionsProvider(department.id),
    );
    final catalogAsync = ref.watch(permissionCatalogProvider);
    final checked = _checked;

    return AdminPermissionEditorSurface(
      key: const ValueKey('admin-department-permission-card'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s8,
            children: [
              Text(
                '部门权限 · ${department.name}',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              AdminPermissionExportButton(
                scope: PermissionExportScope.department,
                sourceId: department.id,
                sourceName: department.name,
                enabled: !_isDirty && !_saving && permissionsAsync.hasValue,
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.small,
                icon: Icons.link_rounded,
                onPressed: !_isDirty && !_saving && !_batchBusy
                    ? () => _applyBatch(true, single: true)
                    : null,
                child: const Text('应用模板'),
              ),
              PermissionTemplateBindingStrip(
                kind: 'department',
                targetId: department.id,
                enabled: !_isDirty && !_saving && !_batchBusy,
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            _isDirty
                ? '已配置 ${checked.length} 项 · $_dirtyCount 项未保存'
                : '已配置 ${checked.length} 项',
            style: theme.textTheme.bodySmall?.copyWith(
              color: _isDirty
                  ? UtenColors.warning
                  : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          _catalogBody(permissionsAsync, catalogAsync, checked),
        ],
      ),
    );
  }

  Widget _catalogBody(
    AsyncValue<List<String>> permissionsAsync,
    AsyncValue<List<PermissionCatalogGroup>> catalogAsync,
    Set<String> checked,
  ) {
    if (permissionsAsync.hasError || catalogAsync.hasError) {
      return UtenEmpty.error(
        message: '部门权限加载失败',
        description: '请检查网络后重试。',
        actionLabel: '重试',
        onAction: () {
          final department = _dept;
          if (department != null) {
            ref.invalidate(adminDepartmentPermissionsProvider(department.id));
          }
          ref.invalidate(permissionCatalogProvider);
        },
      );
    }
    final rawGroups = catalogAsync.value;
    if (rawGroups == null || permissionsAsync.isLoading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: UtenSpacing.s24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final groups = rawGroups
        .map(
          (group) => PermissionCatalogGroup(
            module: group.module,
            category: group.category,
            // 不能配给部门的码不显示(授权策略由服务端下发)；已在部门里的仍显示，便于收回。
            permissions: group.permissions
                .where(
                  (permission) =>
                      permission.grantPolicy.departmentGrantable ||
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
        _dept?.id,
      )),
      groups: groups,
      enabledFilterLabel: '已配置',
      disabledFilterLabel: '未配置',
      enableGroupLabel: '本组全部配置',
      disableGroupLabel: '本组全部取消配置',
      enableModuleLabel: '本模块全部配置',
      disableModuleLabel: '本模块全部取消配置',
      isEnabled: (permission) =>
          checked.contains(permission.code) ||
          (_dependencyState?.templatePermissions.contains(permission.code) ??
              false),
      onGrantScope: _grantScope,
      onDisableGroup: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        false,
      ),
      enableAllLabel: '全部配置',
      disableAllLabel: '全部取消配置',
      onDisableAll: (permissions) => _setPermissions(
        permissions.map((permission) => permission.code),
        false,
      ),
      itemBuilder: (context, permission) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
          child: Row(
            children: [
              Expanded(
                child: PermissionTitleBlock(
                  name: permission.name,
                  actionType: permission.actionType,
                  description: permission.description,
                  grantPolicy: permission.grantPolicy,
                  baseline: permission.baseline,
                  sensitivity: permission.sensitivity,
                  nameStyle: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (_dependencyState?.templatePermissions.contains(
                    permission.code,
                  ) ??
                  false)
                const Tooltip(
                  message: '来自关联模板，请在模板中调整；员工个人取消继续优先',
                  child: Icon(Icons.link_rounded, size: 16),
                ),
              const SizedBox(width: UtenSpacing.s8),
              Semantics(
                label:
                    '${permission.name}${checked.contains(permission.code) ? '已配置' : '未配置'}',
                child: Switch(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  value:
                      checked.contains(permission.code) ||
                      (_dependencyState?.templatePermissions.contains(
                            permission.code,
                          ) ??
                          false),
                  onChanged:
                      (_dependencyState?.templatePermissions.contains(
                            permission.code,
                          ) ??
                          false)
                      ? null
                      : (value) => _toggle(permission, value),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
