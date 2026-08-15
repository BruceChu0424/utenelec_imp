// 部门树 + 员工选择器：先选部门（未展开的分类树），点部门列出该部门（含子部门）的人员，
// 也可直接搜索姓名/工号跨部门找人。左树 + 右人员列表布局仿 uten_goods_picker.dart。
//
// 问题 #6：模具「保管人」原来是纯搜索平铺列表，改成"先浏览部门再挑人"，更贴近老员工的
// 使用习惯（不知道该搜什么名字时，按部门找人更直观）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_employee_picker.dart'
    show UtenEmployeePickerItem;
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/hierarchy/category_tree_search.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_tree_view.dart';
import '../models/employee_api_models.dart';
import '../repositories/employee_repository.dart';

/// 员工选择器专用最小部门树：权限与员工摘要列表同为 employee:view。
/// 不复用 departmentPickerTreeProvider，避免要求无关的 department:view。
final employeePickerDepartmentTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>((ref) async {
      final rows = await ref
          .watch(apiClientProvider)
          .getList(ApiEndpoints.employeePickerDepartmentTree);
      return rows.map(DepartmentNode.fromJson).toList();
    });

/// 弹出「部门树 + 员工」选择器，返回所选员工；取消返回 null。
Future<UtenEmployeePickerItem?> showUtenDepartmentEmployeePicker(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择员工',
}) async {
  List<DepartmentNode> tree;
  try {
    tree = await ref.read(employeePickerDepartmentTreeProvider.future);
  } catch (_) {
    if (context.mounted) context.appError('部门树加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  final sheet = _DeptEmployeePickerSheet(tree: tree, title: title);
  return showUtenAdaptivePanel<UtenEmployeePickerItem>(
    context: context,
    drawerWidth: 720,
    builder: (_) => sheet,
  );
}

class _DeptEmployeePickerSheet extends ConsumerStatefulWidget {
  const _DeptEmployeePickerSheet({required this.tree, required this.title});
  final List<DepartmentNode> tree;
  final String title;

  @override
  ConsumerState<_DeptEmployeePickerSheet> createState() =>
      _DeptEmployeePickerSheetState();
}

class _DeptEmployeePickerSheetState
    extends ConsumerState<_DeptEmployeePickerSheet> {
  static const _pageSize = 100;

  String? _selectedDeptId;
  String? _selectedDeptName;
  final _keywordCtl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _searchLocationError;
  List<UtenEmployeePickerItem> _items = const [];
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

  @override
  void dispose() {
    _keywordCtl.dispose();
    super.dispose();
  }

  void _onDeptTap(DepartmentNode node) {
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
        includeSubtree: true,
      );
      if (!mounted || request != _requestVersion) return;
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
      if (!mounted || request != _requestVersion) return;
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
              includeSubtree: true,
            ),
            categoryIdOf: (item) => item.departmentId,
            isCurrent: () => mounted && request == _requestVersion,
          );
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
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
          includeSubtree: true,
        );
        if (!mounted || request != _requestVersion) return;
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
        if (!mounted || request != _requestVersion) return;
        setState(() => _error = '加载人员失败，请稍后重试');
      }
      return;
    }

    if (!mounted || request != _requestVersion) return;
    setState(() {
      _visibleFilterIds = resolution.visibleIds;
      _contentMatchDepartmentIds = resolution.contentCategoryIds;
      _selectedDeptId = selectedId;
      _selectedDeptName = selected?.name;
      _searchLocationError = null;
    });
  }

  Future<void> _loadEmployees({String? departmentId, String? keyword}) async {
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
            departmentId: departmentId,
            includeSubtree: true,
          );
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _replacePage(result, departmentId: departmentId, keyword: keyword);
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
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
    _items = result.items.map(_toPickerItem).toList();
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
        departmentName: [
          if (employee.departmentName != null) employee.departmentName!,
          '工号${employee.code}',
        ].join(' · '),
      );

  Future<void> _loadMoreEmployees() async {
    if (_loadingMore || _itemPage >= _itemTotalPages) return;
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
            departmentId: _pageDepartmentId,
            includeSubtree: true,
          );
      if (!mounted || request != _requestVersion) return;
      setState(() {
        _items = [..._items, ...result.items.map(_toPickerItem)];
        _itemPage = result.page;
        _itemTotalPages = result.totalPages;
        _itemTotal = result.total;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || request != _requestVersion) return;
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
    final theme = Theme.of(context);
    final treeWidth = context.breakpoint.isCompact ? 150.0 : 240.0;
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
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: treeWidth,
                child: UtenDepartmentTreeView(
                  nodes: widget.tree,
                  showSearch: false,
                  header: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
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
                  selectedIds: _selectedDeptId == null
                      ? const {}
                      : {_selectedDeptId!},
                  nodeEnabledPredicate: (_) => true,
                  onNodeTap: _onDeptTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
          ),
        ),
      ],
    );
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
        Expanded(child: _buildList(theme)),
      ],
    );
  }

  Widget _buildList(ThemeData theme) {
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
    return ListView.separated(
      itemCount: _items.length + (showFooter ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        if (i == _items.length) {
          if (_loadingMore) {
            return const Padding(
              padding: EdgeInsets.all(16),
              child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: TextButton.icon(
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
          );
        }
        final e = _items[i];
        return ListTile(
          title: Text(e.name),
          subtitle: e.departmentName == null ? null : Text(e.departmentName!),
          onTap: () => Navigator.of(context).pop(e),
        );
      },
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

  final bool allowClear;

  @override
  State<DepartmentEmployeePickerField> createState() =>
      _DepartmentEmployeePickerFieldState();
}

class _DepartmentEmployeePickerFieldState
    extends State<DepartmentEmployeePickerField> {
  late final TextEditingController _ctl;
  String? _id;

  @override
  void initState() {
    super.initState();
    _id = (widget.initialId == null || widget.initialId!.isEmpty)
        ? null
        : widget.initialId;
    _ctl = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(UtenEmployeePickerItem? item) {
    setState(() {
      _id = item?.id;
      _ctl.text = item?.name ?? '';
    });
    widget.onChanged(_id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: _ctl,
      readOnly: true,
      decoration: InputDecoration(
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
      onTap: () async {
        final item = await widget.onPick();
        if (item != null) _set(item);
      },
    );
  }
}
