import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_page_layout.dart';
import '../../../components/layout/uten_split_handle.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/feedback/uten_dialog.dart';
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
import '../models/goods_node.dart';
import '../repositories/goods_bom_repository.dart';
import '../providers/color_unit_dict.dart';
import 'bom_component_picker.dart';
import 'bom_component_quantity_field.dart';
import 'bom_inline_edit_cell.dart';
import 'goods_bom_comparison_editor.dart';
import 'master_edit_dialog.dart' show kGoodsSourceTypeOptions;
import 'master_data_table_view.dart';

/// Every display row is an actual BOM component; differences belong to cells.
class _ComparisonTableRow {
  const _ComparisonTableRow({
    required this.comparison,
    required this.path,
    required this.depth,
    this.cyclic = false,
  });
  final BomComparisonRow comparison;
  final String path;
  final int depth;
  final bool cyclic;
  String get key => '$path|component';
}

/// The same table, compact tree cells, headers, selection and column controls
/// as GoodsBomTab. Comparison colors and live draft checking are projected here.
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
    this.leftActions,
    this.rightActions,
    this.editor,
    this.onEditError,
  });
  final GoodsBomComparison? comparison;
  final Widget leftHeader, rightHeader;
  final Widget? leftActions, rightActions;
  final Set<String> selected;
  final ValueChanged<Set<String>> onSelected;
  final bool enabled, onlyDifferences, loading;
  final double initialRatio;
  final GoodsBomComparisonEditor? editor;
  final ValueChanged<Object>? onEditError;
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
  final _children = <String, List<BomComparisonRow>>{};
  final _childPresence = <String, ({bool left, bool right})>{};
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
  }

  @override
  void didUpdateWidget(covariant GoodsBomComparisonTables oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.comparison, widget.comparison)) {
      ++_epoch;
      _reading.clear();
      _errors.clear();
      if (oldWidget.comparison?.leftId != widget.comparison?.leftId ||
          oldWidget.comparison?.rightId != widget.comparison?.rightId ||
          !identical(oldWidget.editor, widget.editor)) {
        _expanded.clear();
        _children.clear();
        _childPresence.clear();
      } else {
        final ids = _expanded.entries
            .where((e) => e.value)
            .map((e) => e.key.split('/').last)
            .toSet();
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          for (final id in ids) {
            if (mounted) await _loadChildren(id, refresh: true);
          }
        });
      }
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

  bool _isExpanded(_ComparisonTableRow row) => _expanded[row.path] ?? false;
  bool _hasChildren(_ComparisonTableRow row) =>
      !row.cyclic && (row.comparison.left ?? row.comparison.right)!.hasChildren;

  Future<void> _loadChildren(String id, {bool refresh = false}) async {
    if ((!refresh && _children.containsKey(id)) || !_reading.add(id)) return;
    final epoch = _epoch, boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        epoch == _epoch &&
        boundary == ref.read(sensitiveReadBoundaryProvider);
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: current);
      final presence = _childPresence[id] ?? (left: true, right: true);
      final editor = widget.editor;
      final items = await scope.run(
        () => Future.wait([
          !presence.left
              ? Future.value(<GoodsBomItem>[])
              : editor?.read(widget.comparison!.leftId, id) ??
                    ref.read(goodsBomRepositoryProvider).list(id),
          !presence.right
              ? Future.value(<GoodsBomItem>[])
              : editor?.read(widget.comparison!.rightId, id) ??
                    ref.read(goodsBomRepositoryProvider).list(id),
        ]),
      );
      final children = (await GoodsBomComparison.build(
        leftId: id,
        rightId: id,
        left: items[0],
        right: items[1],
        isCurrent: current,
      )).rows;
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
    if (!_hasChildren(row)) return;
    setState(() => _expanded[row.path] = !_isExpanded(row));
    if (_isExpanded(row)) {
      _loadChildren(
        (row.comparison.left ?? row.comparison.right)!.componentGoodsId,
      );
    }
  }

  List<_ComparisonTableRow> _rows() {
    final result = <_ComparisonTableRow>[];
    void add(
      BomComparisonRow comparison,
      String path,
      int depth,
      Set<String> ancestors,
    ) {
      final item = (comparison.left ?? comparison.right)!;
      final row = _ComparisonTableRow(
        comparison: comparison,
        path: path,
        depth: depth,
        cyclic: ancestors.contains(item.componentGoodsId),
      );
      result.add(row);
      _childPresence[item.componentGoodsId] = (
        left: comparison.left != null,
        right: comparison.right != null,
      );
      if (!_isExpanded(row) || !_hasChildren(row)) return;
      for (final child
          in _children[item.componentGoodsId] ?? <BomComparisonRow>[]) {
        add(child, '$path/${child.key}', depth + 1, {
          ...ancestors,
          item.componentGoodsId,
        });
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

  bool _different(
    _ComparisonTableRow row,
    String? field, {
    bool status = false,
  }) {
    if (row.comparison.left == null || row.comparison.right == null) {
      return true;
    }
    return status
        ? row.comparison.difference != BomDifference.same
        : field != null && row.comparison.fields.contains(field);
  }

  Color _foreground(bool different) =>
      Theme.of(context).brightness == Brightness.dark
      ? different
            ? UtenColors.errorOnDark
            : UtenColors.successOnDark
      : different
      ? UtenColors.errorText
      : UtenColors.successText;
  Color _background(bool different) =>
      Theme.of(context).brightness == Brightness.dark
      ? _foreground(different).withValues(alpha: .13)
      : different
      ? UtenColors.errorBg
      : UtenColors.successBg;
  String _label(BomComparisonRow row) => row.orderChanged && row.fields.isEmpty
      ? '顺序不同'
      : switch (row.difference) {
          BomDifference.same => '相同',
          BomDifference.changed => '有差异',
          BomDifference.leftOnly => '仅左侧',
          BomDifference.rightOnly => '仅右侧',
        };
  GoodsBomItem? _item(_ComparisonTableRow row, bool left) =>
      left ? row.comparison.left : row.comparison.right;
  String _name(_ComparisonTableRow row, bool left) =>
      _item(row, left)?.componentName ?? '此侧没有该组件';
  String? _masterDisplay(GoodsBomItem? item, String field, String? fallback) =>
      item == null
      ? null
      : (widget.editor?.masterValue(item, field) ?? fallback)?.toString();
  MasterColumnDef<_ComparisonTableRow> _column({
    required bool left,
    required String key,
    required String label,
    required double width,
    required String? Function(_ComparisonTableRow) value,
    String? field,
    bool compared = true,
    bool status = false,
    String? Function(_ComparisonTableRow)? exactValue,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    value: value,
    columnSearchEnabled: false,
    exactValueOf: exactValue,
    cellColor: compared
        ? (_, row) => _background(_different(row, field, status: status))
        : null,
    cellBuilder:
        const {
          'qty',
          'basisOutputQty',
          'summary',
          'color',
          'spec',
          'model',
          'material',
          'source',
          'controlStage',
          'consumptionBasis',
          'allowPartialPackage',
          'hardGate',
        }.contains(key)
        ? (context, row) =>
              _editCell(left, row, key, field, value(row) ?? '') ??
              Text(
                value(row) ?? '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              )
        : null,
  );
  String _root(bool left) =>
      left ? widget.comparison!.leftId : widget.comparison!.rightId;
  String _parent(_ComparisonTableRow row, bool left) {
    final path = row.path.split('/');
    return path.length == 1 ? _root(left) : path[path.length - 2];
  }

  Future<void> _runEdit(Future<void> action) async {
    try {
      await action;
    } catch (error) {
      if (mounted) widget.onEditError?.call(error);
    }
  }

  Future<void> _chooseComponent(bool left, _ComparisonTableRow row) async {
    final editor = widget.editor, item = _item(row, left);
    if (editor == null || item == null || !widget.enabled) return;
    try {
      await editor.flush(root: _root(left));
    } catch (error) {
      if (mounted) widget.onEditError?.call(error);
      return;
    }
    if (!mounted || !identical(editor, widget.editor)) return;
    final chosen = await ref.read(bomComponentSinglePickerProvider)(
      context,
      ref,
    );
    if (chosen == null ||
        !mounted ||
        !identical(editor, widget.editor) ||
        chosen.id == item.componentGoodsId) {
      return;
    }
    if (chosen.isPeriodicIssue &&
        chosen.periodicCostBasis != null &&
        chosen.periodicCostBasis != GoodsPeriodicCostBasis.own) {
      widget.onEditError?.call(
        ApiException('BOM_EDIT_PERIODIC', '共用期间料不能作为新组件直接加入，请先核对发料方式'),
      );
      return;
    }
    String? quantity;
    if (item.componentUnitName != chosen.unitName ||
        item.isPeriodicEdge != chosen.isPeriodicIssue ||
        chosen.isPeriodicIssue) {
      quantity = await showDialog<String>(
        context: context,
        builder: (_) => _ComparisonQuantityDialog(goods: chosen),
      );
      if (quantity == null || !mounted || !identical(editor, widget.editor)) {
        return;
      }
    }
    await _runEdit(
      editor.replaceComponent(
        _root(left),
        _parent(row, left),
        item,
        chosen,
        quantity: quantity,
      ),
    );
  }

  Widget? _editCell(
    bool left,
    _ComparisonTableRow row,
    String key,
    String? comparedField,
    String display,
  ) {
    final editor = widget.editor, item = _item(row, left);
    if (editor == null || item == null) return null;
    final field = switch (key) {
      'color' => 'colorId',
      'source' => 'sourceType',
      'componentName' => 'componentGoodsId',
      _ => key,
    };
    final root = _root(left),
        parent = _parent(row, left),
        side = left ? 'left' : 'right';
    final allowed = editor.canEdit(root, item, field);
    final cached = editor.cachedInput(root, parent, item, field);
    if (!allowed && cached?.pending != true) return null;
    final enabled = widget.enabled && !widget.loading && allowed;
    final identity = ValueKey((
      'bom-compare-editor',
      root,
      parent,
      item.id,
      field,
      editor.generation,
    ));
    final activation = ValueKey(
      'bom-compare-activate-$side-$field-${row.path}',
    );
    if (const {
      'qty',
      'basisOutputQty',
      'summary',
      'model',
      'spec',
      'material',
    }.contains(field)) {
      final periodic =
          field == 'qty' &&
          item.isPeriodicEdge &&
          item.periodicUnitWeightGrams != null;
      final initial = switch (field) {
        'qty' =>
          periodic
              ? formatBomQty(item.periodicUnitWeightGrams!)
              : item.designQtyText,
        'basisOutputQty' => item.basisOutputQtyText,
        'summary' => item.summary ?? '',
        _ =>
          (editor.masterValue(item, field) ??
                      switch (field) {
                        'model' => item.componentModel,
                        'spec' => item.componentSpec,
                        _ => item.componentMaterial,
                      })
                  ?.toString() ??
              '',
      };
      return BomLiveTextCell(
        key: identity,
        controller: editor.input(root, parent, item, field, initial),
        label: field == 'qty'
            ? '设计使用数量'
            : key == 'summary'
            ? '备注'
            : key == 'spec'
            ? '规格'
            : key == 'model'
            ? '型号'
            : key == 'material'
            ? '材质'
            : '基准产量',
        enabled: enabled,
        numeric: field == 'qty' || field == 'basisOutputQty',
        unit: field == 'qty'
            ? periodic
                  ? '克'
                  : item.componentUnitName
            : null,
        foregroundColor: _different(row, comparedField)
            ? _foreground(true)
            : null,
        fieldKey: ValueKey('bom-compare-input-$side-$field-${row.path}'),
        activationKey: activation,
      );
    }
    if (field == 'componentGoodsId') {
      return BomInlineEditCell(
        key: identity,
        label: '更换组件',
        activationKey: activation,
        enabled: enabled,
        onActivate: () => _chooseComponent(left, row),
        preview: Text(
          _name(row, left),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        editorBuilder: (_) => TextButton.icon(
          onPressed: enabled ? () => _chooseComponent(left, row) : null,
          icon: const Icon(Icons.search_rounded),
          label: const Text('选择组件'),
        ),
      );
    }
    return BomInlineEditCell(
      key: identity,
      label: '编辑${comparedField ?? key}',
      activationKey: activation,
      enabled: enabled,
      preview: Text(
        display.isEmpty ? '—' : display,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      editorBuilder: (_) {
        if (field == 'colorId') {
          return Consumer(
            builder: (context, cellRef, _) {
              final colors = cellRef.watch(colorDictProvider).value ?? const [];
              return UtenDropdownField(
                value: item.colorId,
                selectedLabel:
                    editor.colorName(root, item) ?? item.componentColorName,
                dense: true,
                enabled: enabled,
                items: [
                  for (final color in colors)
                    UtenDropdownItem(
                      value: color.id,
                      label: color.name ?? color.code ?? color.id,
                    ),
                ],
                onChanged: (value) {
                  final chosen = colors
                      .where((color) => color.id == value)
                      .firstOrNull;
                  _runEdit(
                    editor.edit(
                      root,
                      parent,
                      item,
                      field,
                      value,
                      label: chosen?.name ?? chosen?.code ?? '—',
                    ),
                  );
                },
              );
            },
          );
        }
        final String? selected = switch (field) {
          'sourceType' =>
            (editor.masterValue(item, field) ?? item.componentSourceType)
                ?.toString(),
          'controlStage' => item.controlStage.code,
          'consumptionBasis' => item.consumptionBasis.code,
          'allowPartialPackage' => item.allowPartialPackage.toString(),
          'hardGate' => item.hardGate.toString(),
          _ => null,
        };
        final items = <UtenDropdownItem>[
          if (field == 'sourceType')
            for (final option in kGoodsSourceTypeOptions)
              UtenDropdownItem(value: option.value, label: option.label),
          if (field == 'controlStage')
            for (final option in BomControlStage.values)
              UtenDropdownItem(value: option.code, label: option.label),
          if (field == 'consumptionBasis')
            for (final option in BomConsumptionBasis.values)
              UtenDropdownItem(value: option.code, label: option.label),
          if (field == 'allowPartialPackage' || field == 'hardGate') ...[
            UtenDropdownItem(
              value: 'true',
              label: field == 'hardGate' ? '启用' : '允许',
            ),
            UtenDropdownItem(
              value: 'false',
              label: field == 'hardGate' ? '关闭' : '整包',
            ),
          ],
        ];
        return UtenDropdownField(
          value: selected,
          dense: true,
          enabled: enabled,
          allowClear: false,
          items: items,
          onChanged: (value) {
            if (value != null) {
              _runEdit(
                editor.edit(
                  root,
                  parent,
                  item,
                  field,
                  const {'allowPartialPackage', 'hardGate'}.contains(field)
                      ? value == 'true'
                      : value,
                ),
              );
            }
          },
        );
      },
    );
  }

  Widget? _treeNotice(_ComparisonTableRow row) {
    final id = (row.comparison.left ?? row.comparison.right)!.componentGoodsId;
    if (_reading.contains(id)) {
      return const SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    if (row.cyclic) {
      return Tooltip(
        message: '存在循环引用，请检查 BOM',
        child: Icon(
          Icons.error_outline_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.error,
        ),
      );
    }
    if (_errors[id] != null) {
      return IconButton(
        tooltip: _errors[id],
        icon: const Icon(Icons.refresh_rounded),
        onPressed: () => _loadChildren(id),
      );
    }
    return null;
  }

  List<MasterColumnDef<_ComparisonTableRow>> _columns(bool left) {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final priceVisible =
        boundary.superAdmin ||
        boundary.permissions.contains(Perm.goodsPriceView) ||
        boundary.permissions.contains(Perm.goodsPriceEdit);
    return [
      _column(
        left: left,
        key: 'code',
        label: '编码',
        width: 88,
        value: (row) => _item(row, left)?.componentCode ?? '—',
      ),
      MasterColumnDef(
        key: 'componentName',
        label: '名称',
        width: 280,
        columnSearchEnabled: false,
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
        cellColor: (_, row) => _background(_different(row, null)),
        cellBuilder: (context, row) => UtenTreeTableCell.compact(
          depth: row.depth,
          title: _name(row, left),
          titleWidget: _editCell(
            left,
            row,
            'componentName',
            null,
            _name(row, left),
          ),
          hasChildren: _hasChildren(row),
          expanded: _isExpanded(row),
          onToggle: _hasChildren(row) ? () => _toggle(row) : null,
          toggleKey: ValueKey(
            'bom-compare-toggle-${left ? "left" : "right"}-${row.path}',
          ),
          titleBadge: _treeNotice(row),
          foregroundColor: _foreground(_different(row, null)),
        ),
      ),
      _column(
        left: left,
        key: 'color',
        label: '颜色',
        width: 80,
        field: '颜色',
        value: (row) => _item(row, left) == null
            ? '—'
            : widget.editor?.colorName(_root(left), _item(row, left)!) ??
                  _item(row, left)?.componentColorName ??
                  '—',
      ),
      _column(
        left: left,
        key: 'spec',
        label: '规格',
        width: 120,
        value: (row) =>
            _masterDisplay(
              _item(row, left),
              'spec',
              _item(row, left)?.componentSpec,
            ) ??
            '—',
      ),
      _column(
        left: left,
        key: 'qty',
        label: '设计使用数量',
        width: 130,
        field: '设计使用数量',
        value: (row) => _item(row, left) == null
            ? '—'
            : '${_item(row, left)!.designQtyText} ${_item(row, left)!.componentUnitName ?? ""}',
        exactValue: (row) => _item(row, left)?.qtyExactText,
      ),
      _column(
        left: left,
        key: 'comparisonStatus',
        label: '对比状态',
        width: 96,
        status: true,
        value: (row) => _label(row.comparison),
      ),
      _column(
        left: left,
        key: 'summary',
        label: '备注',
        width: 200,
        field: '备注',
        value: (row) => _item(row, left)?.summary,
      ),
      _column(
        left: left,
        key: 'model',
        label: '型号',
        width: 100,
        value: (row) => _masterDisplay(
          _item(row, left),
          'model',
          _item(row, left)?.componentModel,
        ),
      ),
      _column(
        left: left,
        key: 'material',
        label: '材质',
        width: 140,
        value: (row) => _masterDisplay(
          _item(row, left),
          'material',
          _item(row, left)?.componentMaterial,
        ),
      ),
      _column(
        left: left,
        key: 'source',
        label: '来源',
        width: 90,
        value: (row) => _masterDisplay(
          _item(row, left),
          'sourceType',
          _item(row, left)?.componentSourceType,
        ),
      ),
      _column(
        left: left,
        key: 'controlStage',
        label: '管控阶段',
        width: 110,
        field: '管控阶段',
        value: (row) => _item(row, left)?.controlStage.label,
      ),
      _column(
        left: left,
        key: 'consumptionBasis',
        label: '计量方式',
        width: 110,
        field: '计量方式',
        value: (row) => _item(row, left)?.consumptionBasis.label,
      ),
      _column(
        left: left,
        key: 'basisOutputQty',
        label: '基准产量',
        width: 110,
        field: '基准产量',
        value: (row) => _item(row, left)?.basisOutputQtyText,
        exactValue: (row) => _item(row, left)?.basisOutputQtyExactText,
      ),
      _column(
        left: left,
        key: 'allowPartialPackage',
        label: '允许尾包',
        width: 100,
        field: '允许尾包',
        value: (row) => _item(row, left) == null
            ? '—'
            : _item(row, left)!.allowPartialPackage
            ? '允许'
            : '整包',
      ),
      _column(
        left: left,
        key: 'hardGate',
        label: '齐套门槛',
        width: 100,
        field: '齐套门槛',
        value: (row) => _item(row, left) == null
            ? '—'
            : _item(row, left)!.hardGate
            ? '启用'
            : '关闭',
      ),
      _column(
        left: left,
        key: 'supplier',
        label: '默认供应商',
        width: 140,
        field: '默认供应商',
        value: (row) {
          final item = _item(row, left);
          if (item == null) return '—';
          final name = ref
              .read(masterNameServiceProvider)
              .supplier(item.defaultSupplierId);
          return name == '—' ? bomComparisonValues(item)['默认供应商'] : name;
        },
      ),
      if (priceVisible) ...[
        _column(
          left: left,
          key: 'price',
          label: '单价',
          width: 110,
          field: '单价',
          value: (row) =>
              _item(row, left)?.priceExactText ??
              _item(row, left)?.price?.toString(),
          exactValue: (row) => _item(row, left)?.priceExactText,
        ),
        _column(
          left: left,
          key: 'total',
          label: '金额',
          width: 110,
          field: '金额',
          value: (row) =>
              _item(row, left)?.totalExactText ??
              _item(row, left)?.total?.toString(),
          exactValue: (row) => _item(row, left)?.totalExactText,
        ),
      ],
      _column(
        left: left,
        key: 'learningSource',
        label: '学习来源',
        width: 100,
        compared: false,
        value: (row) => _item(row, left) == null
            ? '—'
            : _item(row, left)!.systemLearned
            ? '系统学习'
            : '人工维护',
      ),
      _column(
        left: left,
        key: 'actualQty',
        label: '真实使用数量',
        width: 130,
        compared: false,
        value: (row) => _item(row, left)?.actualQtyText,
      ),
    ];
  }

  Widget _table(
    bool left,
    List<_ComparisonTableRow> rows,
  ) => UtenPageScrollRoleScope.local(
    child: PrimaryScrollController(
      controller: left ? _leftV : _rightV,
      child: MasterDataTableView<_ComparisonTableRow>(
        key: ValueKey('bom-comparison-table-${left ? "left" : "right"}'),
        // Do not replay the obsolete name/status-first comparison layout.
        tableKey:
            'goods.bom.comparison.identity-first.v2.${left ? "left" : "right"}',
        primary: true,
        expensiveRowMounts: widget.editor?.drafts.isNotEmpty == true,
        columns: _columns(left),
        requiredLeadingColumnKeys: const ['code'],
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
        PopupMenuItem(value: 'children', child: Text('展开一层子组件')),
        PopupMenuItem(value: 'collapse', child: Text('收起所有子组件')),
        PopupMenuItem(value: 'equal', child: Text('左右各一半')),
      ],
    );
    if (!mounted) return;
    setState(() {
      if (action == 'collapse') _expanded.clear();
      if (action == 'children') {
        for (final row in widget.comparison?.rows ?? <BomComparisonRow>[]) {
          if ((row.left ?? row.right)!.hasChildren) _expanded[row.key] = true;
        }
      }
      if (action == 'equal') _ratio = .5;
    });
    if (action == 'children') {
      for (final row in widget.comparison?.rows ?? <BomComparisonRow>[]) {
        if ((row.left ?? row.right)!.hasChildren) {
          _loadChildren((row.left ?? row.right)!.componentGoodsId);
        }
      }
    }
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
              child: Column(
                children: [
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: area.maxHeight * .3),
                    child: SingleChildScrollView(
                      child: IntrinsicHeight(
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            SizedBox(
                              width: leftWidth,
                              child: widget.leftHeader,
                            ),
                            const SizedBox(width: UtenSpacing.s24),
                            Expanded(child: widget.rightHeader),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(width: leftWidth, child: _table(true, rows)),
                        UtenSplitHandle(
                          key: _handleKey,
                          width: UtenSpacing.s24,
                          tooltip: '拖动调整对比比例 · 点击展开对比操作',
                          onDelta: (delta) => setState(
                            () => _ratio =
                                ((leftWidth + delta).clamp(
                                  360.0,
                                  usable - 360,
                                )) /
                                usable,
                          ),
                          onReset: () => setState(() => _ratio = .5),
                          onTap: _menu,
                        ),
                        Expanded(child: _table(false, rows)),
                      ],
                    ),
                  ),
                  if (widget.leftActions != null || widget.rightActions != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: area.maxHeight * .35,
                      ),
                      child: SingleChildScrollView(
                        child: IntrinsicHeight(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: leftWidth,
                                child:
                                    widget.leftActions ??
                                    const SizedBox.shrink(),
                              ),
                              const SizedBox(width: UtenSpacing.s24),
                              Expanded(
                                child:
                                    widget.rightActions ??
                                    const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
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

class _ComparisonQuantityDialog extends StatefulWidget {
  const _ComparisonQuantityDialog({required this.goods});
  final GoodsListItem goods;
  @override
  State<_ComparisonQuantityDialog> createState() =>
      _ComparisonQuantityDialogState();
}

class _ComparisonQuantityDialogState extends State<_ComparisonQuantityDialog> {
  final _quantity = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UtenAlertDialog(
    showCloseButton: true,
    closeTooltip: '取消更换组件',
    onClose: () {
      if (ModalRoute.of(context)?.isCurrent == true) Navigator.pop(context);
    },
    title: const Text('填写新组件的使用数量'),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.goods.name ?? widget.goods.code ?? '新组件'),
        BomComponentQuantityField(goods: widget.goods, controller: _quantity),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (!bomDesignQuantityValid(_quantity.text)) {
            setState(() => _error = '请输入大于 0 的使用数量');
            return;
          }
          Navigator.pop(context, _quantity.text.trim());
        },
        child: const Text('确认更换'),
      ),
    ],
  );
}
