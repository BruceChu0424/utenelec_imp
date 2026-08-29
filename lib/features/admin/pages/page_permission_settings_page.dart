import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../models/managed_permission_department_forest.dart';
import '../../../shared/auth/page_permission_delegation_models.dart';
import '../../../shared/auth/permission_action_type.dart';
import '../../../shared/auth/page_permission_delegation_repository.dart';
import '../../../shared/auth/page_permission_scope.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/employee_display.dart';
import '../../employee/widgets/employee_account_provision_flow.dart';
import '../widgets/permission_action_badge.dart';

/// 只管理来源业务页权限的人员主从工作台。
class PagePermissionSettingsPage extends ConsumerStatefulWidget {
  const PagePermissionSettingsPage({super.key, required this.surfaceKey});

  final String surfaceKey;

  @override
  ConsumerState<PagePermissionSettingsPage> createState() =>
      _PagePermissionSettingsPageState();
}

class _PagePermissionSettingsPageState
    extends ConsumerState<PagePermissionSettingsPage> {
  PagePermissionScope? get _scope =>
      pagePermissionScopeBySurfaceKey(widget.surfaceKey);

  List<ManagedPermissionDepartment> _departments = const [];
  ManagedPermissionDepartmentForest _departmentForest =
      ManagedPermissionDepartmentForest.fromRows(const []);
  int _departmentPickerRevision = 0;
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
  PagePermissionEmployeeDetail? _detail;
  bool _detailLoading = false;
  String? _detailError;
  int _detailRequest = 0;
  final Map<String, bool> _pending = <String, bool>{};
  bool _saving = false;
  bool _showDetail = false;
  PermissionActionType? _actionType;

  bool get _dirty => _pending.isNotEmpty;

  PagePermissionDelegationRepository get _repository =>
      ref.read(pagePermissionDelegationRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadDepartments());
  }

  Future<void> _loadDepartments() async {
    if (_scope == null) return;
    setState(() {
      _departmentsLoading = true;
      _departmentsError = null;
    });
    try {
      final rows = await _repository.managedDepartments(widget.surfaceKey);
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
        surfaceKey: widget.surfaceKey,
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
      if (!append &&
          _selected == null &&
          combined.isNotEmpty &&
          MediaQuery.sizeOf(context).width >= 1100) {
        final autoSelected = combined.firstWhere(
          (employee) => employee.hasAccount,
          orElse: () => combined.first,
        );
        await _selectStaff(autoSelected, offerProvision: false);
      }
    } on ApiException catch (error) {
      if (!mounted || request != _staffRequest) return;
      setState(() {
        _staffError = error.message;
        _staffLoading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || request != _staffRequest) return;
      setState(() {
        _staffError = append ? '加载更多失败，请重试' : '人员加载失败，请重试';
        _staffLoading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _changeDepartment(String? departmentId) async {
    if (departmentId == _departmentId) return;
    if (!await _confirmDiscard()) {
      if (mounted) setState(() => _departmentPickerRevision++);
      return;
    }
    setState(() {
      _departmentId = departmentId;
      _selected = null;
      _detail = null;
      _detailError = null;
      _pending.clear();
      _showDetail = false;
      _staff = const [];
      _page = 0;
      _totalPages = 0;
      _total = 0;
    });
    await _loadStaff();
  }

  void _onSearchInput(String _) {
    // 输入防抖窗口内先让旧请求失效，避免旧响应覆盖新关键词。
    _staffRequest++;
  }

  void _onSearch(String value) {
    final normalized = value.trim();
    if (normalized == _search) return;
    _search = normalized;
    _loadStaff();
  }

  Future<void> _selectStaff(
    PagePermissionStaffSummary employee, {
    bool offerProvision = true,
  }) async {
    if (_selected?.employeeId == employee.employeeId) {
      setState(() => _showDetail = true);
      if (!employee.hasAccount &&
          offerProvision &&
          ref.read(currentPermissionsProvider).contains(Perm.accountSupport)) {
        await _provisionSelectedEmployee(employee);
      }
      return;
    }
    if (!await _confirmDiscard()) return;
    setState(() {
      _selected = employee;
      _detail = null;
      _detailError = null;
      _pending.clear();
      _showDetail = true;
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
        surfaceKey: widget.surfaceKey,
        departmentId: departmentId,
        employeeId: employee.employeeId,
      );
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _detail = value;
        _pending.clear();
        _detailLoading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _detailError = error.message;
        _detailLoading = false;
      });
    } catch (_) {
      if (!mounted || request != _detailRequest) return;
      setState(() {
        _detailError = '权限详情加载失败，请重试';
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
        surfaceKey: widget.surfaceKey,
        departmentId: detail.departmentId,
        employeeId: detail.employeeId,
        changes: changes,
      );
      if (!mounted) return;
      setState(() {
        _detail = value;
        _pending.clear();
      });
      context.appSuccess('本页权限已保存');
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
      content: const Text('当前员工有尚未保存的本页权限修改。确定丢弃吗？'),
      confirmLabel: '丢弃',
      danger: true,
    );
    return mounted && confirmed == true;
  }

  Future<void> _backToList() async {
    if (!await _confirmDiscard()) return;
    if (!mounted) return;
    setState(() {
      _showDetail = false;
      _pending.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    final scope = _scope;
    if (scope == null) {
      return const Scaffold(
        appBar: UtenAppBar(
          title: '权限设置',
          showBackButton: true,
          showPagePermissionAction: false,
        ),
        body: UtenEmpty(
          icon: Icons.link_off_rounded,
          message: '未知的页面权限范围',
          description: '请从业务页面右上角的“权限设置”进入。',
        ),
      );
    }

    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final compactDetail = !wide && _showDetail && _selected != null;
    return PopScope<void>(
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !await _confirmDiscard() || !context.mounted) return;
        context.pop();
      },
      child: Scaffold(
        appBar: UtenAppBar(
          title: '权限设置 · ${scope.title}',
          subtitle: '仅管理当前业务页面',
          showBackButton: !compactDetail,
          leading: compactDetail
              ? IconButton(
                  tooltip: '返回人员列表',
                  onPressed: _backToList,
                  icon: const Icon(Icons.arrow_back_rounded),
                )
              : null,
          showPagePermissionAction: false,
        ),
        body: _body(wide),
      ),
    );
  }

  Widget _body(bool wide) {
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
        description: '负责人关系请在人事的部门管理中设置，本权限页不再维护负责人范围。',
      );
    }
    if (wide) {
      return UtenSplitView(
        persistenceKey: 'pagePermissions.${widget.surfaceKey}',
        initialLeadingWidth: 340,
        minLeadingWidth: 280,
        leading: _staffPane(),
        trailing: _detailPane(),
      );
    }
    return _showDetail && _selected != null ? _detailPane() : _staffPane();
  }

  Widget _departmentFilter() {
    ManagedPermissionDepartment? selected;
    for (final row in _departments) {
      if (row.departmentId == _departmentId) {
        selected = row;
        break;
      }
    }
    return UtenDepartmentPicker(
      key: ValueKey(
        'page-permission-department-${_departmentId ?? 'all'}-'
        '$_departmentPickerRevision',
      ),
      mode: UtenDepartmentPickerMode.single,
      treeOverride: _departmentForest.roots,
      initialSelection: selected == null
          ? const []
          : [
              DeptSelection(
                id: selected.departmentId,
                name: selected.departmentName,
                fullPath: '',
                level: selected.level,
              ),
            ],
      label: '部门筛选(可选)',
      hint: '全部可管理范围',
      allowClear: true,
      clearLabel: '显示全部可管理范围',
      expandOnRowTap: true,
      selectablePredicate: (node) =>
          _departmentForest.selectableIds.contains(node.id),
      onChanged: (selection) {
        _changeDepartment(selection.isEmpty ? null : selection.single.id);
      },
    );
  }

  Widget _staffPane() {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            UtenSpacing.s12,
            UtenSpacing.s12,
            UtenSpacing.s12,
            UtenSpacing.s8,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _departmentFilter(),
              const SizedBox(height: UtenSpacing.s8),
              UtenSearchBar(
                hint: _departmentId == null
                    ? '在全部可管理范围搜索姓名 / 工号'
                    : '在该部门及子部门搜索姓名 / 工号',
                onInputChanged: _onSearchInput,
                onChanged: _onSearch,
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                _departmentId == null
                    ? '共 $_total 人 · 当前全部可管理组织范围'
                    : '共 $_total 人 · 所选部门及其子部门',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _staffList()),
      ],
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
    return RefreshIndicator(
      onRefresh: _loadStaff,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
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
          final selected = employee.employeeId == _selected?.employeeId;
          return Card(
            elevation: 0,
            margin: const EdgeInsets.only(bottom: UtenSpacing.s8),
            clipBehavior: Clip.antiAlias,
            child: ListTile(
              key: ValueKey('page-permission-staff-${employee.employeeId}'),
              selected: selected,
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
              trailing: _staffAccountStatus(employee),
              onTap: () => _selectStaff(employee),
            ),
          );
        },
      ),
    );
  }

  Widget _detailPane() {
    final employee = _selected;
    if (employee == null) {
      return const UtenEmpty(
        icon: Icons.person_search_outlined,
        message: '从左侧选择一名员工',
        description: '右侧只会显示当前业务页面的权限。',
      );
    }
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
    final theme = Theme.of(context);
    final visiblePermissions = _actionType == null
        ? detail.permissions
        : detail.permissions
              .where((permission) => permission.actionType == _actionType)
              .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: Row(
            children: [
              CircleAvatar(child: Text(_initial(detail.fullName))),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      detail.fullName ?? '未命名员工',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      [
                        detail.departmentName,
                        if ((detail.code ?? '').isNotEmpty) detail.code!,
                        if ((detail.positionName ?? '').isNotEmpty)
                          detail.positionName!,
                      ].join(' · '),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              if (detail.superAdminMode)
                const Chip(
                  avatar: Icon(Icons.verified_user_outlined, size: 18),
                  label: Text('超管全量'),
                ),
            ],
          ),
        ),
        Container(
          margin: const EdgeInsets.fromLTRB(
            UtenSpacing.s16,
            0,
            UtenSpacing.s16,
            UtenSpacing.s12,
          ),
          padding: const EdgeInsets.all(UtenSpacing.s12),
          color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.45),
          child: Text(
            detail.superAdminMode
                ? '这里显示本页完整权限目录；关闭表示明确收回，开启表示明确加授。'
                : '这里只显示你当前拥有的本页权限；锁定项不可转授，未授权的权限不会出现。',
            style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
          ),
        ),
        _permissionActionFilter(detail.permissions),
        const SizedBox(height: UtenSpacing.s8),
        Expanded(
          child: detail.permissions.isEmpty
              ? const UtenEmpty(
                  icon: Icons.lock_outline_rounded,
                  message: '本页没有可显示权限',
                )
              : visiblePermissions.isEmpty
              ? UtenEmpty(
                  icon: Icons.filter_alt_off_outlined,
                  message: '没有匹配的动作权限',
                  actionLabel: '查看全部动作',
                  onAction: () => setState(() => _actionType = null),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    horizontal: UtenSpacing.s16,
                  ),
                  itemCount: visiblePermissions.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final permission = visiblePermissions[index];
                    final storedValue = detail.superAdminMode
                        ? permission.effective
                        : permission.baseEffective ||
                              permission.delegationEnabled;
                    final value = _pending[permission.code] ?? storedValue;
                    return SwitchListTile.adaptive(
                      key: ValueKey(
                        'page-permission-${detail.employeeId}-'
                        '${permission.code}',
                      ),
                      value: value,
                      onChanged: permission.editable && !_saving
                          ? (next) => setState(() {
                              if (next == storedValue) {
                                _pending.remove(permission.code);
                              } else {
                                _pending[permission.code] = next;
                              }
                            })
                          : null,
                      secondary: Icon(
                        permission.editable
                            ? Icons.admin_panel_settings_outlined
                            : Icons.lock_outline_rounded,
                      ),
                      title: PermissionTitleBlock(
                        name: permission.name,
                        actionType: permission.actionType,
                        description: permission.description,
                      ),
                      subtitle: Text(
                        permission.reason?.trim().isNotEmpty == true
                            ? permission.reason!
                            : permission.effective
                            ? '当前已生效'
                            : '当前未授权',
                      ),
                    );
                  },
                ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _dirty && !_saving
                      ? () => setState(_pending.clear)
                      : null,
                  child: const Text('撤销修改'),
                ),
                const SizedBox(width: UtenSpacing.s8),
                FilledButton.icon(
                  key: const ValueKey('page-permission-save'),
                  onPressed: _dirty && !_saving ? _save : null,
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
        ),
      ],
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.person_off_outlined, size: 16, color: foreground),
            const SizedBox(width: UtenSpacing.s4),
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _permissionActionFilter(List<PageStaffPermissionState> permissions) {
    if (permissions.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final actionTypes =
        permissions.map((item) => item.actionType).toSet().toList()..sort(
          (left, right) => PermissionActionType.values
              .indexOf(left)
              .compareTo(PermissionActionType.values.indexOf(right)),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
      child: Semantics(
        container: true,
        label: '按动作类型筛选本页权限',
        child: Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '动作类型',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w600,
              ),
            ),
            ChoiceChip(
              key: const ValueKey('page-permission-action-all'),
              label: Text('全部 ${permissions.length}'),
              selected: _actionType == null,
              showCheckmark: false,
              onSelected: (_) => setState(() => _actionType = null),
            ),
            for (final type in actionTypes)
              ChoiceChip(
                key: ValueKey(
                  'page-permission-action-${type.wireValue.toLowerCase()}',
                ),
                label: Text(
                  '${type.label} '
                  '${permissions.where((item) => item.actionType == type).length}',
                ),
                selected: _actionType == type,
                showCheckmark: false,
                onSelected: (_) => setState(() => _actionType = type),
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
