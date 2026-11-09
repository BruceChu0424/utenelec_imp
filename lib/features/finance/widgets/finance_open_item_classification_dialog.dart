import '../shared/finance_workbench_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import 'finance_classification_correction_dialog.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import 'finance_source_table.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/paging/read_view_activity.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_paged_read_view_mixin.dart';

const _categories = {
  'GOODS': '货款',
  'MOULD': '模具款',
  'MATERIAL': '物料金额',
  'PREPAYMENT': '预收款',
};

/// Supplier advances share the same exact original/local category editor.
Future<bool?> showFinancePrepaymentClassificationDialog(
  BuildContext context, {
  required String paymentId,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ClassificationEditor(id: paymentId, mode: 'prepayments'),
);

Future<bool?> showFinanceReceiptClassificationDialog(
  BuildContext context, {
  required String receiptLineId,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _ClassificationEditor(id: receiptLineId, mode: 'receipts'),
);

Future<void> showFinanceOpenItemClassificationDialog(
  BuildContext context, {
  String? ledgerId,
  String? partyId,
  String? currencyId,
  bool receivable = false,
}) => showFinanceWorkbenchPanel<void>(
  context: context,
  builder: (_) => ledgerId == null
      ? _ClassificationDirectory(
          partyId: partyId,
          currencyId: currencyId,
          receivable: receivable,
        )
      : _ClassificationEditor(id: ledgerId, mode: 'sources'),
);

class _ClassificationDirectory extends ConsumerStatefulWidget {
  const _ClassificationDirectory({
    this.partyId,
    this.currencyId,
    required this.receivable,
  });
  final String? partyId, currencyId;
  final bool receivable;
  @override
  ConsumerState<_ClassificationDirectory> createState() =>
      _ClassificationDirectoryState();
}

class _ClassificationDirectoryState
    extends ConsumerState<_ClassificationDirectory>
    with ScopedPagedReadViewMixin<_ClassificationDirectory> {
  late final ApiClient _api;
  late final int _epoch;
  List<Map<String, dynamic>> _items = [];
  Set<String> _selectedSources = {};
  bool _busy = false;
  String? _error;
  int _generation = 0;
  @override
  Future<void> onReadViewResumed() => _load();
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  Future<PagedResult<Map<String, dynamic>>> _fetchPage(
    int page,
    int size,
  ) async => PagedResult.fromJsonResponsive<Map<String, dynamic>>(
    await _api.get(
      '/finance/open-item-classifications',
      query: {
        'direction': widget.receivable ? 'AR' : 'AP',
        'page': '$page',
        'size': '$size',
        if (widget.partyId != null) 'partyId': widget.partyId,
        if (widget.currencyId != null) 'currencyId': widget.currencyId,
      },
    ),
    (row) => Map<String, dynamic>.unmodifiable(row),
  );

  Future<void> _load() async {
    if (!_current) return;
    final generation = ++_generation;
    bool current() => _current && generation == _generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await readScopedPage<Map<String, dynamic>>(
        1,
        slot: 'open-item-classifications',
        idOf: (row) => row['ledgerId'],
        query: [_api, widget.receivable, widget.partyId, widget.currencyId],
        currentQuery: () => [
          _api,
          widget.receivable,
          widget.partyId,
          widget.currencyId,
        ],
        isCurrent: current,
        fetchPage: (page) async => _fetchPage(page, 100),
        fetchPageSized: _fetchPage,
        onProgressiveBatch: (partial) =>
            setState(() => _items = partial.items),
      );
      if (current()) setState(() => _items = result.items);
    } catch (error) {
      if (!isRetiredViewRead(error) && current()) {
        setState(() {
          _error = _message(error);
          if (pagedReadAccessDenied(error)) {
            _items = [];
            _selectedSources = {};
          }
        });
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _edit(Map<String, dynamic> item) async {
    if (!_current ||
        _busy ||
        !_items.any((accepted) => identical(accepted, item))) {
      return;
    }
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _ClassificationEditor(id: '${item['ledgerId']}', mode: 'sources'),
    );
    if (_current) await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (ref.watch(exportContextEpochProvider) != _epoch) return _lost(context);
    return Stack(
      children: [
        UtenDialogFrame(
          maxWidth: 1000,
          fillHeight: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              UtenDialogHeader(
                title: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(widget.receivable ? '应收项目分类' : '货款/模具款分类'),
                    UtenFieldHintIcon(
                      info: _error ?? '按真实来源及全部原收付款、抵销两端归属，原币和本币分别完整分配。',
                    ),
                  ],
                ),
                showCloseButton: true,
                onClose: _busy ? null : () => Navigator.pop(context),
              ),
              Expanded(
                child: financeSourceTable(
                  tableKey: 'finance.open-item.classification.sources',
                  columns: [
                    financeSourceColumn(
                      'partyCode',
                      widget.receivable ? '客户编号' : '供应商编号',
                    ),
                    financeSourceColumn(
                      'partyName',
                      widget.receivable ? '客户' : '供应商',
                      width: 180,
                    ),
                    financeSourceColumn('currencyCode', '币别', width: 100),
                    financeSourceColumn('billNo', '单号', width: 220),
                    financeSourceColumn('sourceDocType', '来源类型', width: 180),
                    financeSourceColumn('billDate', '日期', type: 'date'),
                    financeSourceColumn(
                      'classificationId',
                      '分类状态',
                      value: (row) =>
                          row['classificationId'] == null ? '待分类' : '已分类',
                    ),
                  ],
                  rows: _items,
                  selectable: true,
                  selectedIds: _selectedSources,
                  onSelectedIdsChanged: (ids) {
                    if (!_busy) setState(() => _selectedSources = ids);
                  },
                  idOf: (row) => '${row['ledgerId']}',
                  busy: _busy,
                  error: _error,
                  retry: () => _load(),
                  scope: (
                    _epoch,
                    widget.partyId,
                    widget.currencyId,
                    widget.receivable,
                  ),
                  canOpen: (_) => !_busy,
                  onOpen: _edit,
                ),
              ),
              UtenDialogActions(
                alignment: MainAxisAlignment.end,
                overflowAlignment: OverflowBarAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy || _selectedSources.isEmpty
                        ? null
                        : () async {
                            if (_selectedSources.length > 64) {
                              setState(() => _error = '同次最多选择64个来源，须保留完整关联图');
                              return;
                            }
                            await showFinanceClassificationCorrectionDialog(
                              context,
                              ledgerIds: _selectedSources.toList()..sort(),
                            );
                            if (_current) await _load();
                          },
                    child: const Text('整图更正'),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_busy)
          const UtenBusyOverlay(title: '正在读取往来分类', showDoNotLeaveHint: false),
      ],
    );
  }
}

class _ClassificationEditor extends ConsumerStatefulWidget {
  const _ClassificationEditor({required this.id, required this.mode});
  final String id, mode;
  @override
  ConsumerState<_ClassificationEditor> createState() =>
      _ClassificationEditorState();
}

class _ClassificationLine extends EditableGridRow {
  _ClassificationLine(this.category, this.targetCategory, List<String> values)
    : fields = [for (final value in values) TextEditingController(text: value)];
  final String category;
  final String? targetCategory;
  final List<TextEditingController> fields;
  final enabledNotifier = ValueNotifier<bool>(false);
  bool get enabled => enabledNotifier.value;
  set enabled(bool value) => enabledNotifier.value = value;
  String get label => targetCategory == null
      ? _categories[category] ?? category
      : '${_categories[category]}抵${_categories[targetCategory]}';
  @override
  void dispose() {
    for (final field in fields) {
      field.dispose();
    }
    enabledNotifier.dispose();
    super.dispose();
  }
}

class _ClassificationEditorState extends ConsumerState<_ClassificationEditor>
    with ReadViewActivityMixin<_ClassificationEditor> {
  late final ApiClient _api;
  late final int _epoch;
  final _reference = TextEditingController();
  final _requestId = const Uuid().v4();
  Map<String, dynamic>? _source, _pending;
  final _grid = UtenEditableGridController<_ClassificationLine>();
  List<_ClassificationLine> get _lines => _grid.rows;
  bool _busy = false, _unknown = false, _dirty = false;
  bool _readDenied = false;
  int _readGeneration = 0;
  @override
  Future<void> onReadViewResumed() =>
      _dirty || _unknown ? _refreshReferences() : _load();
  String? _error;
  bool get _current =>
      mounted &&
      _epoch == ref.read(exportContextEpochProvider) &&
      identical(_api, ref.read(apiClientProvider));
  bool get _sourceAmounts =>
      widget.mode == 'sources' || widget.mode == 'prepayments';
  bool get _receiptAmounts => widget.mode == 'receipts';
  bool get _offsetAmounts =>
      widget.mode == 'offsets' || widget.mode == 'customer-offsets';
  bool get _receivable =>
      _receiptAmounts ||
      widget.mode == 'customer-offsets' ||
      _source?['direction'] == 'AR';
  List<String> get _readKeys => _sourceAmounts
      ? ['amount_original', 'amount_local']
      : _receiptAmounts
      ? [
          'amount_original',
          'write_off_original',
          'cash_local',
          'write_off_local',
          'book_local',
        ]
      : widget.mode == 'payments'
      ? ['amount_original', 'cash_local', 'book_local']
      : ['amount_original', 'source_local', 'target_local'];
  List<String> get _writeKeys => _sourceAmounts
      ? ['amountOriginal', 'amountLocal']
      : _receiptAmounts
      ? [
          'amountOriginal',
          'writeOffOriginal',
          'cashLocal',
          'writeOffLocal',
          'bookLocal',
        ]
      : widget.mode == 'payments'
      ? ['amountOriginal', 'cashLocal', 'bookLocal']
      : ['amountOriginal', 'sourceLocal', 'targetLocal'];
  List<String> get _amountLabels => _sourceAmounts
      ? ['原币金额', '本币金额']
      : _receiptAmounts
      ? ['收款原币', '冲销原币', '实际回款本币', '冲销本币', '账面核销本币']
      : widget.mode == 'payments'
      ? ['原币金额', '实际付款本币', '账面核销本币']
      : ['抵销原币金额', '来源账面本币', '目标账面本币'];
  String get _path => widget.mode == 'prepayments'
      ? '/finance/supplier-prepayments/${widget.id}'
      : '/finance/open-item-classifications/${widget.mode}/${widget.id}';
  String get _writePath =>
      widget.mode == 'prepayments' ? '$_path/classification' : _path;
  bool get _canEdit {
    final permissions = ref.read(currentPermissionsProvider);
    if (widget.mode == 'prepayments') {
      return permissions.contains(Perm.financePaymentApprove) &&
          permissions.contains(Perm.supplierSettlementConfirm);
    }
    return permissions.contains(
      widget.mode == 'payments'
          ? Perm.financePaymentApprove
          : widget.mode == 'offsets' || _source?['direction'] == 'AP'
          ? Perm.supplierSettlementConfirm
          : Perm.financeReceiptApprove,
    );
  }

  @override
  void initState() {
    super.initState();
    _api = ref.read(apiClientProvider);
    _epoch = ref.read(exportContextEpochProvider);
    _load();
  }

  @override
  void dispose() {
    _reference.dispose();
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy || _unknown) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final generation = ++_readGeneration;
    bool current() => _current && generation == _readGeneration;
    try {
      final result = await readViewActivity.runRead(current, () async {
        final source = await _api.get(_path);
        if (widget.mode != 'sources') return source;
        final ar = _sourceDirection(source) == 'AR';
        final cash = await _completeReferences('cash', ar, current);
        final offsets = await _completeReferences('offsets', ar, current);
        return {
          ...source,
          'cashReferences': cash,
          'offsetReferences': offsets,
          ar ? 'receipts' : 'payments': cash['items'],
          'offsets': offsets['items'],
        };
      });
      if (!current()) return;
      final saved = _maps(result['parts']);
      final sourceParts = _maps(result['sourceParts']);
      final categories = _sourceAmounts
          ? (_sourceDirection(result) == 'AR'
                ? ['GOODS', 'MATERIAL']
                : ['GOODS', 'MOULD'])
          : sourceParts.map((p) => '${p['category']}').toSet().toList();
      final lines = <_ClassificationLine>[];
      for (final category in categories) {
        final targets = _offsetAmounts
            ? _maps(result['targetParts'])
                  .map((p) => p['category']?.toString())
                  .whereType<String>()
                  .toList()
            : <String?>[null];
        for (final target in targets) {
          final old = saved
              .where(
                (p) => _offsetAmounts
                    ? p['source_category'] == category &&
                          p['target_category'] == target
                    : p['category'] == category,
              )
              .firstOrNull;
          final line = _ClassificationLine(category, target, [
            for (final key in _readKeys) old == null ? '0' : _exact(old, key),
          ])..enabled = old != null;
          lines.add(line);
        }
      }
      _grid.replaceAll(lines);
      setState(() {
        _source = result;
        _dirty = false;
        _reference.text = '';
      });
    } catch (error) {
      if (!isRetiredViewRead(error) && current()) {
        setState(() {
          _error = _message(error);
          if (pagedReadAccessDenied(error)) {
            _readDenied = true;
            _source = null;
          }
        });
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  String _sourceDirection(Map<String, dynamic> value) =>
      value['direction']?.toString() ?? 'AP';
  void _fill(_ClassificationLine selected) {
    if (_source == null || _busy || _unknown) return;
    final keys = _writeKeys;
    setState(() {
      for (final line in _lines) {
        line.enabled = identical(line, selected);
        for (int i = 0; i < line.fields.length; i++) {
          line.fields[i].text = identical(line, selected)
              ? _exact(_source!, keys[i])
              : '0';
        }
      }
      _dirty = true;
    });
  }

  Future<void> _save() async {
    if (!_current || _busy || !_canEdit || _source == null) return;
    if (!_unknown) {
      if (_reference.text.trim().isEmpty ||
          !_lines.any((line) => line.enabled)) {
        setState(() => _error = '请填写明确来源依据并选择实际分类');
        return;
      }
      final parts = <Map<String, dynamic>>[];
      for (final line in _lines.where((line) => line.enabled)) {
        final values = [for (final field in line.fields) field.text.trim()];
        if (values.any(
          (value) => !RegExp(r'^-?(?:\d+)(?:\.\d+)?$').hasMatch(value),
        )) {
          setState(() => _error = '金额请保留原十进制数值，不填写千分位或公式');
          return;
        }
        parts.add({
          if (_offsetAmounts) ...{
            'sourceCategory': line.category,
            'targetCategory': line.targetCategory,
          } else
            'category': line.category,
          for (int i = 0; i < _writeKeys.length; i++) _writeKeys[i]: values[i],
        });
      }
      _pending = {
        'requestId': _requestId,
        'expectedRevision': _source!['revision'] ?? -1,
        'sourceReference': _reference.text,
        'parts': parts,
        if (widget.mode == 'sources')
          'effectiveFrom': _source!['effectiveFrom'],
        if (!_sourceAmounts)
          'sourceClassificationId': _source!['sourceClassificationId'],
        if (_offsetAmounts)
          'targetClassificationId': _source!['targetClassificationId'],
      };
    }
    final wasUnknown = _unknown;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _api.post(_writePath, body: _pending);
      if (mounted && _current) Navigator.pop(context, true);
    } catch (error) {
      if (_current) {
        setState(() {
          _unknown = wasUnknown || !_rejected(error);
          _error = _unknown
              ? '${_message(error)}。原分配和请求编号已保留，请核对并重试原请求。'
              : _message(error);
        });
      }
    } finally {
      if (_current) setState(() => _busy = false);
    }
  }

  Future<void> _openChild(String mode, String id) async {
    if (!_current || _busy || _unknown) return;
    if (_dirty) {
      setState(() => _error = '请先保存当前来源分类，再核对付款或抵销分配');
      return;
    }
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ClassificationEditor(id: id, mode: mode),
    );
    if (_current) await _load();
  }

  Future<Map<String, dynamic>> _completeReferences(
    String kind,
    bool ar,
    bool Function() current,
  ) async {
    final result = await loadCompletePagedResult<Map<String, dynamic>>(
      isCurrent: current,
      idOf: (row) =>
          row[kind == 'cash'
              ? (ar ? 'receiptLineId' : 'paymentLineId')
              : 'offsetId'],
      loadPage: (page, size) async {
        final raw = await _api.get(
          '$_path/references',
          query: {'kind': kind, 'page': '$page', 'size': '$size'},
        );
        return PagedReadSnapshot<Map<String, dynamic>, Map<String, dynamic>>(
          page: await PagedResult.fromJsonResponsive<Map<String, dynamic>>(
            raw,
            (row) => Map<String, dynamic>.unmodifiable(row),
          ),
          snapshot: raw,
          rebuildSnapshot: (combined) => {
            ...raw,
            'items': combined.items,
            'page': combined.page,
            'size': combined.size,
            'total': combined.total,
            'totalPages': combined.totalPages,
          },
        );
      },
    );
    return (result
            as PagedReadSnapshot<Map<String, dynamic>, Map<String, dynamic>>)
        .snapshot;
  }

  Future<void> _refreshReferences() async {
    // Unsaved allocations, evidence, optimistic head and uncertain writes are
    // local command state. A return only refreshes read-only reference lists.
    if (!_current ||
        _busy ||
        _unknown ||
        widget.mode != 'sources' ||
        _source == null) {
      return;
    }
    final generation = ++_readGeneration;
    bool current() => _current && generation == _readGeneration;
    final ar = _receivable;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final values = await readViewActivity.runRead(
        current,
        () async => [
          await _completeReferences('cash', ar, current),
          await _completeReferences('offsets', ar, current),
        ],
      );
      if (!current()) return;
      setState(
        () => _source = {
          ..._source!,
          'cashReferences': values[0],
          'offsetReferences': values[1],
          ar ? 'receipts' : 'payments': values[0]['items'],
          'offsets': values[1]['items'],
        },
      );
    } catch (error) {
      if (!isRetiredViewRead(error) && current()) {
        setState(() {
          _error = _message(error);
          if (pagedReadAccessDenied(error)) {
            _readDenied = true;
            _source = null;
          }
        });
      }
    } finally {
      if (current()) setState(() => _busy = false);
    }
  }

  Future<void> _close() async {
    if (_busy || _unknown) return;
    if (_dirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => UtenAlertDialog(
          title: const Text('放弃未保存的分配？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('继续填写'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('放弃'),
            ),
          ],
        ),
      );
      if (discard != true) return;
    }
    if (mounted) Navigator.pop(context, false);
  }

  @override
  Widget build(BuildContext context) {
    if (_readDenied ||
        ref.watch(exportContextEpochProvider) != _epoch ||
        !identical(_api, ref.watch(apiClientProvider))) {
      return _lost(context);
    }
    final editable = !_busy && !_unknown && _canEdit;
    final labels = _amountLabels;
    final moneyKeys = _writeKeys;
    final columns = <EditableGridColumn<_ClassificationLine>>[
      EditableGridColumn(
        key: 'enabled',
        label: '选用',
        width: 72,
        required: true,
        textOf: (row) => row.enabled ? '已选' : '未选',
        listenableOf: (row) => row.enabledNotifier,
        cellBuilder: (context, row) => ValueListenableBuilder<bool>(
          valueListenable: row.enabledNotifier,
          builder: (_, enabled, child) => Checkbox(
            value: enabled,
            onChanged: editable
                ? (value) {
                    row.enabled = value ?? false;
                    _dirty = true;
                  }
                : null,
          ),
        ),
      ),
      EditableGridColumn(
        key: 'category',
        label: '类别',
        width: 240,
        required: true,
        textOf: (row) => row.label,
        cellBuilder: (context, row) => Text(row.label),
      ),
      for (int i = 0; i < labels.length; i++)
        EditableGridColumn(
          key: 'amount$i',
          label: labels[i],
          width: 220,
          required: true,
          numeric: true,
          aiSensitive: true,
          textOf: (row) => row.fields[i].text,
          listenableOf: (row) => row.fields[i],
          exactValueOf: (row) => row.fields[i].text,
          cellBuilder: (context, row) => ValueListenableBuilder<bool>(
            valueListenable: row.enabledNotifier,
            builder: (_, enabled, child) => UtenInput(
              key: ValueKey(
                'classification-${row.category}-${row.targetCategory}-$i',
              ),
              controller: row.fields[i],
              enabled: editable && enabled,
              aiSensitive: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),

              onChanged: (_) => _dirty = true,
            ),
          ),
        ),
      EditableGridColumn(
        key: 'actions',
        label: '操作',
        width: 250,
        required: true,
        textOf: (row) => '全部分配为${row.label}',
        cellBuilder: (context, row) => TextButton(
          onPressed: editable ? () => _fill(row) : null,
          child: Text('全部分配为${row.label}'),
        ),
      ),
    ];
    return PopScope(
      canPop: false,
      child: Stack(
        children: [
          UtenDialogFrame(
            maxWidth: 1150,
            fillHeight: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          widget.mode == 'prepayments'
                              ? '供应商预付款货款/模具款分类'
                              : widget.mode == 'sources'
                              ? '往来项目分类'
                              : widget.mode == 'payments'
                              ? '付款金额分配'
                              : _receiptAmounts
                              ? '收款金额分配'
                              : '往来抵销分配',
                        ),
                      ),
                      UtenFieldHintIcon(
                        info:
                            _error ??
                            (_source == null
                                ? '来源尚未读取，请重新核对'
                                : widget.mode == 'sources' &&
                                      _source!['sourceVerified'] != true
                                ? '来源对象或历史金额尚未核验，不能确认分类。'
                                : '原币、实际现金、冲销与账面核销分别按真实事实完整分配，不换算、补差或截断输入。'),
                      ),
                    ],
                  ),
                  showCloseButton: true,
                  onClose: _busy || _unknown ? null : _close,
                ),
                Expanded(
                  child: _source == null
                      ? Center(
                          child: _busy
                              ? const SizedBox.shrink()
                              : const SizedBox.shrink(),
                        )
                      : SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: UtenSpacing.s16,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                SelectableText(
                                  '${_source!['billNo'] ?? _source!['offsetId']}',
                                ),
                                if (_source!['currencyCode'] != null)
                                  Text(
                                    '币别：${_source!['currencyCode']} ${_source!['currencyName'] ?? ''}',
                                  ),
                                if (_source!['appliedBillNo'] != null)
                                  Text(
                                    '对应${_receivable ? '应收' : '应付'}：${_source!['appliedBillNo']}',
                                  ),
                                if (_source!['sourceBillNo'] != null)
                                  Text(
                                    '来源：${_source!['sourceBillNo']}  目标：${_source!['targetBillNo']}',
                                  ),
                                for (int i = 0; i < labels.length; i++)
                                  Text(
                                    '${labels[i]}：${_exact(_source!, moneyKeys[i])}',
                                  ),
                                const SizedBox(height: UtenSpacing.s8),
                                UtenEditableGrid<_ClassificationLine>(
                                  tableKey:
                                      'finance.open-item.classification.${widget.mode}',
                                  controller: _grid,
                                  columns: columns,
                                  showAddRow: false,
                                  showRowDelete: false,
                                  showRemoveRowsAction: false,
                                  showColumnSettings: false,
                                  stickyHeader: false,
                                  selectionEnabled: editable,
                                  rowMenuExtraBuilder: (context, selected) => [
                                    if (selected.length == 1)
                                      UtenMenuItem(
                                        label: '全部分配为${selected.single.label}',
                                        enabled: editable,
                                        onTap: () => _fill(selected.single),
                                      ),
                                  ],
                                ),
                                const SizedBox(height: UtenSpacing.s12),
                                UtenInput(
                                  label: '来源依据',
                                  controller: _reference,
                                  enabled: editable,
                                  maxLines: 2,
                                  inputFormatters: [
                                    LengthLimitingTextInputFormatter(2000),
                                  ],
                                  onChanged: (_) => _dirty = true,
                                ),
                                if (widget.mode == 'sources') ...[
                                  const SizedBox(height: UtenSpacing.s16),
                                  Text(
                                    _receivable ? '收款行分配' : '付款行分配',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  SizedBox(
                                    height: 250,
                                    child: financeSourceTable(
                                      tableKey:
                                          'finance.open-item.classification.payments',
                                      columns: [
                                        financeSourceColumn(
                                          'billNo',
                                          _receivable ? '收款单号' : '付款单号',
                                          width: 230,
                                        ),
                                        financeSourceColumn(
                                          'billDate',
                                          '日期',
                                          type: 'date',
                                        ),
                                        financeSourceColumn(
                                          'classificationId',
                                          '分配状态',
                                          value: (row) =>
                                              row['classificationId'] == null
                                              ? '待分配'
                                              : '已分配',
                                        ),
                                      ],
                                      rows: _maps(
                                        _source![_receivable
                                            ? 'receipts'
                                            : 'payments'],
                                      ),
                                      busy: _busy,
                                      idOf: (row) =>
                                          '${row[_receivable ? 'receiptLineId' : 'paymentLineId']}',
                                      canOpen: (_) => !_busy && !_unknown,
                                      onOpen: (row) => _openChild(
                                        _receivable ? 'receipts' : 'payments',
                                        '${row[_receivable ? 'receiptLineId' : 'paymentLineId']}',
                                      ),
                                      scope: (_epoch, widget.id),
                                    ),
                                  ),
                                  const SizedBox(height: UtenSpacing.s12),
                                  Text(
                                    '抵销两端分配',
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                  SizedBox(
                                    height: 250,
                                    child: financeSourceTable(
                                      tableKey:
                                          'finance.open-item.classification.offsets',
                                      columns: [
                                        financeSourceColumn(
                                          'effectiveDate',
                                          '生效日期',
                                          type: 'date',
                                        ),
                                        financeSourceColumn(
                                          'offsetId',
                                          '原抵销记录',
                                          width: 290,
                                        ),
                                        financeSourceColumn(
                                          'classificationId',
                                          '分配状态',
                                          value: (row) =>
                                              row['classificationId'] == null
                                              ? '待分配'
                                              : '已分配',
                                        ),
                                      ],
                                      rows: _maps(_source!['offsets']),
                                      busy: _busy,
                                      idOf: (row) => '${row['offsetId']}',
                                      canOpen: (_) => !_busy && !_unknown,
                                      onOpen: (row) => _openChild(
                                        _receivable
                                            ? 'customer-offsets'
                                            : 'offsets',
                                        '${row['offsetId']}',
                                      ),
                                      scope: (_epoch, widget.id),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                ),
                UtenDialogActions(
                  alignment: MainAxisAlignment.end,
                  overflowAlignment: OverflowBarAlignment.end,
                  children: [
                    if (widget.mode == 'sources')
                      TextButton(
                        onPressed: _busy || _unknown || _dirty
                            ? null
                            : () async {
                                await showFinanceClassificationCorrectionDialog(
                                  context,
                                  ledgerIds: [widget.id],
                                );
                                if (_current) await _load();
                              },
                        child: const Text('整图更正'),
                      ),
                    if (_canEdit)
                      UtenButton(
                        onPressed: _busy || _source == null ? null : _save,
                        isLoading: _busy,
                        child: Text(_unknown ? '核对并重试原请求' : '确认分配'),
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (_busy)
            const UtenBusyOverlay(
              title: '正在核对原分类分配',
              showDoNotLeaveHint: false,
            ),
        ],
      ),
    );
  }
}

String _exact(Map<String, dynamic> value, String key) =>
    value['${key}Exact']?.toString() ?? value[key]?.toString() ?? '待核验';
List<Map<String, dynamic>> _maps(Object? value) => [
  if (value is List)
    for (final row in value)
      if (row is Map<String, dynamic>) row,
];
String _message(Object error) =>
    error is ApiException ? error.message : '操作未完成，请核对网络后重试';
bool _rejected(Object error) =>
    error is ApiException &&
    error.hasResponseCode &&
    (error.httpStatus ?? 0) >= 400 &&
    (error.httpStatus ?? 0) < 500 &&
    error.httpStatus != 408;
Widget _lost(BuildContext context) => UtenAlertDialog(
  showCloseButton: true,
  onClose: () => Navigator.pop(context),

  title: const Text('访问范围已变化'),
);
