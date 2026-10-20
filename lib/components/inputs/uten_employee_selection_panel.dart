import '../../shared/search/keyword_search.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/network/api_exception.dart';
import '../../core/theme/uten_tokens.dart';
import '../../features/basic_data/widgets/master_data_table_view.dart';
import '../../features/department/models/department_node.dart';
import '../../features/employee/providers/employee_picker_department_tree_provider.dart';
import '../../shared/hierarchy/uten_tree_path.dart';
import '../../shared/formatters/employee_display.dart';
import '../../shared/widgets/uten_hierarchy_tree_view.dart';
import '../feedback/uten_empty.dart';
import '../layout/uten_adaptive_panel.dart';
import '../layout/uten_picker_confirm_bar.dart';
import '../layout/uten_split_view.dart';
import '../layout/uten_panel_opening_scope.dart';
import 'uten_employee_department_tree.dart';
import 'uten_employee_picker_models.dart';
import 'uten_employee_picker_access.dart';
import 'uten_search_bar.dart';

/// Only the caller's authorized candidates form this directory. Minimal
/// organization metadata supplies hierarchy, never additional staff records.
Future<List<UtenEmployeePickerItem>?> showUtenEmployeeSelectionPanel(
  BuildContext context, {
  required UtenEmployeePickerLoader loader,
  Future<List<DepartmentNode>> Function()? departmentTreeLoader,
  String title = '选择人员',
  bool multiple = false,
  List<UtenEmployeePickerItem> initialSelection = const [],
  String? selectedId,
  String? departmentName,
  Object? candidateScopeKey,
  bool showDepartmentFilter = true,
  String searchHint = '搜索部门 / 姓名 / 工号',
  String emptyMessage = '未找到匹配的人员',
  String? emptyDescription,
  String confirmLabel = '确定',
  String clearLabel = '清空',
  String Function(int count)? selectedCountLabel,
}) async {
  final access = EmployeePickerAccess(
    EmployeePickerAccess.containerOf(context),
  );
  final ticket = access.capture();
  try {
    final result = await showUtenAdaptivePanel<List<UtenEmployeePickerItem>>(
      context: context,
      drawerWidth: 720,
      builder: (_) => UtenEmployeeSelectionPanel(
        loader: loader,
        departmentTreeLoader: departmentTreeLoader,
        title: title,
        multiple: multiple,
        initialSelection: initialSelection,
        selectedId: selectedId,
        departmentName: departmentName,
        candidateScopeKey: candidateScopeKey,
        showDepartmentFilter: showDepartmentFilter,
        searchHint: searchHint,
        emptyMessage: emptyMessage,
        emptyDescription: emptyDescription,
        confirmLabel: confirmLabel,
        clearLabel: clearLabel,
        selectedCountLabel: selectedCountLabel,
      ),
    );
    return context.mounted &&
            identical(
              access.container,
              EmployeePickerAccess.containerOf(context),
            ) &&
            ticket.isCurrent
        ? result
        : null;
  } finally {
    access.dispose();
  }
}

/// Shared employee selection body for fields and embedded business pickers.
/// Selection is a local draft until Confirm; Cancel always discards it.
class UtenEmployeeSelectionPanel extends StatefulWidget {
  const UtenEmployeeSelectionPanel({
    super.key,
    required this.loader,
    this.departmentTreeLoader,
    this.title = '选择人员',
    this.multiple = false,
    this.initialSelection = const [],
    this.selectedId,
    this.departmentName,
    this.candidateScopeKey,
    this.showDepartmentFilter = true,
    this.searchHint = '搜索部门 / 姓名 / 工号',
    this.emptyMessage = '未找到匹配的人员',
    this.emptyDescription,
    this.confirmLabel = '确定',
    this.clearLabel = '清空',
    this.selectedCountLabel,
    this.onConfirm,
    this.onCancel,
  });

  final UtenEmployeePickerLoader loader;
  final Future<List<DepartmentNode>> Function()? departmentTreeLoader;
  final String title;
  final bool multiple;
  final List<UtenEmployeePickerItem> initialSelection;
  final String? selectedId;
  final String? departmentName;
  final Object? candidateScopeKey;
  final bool showDepartmentFilter;
  final String searchHint;
  final String emptyMessage;
  final String? emptyDescription;
  final String confirmLabel;
  final String clearLabel;
  final String Function(int count)? selectedCountLabel;
  final ValueChanged<List<UtenEmployeePickerItem>>? onConfirm;
  final VoidCallback? onCancel;

  @override
  State<UtenEmployeeSelectionPanel> createState() =>
      _UtenEmployeeSelectionPanelState();
}

class _UtenEmployeeSelectionPanelState extends State<UtenEmployeeSelectionPanel>
    with EmployeePickerAccessState<UtenEmployeeSelectionPanel> {
  static const _allDepartments = UtenEmployeeDepartmentDirectory.allDepartments;
  final _searchController = TextEditingController();
  late final Map<String, UtenEmployeePickerItem> _selected;
  List<UtenEmployeePickerItem> _baseline = const [];
  List<UtenEmployeePickerItem> _items = const [];
  List<DepartmentNode> _organization = const [];
  bool _treeLoading = false;
  bool _treeFailed = false;
  int _treeRequest = 0;
  String _department = _allDepartments;
  String _query = '';
  bool _loading = true;
  Object? _error;
  int _request = 0;
  bool _started = false;
  bool _invalidated = false;
  ModalRoute<Object?>? _route;
  late final EmployeePickerAccessTicket _accessTicket;

  @override
  void initState() {
    super.initState();
    _selected = {
      for (final item
          in widget.multiple
              ? widget.initialSelection
              : widget.initialSelection.take(1))
        item.id: item,
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    if (!_started) {
      _started = true;
      _accessTicket = pickerAccess.capture();
      _loadOrganization();
      _load();
    }
  }

  @override
  void onPickerAccessInvalidated() {
    _invalidated = true;
    _request++;
    _treeRequest++;
    _selected.clear();
    _baseline = const [];
    _items = const [];
    _organization = const [];
    // Never pop whichever unrelated dialog happened to open above this picker.
    final route = _route;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (route is PopupRoute && route.isActive) {
        route.navigator?.removeRoute(route);
      } else {
        setState(() {});
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  @override
  void didUpdateWidget(UtenEmployeeSelectionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final scopeChanged =
        widget.candidateScopeKey != oldWidget.candidateScopeKey ||
        widget.departmentName != oldWidget.departmentName ||
        widget.showDepartmentFilter != oldWidget.showDepartmentFilter;
    final selectionChanged =
        widget.multiple != oldWidget.multiple ||
        !sameEmployeePickerSelection(
          widget.initialSelection,
          oldWidget.initialSelection,
        );
    if (!scopeChanged && !selectionChanged) return;
    _request++;
    _treeRequest++;
    _selected.clear();
    if (!scopeChanged || selectionChanged) {
      for (final item
          in widget.multiple
              ? widget.initialSelection
              : widget.initialSelection.take(1)) {
        _selected[item.id] = item;
      }
    }
    _baseline = const [];
    _items = const [];
    _department = _allDepartments;
    if (scopeChanged) {
      _organization = const [];
      _treeLoading = false;
      _treeFailed = false;
    }
    _query = '';
    _searchController.clear();
    _loadOrganization();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  UtenEmployeeDepartmentDirectory get _directory =>
      UtenEmployeeDepartmentDirectory(
        organization: _organization,
        candidates: [..._baseline, ..._items],
      );

  Future<void> _loadOrganization() async {
    if (_invalidated || !widget.showDepartmentFilter) return;
    final ticket = pickerAccess.capture();
    final request = ++_treeRequest;
    setState(() {
      _treeLoading = true;
      _treeFailed = false;
    });
    try {
      final loader = widget.departmentTreeLoader;
      final source = pickerAccess.container;
      final organization = loader != null
          ? await loader()
          : source == null
          ? <DepartmentNode>[]
          : await source.read(employeePickerDepartmentTreeProvider.future);
      if (!mounted || !ticket.isCurrent || request != _treeRequest) return;
      setState(() {
        _organization = organization;
        _treeLoading = false;
      });
      if (_query.isNotEmpty) _load();
    } catch (_) {
      if (!mounted || !ticket.isCurrent || request != _treeRequest) return;
      setState(() {
        _organization = const [];
        _treeLoading = false;
        _treeFailed = true;
      });
    }
  }

  bool _matchesDepartment(
    UtenEmployeePickerItem item,
    String query,
    UtenEmployeeDepartmentDirectory directory,
  ) =>
      widget.showDepartmentFilter &&
      keywordSearchTerms(query).any(
        (term) => matchesKeywordSearch([
          item.departmentName,
          directory.pathOf(item),
        ], term),
      ) &&
      matchesKeywordSearch([
        item.name,
        item.employeeCode,
        item.departmentName,
        directory.pathOf(item),
      ], query);

  void _onInput(String value) {
    _request++;
    setState(() {
      _query = value.trim();
      _department = _allDepartments;
      _loading = true;
      _error = null;
    });
  }

  Future<void> _load() async {
    if (_invalidated) return;
    final ticket = pickerAccess.capture();
    final request = ++_request;
    final query = _query;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.loader(query.isEmpty ? null : query);
      if (!mounted ||
          !ticket.isCurrent ||
          _invalidated ||
          request != _request ||
          query != _query) {
        return;
      }
      final directory = _directory;
      final byId = <String, UtenEmployeePickerItem>{
        // A department-name search must also find its already-authorized
        // people when the business endpoint searches only names/codes.
        if (query.isNotEmpty)
          for (final item in _baseline)
            if (_matchesDepartment(item, query, directory)) item.id: item,
        for (final item in result) item.id: item,
      };
      setState(() {
        final candidates = byId.values.toList();
        if (query.isNotEmpty) {
          final order = {
            for (var index = 0; index < candidates.length; index++)
              candidates[index].id: index,
          };
          candidates.sort((a, b) {
            final rankA =
                keywordSearchRankWithPrimary(
                  [a.name],
                  [a.employeeCode],
                  query,
                ) ??
                8;
            final rankB =
                keywordSearchRankWithPrimary(
                  [b.name],
                  [b.employeeCode],
                  query,
                ) ??
                8;
            final rank = rankA.compareTo(rankB);
            return rank != 0 ? rank : order[a.id]!.compareTo(order[b.id]!);
          });
        }
        _items = candidates;
        if (query.isEmpty) _baseline = _items;
        for (final item in _items) {
          if (_selected.containsKey(item.id)) _selected[item.id] = item;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted ||
          !ticket.isCurrent ||
          _invalidated ||
          request != _request) {
        return;
      }
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  void _toggle(UtenEmployeePickerItem item) {
    if (!_accessTicket.isCurrent ||
        _invalidated ||
        _loading ||
        _error != null) {
      return;
    }
    final selected = _selected.containsKey(item.id);
    if (!item.enabled && !selected) return;
    setState(() {
      if (widget.multiple && selected) {
        _selected.remove(item.id);
      } else if (item.enabled) {
        if (!widget.multiple) _selected.clear();
        _selected[item.id] = item;
      }
    });
  }

  void _cancel() {
    if (widget.onCancel != null) {
      widget.onCancel!();
    } else {
      Navigator.of(context).pop();
    }
  }

  void _confirm() {
    if (!_accessTicket.isCurrent ||
        _invalidated ||
        _loading ||
        _error != null) {
      return;
    }
    final selection = _selected.values.toList(growable: false);
    if (selection.any((item) => !item.enabled) ||
        (!widget.multiple && selection.length != 1)) {
      return;
    }
    if (widget.onConfirm != null) {
      widget.onConfirm!(selection);
    } else {
      Navigator.of(context).pop(selection);
    }
  }

  Widget _search() => Padding(
    // 左缘贴 0（2026-10-18 全站分栏口径）：与分类页左栏搜索共缘。
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: UtenSearchBar(
      key: const Key('uten-employee-picker-search'),
      controller: _searchController,
      hint:
          !widget.showDepartmentFilter && widget.searchHint == '搜索部门 / 姓名 / 工号'
          ? '搜索姓名 / 工号'
          : widget.searchHint,
      onInputChanged: _onInput,
      onChanged: (_) => _load(),
    ),
  );

  double _treeWidth(List<UtenEmployeeDepartmentNode> nodes, ThemeData theme) {
    final painter = TextPainter(
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    );
    var width = 0.0;
    void measure(UtenEmployeeDepartmentNode node) {
      painter.text = TextSpan(
        text: node.name,
        style: theme.textTheme.bodyMedium,
      );
      painter.layout();
      width = math.max(width, painter.width);
      for (final child in node.children) {
        measure(child);
      }
    }

    for (final node in nodes) {
      measure(node);
    }
    painter.dispose();
    return (width + 65).clamp(200, 560);
  }

  @override
  Widget build(BuildContext context) {
    if (_invalidated) return const SizedBox.shrink();
    final theme = Theme.of(context);
    Widget body;
    if (!widget.showDepartmentFilter) {
      body = Column(
        children: [
          _search(),
          Expanded(child: _list(theme)),
        ],
      );
    } else {
      final directory = _directory;
      final departments = directory.nodes;
      final visibleIds = _query.isEmpty
          ? null
          : directory.visibleIdsFor(_items);
      final tree = UtenHierarchyTreeView<UtenEmployeeDepartmentNode>(
        key: const Key('uten-employee-picker-departments'),
        nodes: departments,
        mode: UtenTreeSelectMode.single,
        selectedIds: {_department},
        searchHint: '搜索部门 / 姓名 / 工号',
        emptyNoun: '部门或人员',
        showSearch: false,
        header: _search(),
        visibleFilterIds: visibleIds,
        externalSearchQuery: _query,
        externalSearchLoading: _loading,
        flatLevelColors: true,
        expandOnRowTap: true,
        onToggleSelect: (node) => setState(() => _department = node.id),
      );
      body = UtenSplitView(
        persistenceKey: 'employeePicker.departmentTree',
        initialLeadingWidth: _treeWidth(departments, theme),
        minLeadingWidth: 160,
        maxLeadingWidth: 560,
        leadingNoun: '部门',
        selectedLeadingLabel:
            utenTreeSelectionPath(departments, _department) ?? '全部部门',
        selectedLeadingKey: _department,
        compactHeader: _search(),
        leading: _treeLoading || _treeFailed
            ? Column(
                children: [
                  _search(),
                  Expanded(
                    child: _treeFailed
                        ? UtenEmpty.error(
                            message: '部门层级加载失败',
                            actionLabel: '重试',
                            onAction: _loadOrganization,
                          )
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ],
              )
            : tree,
        trailing: _list(theme),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (widget.departmentName?.isNotEmpty == true)
                      Text(
                        widget.departmentName!,
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: _cancel,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: UtenPanelDeferredView(builder: (_) => body),
          ),
        ),
        _confirmBar(theme),
      ],
    );
  }

  Widget _list(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      final error = _error;
      return UtenEmpty.error(
        message: error is ApiException && error.message.trim().isNotEmpty
            ? error.message
            : '人员列表加载失败，请重试',
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final directory = _directory;
    final items = _items
        .where((item) => directory.contains(_department, item))
        .toList(growable: false);
    if (items.isEmpty) {
      return UtenEmpty(
        icon: Icons.table_rows_outlined,
        message: _query.isEmpty ? widget.emptyMessage : '未找到匹配的人员',
        description: _query.isEmpty ? widget.emptyDescription : null,
      );
    }
    final showNotes = items.any(
      (item) => item.subtitle?.trim().isNotEmpty == true || !item.enabled,
    );
    return MasterDataTableView<UtenEmployeePickerItem>(
      key: const Key('uten-employee-picker-candidates'),
      columns: [
        MasterColumnDef(
          key: 'name',
          label: '姓名',
          width: 150,
          value: (item) => item.name,
          columnSearchEnabled: false,
        ),
        MasterColumnDef(
          key: 'employeeCode',
          label: '工号',
          width: 130,
          value: (item) => item.employeeCode,
          columnSearchEnabled: false,
        ),
        if (widget.showDepartmentFilter)
          MasterColumnDef(
            key: 'department',
            label: '部门',
            width: 200,
            value: (item) => item.departmentName,
            columnSearchEnabled: false,
            cellBuilder: (_, item) => Tooltip(
              message: directory.pathOf(item) ?? item.departmentName ?? '未提供部门',
              child: Text(item.departmentName ?? '未提供部门'),
            ),
          ),
        if (widget.showDepartmentFilter) ...[
          MasterColumnDef(
            key: 'accountStatus',
            label: '账号状态',
            width: 110,
            value: (item) => employeeAccountStatusLabel(item.accountStatus),
            columnSearchEnabled: false,
          ),
          MasterColumnDef(
            key: 'employmentStatus',
            label: '在职状态',
            width: 110,
            value: (item) =>
                employeeEmploymentStatusLabel(item.employmentStatus),
            columnSearchEnabled: false,
          ),
        ],
        if (showNotes)
          MasterColumnDef(
            key: 'notes',
            label: '说明',
            width: 240,
            value: (item) => [
              if (item.subtitle?.trim().isNotEmpty == true)
                item.subtitle!.trim(),
              if (!item.enabled) item.disabledReason ?? '不可选择',
            ].join('；'),
            columnSearchEnabled: false,
          ),
      ],
      items: items,
      rowKeyOf: (item) => item.id,
      rowWidgetKeyOf: (item) => ValueKey('employee-picker-item-${item.id}'),
      rowForegroundColor: (item) => item.enabled ? null : theme.disabledColor,
      idOf: (item) =>
          item.enabled || _selected.containsKey(item.id) ? item.id : null,
      singleTapRows: true,
      selectable: widget.multiple,
      selectedIds: _selected.keys.toSet(),
      isSelected: (item) =>
          _selected.containsKey(item.id) ||
          (_selected.isEmpty && item.id == widget.selectedId),
      onRowTap: widget.multiple ? null : _toggle,
      onRowSelectionChanged: widget.multiple
          ? (item, _) => _toggle(item)
          : null,
      onSelectedIdsChanged: (ids) {
        if (!_accessTicket.isCurrent ||
            _invalidated ||
            _loading ||
            _error != null) {
          return;
        }
        setState(() {
          _selected.removeWhere((id, _) => !ids.contains(id));
          for (final item in items) {
            if (item.enabled && ids.contains(item.id)) {
              _selected[item.id] = item;
            }
          }
        });
      },
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      showSelectionSummary: false,
      showFullscreenToggle: false,
      showColumnChooser: false,
      showPaginationControls: false,
      enableTextSelection: false,
    );
  }

  Widget _confirmBar(ThemeData theme) {
    final label = widget.multiple
        ? widget.selectedCountLabel?.call(_selected.length) ??
              '已选 ${_selected.length} 人'
        : _selected.isEmpty
        ? '未选择'
        : '已选择：${_selected.values.first.displayName}';
    final canConfirm =
        !_invalidated &&
        !_loading &&
        _error == null &&
        (widget.multiple || _selected.length == 1) &&
        _selected.values.every((item) => item.enabled);
    final status = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    return UtenPickerConfirmBar(
      selectedCount: _selected.length,
      summary: status,
      confirmEnabled: canConfirm,
      onClear: widget.multiple ? () => setState(_selected.clear) : null,
      clearLabel: widget.clearLabel,
      onCancel: _cancel,
      onConfirm: _confirm,
      confirmLabel: widget.confirmLabel,
    );
  }
}
