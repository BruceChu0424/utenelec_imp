import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_review_input_cell.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_picker_icon_button.dart';
import '../../../components/inputs/uten_table_cell_auto_width.dart';
import '../../../components/inputs/uten_table_cell_spec.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../components/layout/uten_page_layout.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/human_error_message.dart';
import '../models/goods_import.dart';
import '../models/product_category_node.dart';
import '../widgets/basic_data_l10n.dart';
import '../widgets/master_data_table_view.dart';
import '../widgets/master_edit_dialog.dart'
    show kGoodsSourceTypeOptions, kMasterStatusOptions;
import '../widgets/goods_import_reference_picker.dart';
import '../widgets/uten_category_tree_view.dart';

typedef GoodsImportPreviewDetector =
    Future<GoodsImportReport> Function(
      GoodsImportCorrections corrections,
      Set<int> excludedRowNums,
    );

class GoodsImportPreviewDecision {
  const GoodsImportPreviewDecision({
    required this.report,
    required this.cellCorrections,
    required this.excludedRowNums,
    required this.removedRowNums,
    required this.replaceRowKeys,
    required this.hasRemaining,
  });

  final GoodsImportReport report;
  final GoodsImportCorrections cellCorrections;

  /// Exact exclusions signed by the selected detection plan.
  final Set<int> excludedRowNums;

  /// Deleted or already processed rows; unselected rows remain for later.
  final Set<int> removedRowNums;
  final Set<String> replaceRowKeys;
  final bool hasRemaining;
}

/// A read-only server plan with an editable local draft. Category edits update
/// the projected tree immediately; no master data is written before confirmation.
class GoodsImportPreviewPage extends StatefulWidget {
  const GoodsImportPreviewPage({
    super.key,
    required this.report,
    required this.filename,
    required this.mode,
    required this.detect,
    required this.onDraftChanged,
    this.cellCorrections = const {},
    this.excludedRowNums = const {},
    this.needsValidation = false,
    this.pickReference,
  });

  final GoodsImportReport report;
  final String filename;
  final GoodsImportMode mode;
  final GoodsImportPreviewDetector detect;
  final void Function(GoodsImportCorrections, Set<int>) onDraftChanged;
  final GoodsImportCorrections cellCorrections;
  final Set<int> excludedRowNums;
  final bool needsValidation;
  final Future<GoodsImportReferenceSelection?> Function(
    BuildContext context, {
    required String field,
    required String currentValue,
    required List<String> currentCategorySegments,
    required Iterable<String> draftValues,
  })?
  pickReference;

  @override
  State<GoodsImportPreviewPage> createState() => _GoodsImportPreviewPageState();
}

class _GoodsImportPreviewPageState extends State<GoodsImportPreviewPage> {
  late GoodsImportReport _report = widget.report;
  late final GoodsImportCorrections _corrections = {
    for (final entry in widget.cellCorrections.entries)
      entry.key: Map<String, String>.of(entry.value),
  };
  late final Set<int> _removed = Set.of(widget.excludedRowNums);
  late Set<String> _selected = {
    for (final row in _rows)
      if (_ready.contains(row.rowNum)) '${row.rowNum}',
  };
  final _controllers = <String, TextEditingController>{};
  final _originalValues = <String, String>{};
  final _pickedCategorySegments = <int, List<String>>{};
  final _replaceRows = <int>{};
  final _manuallyDeselected = <int>{};
  Timer? _debounce;
  int _revision = 0;
  int _categoryRevision = 0;
  bool _checking = false;
  late bool _dirty = widget.needsValidation;
  String? _message;
  String? _category;
  int _indexedRevision = -1;
  GoodsImportReport? _indexedReport;
  List<GoodsImportProblemRow> _indexedRows = const [];
  Set<int> _indexedReady = const {};
  Map<int, GoodsImportReviewRow> _indexedChanges = const {};
  Map<int, List<GoodsImportError>> _indexedErrors = const {};
  List<GoodsImportError> _activeErrors = const [];
  List<ProductCategoryNode> _indexedTree = const [];
  Set<String> _indexedFields = const {};
  final _rowPaths = <int, String>{};
  final _rowAncestors = <int, Set<String>>{};
  final _pathLabels = <String, String>{};

  List<GoodsImportProblemRow> get _rows {
    _ensureIndex();
    return _indexedRows;
  }

  Set<int> get _ready {
    _ensureIndex();
    return _indexedReady;
  }

  Map<int, GoodsImportReviewRow> get _changes {
    _ensureIndex();
    return _indexedChanges;
  }

  void _ensureIndex() {
    if (_indexedRevision == _categoryRevision &&
        identical(_indexedReport, _report)) {
      return;
    }
    _indexedRows = _report.previewRows
        .where((row) => !_removed.contains(row.rowNum))
        .toList(growable: false);
    _indexedReady = _report.readyRowNums
        .where((row) => !_removed.contains(row))
        .toSet();
    _indexedChanges = {for (final row in _report.reviewRows) row.rowNum: row};
    _indexedFields = {for (final row in _indexedRows) ...row.cells.keys};
    _indexedErrors = {};
    _activeErrors = _report.errors
        .where((error) => !_removed.contains(error.rowNum))
        .toList(growable: false);
    for (final error in _activeErrors) {
      (_indexedErrors[error.rowNum] ??= []).add(error);
    }
    final paths = <String, String>{};
    final descendants = <String?, Set<String>>{};
    final counts = <String, int>{};
    _rowPaths.clear();
    _rowAncestors.clear();
    _pathLabels.clear();
    for (final row in _indexedRows) {
      final segments = _rowSegments(row);
      _rowPaths[row.rowNum] = segments.isEmpty ? '' : jsonEncode(segments);
      final ancestors = _rowAncestors[row.rowNum] = {};
      String? parent;
      for (var i = 0; i < segments.length; i++) {
        final prefix = segments.take(i + 1).toList();
        final path = jsonEncode(prefix);
        ancestors.add(path);
        _pathLabels[path] = prefix.join(' / ');
        paths[path] = segments[i];
        (descendants[parent] ??= {}).add(path);
        counts.update(path, (value) => value + 1, ifAbsent: () => 1);
        parent = path;
      }
    }
    List<ProductCategoryNode> children(String? parent, int depth) => [
      for (final path in descendants[parent] ?? const <String>{})
        ProductCategoryNode(
          id: path,
          code: '',
          name: paths[path]!,
          level: depth,
          parentId: parent,
          children: children(path, depth + 1),
          goodsCount: counts[path],
        ),
    ];
    _indexedTree = children(null, 0);
    _indexedRevision = _categoryRevision;
    _indexedReport = _report;
  }

  @override
  void initState() {
    super.initState();
    final paths = _rows.map((row) => _path(row)).toSet();
    if (paths.length == 1 && paths.first.isNotEmpty) _category = paths.first;
    if (_dirty) _debounce = Timer(Duration.zero, _validate);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _value(GoodsImportProblemRow row, String field) =>
      _corrections[row.rowNum]?[field] ??
      row.cells[field] ??
      switch (field) {
        'code' => row.code,
        'name' => row.name,
        'categoryPath' => row.categoryPath,
        _ => '',
      };

  List<String> _segments(String raw) => raw
      .split(raw.contains('/') ? '/' : '-')
      .map((part) => part.replaceAll('\u3000', ' ').trim())
      .where((part) => part.isNotEmpty)
      .toList(growable: false);

  List<String> _rowSegments(GoodsImportProblemRow row) {
    final current = _value(row, 'categoryPath');
    final picked = _pickedCategorySegments[row.rowNum];
    if (picked != null) return picked;
    return row.categorySegments.isNotEmpty && current == row.categoryPath
        ? row.categorySegments
        : _segments(current);
  }

  String _path(GoodsImportProblemRow row) {
    final segments = _rowSegments(row);
    return segments.isEmpty ? '' : jsonEncode(segments);
  }

  bool _underPath(GoodsImportProblemRow row, String path) {
    return _rowPaths[row.rowNum] == path ||
        _rowAncestors[row.rowNum]?.contains(path) == true;
  }

  List<ProductCategoryNode> _tree() {
    _ensureIndex();
    return _indexedTree;
  }

  void _publishDraft() => widget.onDraftChanged(
    freezeGoodsImportCorrections(_corrections),
    Set.unmodifiable(_removed),
  );

  void _edit(GoodsImportProblemRow row, String field, String value) {
    setState(() {
      (_corrections[row.rowNum] ??= {})[field] = value;
      _dirty = true;
      _revision++;
      _message = null;
      if (field == 'categoryPath') {
        _pickedCategorySegments.remove(row.rowNum);
        _categoryRevision++;
        _category = _path(row);
      }
    });
    _publishDraft();
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 650), _validate);
  }

  Future<bool> _validate({Set<int>? exclusions}) async {
    _debounce?.cancel();
    if (_checking || !mounted) return false;
    final revision = _revision;
    final excluded = Set<int>.unmodifiable(exclusions ?? _removed);
    setState(() {
      _checking = true;
      _message = null;
    });
    try {
      final report = await widget.detect(
        freezeGoodsImportCorrections(_corrections),
        excluded,
      );
      if (!mounted || revision != _revision) return false;
      setState(() {
        _report = report;
        _pickedCategorySegments.clear();
        _dirty = false;
        // Every corrected valid row joins the selection unless the user
        // explicitly left it out. Category filters never clear hidden rows.
        final ready = _ready;
        _selected = {
          for (final row in _rows)
            if (ready.contains(row.rowNum) &&
                !_manuallyDeselected.contains(row.rowNum))
              '${row.rowNum}',
        };
        if (_category != null &&
            !_rows.any((row) => _underPath(row, _category!))) {
          _category = null;
        }
      });
      return true;
    } catch (error) {
      if (mounted && revision == _revision) {
        setState(() {
          _dirty = true;
          _message = humanErrorMessage(error) ?? '检查失败，请重试';
        });
      }
      return false;
    } finally {
      if (mounted) {
        setState(() => _checking = false);
        if (revision != _revision) {
          _debounce = Timer(const Duration(milliseconds: 300), _validate);
        }
      }
    }
  }

  void _selectionChanged(Set<String> next) {
    if (_checking) return;
    setState(() {
      for (final row in _rows) {
        if (next.contains('${row.rowNum}')) {
          _manuallyDeselected.remove(row.rowNum);
        } else {
          _manuallyDeselected.add(row.rowNum);
        }
      }
      _selected = Set.of(next);
    });
  }

  void _removeSelected() {
    if (_selected.isEmpty || _checking) return;
    setState(() {
      final removed = _selected.map(int.parse).toSet();
      _removed.addAll(removed);
      _corrections.removeWhere((row, _) => removed.contains(row));
      _selected.clear();
      _dirty = true;
      _revision++;
      _categoryRevision++;
      if (_category != null &&
          !_rows.any((row) => _underPath(row, _category!))) {
        _category = null;
      }
    });
    _publishDraft();
    _validate();
  }

  Future<void> _confirm() async {
    if (_checking || _dirty || _selected.isEmpty) return;
    final selected = _selected.map(int.parse).toSet();
    if (!selected.every(_ready.contains)) return;
    final remaining = _rows
        .where((row) => !selected.contains(row.rowNum))
        .toList();
    final exclusions = {..._removed, for (final row in remaining) row.rowNum};
    var confirmedReport = _report;
    if (remaining.isNotEmpty) {
      final revision = _revision;
      final previousChanges = _reviewFingerprint(_report, selected);
      setState(() => _checking = true);
      try {
        confirmedReport = await widget.detect(
          freezeGoodsImportCorrections(_corrections),
          Set.unmodifiable(exclusions),
        );
      } catch (error) {
        if (mounted) {
          setState(() {
            _dirty = true;
            _message = humanErrorMessage(error) ?? '检查失败，请重试';
          });
        }
        return;
      } finally {
        if (mounted) setState(() => _checking = false);
      }
      if (!mounted || revision != _revision) {
        if (mounted) _validate();
        return;
      }
      if (confirmedReport.hasErrors ||
          confirmedReport.planId == null ||
          previousChanges != _reviewFingerprint(confirmedReport, selected)) {
        // Keep every unselected source row in the editable preview. A selected
        // plan is only a commit receipt, never the full preview's new dataset.
        await _validate();
        if (!mounted) return;
        setState(() => _message = '货品资料已有变化，请重新核对后确认');
        return;
      }
    }
    if (!mounted || confirmedReport.planId?.isNotEmpty != true) return;
    Navigator.of(context).pop(
      GoodsImportPreviewDecision(
        report: confirmedReport,
        cellCorrections: freezeGoodsImportCorrections(_corrections),
        excludedRowNums: Set.unmodifiable(exclusions),
        removedRowNums: Set.unmodifiable(_removed),
        replaceRowKeys: {
          for (final row in confirmedReport.reviewRows)
            if (selected.contains(row.rowNum) &&
                row.hasConflicts &&
                _replaceRows.contains(row.rowNum))
              row.rowKey,
        },
        hasRemaining: remaining.isNotEmpty,
      ),
    );
  }

  String _reviewFingerprint(GoodsImportReport report, Set<int> selected) =>
      jsonEncode([
        for (final row in report.reviewRows)
          if (selected.contains(row.rowNum))
            [
              row.rowNum,
              row.matchType,
              [
                for (final change in row.changes)
                  [change.field, change.kind, change.oldValue, change.newValue],
              ],
            ],
      ]);

  String? _cellError(GoodsImportProblemRow row, String field, String label) {
    _ensureIndex();
    final errors = (_indexedErrors[row.rowNum] ?? const <GoodsImportError>[])
        .where(
          (error) =>
              error.rowNum == row.rowNum &&
              (error.column == label ||
                  error.column == field ||
                  error.column ==
                      const {
                        'name': '货品名称',
                        'clientGoodsName': '客户货品名称',
                        'cNumber': '客户型号',
                        'series': '系列',
                        'model': '型号',
                        'spec': '规格',
                        'material': '材质',
                        'rearInsertCode': '后模镶件编号',
                        'paper': '备注',
                        'nameEn': '英文名称',
                        'colorName': '主颜色',
                        'unitName': '单位',
                        'sourceType': '来源',
                        'status': '状态',
                        'price': '价格',
                        'minOrderQty': '最小起订量',
                        'orderMultipleQty': '订货倍数',
                        'goodsId': '系统标识',
                        'bomRef': '组装信息ID',
                      }[field] ||
                  (field == 'goodsId' && error.column == '货品UUID') ||
                  (field == 'categoryPath' &&
                      const {'类别', '分类', '分类路径'}.contains(error.column)) ||
                  (field == 'code' &&
                      const {'编号', '货品编号'}.contains(error.column))),
        );
    return errors.isEmpty
        ? null
        : errors.map((error) => error.message).join('\n');
  }

  Widget _editor(GoodsImportProblemRow row, String field, String label) {
    final controller = _controllers.putIfAbsent(
      '${row.rowNum}:$field',
      () => TextEditingController(text: _value(row, field)),
    );
    final changes =
        _changes[row.rowNum]?.changes ?? const <GoodsImportChange>[];
    final old = changes.where(
      (change) =>
          change.field == field ||
          (field == 'cNumber' && change.field == 'clientModel') ||
          (field == 'categoryPath' && change.field == 'categoryId'),
    );
    final original = _originalValues.putIfAbsent(
      '${row.rowNum}:$field',
      () => _value(row, field),
    );
    final before = old.isEmpty ? original : old.first.oldValue;
    final error = _cellError(row, field, label);
    final changed = (before ?? '') != controller.text;
    final replacementEnabled =
        old.isEmpty ||
        !old.first.isConflict ||
        _replaceRows.contains(row.rowNum);
    return Builder(
      builder: (cellContext) {
        final theme = Theme.of(cellContext);
        return UtenReviewInputCell(
          before: before,
          after: controller.text,
          decimalValues: false,
          replacementEnabled: replacementEnabled,
          child: Theme(
            data: theme.copyWith(
              textTheme: theme.textTheme.copyWith(
                bodyLarge: theme.textTheme.bodyLarge?.copyWith(
                  color: changed && replacementEnabled
                      ? (theme.brightness == Brightness.dark
                            ? UtenColors.successOnDark
                            : UtenColors.successText)
                      : null,
                ),
              ),
            ),
            child: field == 'sourceType' || field == 'status'
                ? UtenDropdownField(
                    key: ValueKey('goods-import-$field-${row.rowNum}'),
                    label: label,
                    dense: true,
                    value: controller.text.isEmpty ? null : controller.text,
                    items: [
                      for (final option
                          in field == 'sourceType'
                              ? kGoodsSourceTypeOptions
                              : kMasterStatusOptions)
                        UtenDropdownItem(
                          value: option.value,
                          label: option.label,
                        ),
                      if (controller.text.isNotEmpty &&
                          !(field == 'sourceType'
                                  ? kGoodsSourceTypeOptions
                                  : kMasterStatusOptions)
                              .any((option) => option.value == controller.text))
                        UtenDropdownItem(
                          value: controller.text,
                          label: controller.text,
                          error: error != null,
                          enabled: false,
                        ),
                    ],
                    errorMessage: error,
                    onChanged: (value) {
                      controller.text = value ?? '';
                      _edit(row, field, controller.text);
                    },
                  )
                : Row(
                    children: [
                      Expanded(
                        child: Semantics(
                          label: label,
                          child: UtenInput(
                            key: ValueKey('goods-import-$field-${row.rowNum}'),
                            hint: field == 'code' ? '自动编号' : null,
                            controller: controller,
                            errorMessage: error,
                            onChanged: (value) => _edit(row, field, value),
                            onFieldSubmitted: (_) => _validate(),
                          ),
                        ),
                      ),
                      if (widget.pickReference != null &&
                          const {
                            'categoryPath',
                            'colorName',
                            'unitName',
                          }.contains(field))
                        UtenPickerIconButton(
                          key: ValueKey(
                            'goods-import-pick-$field-${row.rowNum}',
                          ),
                          tooltip: '选择$label',
                          onPressed: () async {
                            final selection = await widget.pickReference!(
                              cellContext,
                              field: field,
                              currentValue: controller.text,
                              currentCategorySegments: field == 'categoryPath'
                                  ? _rowSegments(row)
                                  : const [],
                              draftValues: _rows.map(
                                (item) => _value(item, field),
                              ),
                            );
                            if (!mounted || selection == null) return;
                            controller.text = selection.value;
                            _edit(row, field, selection.value);
                            if (field == 'categoryPath') {
                              setState(() {
                                _pickedCategorySegments[row.rowNum] =
                                    selection.categorySegments;
                                _categoryRevision++;
                                _category = _path(row);
                              });
                            }
                          },
                        ),
                    ],
                  ),
          ),
        );
      },
    );
  }

  List<MasterColumnDef<GoodsImportProblemRow>> _columns() {
    final l = basicDataL10n(context);
    final labels = <String, String>{
      'code': l.goodsImportCodeCorrection,
      'name': l.goodsImportFieldName,
      'categoryPath': l.goodsImportFieldCategory,
      'clientGoodsName': l.goodsImportFieldClientName,
      'cNumber': l.goodsImportFieldClientModel,
      'series': l.goodsImportFieldSeries,
      'model': l.goodsImportFieldModel,
      'spec': l.goodsImportFieldSpec,
      'material': l.goodsImportFieldMaterial,
      'rearInsertCode': l.goodsImportFieldRearInsert,
      'paper': l.goodsImportFieldPaper,
      'nameEn': l.goodsNameEnLabel,
      'colorName': l.goodsImportFieldColor,
      'unitName': l.goodsImportFieldUnit,
      'sourceType': l.goodsImportFieldSource,
      'status': l.goodsImportFieldStatus,
      'price': l.goodsImportFieldPrice,
      'minOrderQty': l.goodsImportFieldMinOrder,
      'orderMultipleQty': l.goodsImportFieldOrderMultiple,
      'goodsId': '系统标识',
      'bomRef': '组装信息ID',
      'owningWarehouseName': '所属仓库',
      'productionWorkshopName': '生产车间',
      'mouldCode': '模具编号',
      'mouldName': '模具名称',
    };
    return [
      MasterColumnDef(
        key: 'rowNum',
        label: l.importReviewSourceRow,
        width: 80,
        value: (row) => '${row.rowNum}',
        columnSearchEnabled: false,
      ),
      MasterColumnDef(
        key: 'result',
        label: '导入操作',
        width: 170,
        minimumWidthOf: (_) => 100,
        columnSearchEnabled: false,
        value: (row) => _rowStatus(row),
        cellBuilder: (context, row) {
          final change = _changes[row.rowNum];
          if (change?.hasConflicts == true) {
            return UtenButton(
              key: ValueKey('goods-import-conflict-${row.rowNum}'),
              size: UtenButtonSize.small,
              type: UtenButtonType.secondary,
              onPressed: _checking
                  ? null
                  : () => setState(() {
                      if (!_replaceRows.remove(row.rowNum)) {
                        _replaceRows.add(row.rowNum);
                      }
                    }),
              child: Text(_replaceRows.contains(row.rowNum) ? '替换差异' : '保留原值'),
            );
          }
          final errors =
              _indexedErrors[row.rowNum] ?? const <GoodsImportError>[];
          return Tooltip(
            message: errors
                .map((error) => '${error.column}：${error.message}')
                .join('\n'),
            child: Text(
              _rowStatus(row),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: errors.isNotEmpty
                    ? Theme.of(context).colorScheme.error
                    : null,
              ),
            ),
          );
        },
      ),
      for (final entry in labels.entries)
        if (const {'code', 'name', 'categoryPath'}.contains(entry.key) ||
            _indexedFields.contains(entry.key))
          MasterColumnDef(
            key: entry.key,
            label: entry.value,
            width: entry.key == 'categoryPath' ? 340 : 240,
            minimumWidthOf: (_) => 80,
            measureValueOf: entry.key == 'code'
                ? (row) =>
                      _value(row, 'code').isEmpty ? '自动编号' : _value(row, 'code')
                : null,
            measureWidthScope: entry.key == 'code' ? 'goodsImport.code' : null,
            measureWidthOf: entry.key == 'code'
                ? (context, row, scaler) =>
                      utenTableCellTextWidth(
                        _value(row, 'code').isEmpty
                            ? '自动编号'
                            : _value(row, 'code'),
                        style:
                            Theme.of(context).textTheme.bodyMedium ??
                            const TextStyle(),
                        textScaler: scaler,
                      ) +
                      UtenEditableGridCellSpec.contentPaddingOf(
                        context,
                      ).horizontal
                : null,
            defaultVisible:
                !_readOnlyFields.contains(entry.key) ||
                entry.key == 'goodsId' ||
                (entry.key == 'bomRef' &&
                    _rows.any((row) => _value(row, entry.key).isNotEmpty)) ||
                _rows.any(
                  (row) => _cellError(row, entry.key, entry.value) != null,
                ),
            info: _readOnlyFields.contains(entry.key)
                ? (const {'goodsId', 'bomRef'}.contains(entry.key)
                      ? '从文件核对，需改动时修改原文件'
                      : '仅供核对，导入不修改此字段')
                : null,
            columnSearchEnabled: false,
            value: (row) => _value(row, entry.key),
            cellBuilderHandlesSemantics: true,
            cellBuilder: (context, row) => _readOnlyFields.contains(entry.key)
                ? Tooltip(
                    message:
                        _cellError(row, entry.key, entry.value) ??
                        _value(row, entry.key),
                    child: Text(
                      _value(row, entry.key),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _cellError(row, entry.key, entry.value) == null
                            ? null
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  )
                : _editor(row, entry.key, entry.value),
          ),
    ];
  }

  static const _readOnlyFields = {
    'goodsId',
    'bomRef',
    'owningWarehouseName',
    'productionWorkshopName',
    'mouldCode',
    'mouldName',
  };

  String _rowStatus(GoodsImportProblemRow row) {
    if (_indexedErrors[row.rowNum]?.isNotEmpty == true) return '待修正';
    final changes = _changes[row.rowNum];
    if (changes?.hasConflicts == true) return '替换差异';
    if (changes != null) return '补齐资料';
    return widget.mode == GoodsImportMode.createOnly ? '新建货品' : '已通过';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = _rows;
    final tree = _tree();
    final visible = _category == null
        ? rows
        : rows.where((row) => _underPath(row, _category!)).toList();
    final selectedReady =
        _selected.isNotEmpty &&
        _selected.every((id) => _ready.contains(int.parse(id)));
    return Scaffold(
      appBar: UtenAppBar(
        title: widget.mode == GoodsImportMode.createOnly ? '确认新建货品' : '确认导入货品',
        leading: UtenBackButton(onPressed: () => Navigator.of(context).pop()),
        showPagePermissionAction: false,
      ),
      body: SafeArea(
        child: UtenSplitView(
          persistenceKey: 'basicData.goodsImportPreview',
          initialLeadingWidth: 280,
          selectedLeadingLabel: _pathLabels[_category] ?? '本次导入分类',
          openLeadingButtonKey: const ValueKey('goods-import-open-categories'),
          leading: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: Text('本次导入分类', style: theme.textTheme.titleSmall),
              ),
              ListTile(
                key: const ValueKey('goods-import-all-categories'),
                dense: true,
                selected: _category == null,
                leading: const Icon(Icons.inventory_2_outlined, size: 20),
                title: Text('全部货品（${rows.length}）'),
                onTap: () => setState(() => _category = null),
              ),
              Expanded(
                child: UtenCategoryTreeView<ProductCategoryNode>(
                  key: const ValueKey('goods-import-category-tree'),
                  nodes: tree,
                  initiallyExpandDepth: 100,
                  selectedIds: {?_category},
                  sortByCode: false,
                  onNodeTap: (node) => setState(() => _category = node.id),
                  trailingBuilder: (node) => Padding(
                    padding: const EdgeInsets.only(right: UtenSpacing.s8),
                    child: Text(
                      '${node.goodsCount}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
              ),
            ],
          ),
          trailing: UtenPageEdgePadding.pane(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * .22,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.filename,
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: UtenSpacing.s8),
                        Wrap(
                          spacing: 16,
                          runSpacing: 6,
                          children: [
                            Text('共 ${rows.length} 条'),
                            Text(
                              '可导入 ${_ready.length} 条',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                              ),
                            ),
                            if (_activeErrors.isNotEmpty)
                              Text(
                                '${_activeErrors.length} 处待修正',
                                style: TextStyle(
                                  color: theme.colorScheme.error,
                                ),
                              ),
                            if (_report.restorableRows > 0)
                              Text(
                                '将恢复 ${_report.restorableRows} 条',
                                style: TextStyle(
                                  color: theme.colorScheme.tertiary,
                                ),
                              ),
                          ],
                        ),
                        if (_message != null)
                          Text(
                            _message!,
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                        for (final error in _activeErrors.where(
                          (error) =>
                              !rows.any((row) => row.rowNum == error.rowNum),
                        ))
                          Text(
                            '${error.column}：${error.message}',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                      ],
                    ),
                  ),
                ),
                SizedBox(
                  height: 8,
                  child: _checking
                      ? const LinearProgressIndicator(minHeight: 2)
                      : null,
                ),
                Expanded(
                  child: MasterDataTableView<GoodsImportProblemRow>(
                    key: const ValueKey('goods-import-preview-table'),
                    expensiveRowMounts: false,
                    columns: _columns(),
                    items: visible,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    showPaginationControls: false,
                    showFullscreenToggle: false,
                    selectable: true,
                    selectedIds: _selected,
                    idOf: (row) => '${row.rowNum}',
                    rowKeyOf: (row) => '${row.rowNum}',
                    rowWidgetKeyOf: (row) =>
                        ValueKey('goods-import-preview-row-${row.rowNum}'),
                    onSelectedIdsChanged: _selectionChanged,
                    emptyMessage: '没有待导入货品',
                    toolbarLeadingActions: [
                      if (_report.conflictRows > 0)
                        UtenButton(
                          key: const ValueKey('goods-import-replace-selected'),
                          type: UtenButtonType.secondary,
                          icon: Icons.find_replace,
                          onPressed: _checking || _selected.isEmpty
                              ? null
                              : () => setState(() {
                                  _replaceRows.addAll(
                                    _selected
                                        .map(int.parse)
                                        .where(
                                          (row) =>
                                              _changes[row]?.hasConflicts ==
                                              true,
                                        ),
                                  );
                                }),
                          child: const Text('替换所选差异'),
                        ),
                      UtenButton(
                        key: const ValueKey('goods-import-select-ready'),
                        type: UtenButtonType.secondary,
                        icon: Icons.done_all,
                        onPressed: _checking
                            ? null
                            : () => _selectionChanged({
                                for (final row in rows)
                                  if (_ready.contains(row.rowNum))
                                    '${row.rowNum}',
                              }),
                        child: const Text('选择通过项'),
                      ),
                      UtenButton(
                        key: const ValueKey(
                          'goods-import-redetect-corrections',
                        ),
                        type: UtenButtonType.secondary,
                        icon: Icons.refresh,
                        isLoading: _checking,
                        onPressed: () => _validate(),
                        child: Text(_dirty ? '检查修改' : '重新检查'),
                      ),
                    ],
                    bottomContentPadding:
                        UtenFloatingActionGroup.scrollClearance,
                    batchActionsBuilder: (_, selected) => [
                      UtenButton(
                        key: const ValueKey('goods-import-remove-selected'),
                        type: UtenButtonType.secondary,
                        icon: Icons.delete_outline,
                        onPressed: _checking || selected.isEmpty
                            ? null
                            : _removeSelected,
                        child: const Text('移除所选'),
                      ),
                      UtenButton(
                        key: const ValueKey('goods-import-preview-confirm'),
                        size: UtenButtonSize.large,
                        icon: Icons.file_download_done_outlined,
                        onPressed:
                            _checking ||
                                _dirty ||
                                !selectedReady ||
                                _report.planId?.isNotEmpty != true
                            ? null
                            : _confirm,
                        child: Text('确认导入 ${selected.length} 条'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
