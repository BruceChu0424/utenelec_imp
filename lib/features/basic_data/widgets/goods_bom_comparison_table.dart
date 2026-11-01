import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_page_layout.dart';
import '../../../components/layout/uten_split_handle.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../models/goods_bom_comparison.dart';
import '../models/goods_bom_item.dart';
import '../repositories/goods_bom_repository.dart';
import 'master_data_table_view.dart';

class _ComparisonTableRow {
  const _ComparisonTableRow({
    required this.comparison,
    required this.path,
    required this.depth,
    this.field,
    this.notice,
  });
  final BomComparisonRow comparison;
  final String path;
  final int depth;
  final String? field, notice;
  String get key => '$path|${field ?? notice ?? "component"}';
}

/// The same table, compact tree cells, headers, selection and column controls
/// as GoodsBomTab. Only read-only comparison projection is specific here.
class GoodsBomComparisonTables extends ConsumerStatefulWidget {
  const GoodsBomComparisonTables({
    super.key,
    required this.comparison,
    required this.leftHeader,
    required this.rightHeader,
    required this.selected,
    required this.onSelected,
    required this.enabled,
    required this.onlyDifferences,
    required this.loading,
    required this.initialRatio,
  });
  final GoodsBomComparison? comparison;
  final Widget leftHeader, rightHeader;
  final Set<String> selected;
  final ValueChanged<Set<String>> onSelected;
  final bool enabled, onlyDifferences, loading;
  final double initialRatio;
  @override
  ConsumerState<GoodsBomComparisonTables> createState() =>
      _GoodsBomComparisonTablesState();
}

class _GoodsBomComparisonTablesState
    extends ConsumerState<GoodsBomComparisonTables> {
  final _horizontal = ScrollController();
  final _leftV = ScrollController(), _rightV = ScrollController();
  final _handleKey = GlobalKey();
  final _expanded = <String, bool>{};
  final _fullFields = <String>{};
  final _children = <String, List<GoodsBomItem>>{};
  final _reading = <String>{};
  final _errors = <String, String>{};
  late double _ratio = widget.initialRatio;
  bool _syncing = false;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    _leftV.addListener(() => _sync(_leftV, _rightV));
    _rightV.addListener(() => _sync(_rightV, _leftV));
    _loadExpanded();
  }

  @override
  void didUpdateWidget(covariant GoodsBomComparisonTables oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comparison, widget.comparison)) {
      ++_epoch;
      _expanded.clear();
      _fullFields.clear();
      _children.clear();
      _reading.clear();
      _errors.clear();
      _loadExpanded();
    }
  }

  void _sync(ScrollController source, ScrollController target) {
    if (_syncing || !source.hasClients || !target.hasClients) return;
    _syncing = true;
    try {
      target.jumpTo(
        source.offset.clamp(
          target.position.minScrollExtent,
          target.position.maxScrollExtent,
        ),
      );
    } finally {
      _syncing = false;
    }
  }

  @override
  void dispose() {
    ++_epoch;
    _horizontal.dispose();
    _leftV.dispose();
    _rightV.dispose();
    super.dispose();
  }

  bool _isExpanded(_ComparisonTableRow row) =>
      _expanded[row.path] ??
      (row.depth == 0 && row.comparison.difference != BomDifference.same);
  bool _hasChildren(_ComparisonTableRow row) =>
      row.field == null && row.notice == null;

  void _loadExpanded() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final row in widget.comparison?.rows ?? <BomComparisonRow>[]) {
        if ((_expanded[row.key] ?? row.difference != BomDifference.same) &&
            (row.left ?? row.right)!.hasChildren) {
          _loadChildren((row.left ?? row.right)!.componentGoodsId);
        }
      }
    });
  }

  Future<void> _loadChildren(String id) async {
    if (_children.containsKey(id) || !_reading.add(id)) return;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      final children = await scope.run(
        () => ref.read(goodsBomRepositoryProvider).list(id),
      );
      if (current()) {
        setState(() {
          _children[id] = children;
          _errors.remove(id);
        });
      }
    } catch (error) {
      if (current()) {
        setState(
          () => _errors[id] = error is ApiException
              ? error.message
              : '子组件加载失败，收起后展开重试',
        );
      }
    } finally {
      if (current()) setState(() => _reading.remove(id));
    }
  }

  void _toggle(_ComparisonTableRow row) {
    setState(() => _expanded[row.path] = !_isExpanded(row));
    final item = row.comparison.left ?? row.comparison.right;
    if (_isExpanded(row) && item!.hasChildren) {
      _loadChildren(item.componentGoodsId);
    }
  }

  List<String> _fields(BomComparisonRow row, String path) {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final priceVisible =
        boundary.superAdmin ||
        boundary.permissions.contains(Perm.goodsPriceView) ||
        boundary.permissions.contains(Perm.goodsPriceEdit);
    bool allowed(String field) =>
        priceVisible || (field != '单价' && field != '金额');
    if (row.difference == BomDifference.changed) {
      return row.fields.where(allowed).toList();
    }
    if (row.difference == BomDifference.same || _fullFields.contains(path)) {
      return bomComparisonValues(
        (row.left ?? row.right)!,
      ).keys.where(allowed).toList();
    }
    return [
      '设计使用数量',
      '管控阶段',
      '计量方式',
      if ((row.left ?? row.right)?.summary?.isNotEmpty == true) '备注',
    ];
  }

  List<_ComparisonTableRow> _rows() {
    final result = <_ComparisonTableRow>[];
    void add(
      BomComparisonRow comparison,
      String path,
      int depth,
      Set<String> ancestors,
    ) {
      final root = _ComparisonTableRow(
        comparison: comparison,
        path: path,
        depth: depth,
      );
      result.add(root);
      if (!_isExpanded(root)) return;
      for (final field in _fields(comparison, path)) {
        result.add(
          _ComparisonTableRow(
            comparison: comparison,
            path: path,
            depth: depth + 1,
            field: field,
          ),
        );
      }
      final item = comparison.left ?? comparison.right;
      if (!item!.hasChildren) return;
      if (ancestors.contains(item.componentGoodsId)) {
        result.add(
          _ComparisonTableRow(
            comparison: comparison,
            path: path,
            depth: depth + 1,
            notice: '存在循环引用，请检查 BOM',
          ),
        );
        return;
      }
      if (_errors.containsKey(item.componentGoodsId) ||
          _reading.contains(item.componentGoodsId)) {
        result.add(
          _ComparisonTableRow(
            comparison: comparison,
            path: path,
            depth: depth + 1,
            notice: _errors[item.componentGoodsId] ?? '正在读取子组件…',
          ),
        );
      }
      for (final child
          in _children[item.componentGoodsId] ?? <GoodsBomItem>[]) {
        add(
          BomComparisonRow(
            left: comparison.left == null ? null : child,
            right: comparison.right == null ? null : child,
          ),
          '$path/${child.componentGoodsId}',
          depth + 1,
          {...ancestors, item.componentGoodsId},
        );
      }
    }

    for (final row in widget.comparison?.rows ?? <BomComparisonRow>[]) {
      if (widget.onlyDifferences && row.difference == BomDifference.same) {
        continue;
      }
      add(row, row.key, 0, {});
    }
    return result;
  }

  Color _foreground(BomDifference kind) => kind == BomDifference.same
      ? Theme.of(context).brightness == Brightness.dark
            ? UtenColors.successOnDark
            : UtenColors.successText
      : Theme.of(context).colorScheme.error;

  String _label(BomDifference kind) => switch (kind) {
    BomDifference.same => '相同',
    BomDifference.changed => '有差异',
    BomDifference.leftOnly => '仅左侧',
    BomDifference.rightOnly => '仅右侧',
  };

  GoodsBomItem? _item(_ComparisonTableRow row, bool left) =>
      left ? row.comparison.left : row.comparison.right;
  String _name(_ComparisonTableRow row, bool left) =>
      row.field ?? row.notice ?? _item(row, left)?.componentName ?? '此侧没有该组件';

  String _detail(_ComparisonTableRow row, bool left) {
    final item = _item(row, left);
    if (item == null) return '—';
    final field = row.field;
    if (field == null &&
        (row.comparison.difference == BomDifference.leftOnly ||
            row.comparison.difference == BomDifference.rightOnly)) {
      return '仅此侧有组件';
    }
    if (field == null) {
      return row.notice ??
          (row.comparison.orderChanged
              ? '排列顺序不同'
              : row.comparison.fields.isEmpty
              ? ''
              : '${row.comparison.fields.length} 个字段不同');
    }
    if (field == '颜色') {
      return item.componentColorName ?? bomComparisonValues(item)[field] ?? '—';
    }
    if (field == '默认供应商' && item.defaultSupplierId != null) {
      final name = ref
          .read(masterNameServiceProvider)
          .supplier(item.defaultSupplierId);
      return name == '—' ? item.defaultSupplierId! : name;
    }
    final value = bomComparisonValues(item)[field];
    return value == null || value.isEmpty ? '—' : value;
  }

  List<MasterColumnDef<_ComparisonTableRow>> _columns(bool left) => [
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'componentName',
      label: '组件名称',
      width: 280,
      minimumWidthOf: (context) =>
          UtenTreeTableCell.compactMinimumWidthOf(context, depth: 1),
      value: (row) => _name(row, left),
      measureValueOf: (row) => '${row.depth}|${_name(row, left)}',
      measureWidthOf: (context, row, scaler) =>
          UtenTreeTableCell.compactMeasureWidthOf(
            context,
            title: _name(row, left),
            depth: row.depth,
            textScaler: scaler,
          ),
      fillsCellHeight: true,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (context, row) => UtenTreeTableCell.compact(
        depth: row.depth,
        title: _name(row, left),
        hasChildren: _hasChildren(row),
        expanded: _isExpanded(row),
        onToggle: _hasChildren(row) ? () => _toggle(row) : null,
        toggleKey: ValueKey(
          'bom-compare-toggle-${left ? "left" : "right"}-${row.path}',
        ),
        foregroundColor: _foreground(row.comparison.difference),
      ),
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'comparisonStatus',
      label: '对比状态',
      width: 90,
      value: (row) => row.field != null
          ? '配方字段'
          : row.notice != null
          ? '子组件'
          : _label(row.comparison.difference),
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'comparisonValue',
      label: '差异详情',
      width: 180,
      value: (row) => _detail(row, left),
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'learningSource',
      label: '学习来源',
      width: 90,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left) == null
          ? '—'
          : _item(row, left)!.systemLearned
          ? '系统学习'
          : '人工维护',
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'code',
      label: '编号',
      width: 100,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.componentCode,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'model',
      label: '型号',
      width: 100,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.componentModel,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'spec',
      label: '规格',
      width: 120,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.componentSpec,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'color',
      label: '颜色',
      width: 90,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.componentColorName,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'material',
      label: '材质',
      width: 140,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.componentMaterial,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'source',
      label: '来源',
      width: 90,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.componentSourceType,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'qty',
      label: '设计使用数量',
      width: 130,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left) == null
          ? '—'
          : '${_item(row, left)!.designQtyText} ${_item(row, left)!.componentUnitName ?? ""}',
      exactValueOf: (row) =>
          row.field == null ? _item(row, left)?.qtyExactText : null,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'actualQty',
      label: '真实使用数量',
      width: 130,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.actualQtyText,
    ),
    MasterColumnDef(
      columnSearchEnabled: false,
      key: 'summary',
      label: '备注',
      width: 200,
      value: (row) => row.field != null || row.notice != null
          ? ''
          : _item(row, left)?.summary,
    ),
  ];

  Widget _table(
    bool left,
    List<_ComparisonTableRow> rows,
  ) => UtenPageScrollRoleScope.local(
    child: PrimaryScrollController(
      controller: left ? _leftV : _rightV,
      child: MasterDataTableView<_ComparisonTableRow>(
        key: ValueKey('bom-comparison-table-${left ? "left" : "right"}'),
        tableKey: 'goods.bom.comparison.${left ? "left" : "right"}',
        primary: true,
        columns: _columns(left),
        requiredLeadingColumnKeys: const ['componentName', 'comparisonStatus'],
        items: rows,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        dataCellVerticalPadding: UtenTreeTableCell.compactCellVerticalPadding,
        selectable: true,
        idOf: (row) =>
            widget.enabled &&
                row.depth == 0 &&
                row.field == null &&
                row.comparison.difference != BomDifference.same
            ? row.comparison.key
            : null,
        rowKeyOf: (row) => row.key,
        rowWidgetKeyOf: (row) =>
            ValueKey('bom-compare-${left ? "left" : "right"}-${row.key}'),
        unselectableLeadingBuilder: (_, _) => const SizedBox.shrink(),
        selectedIds: widget.selected,
        onSelectedIdsChanged: widget.enabled ? widget.onSelected : null,
        showSelectionSummary: false,
        showPaginationControls: false,
        showFullscreenToggle: false,
        rowColor: (row) => _foreground(row.comparison.difference).withValues(
          alpha: row.comparison.difference == BomDifference.same ? .08 : .1,
        ),
        rowForegroundColor: (row) => _foreground(row.comparison.difference),
        isLoading: widget.loading,
        emptyMessage: widget.comparison == null
            ? '打开左右货品后重新分析'
            : widget.onlyDifferences
            ? '没有差异，左右组件一致'
            : '没有组件，可更换货品继续对比',
      ),
    ),
  );

  Future<void> _menu() async {
    final box = _handleKey.currentContext!.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final origin = box.localToGlobal(
      Offset(0, box.size.height / 2),
      ancestor: overlay,
    );
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        origin & const Size(24, 48),
        Offset.zero & overlay.size,
      ),
      items: const [
        PopupMenuItem(value: 'differences', child: Text('展开全部差异')),
        PopupMenuItem(value: 'same', child: Text('折叠相同组件')),
        PopupMenuItem(value: 'fields', child: Text('展开全部配方字段')),
        PopupMenuItem(value: 'equal', child: Text('左右各一半')),
      ],
    );
    if (!mounted) return;
    setState(() {
      for (final row in widget.comparison?.rows ?? <BomComparisonRow>[]) {
        if (action == 'differences' && row.difference != BomDifference.same ||
            action == 'fields') {
          _expanded[row.key] = true;
        }
        if (action == 'same' && row.difference == BomDifference.same) {
          _expanded[row.key] = false;
        }
        if (action == 'fields') _fullFields.add(row.key);
      }
      if (action == 'equal') _ratio = .5;
    });
    _loadExpanded();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    return LayoutBuilder(
      builder: (context, area) {
        final width = math.max(area.maxWidth, 900.0),
            usable = width - UtenSpacing.s24;
        final leftWidth = (usable * _ratio).clamp(360.0, usable - 360);
        return Scrollbar(
          controller: _horizontal,
          thumbVisibility: width > area.maxWidth,
          child: SingleChildScrollView(
            controller: _horizontal,
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              height: area.maxHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: leftWidth,
                    child: Column(
                      children: [
                        widget.leftHeader,
                        Expanded(child: _table(true, rows)),
                      ],
                    ),
                  ),
                  UtenSplitHandle(
                    key: _handleKey,
                    width: UtenSpacing.s24,
                    tooltip: '拖动调整对比比例 · 点击展开对比操作',
                    onDelta: (delta) => setState(
                      () => _ratio =
                          ((leftWidth + delta).clamp(360.0, usable - 360)) /
                          usable,
                    ),
                    onReset: () => setState(() => _ratio = .5),
                    onTap: _menu,
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        widget.rightHeader,
                        Expanded(child: _table(false, rows)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
