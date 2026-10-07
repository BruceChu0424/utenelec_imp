// 页面权限抽屉（V812 权限整理）：业务页右上角「权限设置」原地滑出的右侧面板。
//
// 与被替代的独立设置页相比的三个新口径：
//  ① hub 抽屉「父+子」一站式——后端 surfaceTree 返回根面组(未被认领的码) +
//     各卡片子面组，一组一个分组条(与系统权限目录同款深绿分组头)；
//  ② 动作族归并——「编辑」族把新增+修改合成一颗三态开关，删除/审核独立，
//     展开族行仍可逐码细调(敏感码开启前确认的口径不变)；
//  ③ 批量授权——族级三态开关、分组头菜单(本组全部授权/全部收回)一次提交，
//     保存仍走 CAS 批量端点(expectedVersion 冲突即刷新)。
//
// 数据契约：权限项零写死，全部来自服务端目录(page_permission_delegation_models)。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/widgets/uten_department_tree_view.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_table_column_kit.dart'
    show utenTableSelectedRowColor;
import '../../../core/responsive/breakpoint.dart';
import '../models/managed_permission_department_forest.dart';
import '../widgets/permission_action_badge.dart';
import '../../../shared/auth/page_permission_delegation_models.dart';
import '../../../shared/auth/page_permission_delegation_repository.dart';
import '../../../shared/auth/page_permission_scope.dart';
import '../../../shared/auth/permission_action_family.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/employee_display.dart';
import '../../employee/widgets/employee_account_provision_flow.dart';
import 'perm_catalog_group_section.dart';

/// 从页面右上角打开「{页面名} · 页面权限」抽屉。
Future<void> showPagePermissionDrawer(
  BuildContext context, {
  required PagePermissionScope scope,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierLabel: '页面权限设置',
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
    pageBuilder: (context, _, _) {
      final media = MediaQuery.of(context);
      final width = math.min(
        media.size.width,
        math.max(720.0, media.size.width * 0.5),
      );
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          width: width,
          child: Padding(
            padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
            child: PagePermissionDrawer(scope: scope),
          ),
        ),
      );
    },
  );
}

class PagePermissionDrawer extends ConsumerStatefulWidget {
  const PagePermissionDrawer({super.key, required this.scope});

  final PagePermissionScope scope;

  @override
  ConsumerState<PagePermissionDrawer> createState() =>
      _PagePermissionDrawerState();
}

class _PagePermissionDrawerState extends ConsumerState<PagePermissionDrawer> {
  List<ManagedPermissionDepartment> _departments = const [];
  ManagedPermissionDepartmentForest _departmentForest =
      ManagedPermissionDepartmentForest.fromRows(const []);
  String? _departmentId;
  bool _departmentsLoading = true;
  String? _departmentsError;

  List<PagePermissionStaffSummary> _staff = const [];
  String _search = '';
  int _page = 0;
  int _totalPages = 0;
  int _total = 0;
  bool _staffLoading = false;
  bool _loadingMore = false;
  String? _staffError;
  int _staffRequest = 0;

  PagePermissionStaffSummary? _selected;
  PagePermissionStaffSummary? _pickedStaff;
  PagePermissionEmployeeDetail? _detail;
  bool _detailLoading = false;
  String? _detailError;
  int _detailRequest = 0;
  final Map<String, bool> _pending = <String, bool>{};
  bool _saving = false;
  bool _allowClose = false;
  final Set<String> _expandedFamilies = <String>{};

  bool get _dirty => _pending.isNotEmpty;

  PagePermissionDelegationRepository get _repository =>
      ref.read(pagePermissionDelegationRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDepartments());
  }

  // ===== 数据加载（与被替代设置页同一契约：可管理部门 → 分页搜人 → 单人明细）=====

  Future<void> _loadDepartments() async {
    setState(() {
      _departmentsLoading = true;
      _departmentsError = null;
    });
    try {
      final rows = await _repository.managedDepartments(
        widget.scope.surfaceKey,
      );
      final forest = ManagedPermissionDepartmentForest.fromRows(rows);
      if (!mounted) return;
      setState(() {
        _departments = rows;
        _departmentForest = forest;
        _departmentId = forest.selectableIds.contains(_departmentId)
            ? _departmentId
            : null;
        _departmentsLoading = false;
      });
      if (rows.isNotEmpty) await _loadStaff();
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _departmentsError = error.message;
        _departmentsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _departmentsError = '可管理部门加载失败，请重试';
        _departmentsLoading = false;
      });
    }
  }

  Future<void> _loadStaff({bool append = false}) async {
    final departmentId = _departmentId;
    final request = ++_staffRequest;
    final nextPage = append ? _page + 1 : 1;
    setState(() {
      if (append) {
        _loadingMore = true;
      } else {
        _staffLoading = true;
        _staffError = null;
      }
    });
    try {
      final result = await _repository.staffPage(
        surfaceKey: widget.scope.surfaceKey,
        departmentId: departmentId,
        search: _search,
        page: nextPage,
      );
      if (!mounted || request != _staffRequest) return;
      final combined = append
          ? <PagePermissionStaffSummary>[..._staff, ...result.items]
          : result.items;
      setState(() {
        _staff = combined;
        _page = result.page;
        _totalPages = result.totalPages;
        _total = result.total;
        _staffLoading = false;
        _loadingMore = false;
        _staffError = null;
      });
    } catch (error) {
      if (!mounted || request != _staffRequest) return;
      setState(() {
        _staffError = error is ApiException
            ? error.message
            : (append ? '加载更多失败，请重试' : '人员加载失败，请重试');
        _staffLoading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _changeDepartment(String? departmentId) async {
    if (departmentId == _departmentId) return;
    if (!await _confirmDiscard()) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _detailRequest++;
      _detailLoading = false;
      _departmentId = departmentId;
      _pickedStaff = null;
      _selected = null;
      _detail = null;
      _detailError = null;
      _pending.clear();
      _expandedFamilies.clear();
      _staff = const [];
      _page = 0;
      _totalPages = 0;
      _total = 0;
    });
    await _loadStaff();
  }

  void _onSearchInput(String _) {
    _staffRequest++;
  }

  void _onSearch(String value) {
    final normalized = value.trim();
    _search = normalized;
    _loadStaff();
  }

  Future<void> _selectStaff(
    PagePermissionStaffSummary employee, {
    bool offerProvision = true,
  }) async {
    if (_selected?.employeeId == employee.employeeId) return;
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() {
      _detailRequest++;
      _detailLoading = false;
      _selected = employee;
      _detail = null;
      _detailError = null;
      _pending.clear();
      _expandedFamilies.clear();
    });
    if (!employee.hasAccount) {
      if (offerProvision &&
          ref.read(currentPermissionsProvider).contains(Perm.accountSupport)) {
        await _provisionSelectedEmployee(employee);
      }
      return;
    }
    await _loadDetail();
  }

  Future<void> _provisionSelectedEmployee(
    PagePermissionStaffSummary employee,
  ) async {
    final result = await showProvisionSelectedEmployeeAccountFlow(
      context,
      ref: ref,
      employeeId: employee.employeeId,
      employeeName: employee.fullName ?? '未命名员工',
      employeeCode: employee.code,
      hasAccount: employee.hasAccount,
    );
    if (result == null || !mounted) return;

    await _loadStaff();
    if (!mounted) return;
    PagePermissionStaffSummary? refreshed;
    for (final item in _staff) {
      if (item.employeeId == employee.employeeId) {
        refreshed = item;
        break;
      }
    }
    final updated = refreshed?.hasAccount == true
        ? refreshed!
        : PagePermissionStaffSummary(
            employeeId: employee.employeeId,
            departmentId: employee.departmentId,
            departmentName: employee.departmentName,
            code: employee.code,
            fullName: employee.fullName,
            positionName: employee.positionName,
            departmentManager: employee.departmentManager,
            hasAccount: true,
            accountActive: true,
          );
    setState(() {
      _staff = _staff
          .map((item) => item.employeeId == updated.employeeId ? updated : item)
          .toList(growable: false);
      _selected = updated;
      _detail = null;
      _detailError = null;
      _pending.clear();
    });
    await _loadDetail();
  }

  Future<void> _loadDetail() async {
    final employee = _selected;
    if (employee == null) return;
    if (!employee.hasAccount) {
      setState(() {
        _detail = null;
        _detailLoading = false;
        _detailError = null;
      });
      return;
    }
    final departmentId = employee.departmentId.trim();
    if (departmentId.isEmpty) {
      setState(() => _detailError = '员工缺少部门信息，无法加载权限详情');
      return;
    }
    final request = ++_detailRequest;
    setState(() {
      _detailLoading = true;
      _detailError = null;
    });
    try {
      final value = await _repository.employeePermissions(
        surfaceKey: widget.scope.surfaceKey,
        departmentId: departmentId,
        employeeId: employee.employeeId,
      );
      if (!mounted ||
          request != _detailRequest ||
          _selected?.employeeId != employee.employeeId) {
        return;
      }
      setState(() {
        _detail = value;
        _pending.clear();
        _detailLoading = false;
      });
    } catch (error) {
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _detailError = error is ApiException ? error.message : '权限详情加载失败，请重试';
        _detailLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final detail = _detail;
    if (detail == null || _pending.isEmpty || _saving) return;
    final byCode = {for (final item in detail.permissions) item.code: item};
    final changes =
        _pending.entries
            .map(
              (entry) => PagePermissionChange(
                code: entry.key,
                enabled: entry.value,
                expectedVersion: byCode[entry.key]!.rowVersion,
              ),
            )
            .toList()
          ..sort((left, right) => left.code.compareTo(right.code));
    setState(() => _saving = true);
    try {
      final value = await _repository.saveEmployeePermissions(
        surfaceKey: widget.scope.surfaceKey,
        departmentId: detail.departmentId,
        employeeId: detail.employeeId,
        changes: changes,
      );
      if (!mounted) return;
      setState(() {
        _detail = value;
        _pending.clear();
      });
      context.appSuccess('页面权限已保存');
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        context.appError('权限已被其他人更新，正在刷新当前员工');
        await _loadDetail();
      } else {
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) context.appError('权限保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    final confirmed = await UtenDialog.show(
      context,
      title: '丢弃未保存修改',
      content: const Text('当前员工有尚未保存的页面权限修改。确定丢弃吗？'),
      confirmLabel: '丢弃',
      danger: true,
    );
    return mounted && confirmed == true;
  }

  Future<void> _close() async {
    if (_saving) return;
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() => _allowClose = true);
    Navigator.of(context).pop();
  }

  // ===== 权限值与批量 =====

  bool _storedValue(PageStaffPermissionState permission) {
    final detail = _detail;
    if (detail == null) return false;
    return detail.superAdminMode
        ? permission.effective
        : permission.baseEffective || permission.delegationEnabled;
  }

  bool _currentValue(PageStaffPermissionState permission) =>
      _pending[permission.code] ?? _storedValue(permission);

  void _setCode(PageStaffPermissionState permission, bool next) {
    setState(() {
      if (next == _storedValue(permission)) {
        _pending.remove(permission.code);
      } else {
        _pending[permission.code] = next;
      }
    });
  }

  Future<void> _toggleCode(PageStaffPermissionState permission) async {
    if (!permission.editable || _saving) return;
    final detail = _detail;
    final next = !_currentValue(permission);
    if (next &&
        !permission.grantPolicy.bulkEligible &&
        !_currentValue(permission)) {
      final confirmed = await _confirmSensitiveGrant([permission]);
      if (!confirmed) return;
    }
    if (!mounted || _saving || !identical(detail, _detail)) return;
    _setCode(permission, next);
  }

  /// 族内/组内批量：只作用于当前可编辑且尚未到位的码。
  Future<void> _applyBatch(
    List<PageStaffPermissionState> permissions,
    bool enable,
  ) async {
    if (_saving) return;
    final detail = _detail;
    final actionable = permissions
        .where((permission) => permission.editable)
        .toList(growable: false);
    if (actionable.isEmpty) return;
    final toChange = actionable
        .where((permission) => _currentValue(permission) != enable)
        .toList(growable: false);
    if (enable) {
      final sensitive = toChange
          .where((permission) => !permission.grantPolicy.bulkEligible)
          .toList(growable: false);
      if (sensitive.isNotEmpty && !await _confirmSensitiveGrant(sensitive)) {
        return;
      }
    }
    if (!mounted || _saving || !identical(detail, _detail)) return;
    setState(() {
      for (final permission in toChange) {
        if (enable == _storedValue(permission)) {
          _pending.remove(permission.code);
        } else {
          _pending[permission.code] = enable;
        }
      }
    });
  }

  Future<bool> _confirmSensitiveGrant(
    List<PageStaffPermissionState> permissions,
  ) async {
    final names = permissions
        .map((permission) => '「${permission.name}」')
        .join('、');
    final confirmed = await UtenDialog.show(
      context,
      title: '确认授权',
      content: Text(
        '$names会开放商业敏感数据或敏感能力。请确认该员工确需访问。',
        style: const TextStyle(height: 1.5),
      ),
      confirmLabel: '确认授权',
      danger: true,
    );
    return mounted && confirmed == true;
  }

  // ===== 布局 =====

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail;
    final title = detail?.surfaceTitle.trim().isNotEmpty == true
        ? detail!.surfaceTitle
        : widget.scope.title;
    return PopScope<void>(
      canPop: !_saving && (!_dirty || _allowClose),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && !_saving) _close();
      },
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 8,
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _header(theme, title),
              const Divider(height: 1),
              Expanded(
                child: Stack(
                  children: [
                    _body(),
                    if (_saving)
                      const UtenBusyOverlay(
                        title: '正在保存页面权限',
                        description: '正在写入权限变更，请勿重复提交或关闭面板。',
                      ),
                  ],
                ),
              ),
              _bottomBar(theme),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(ThemeData theme, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s4,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Icon(
            Icons.admin_panel_settings_outlined,
            size: 22,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$title · 页面权限',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _detail == null
                      ? '选择一名员工后设置本页权限'
                      : _detail!.superAdminMode
                      ? '超管模式：目录全集，可加授也可明确收回'
                      : '负责人转授：只显示你可转授的权限',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '关闭',
            onPressed: _saving ? null : _close,
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_selected == null) return _pickerView();
    return _permissionView();
  }

  // ===== 选人视图 =====

  Widget _pickerView() {
    if (_departmentsLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_departmentsError != null) {
      return UtenEmpty.error(
        message: _departmentsError,
        actionLabel: '重试',
        onAction: _loadDepartments,
      );
    }
    if (_departments.isEmpty) {
      return const UtenEmpty(
        icon: Icons.shield_outlined,
        message: '当前没有可管理的组织范围',
        description: '负责人关系请在人事的部门管理中设置，本权限面板不再维护负责人范围。',
      );
    }
    final theme = Theme.of(context);
    final tree = UtenDepartmentTreeView(
      nodes: _departmentForest.roots,
      flatLevelColors: true,
      mode: UtenDepartmentTreeMode.single,
      showSearch: false,
      initiallyExpandDepth: 0,
      expandOnRowTap: true,
      selectedIds: _departmentId == null ? const {} : {_departmentId!},
      nodeEnabledPredicate: (node) =>
          _departmentForest.selectableIds.contains(node.id),
      onToggleSelect: (node) => _changeDepartment(node.id),
      header: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s8),
        child: Column(
          children: [
            UtenSearchBar(
              hint: '搜索姓名 / 工号',
              onInputChanged: _onSearchInput,
              onChanged: _onSearch,
            ),
            TextButton(
              onPressed: () => _changeDepartment(null),
              child: const Text('全部可管理部门'),
            ),
          ],
        ),
      ),
    );
    final people = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s8),
          child: Text(
            '共 $_total 人',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(child: _staffList()),
      ],
    );
    if (context.breakpoint.isCompact) {
      return Row(
        children: [
          SizedBox(
            width: math.min(176, MediaQuery.sizeOf(context).width * 0.42),
            child: tree,
          ),
          const VerticalDivider(width: 1),
          Expanded(child: people),
        ],
      );
    }
    return UtenSplitView(
      persistenceKey: 'pagePermission.staffDepartments',
      initialLeadingWidth: 240,
      minLeadingWidth: 200,
      maxLeadingWidth: 560,
      leading: tree,
      trailing: people,
    );
  }

  Widget _staffList() {
    if (_staffLoading && _staff.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_staffError != null && _staff.isEmpty) {
      return UtenEmpty.error(
        message: _staffError,
        actionLabel: '重试',
        onAction: _loadStaff,
      );
    }
    if (_staff.isEmpty) {
      return UtenEmpty(
        icon: Icons.people_outline_rounded,
        message: _search.isNotEmpty
            ? '没有匹配的员工'
            : _departmentId == null
            ? '当前可管理范围暂无员工'
            : '该部门及子部门暂无可管理员工',
        description: _search.isEmpty ? null : '请调整姓名或工号关键词。',
      );
    }
    final hasMore = _page < _totalPages;
    return ListView.builder(
      padding: const EdgeInsets.all(UtenSpacing.s8),
      itemCount: _staff.length + (hasMore || _staffError != null ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _staff.length) {
          return Padding(
            padding: const EdgeInsets.all(UtenSpacing.s8),
            child: OutlinedButton(
              onPressed: _loadingMore ? null : () => _loadStaff(append: true),
              child: _loadingMore
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_staffError ?? '加载更多'),
            ),
          );
        }
        final employee = _staff[index];
        return Card(
          elevation: 0,
          margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
          clipBehavior: Clip.antiAlias,
          child: ListTile(
            key: ValueKey('page-permission-staff-${employee.employeeId}'),
            leading: CircleAvatar(child: Text(_initial(employee.fullName))),
            title: Text(
              formatEmployeeDisplayName(
                employee.fullName ?? '未命名员工',
                employee.code,
              ),
            ),
            subtitle: Text(
              [
                if (employee.departmentName.trim().isNotEmpty)
                  employee.departmentName,
                if ((employee.positionName ?? '').isNotEmpty)
                  employee.positionName!,
              ].join(' · '),
            ),
            trailing: _pickedStaff?.employeeId == employee.employeeId
                ? Icon(
                    Icons.check_circle_rounded,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : _staffAccountStatus(employee),
            selected: _pickedStaff?.employeeId == employee.employeeId,
            selectedTileColor: utenTableSelectedRowColor(Theme.of(context)),
            onTap: () => setState(() => _pickedStaff = employee),
          ),
        );
      },
    );
  }

  Widget _staffAccountStatus(PagePermissionStaffSummary employee) {
    if (employee.hasAccount && employee.accountActive) {
      return const Icon(Icons.chevron_right_rounded);
    }
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final hasDisabledAccount = employee.hasAccount;
    final label = hasDisabledAccount
        ? l10n.accountStatusInactive
        : l10n.accountStatusNotProvisioned;
    final foreground = hasDisabledAccount
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    final background = hasDisabledAccount
        ? theme.colorScheme.errorContainer.withValues(alpha: 0.55)
        : theme.colorScheme.surfaceContainerHighest;
    return Tooltip(
      message: label,
      child: Container(
        key: ValueKey('page-permission-account-status-${employee.employeeId}'),
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s8,
          vertical: UtenSpacing.s4,
        ),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  // ===== 权限视图 =====

  Widget _permissionView() {
    final employee = _selected!;
    if (!employee.hasAccount) {
      final l10n = AppLocalizations.of(context);
      final canProvision = ref
          .watch(currentPermissionsProvider)
          .contains(Perm.accountSupport);
      return UtenEmpty(
        icon: Icons.person_off_outlined,
        message: l10n.pagePermissionAccountNotProvisionedTitle,
        description: canProvision
            ? l10n.pagePermissionAccountNotProvisionedCanProvision
            : l10n.pagePermissionAccountNotProvisionedNoAccess,
        actionLabel: canProvision ? l10n.employeeActionProvision : null,
        onAction: canProvision
            ? () => _provisionSelectedEmployee(employee)
            : null,
      );
    }
    if (_detailLoading && _detail == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_detailError != null && _detail == null) {
      return UtenEmpty.error(
        message: _detailError,
        actionLabel: '重试',
        onAction: _loadDetail,
      );
    }
    final detail = _detail;
    if (detail == null) return const SizedBox.shrink();
    final groups = detail.groups;
    if (groups.isEmpty) {
      return const UtenEmpty(
        icon: Icons.lock_outline_rounded,
        message: '本页没有可显示权限',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _personCard(detail),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              0,
              UtenSpacing.s12,
              UtenSpacing.s16,
            ),
            children: [
              // 单组且为根面（普通页面）：抽屉标题已表达页面名，不再重复分组头。
              if (groups.length == 1 && groups.first.root) ...[
                ..._familyRows(groups.first),
              ] else
                for (final group in groups) ..._groupSection(group),
            ],
          ),
        ),
      ],
    );
  }

  Widget _personCard(PagePermissionEmployeeDetail detail) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s12,
        UtenSpacing.s4,
      ),
      child: Card(
        elevation: 0,
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              CircleAvatar(child: Text(_initial(detail.fullName))),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      formatEmployeeDisplayName(
                        detail.fullName ?? '未命名员工',
                        detail.code,
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      [
                        detail.departmentName,
                        if ((detail.positionName ?? '').isNotEmpty)
                          detail.positionName!,
                        if (detail.superAdminMode) '超管全量',
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _saving ? null : _switchPerson,
                icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                label: const Text('更换'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _switchPerson() async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() {
      _detailRequest++;
      _detailLoading = false;
      _selected = null;
      _detail = null;
      _detailError = null;
      _pending.clear();
      _expandedFamilies.clear();
    });
  }

  List<Widget> _groupSection(PagePermissionSurfaceGroup group) {
    final theme = Theme.of(context);
    final granted = group.permissions.where(_currentValue).length;
    final label = '$granted/${group.permissions.length}';
    return [
      const SizedBox(height: UtenSpacing.s8),
      PermCatalogGroupSection(
        title: group.root ? '${group.title} · 本页' : group.title,
        countLabel: '已授 $label',
        trailing: PopupMenuButton<String>(
          tooltip: '本组批量',
          icon: const Icon(Icons.more_vert_rounded, size: 18),
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'grant',
              child: Text('本组全部授权（不含锁定项）', style: theme.textTheme.bodyMedium),
            ),
            PopupMenuItem(
              value: 'revoke',
              child: Text('本组全部收回（不含锁定项）', style: theme.textTheme.bodyMedium),
            ),
          ],
          onSelected: (value) =>
              _applyBatch(group.permissions, value == 'grant'),
        ),
        children: _familyRows(group),
      ),
    ];
  }

  List<Widget> _familyRows(PagePermissionSurfaceGroup group) {
    // 同族码保持目录序：族顺序固定，族内按服务端返回顺序。
    final byFamily = <PermissionActionFamily, List<PageStaffPermissionState>>{};
    for (final permission in group.permissions) {
      byFamily
          .putIfAbsent(
            PermissionActionFamily.of(permission.actionType),
            () => [],
          )
          .add(permission);
    }
    return [
      for (final family in PermissionActionFamily.values)
        if (byFamily.containsKey(family))
          _familyRow(group, family, byFamily[family]!),
    ];
  }

  Widget _familyRow(
    PagePermissionSurfaceGroup group,
    PermissionActionFamily family,
    List<PageStaffPermissionState> permissions,
  ) {
    final theme = Theme.of(context);
    final familyKey = '${group.surfaceKey}:${family.name}';
    final expanded = _expandedFamilies.contains(familyKey);
    final editable = permissions
        .where((permission) => permission.editable)
        .toList(growable: false);
    final granted = permissions.where(_currentValue).length;
    final total = permissions.length;
    final allOn = granted == total;
    final someOn = granted > 0 && !allOn;
    final canBatch = editable.isNotEmpty && !_saving;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() {
              if (!expanded) {
                _expandedFamilies.add(familyKey);
              } else {
                _expandedFamilies.remove(familyKey);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: UtenSpacing.s4,
                vertical: UtenSpacing.s4,
              ),
              child: Row(
                children: [
                  Icon(
                    family.icon,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      family.detailHint.isEmpty
                          ? family.label
                          : '${family.label}（${family.detailHint}）',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '$granted/$total',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: someOn
                          ? theme.colorScheme.tertiary
                          : theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  // 三态开关按「当前是否全开」取反：未全开 → 一键全开(半选也补齐)，
                  // 已全开 → 一键全收；tristate 的中间态只作展示不参与语义。
                  Checkbox(
                    value: allOn ? true : (someOn ? null : false),
                    tristate: true,
                    onChanged: canBatch
                        ? (_) => _applyBatch(permissions, !allOn)
                        : null,
                  ),
                  AnimatedRotation(
                    turns: expanded ? 0 : -0.25,
                    duration: const Duration(milliseconds: 180),
                    child: const Icon(Icons.chevron_right_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          Padding(
            padding: const EdgeInsets.only(left: UtenSpacing.s12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final permission in permissions)
                  _permissionRow(permission),
              ],
            ),
          ),
        const Divider(height: 1),
      ],
    );
  }

  Widget _permissionRow(PageStaffPermissionState permission) {
    final theme = Theme.of(context);
    final value = _currentValue(permission);
    return Opacity(
      opacity: permission.editable ? 1 : 0.65,
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PermissionTitleBlock(
                    name: permission.name,
                    actionType: permission.actionType,
                    description: permission.description,
                    grantPolicy: permission.grantPolicy,
                    sensitivity: permission.sensitivity,
                  ),
                  Text(
                    permission.reason?.trim().isNotEmpty == true
                        ? permission.reason!
                        : permission.effective
                        ? '当前已生效'
                        : '当前未授权',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Switch.adaptive(
            key: ValueKey(
              'page-permission-${_detail?.employeeId ?? ''}-${permission.code}',
            ),
            value: value,
            onChanged: permission.editable && !_saving
                ? (_) => _toggleCode(permission)
                : null,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(ThemeData theme) {
    if (_selected == null) {
      final picked = _pickedStaff;
      return UtenPickerConfirmBar(
        selectedCount: picked == null ? 0 : 1,
        selectedLabel: picked == null
            ? null
            : formatEmployeeDisplayName(
                picked.fullName ?? '未命名员工',
                picked.code,
              ),
        onCancel: _close,
        onConfirm: picked == null ? null : () => _selectStaff(picked),
      );
    }
    final changed = _pending.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          UtenSpacing.s16,
          UtenSpacing.s8,
          UtenSpacing.s16,
          UtenSpacing.s12,
        ),
        child: Row(
          children: [
            Expanded(
              child: changed == 0
                  ? Text(
                      _detail == null ? '先选择一名员工' : '暂无未保存修改',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    )
                  : Text(
                      '已修改 $changed 项',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
            TextButton(
              onPressed: changed > 0 && !_saving
                  ? () => setState(_pending.clear)
                  : null,
              child: const Text('撤销修改'),
            ),
            const SizedBox(width: UtenSpacing.s8),
            FilledButton.icon(
              key: const ValueKey('page-permission-save'),
              onPressed: changed > 0 && !_saving ? _save : null,
              icon: _saving
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined),
              label: Text(_saving ? '保存中' : '保存更改'),
            ),
          ],
        ),
      ),
    );
  }
}

String _initial(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? '?' : trimmed.characters.first;
}
