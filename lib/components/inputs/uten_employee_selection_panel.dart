import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/network/api_exception.dart';
import '../../core/responsive/breakpoint.dart';
import '../../shared/models/uten_tree_node.dart';
import '../../shared/widgets/uten_hierarchy_tree_view.dart';
import '../feedback/uten_empty.dart';
import '../layout/uten_adaptive_panel.dart';
import '../layout/uten_bottom_action_bar.dart';
import '../layout/uten_split_view.dart';
import '../layout/uten_table_column_kit.dart' show utenTableSelectedRowColor;
import 'uten_employee_picker_models.dart';
import 'uten_search_bar.dart';

/// Only the caller's authorized candidates form this directory. This panel
/// never reads an HR directory or widens a business-specific candidate scope.
Future<List<UtenEmployeePickerItem>?> showUtenEmployeeSelectionPanel(
  BuildContext context, {
  required UtenEmployeePickerLoader loader,
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
}) => showUtenAdaptivePanel<List<UtenEmployeePickerItem>>(
  context: context,
  drawerWidth: math.max(720, MediaQuery.sizeOf(context).width * 0.5),
  builder: (_) => UtenEmployeeSelectionPanel(
    loader: loader,
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

/// Shared employee selection body for fields and embedded business pickers.
/// Selection is a local draft until Confirm; Cancel always discards it.
class UtenEmployeeSelectionPanel extends StatefulWidget {
  const UtenEmployeeSelectionPanel({
    super.key,
    required this.loader,
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

class _UtenEmployeeSelectionPanelState
    extends State<UtenEmployeeSelectionPanel> {
  static const _allDepartments = 'employee-picker:all';
  static const _unknownDepartment = 'employee-picker:unknown';
  final _searchController = TextEditingController();
  late final Map<String, UtenEmployeePickerItem> _selected;
  List<UtenEmployeePickerItem> _baseline = const [];
  List<UtenEmployeePickerItem> _items = const [];
  String _department = _allDepartments;
  String _query = '';
  bool _loading = true;
  Object? _error;
  int _request = 0;

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
    _load();
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
    _query = '';
    _searchController.clear();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  static String _departmentKey(UtenEmployeePickerItem item) {
    final id = item.departmentId?.trim();
    return id == null || id.isEmpty ? _unknownDepartment : 'department:$id';
  }

  bool _matches(UtenEmployeePickerItem item, String query) {
    final needle = query.toLowerCase();
    return [
      item.name,
      item.employeeCode,
      if (widget.showDepartmentFilter) item.departmentName,
    ].any((value) => value?.toLowerCase().contains(needle) == true);
  }

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
    final request = ++_request;
    final query = _query;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.loader(query.isEmpty ? null : query);
      if (!mounted || request != _request || query != _query) return;
      final byId = <String, UtenEmployeePickerItem>{
        // A department-name search must also find its already-authorized
        // people when the business endpoint searches only names/codes.
        if (query.isNotEmpty)
          for (final item in _baseline)
            if (_matches(item, query)) item.id: item,
        for (final item in result) item.id: item,
      };
      setState(() {
        _items = byId.values.toList(growable: false);
        if (query.isEmpty) _baseline = _items;
        for (final item in _items) {
          if (_selected.containsKey(item.id)) _selected[item.id] = item;
        }
        _loading = false;
      });
    } catch (error) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  List<_EmployeeDepartmentNode> _departments() {
    final names = <String, String>{};
    for (final item in [..._baseline, ..._items]) {
      final key = _departmentKey(item);
      final name = item.departmentName?.trim();
      names[key] = key == _unknownDepartment
          ? '未提供部门'
          : name == null || name.isEmpty
          ? '未命名部门'
          : name;
    }
    final departments =
        [
          for (final entry in names.entries)
            _EmployeeDepartmentNode(entry.key, entry.value),
        ]..sort((a, b) {
          if (a.id == _unknownDepartment) return 1;
          if (b.id == _unknownDepartment) return -1;
          final byName = a.name.compareTo(b.name);
          return byName == 0 ? a.id.compareTo(b.id) : byName;
        });
    return [
      const _EmployeeDepartmentNode(_allDepartments, '全部部门'),
      ...departments,
    ];
  }

  void _toggle(UtenEmployeePickerItem item) {
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
    padding: EdgeInsets.symmetric(
      horizontal: context.breakpoint.isCompact ? 8 : 16,
      vertical: 8,
    ),
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

  double _treeWidth(List<_EmployeeDepartmentNode> nodes, ThemeData theme) {
    final painter = TextPainter(textDirection: Directionality.of(context));
    var width = 0.0;
    for (final node in nodes) {
      painter.text = TextSpan(
        text: node.name,
        style: theme.textTheme.bodyMedium,
      );
      painter.layout();
      width = math.max(width, painter.width);
    }
    painter.dispose();
    return (width + 65).clamp(200, 560);
  }

  @override
  Widget build(BuildContext context) {
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
      final departments = _departments();
      final visibleIds = _query.isEmpty
          ? null
          : {
              _allDepartments,
              for (final item in _items) _departmentKey(item),
              for (final node in departments)
                if (node.name.toLowerCase().contains(_query.toLowerCase()))
                  node.id,
            };
      final tree = UtenHierarchyTreeView<_EmployeeDepartmentNode>(
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
        initiallyExpandDepth: 0,
        expandOnRowTap: true,
        onToggleSelect: (node) => setState(() => _department = node.id),
      );
      body = context.breakpoint.isCompact
          ? Row(
              children: [
                SizedBox(width: 152, child: tree),
                const VerticalDivider(width: 1),
                Expanded(child: _list(theme)),
              ],
            )
          : UtenSplitView(
              persistenceKey: 'employeePicker.departmentTree',
              initialLeadingWidth: _treeWidth(departments, theme),
              minLeadingWidth: 200,
              maxLeadingWidth: 560,
              leading: tree,
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
        Expanded(child: body),
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
    final items = _items
        .where(
          (item) =>
              _department == _allDepartments ||
              _departmentKey(item) == _department,
        )
        .toList(growable: false);
    if (items.isEmpty) {
      return UtenEmpty(
        icon: Icons.table_rows_outlined,
        message: _query.isEmpty ? widget.emptyMessage : '未找到匹配的人员',
        description: _query.isEmpty ? widget.emptyDescription : null,
      );
    }
    return ListView.separated(
      key: const Key('uten-employee-picker-candidates'),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final item = items[index];
        final selected = _selected.containsKey(item.id);
        final text = [
          if (item.departmentName?.trim().isNotEmpty == true)
            item.departmentName!.trim(),
          if (item.subtitle?.trim().isNotEmpty == true) item.subtitle!.trim(),
          if (!item.enabled && item.disabledReason?.trim().isNotEmpty == true)
            item.disabledReason!.trim(),
        ].join(' · ');
        return ListTile(
          key: ValueKey('employee-picker-item-${item.id}'),
          selected:
              selected || (_selected.isEmpty && item.id == widget.selectedId),
          selectedTileColor: utenTableSelectedRowColor(theme),
          enabled: item.enabled || (widget.multiple && selected),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 4,
          ),
          leading: widget.multiple
              ? Checkbox(
                  value: selected,
                  onChanged: item.enabled || selected
                      ? (_) => _toggle(item)
                      : null,
                )
              : null,
          title: Text(
            item.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: text.isEmpty
              ? null
              : Text(text, maxLines: 3, overflow: TextOverflow.ellipsis),
          trailing: !widget.multiple && selected
              ? Icon(
                  Icons.check_circle_rounded,
                  color: theme.colorScheme.primary,
                  size: 22,
                )
              : null,
          onTap: item.enabled || (widget.multiple && selected)
              ? () => _toggle(item)
              : null,
        );
      },
    );
  }

  Widget _confirmBar(ThemeData theme) {
    final label = widget.multiple
        ? widget.selectedCountLabel?.call(_selected.length) ??
              '已选 ${_selected.length} 人'
        : _selected.isEmpty
        ? '请选择后点「确定」'
        : '已选择：${_selected.values.first.displayName}';
    final canConfirm =
        (widget.multiple || _selected.length == 1) &&
        _selected.values.every((item) => item.enabled);
    final status = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final actions = Wrap(
      spacing: 8,
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (widget.multiple)
          TextButton(
            onPressed: _selected.isEmpty
                ? null
                : () => setState(_selected.clear),
            child: Text(widget.clearLabel),
          ),
        TextButton(onPressed: _cancel, child: const Text('取消')),
        FilledButton(
          onPressed: canConfirm ? _confirm : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
    return UtenBottomActionBar(
      child: LayoutBuilder(
        builder: (_, constraints) => constraints.maxWidth < 480
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [status, const SizedBox(height: 8), actions],
              )
            : Row(
                children: [
                  Expanded(child: status),
                  actions,
                ],
              ),
      ),
    );
  }
}

class _EmployeeDepartmentNode implements UtenTreeNode<_EmployeeDepartmentNode> {
  const _EmployeeDepartmentNode(this.id, this.name);

  @override
  final String id;
  @override
  final String name;
  @override
  String get code => '';
  @override
  List<_EmployeeDepartmentNode> get children => const [];
  @override
  bool get hasChildren => false;
}
