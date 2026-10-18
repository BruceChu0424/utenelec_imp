// 部门树 + 员工选择器：先选部门（未展开的分类树），点部门列出该部门（含子部门）的人员，
// 也可直接搜索姓名/工号跨部门找人。左树 + 右重点字段表格。
//
// 问题 #6：模具「保管人」原来是纯搜索平铺列表，改成"先浏览部门再挑人"，更贴近老员工的
// 使用习惯（不知道该搜什么名字时，按部门找人更直观）。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_employee_picker.dart'
    show UtenEmployeePickerItem;
import '../../../components/inputs/uten_employee_picker_access.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../shared/hierarchy/uten_tree_path.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/formatters/employee_display.dart';
import '../../../shared/hierarchy/category_tree_search.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_tree_view.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/employee_api_models.dart';
import '../providers/employee_picker_department_tree_provider.dart';
import '../repositories/employee_repository.dart';

export '../providers/employee_picker_department_tree_provider.dart';

/// 弹出「部门树 + 员工」选择器，返回所选员工；取消返回 null。
Future<UtenEmployeePickerItem?> showUtenDepartmentEmployeePicker(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择员工',
  Set<String> statuses = const {'active', 'probation', 'onLeave'},
  Set<String> excludeEmployeeIds = const {},
}) async {
  final access = EmployeePickerAccess(
    EmployeePickerAccess.containerOf(context),
  );
  final ticket = access.capture();
  bool current() =>
      context.mounted &&
      ticket.isCurrent &&
      identical(access.container, EmployeePickerAccess.containerOf(context));
  try {
    List<DepartmentNode> tree;
    try {
      tree = await ref.read(employeePickerDepartmentTreeProvider.future);
    } catch (_) {
      if (context.mounted && current()) context.appError('部门树加载失败，请稍后重试');
      return null;
    }
    if (!context.mounted || !current()) return null;
    final result = await showUtenAdaptivePanel<UtenEmployeePickerItem>(
      context: context,
      drawerWidth: 720,
      builder: (_) => _DeptEmployeePickerSheet(
        openingTicket: ticket,
        tree: tree,
        title: title,
        statuses: statuses,
        excludeEmployeeIds: excludeEmployeeIds,
      ),
    );
    return current() ? result : null;
  } finally {
    access.dispose();
  }
}

class _DeptEmployeePickerSheet extends ConsumerStatefulWidget {
  const _DeptEmployeePickerSheet({
    required this.openingTicket,
    required this.tree,
    required this.title,
    required this.statuses,
    required this.excludeEmployeeIds,
  });
  final EmployeePickerAccessTicket openingTicket;
  final List<DepartmentNode> tree;
  final String title;
  final Set<String> statuses;
  final Set<String> excludeEmployeeIds;

  @override
  ConsumerState<_DeptEmployeePickerSheet> createState() =>
      _DeptEmployeePickerSheetState();
}

class _DeptEmployeePickerSheetState
    extends ConsumerState<_DeptEmployeePickerSheet>
    with EmployeePickerAccessState<_DeptEmployeePickerSheet> {
  static const _pageSize = 100;

  String? _selectedDeptId;
  String? _selectedDeptName;
  final _keywordCtl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _searchLocationError;
  List<UtenEmployeePickerItem> _items = const [];

  /// 已点选（高亮）的员工；底部「确定」才 pop 返回（二次操作契约）。
  UtenEmployeePickerItem? _picked;
  String _globalQuery = '';
  Set<String>? _visibleFilterIds;
  Set<String> _categoryMatchDepartmentIds = {};
  Set<String> _contentMatchDepartmentIds = {};
  int _itemPage = 0;
  int _itemTotalPages = 0;
  int _itemTotal = 0;
  String? _pageDepartmentId;
  String? _pageKeyword;
  bool _loadingMore = false;
  String? _loadMoreError;
  int _requestVersion = 0;
  bool _acceptPendingSearch = false;
  bool _started = false;
  bool _invalidated = false;
  ModalRoute<Object?>? _route;
  late final EmployeePickerAccessTicket _accessTicket;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (!_started) {
      _started = true;
      _accessTicket = pickerAccess.capture();
      if (!widget.openingTicket.isCurrent) onPickerAccessInvalidated();
    }
  }

  @override
  void onPickerAccessInvalidated() {
    _invalidated = true;
    _requestVersion++;
    _acceptPendingSearch = false;
    _picked = null;
    _items = const [];
    _selectedDeptId = null;
    _selectedDeptName = null;
    _globalQuery = '';
    _visibleFilterIds = null;
    _categoryMatchDepartmentIds = {};
    _contentMatchDepartmentIds = {};
    _resetPageState();
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // A newer dialog may be above this selector; remove only our own route.
      if (route is PopupRoute && route.isActive) {
        route.navigator?.removeRoute(route);
      } else {
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool get _canUseCandidates =>
      mounted &&
      !_invalidated &&
      widget.openingTicket.isCurrent &&
      _accessTicket.isCurrent;

  bool _isCurrent(int request) =>
      _canUseCandidates && request == _requestVersion;

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  void _onDeptTap(DepartmentNode node) {
    if (!_canUseCandidates) return;
    _requestVersion++;
    _acceptPendingSearch = false;
    final contentBranch =
        _globalQuery.isNotEmpty &&
        hierarchyBranchContainsAny(
          widget.tree,
          node.id,
          _contentMatchDepartmentIds,
        );
    final categoryBranch =
        _globalQuery.isNotEmpty &&
        _categoryMatchDepartmentIds.contains(node.id);
    final keepQuery = contentBranch || categoryBranch;
    setState(() {
      _selectedDeptId = node.id;
      _selectedDeptName = node.name;
      if (!keepQuery && _globalQuery.isNotEmpty) {
        _keywordCtl.clear();
        _globalQuery = '';
        _visibleFilterIds = null;
        _categoryMatchDepartmentIds = {};
        _contentMatchDepartmentIds = {};
        _searchLocationError = null;
      }
      _loading = false;
    });
    // 撤销输入框尚未触发的防抖词；保留的已生效查询则同步回当前值。
    if (_keywordCtl.text != _globalQuery) {
      _keywordCtl.value = TextEditingValue(
        text: _globalQuery,
        selection: TextSelection.collapsed(offset: _globalQuery.length),
      );
    }
    _loadEmployees(
      departmentId: node.id,
      // 内容命中分支继续按人员词过滤；纯部门命中保留左侧查询，
      // 右侧则浏览该部门（含子部门）的全部员工。
      keyword: contentBranch ? _globalQuery : null,
    );
  }

  /// UtenSearchBar 的查询回调有防抖；每次键入先让旧请求失效，防止旧结果
  /// 在新查询发起前的 300ms 窗口回写。
  void _onSearchInput(String raw) {
    if (!_canUseCandidates) return;
    _requestVersion++;
    final query = raw.trim();
    _acceptPendingSearch = true;
    setState(() {
      _globalQuery = query;
      _visibleFilterIds = query.isEmpty
          ? null
          : categoryHits(widget.tree, query);
      _categoryMatchDepartmentIds = _visibleFilterIds ?? {};
      _contentMatchDepartmentIds = {};
      _loading = query.isNotEmpty;
      _error = null;
      _searchLocationError = null;
    });
  }

  Future<void> _applyGlobalSearch(String rawQuery) async {
    if (!_canUseCandidates) return;
    final query = rawQuery.trim();
    if (!_acceptPendingSearch || query != _globalQuery) return;
    _acceptPendingSearch = false;
    final request = ++_requestVersion;
    if (query.isEmpty) {
      setState(() {
        _globalQuery = '';
        _visibleFilterIds = null;
        _categoryMatchDepartmentIds = {};
        _contentMatchDepartmentIds = {};
        _error = null;
        _searchLocationError = null;
      });
      await _loadEmployees(departmentId: _selectedDeptId);
      return;
    }
    final categoryMatches = categoryHits(widget.tree, query);
    setState(() {
      _globalQuery = query;
      _visibleFilterIds = categoryMatches;
      _categoryMatchDepartmentIds = categoryMatches;
      _contentMatchDepartmentIds = {};
      _loading = true;
      _error = null;
      _searchLocationError = null;
    });
    final repository = ref.read(employeeRepositoryProvider);
    late final PagedResult<EmployeeSummary> firstPage;
    try {
      firstPage = await repository.list(
        size: _pageSize,
        search: query,
        statuses: widget.statuses,
        includeSubtree: true,
      );
      if (!_isCurrent(request)) return;
      final provisional = resolveHierarchySearch(
        roots: widget.tree,
        query: query,
        contentCategoryIds: firstPage.items.map((item) => item.departmentId),
      );
      final selectedId = provisional.selectedId;
      final selected = selectedId == null
          ? null
          : _findDepartment(widget.tree, selectedId);
      setState(() {
        _visibleFilterIds = provisional.visibleIds;
        _contentMatchDepartmentIds = provisional.contentCategoryIds;
        _selectedDeptId = selectedId;
        _selectedDeptName = selected?.name;
        _replacePage(firstPage, departmentId: null, keyword: query);
        _loading = false;
      });
    } catch (_) {
      if (!_isCurrent(request)) return;
      setState(() {
        _error = '员工搜索失败，请稍后重试';
        _loading = false;
      });
      return;
    }

    // 首屏先显示，树定位在后台继续汇总后续页；新输入会通过 request version 终止。
    Set<String>? contentDepartmentIds;
    try {
      contentDepartmentIds =
          await collectPagedHierarchyCategoryIds<EmployeeSummary>(
            seedPage: firstPage,
            loadPage: (page) => repository.list(
              page: page,
              size: _pageSize,
              search: query,
              statuses: widget.statuses,
              includeSubtree: true,
            ),
            categoryIdOf: (item) => item.departmentId,
            isCurrent: () => _isCurrent(request),
          );
    } catch (_) {
      if (!_isCurrent(request)) return;
      setState(() => _searchLocationError = '完整部门定位失败，请稍后重试');
      return;
    }
    if (contentDepartmentIds == null) return;
    final resolution = resolveHierarchySearch(
      roots: widget.tree,
      query: query,
      contentCategoryIds: contentDepartmentIds,
    );
    final selectedId = resolution.selectedId;
    final selected = selectedId == null
        ? null
        : _findDepartment(widget.tree, selectedId);

    // 纯部门命中：右侧浏览该部门全部员工，不把部门词错误地当人员过滤词。
    if (!resolution.hasContentMatches && selectedId != null) {
      try {
        final categoryPage = await repository.list(
          size: _pageSize,
          departmentId: selectedId,
          statuses: widget.statuses,
          includeSubtree: true,
        );
        if (!_isCurrent(request)) return;
        setState(() {
          _visibleFilterIds = resolution.visibleIds;
          _contentMatchDepartmentIds = resolution.contentCategoryIds;
          _selectedDeptId = selectedId;
          _selectedDeptName = selected?.name;
          _replacePage(categoryPage, departmentId: selectedId, keyword: null);
          _loading = false;
          _searchLocationError = null;
        });
      } catch (_) {
        if (!_isCurrent(request)) return;
        setState(() => _error = '加载人员失败，请稍后重试');
      }
      return;
    }

    if (!_isCurrent(request)) return;
    setState(() {
      _visibleFilterIds = resolution.visibleIds;
      _contentMatchDepartmentIds = resolution.contentCategoryIds;
      _selectedDeptId = selectedId;
      _selectedDeptName = selected?.name;
      _searchLocationError = null;
    });
  }

  Future<void> _loadEmployees({String? departmentId, String? keyword}) async {
    if (!_canUseCandidates) return;
    final request = ++_requestVersion;
    if (departmentId == null && (keyword == null || keyword.isEmpty)) {
      setState(() {
        _items = const [];
        _resetPageState();
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await ref
          .read(employeeRepositoryProvider)
          .list(
            size: _pageSize,
            search: keyword,
            statuses: widget.statuses,
            departmentId: departmentId,
            includeSubtree: true,
          );
      if (!_isCurrent(request)) return;
      setState(() {
        _replacePage(result, departmentId: departmentId, keyword: keyword);
        _loading = false;
      });
    } catch (_) {
      if (!_isCurrent(request)) return;
      setState(() {
        _error = '加载人员失败，请稍后重试';
        _loading = false;
      });
    }
  }

  void _replacePage(
    PagedResult<EmployeeSummary> result, {
    required String? departmentId,
    required String? keyword,
  }) {
    _items = result.items
        .where((employee) => !widget.excludeEmployeeIds.contains(employee.id))
        .map(_toPickerItem)
        .toList();
    _itemPage = result.page;
    _itemTotalPages = result.totalPages;
    _itemTotal = result.total;
    _pageDepartmentId = departmentId;
    _pageKeyword = keyword;
    _loadingMore = false;
    _loadMoreError = null;
  }

  void _resetPageState() {
    _itemPage = 0;
    _itemTotalPages = 0;
    _itemTotal = 0;
    _pageDepartmentId = null;
    _pageKeyword = null;
    _loadingMore = false;
    _loadMoreError = null;
  }

  UtenEmployeePickerItem _toPickerItem(EmployeeSummary employee) =>
      UtenEmployeePickerItem(
        id: employee.id,
        name: employee.fullName,
        employeeCode: employee.code,
        departmentId: employee.departmentId,
        departmentName: employee.departmentName,
        accountStatus: employee.accountStatus,
        employmentStatus: employee.status,
      );

  Future<void> _loadMoreEmployees() async {
    if (!_canUseCandidates || _loadingMore || _itemPage >= _itemTotalPages) {
      return;
    }
    final request = _requestVersion;
    final nextPage = _itemPage + 1;
    setState(() {
      _loadingMore = true;
      _loadMoreError = null;
    });
    try {
      final result = await ref
          .read(employeeRepositoryProvider)
          .list(
            page: nextPage,
            size: _pageSize,
            search: _pageKeyword,
            statuses: widget.statuses,
            departmentId: _pageDepartmentId,
            includeSubtree: true,
          );
      if (!_isCurrent(request)) return;
      setState(() {
        _items = [
          ..._items,
          ...result.items
              .where(
                (employee) => !widget.excludeEmployeeIds.contains(employee.id),
              )
              .map(_toPickerItem),
        ];
        _itemPage = result.page;
        _itemTotalPages = result.totalPages;
        _itemTotal = result.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (!_isCurrent(request)) return;
      setState(() {
        _loadingMore = false;
        _loadMoreError = '加载更多失败，请重试';
      });
    }
  }

  DepartmentNode? _findDepartment(List<DepartmentNode> nodes, String id) {
    for (final node in nodes) {
      if (node.id == id) return node;
      final nested = _findDepartment(node.children, id);
      if (nested != null) return nested;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final treePane = UtenDepartmentTreeView(
      nodes: widget.tree,
      mode: UtenDepartmentTreeMode.single,
      flatLevelColors: true,
      expandOnRowTap: true,
      showSearch: false,
      header: Padding(
        // 左缘贴 0（2026-10-18 全站分栏口径）：与分类页左栏搜索共缘。
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 8),
        child: UtenSearchBar(
          controller: _keywordCtl,
          hint: '搜索部门/员工姓名或工号',
          onInputChanged: _onSearchInput,
          onChanged: _applyGlobalSearch,
        ),
      ),
      visibleFilterIds: _visibleFilterIds,
      externalSearchQuery: _globalQuery,
      externalSearchLoading: _loading && _globalQuery.isNotEmpty,
      externalSearchError: _globalQuery.isEmpty
          ? null
          : (_searchLocationError ?? _error),
      initiallyExpandDepth: 0,
      selectedIds: _selectedDeptId == null ? const {} : {_selectedDeptId!},
      nodeEnabledPredicate: (_) => true,
      onToggleSelect: _onDeptTap,
    );
    final body = UtenSplitView(
      persistenceKey: 'employeePicker.departmentTree',
      initialLeadingWidth: _treeNaturalWidth(theme),
      minLeadingWidth: 160,
      maxLeadingWidth: 560,
      leadingNoun: '部门',
      selectedLeadingLabel:
          utenTreeSelectionPath(widget.tree, _selectedDeptId) ?? '全部部门',
      selectedLeadingKey: _selectedDeptId,
      compactHeader: treePane.header,
      leading: treePane,
      trailing: _buildRightPane(theme),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: body),
        UtenPickerConfirmBar(
          selectedCount: _picked == null ? 0 : 1,
          selectedLabel: _picked?.displayName,
          confirmEnabled:
              _canUseCandidates &&
              !_loading &&
              _error == null &&
              _picked != null,
          onConfirm: () {
            if (!_canUseCandidates || _loading || _error != null) return;
            Navigator.of(context).pop(_picked);
          },
        ),
      ],
    );
  }

  double _treeNaturalWidth(ThemeData theme) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    var widest = 0.0;
    void measure(List<DepartmentNode> nodes) {
      for (final node in nodes) {
        painter.text = TextSpan(
          text: node.name,
          style: theme.textTheme.bodyMedium,
        );
        painter.layout();
        widest = math.max(widest, painter.width);
        measure(node.children);
      }
    }

    measure(widget.tree);
    painter.dispose();
    return (widest + 65).clamp(160, 560);
  }

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        if (_selectedDeptName != null || _globalQuery.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                [
                  if (_selectedDeptName != null) '部门：$_selectedDeptName',
                  if (_globalQuery.isNotEmpty)
                    _pageKeyword == null
                        ? '部门匹配：$_globalQuery'
                        : '员工匹配：$_globalQuery',
                  if (_itemTotal > 0) '已显示 ${_items.length}/$_itemTotal',
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        Expanded(child: _buildTable(theme)),
      ],
    );
  }

  Widget _buildTable(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_items.isEmpty) {
      final hasQuery =
          _keywordCtl.text.trim().isNotEmpty || _selectedDeptId != null;
      return Center(
        child: Text(
          hasQuery ? '无匹配人员' : '请选择左侧部门或输入姓名/工号搜索',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    final showFooter =
        _loadingMore || _loadMoreError != null || _itemPage < _itemTotalPages;
    final requestVersion = _requestVersion;
    return Column(
      children: [
        Expanded(
          child: MasterDataTableView<UtenEmployeePickerItem>(
            key: const ValueKey('department-employee-table'),
            columns: [
              MasterColumnDef(
                key: 'name',
                label: '姓名',
                width: 140,
                value: (employee) => employee.name,
                columnSearchEnabled: false,
              ),
              MasterColumnDef(
                key: 'employeeCode',
                label: '工号',
                width: 120,
                value: (employee) => employee.employeeCode,
                columnSearchEnabled: false,
              ),
              MasterColumnDef(
                key: 'department',
                label: '部门',
                width: 200,
                value: (employee) => employee.departmentName,
                columnSearchEnabled: false,
              ),
              MasterColumnDef(
                key: 'accountStatus',
                label: '账号状态',
                width: 100,
                value: (employee) =>
                    employeeAccountStatusLabel(employee.accountStatus),
                columnSearchEnabled: false,
              ),
              MasterColumnDef(
                key: 'employmentStatus',
                label: '在职状态',
                width: 100,
                value: (employee) =>
                    employeeEmploymentStatusLabel(employee.employmentStatus),
                columnSearchEnabled: false,
              ),
            ],
            items: _items,
            rowKeyOf: (employee) => employee.id,
            singleTapRows: true,
            isSelected: (employee) => employee.id == _picked?.id,
            onRowTap: (employee) {
              if (_loading || !_isCurrent(requestVersion)) return;
              setState(() => _picked = employee);
            },
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            paginationScope: (_pageDepartmentId, _pageKeyword, _requestVersion),
            loadingMore: _loadingMore,
            onLoadMore:
                !_loadingMore &&
                    _loadMoreError == null &&
                    _itemPage < _itemTotalPages
                ? _loadMoreEmployees
                : null,
            showPaginationControls: false,
            showFullscreenToggle: false,
            showColumnChooser: false,
            showSelectionSummary: false,
            enableTextSelection: false,
          ),
        ),
        if (showFooter)
          Padding(
            padding: const EdgeInsets.all(8),
            child: _loadingMore
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2.5),
                  )
                : TextButton.icon(
                    key: const ValueKey('department-employee-load-more'),
                    onPressed: _loadMoreEmployees,
                    icon: Icon(
                      _loadMoreError == null
                          ? Icons.expand_more_rounded
                          : Icons.refresh_rounded,
                    ),
                    label: Text(_loadMoreError ?? '加载更多员工'),
                  ),
          ),
      ],
    );
  }
}

/// 只读展示 + 点击打开 [showUtenDepartmentEmployeePicker] 的表单字段
/// （MasterFieldDef.customBuilder 场景，如模具「保管人」；只提交员工 id，
/// 展示名由本组件自行持有——同 packaging_picker_field.dart 的静态 ctx.initialValue 注释）。
class DepartmentEmployeePickerField extends StatefulWidget {
  const DepartmentEmployeePickerField({
    super.key,
    required this.label,
    required this.hint,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.initialLoader,
    this.allowClear = true,
  });

  final String label;
  final String hint;
  final String? initialId;
  final String? initialName;

  /// 回写提交值（员工 id 字符串或 null）。
  final void Function(dynamic value) onChanged;

  /// 打开部门树+员工选择器，取消返回 null。
  final Future<UtenEmployeePickerItem?> Function() onPick;

  /// 历史详情只有员工 id/姓名时，可按 id 补查工号与部门以统一回显。
  final Future<UtenEmployeePickerItem?> Function(String id)? initialLoader;

  final bool allowClear;

  @override
  State<DepartmentEmployeePickerField> createState() =>
      _DepartmentEmployeePickerFieldState();
}

class _DepartmentEmployeePickerFieldState
    extends State<DepartmentEmployeePickerField> {
  late final TextEditingController _ctl;
  String? _id;
  int _loadSerial = 0;
  int _selectionRevision = 0;

  @override
  void initState() {
    super.initState();
    _id = (widget.initialId == null || widget.initialId!.isEmpty)
        ? null
        : widget.initialId;
    _ctl = TextEditingController(text: widget.initialName ?? '');
    _hydrateInitial();
  }

  @override
  void didUpdateWidget(DepartmentEmployeePickerField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialId != oldWidget.initialId ||
        widget.initialName != oldWidget.initialName) {
      _selectionRevision++;
      _id = (widget.initialId == null || widget.initialId!.isEmpty)
          ? null
          : widget.initialId;
      _ctl.text = widget.initialName ?? '';
      _hydrateInitial();
    }
  }

  Future<void> _hydrateInitial() async {
    final request = ++_loadSerial;
    final id = _id;
    final loader = widget.initialLoader;
    if (id == null || loader == null) return;
    try {
      final item = await loader(id);
      if (!mounted || request != _loadSerial || _id != id || item == null) {
        return;
      }
      setState(() => _ctl.text = item.displayName);
    } catch (_) {
      // 历史回显增强失败不影响继续编辑；重新选择时仍返回完整候选。
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(UtenEmployeePickerItem? item) {
    _loadSerial++;
    _selectionRevision++;
    setState(() {
      _id = item?.id;
      _ctl.text = item?.displayName ?? '';
    });
    widget.onChanged(_id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: _ctl,
      readOnly: true,
      decoration: UtenInputDecoration(
        InputDecoration(
          labelText: widget.label,
          hintText: widget.hint,
          prefixIcon: const Icon(Icons.person_search_rounded),
          suffixIcon: _id != null && widget.allowClear
              ? IconButton(
                  tooltip: '清除选择',
                  icon: const Icon(Icons.clear_rounded),
                  onPressed: () => _set(null),
                )
              : Icon(
                  Icons.unfold_more_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
      ),
      onTap: () async {
        final revision = _selectionRevision;
        final item = await widget.onPick();
        if (!mounted || revision != _selectionRevision || item == null) return;
        _set(item);
      },
    );
  }
}
