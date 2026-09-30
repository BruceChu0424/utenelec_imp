import 'dart:async';
import 'dart:convert';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/buttons/uten_export_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_totals_summary_bar.dart';
import '../../../components/data_display/uten_revision_table.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/money_display.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import '../../../shared/widgets/uten_tree_table_cell.dart';
import '../../../shared/widgets/uten_tree_row_projection.dart';
import '../models/currency_node.dart';
import '../models/goods_cost_sheet.dart';
import '../models/goods_node.dart';
import '../repositories/currency_repository.dart';
import '../repositories/client_repository.dart';
import '../repositories/goods_cost_repository.dart';
import 'goods_cost_actual_panel.dart';
import 'goods_cost_import_dialog.dart';
import 'master_data_table_view.dart';
import 'uten_client_picker.dart';

part 'goods_cost_editor.dart';

/// Versioned cost workbench. Saving a sheet never writes the goods master.
class GoodsCostTab extends ConsumerStatefulWidget {
  const GoodsCostTab({
    super.key,
    required this.detail,
    required this.canEdit,
    this.materialTotal,
    this.onSaved,
  });
  final GoodsDetail detail;
  final bool canEdit;
  final double? materialTotal;
  final VoidCallback? onSaved;
  @override
  ConsumerState<GoodsCostTab> createState() => _GoodsCostTabState();
}

class _GoodsCostTabState extends ConsumerState<GoodsCostTab>
    with AutomaticKeepAliveClientMixin, FormDraftMixin {
  static const _tableKey = 'master.goods.cost.items';
  final _controllers = <String, TextEditingController>{};
  final _collapsed = <String>{};
  final _selectedPaths = <String>{};
  Map<String, dynamic> _input = {};
  GoodsCostSheet? _sheet;
  GoodsCostCalculation? _calculationValue;
  Map<String, Map<String, dynamic>> _feeResultsByKey = {},
      _costLinesByPath = {};
  final _calculationSignal = ValueNotifier<int>(0);
  GoodsCostCalculation? get _calculation => _calculationValue;
  set _calculation(GoodsCostCalculation? value) {
    _calculationValue = value;
    _feeResultsByKey = {
      for (final fee in value?.fees ?? <Map<String, dynamic>>[])
        fee['key'].toString(): fee,
    };
    _costLinesByPath = {
      for (final line in value?.lines ?? <Map<String, dynamic>>[])
        line['path'].toString(): line,
    };
    _calculationSignal.value++;
  }

  GoodsCostSnapshot? _historical;
  List<Map<String, dynamic>> _versions = [], _snapshots = [], _templates = [];
  List<CurrencyListItem> _currencies = [];
  List<FormDraft> _localDrafts = [];
  String? _clientName, _error;
  bool _busy = false, _loading = true, _calculating = false, _dirty = false;
  bool _replacingFees = false;
  int _tab = 0, _bodyTab = 0, _inputRevision = 0, _previewRequest = 0;
  int? _calculatedRevision;
  Timer? _debounce;
  String _saveKey = const Uuid().v4();
  String? _confirmKey;
  String? _copyKey;
  final _feeGrid = UtenEditableGridController<GoodsCostFeeRow>();
  GoodsCostRepository get _repository => ref.read(goodsCostRepositoryProvider);
  AppLocalizations get _l => AppLocalizations.of(context);
  bool get _canCostEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.goodsCostEdit);
  bool get _editable =>
      _canCostEdit &&
      !_busy &&
      _historical == null &&
      (_sheet == null || _sheet!.canEdit);
  bool get _stale => _calculatedRevision != _inputRevision;
  double get _materialHeight =>
      (145 + (_calculation?.lines.length ?? 0) * 66).clamp(260, 620).toDouble();
  @override
  bool get wantKeepAlive => true;
  @override
  bool get formDraftEnabled =>
      _canCostEdit &&
      !widget.detail.costMasked &&
      _historical == null &&
      (_sheet == null || _sheet!.status == 'DRAFT');
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftUsesRouterGuard =>
      goRouterPageStateOrNull(context)?.uri.path ==
      '/basicinfo/goods/${widget.detail.id}';
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.goodsCost.spec(
    title:
        '${_l.costWorkspaceTitle} · ${widget.detail.name ?? widget.detail.code ?? ''}',
    route: '/basicinfo/goods/${widget.detail.id}?tab=cost',
  );
  @override
  Map<String, dynamic> captureFormDraft() => {
    'goodsId': widget.detail.id,
    'input': _currentInput(),
    'sheetId': _sheet?.id,
    'serverVersion': _sheet?.version,
    'idempotencyKey': _saveKey,
    'clientName': _clientName,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (widget.detail.costMasked ||
        !_canCostEdit ||
        !ref.read(currentPermissionsProvider).contains(Perm.goodsCostView) ||
        data['goodsId'] != widget.detail.id) {
      throw StateError(_l.costNoPermission);
    }
    final id = costText(data['sheetId']);
    if (id != null) {
      final latest = await _repository.detail(id);
      if (!mounted) return;
      if (!latest.canEdit || latest.version != data['serverVersion']) {
        throw StateError(_l.costConflict);
      }
      _sheet = latest;
    } else {
      _sheet = null;
    }
    _input = copyCostJson(costMap(data['input']));
    _historical = null;
    _clientName = costText(data['clientName']);
    _saveKey = costText(data['idempotencyKey']) ?? const Uuid().v4();
    _dirty = true;
    _inputRevision++;
    _resetEditors();
    await _preview();
  }

  @override
  void initState() {
    super.initState();
    _feeGrid.addListener(_feeRowsChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  @override
  void didUpdateWidget(covariant GoodsCostTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.detail.costMasked && !oldWidget.detail.costMasked) {
      _debounce?.cancel();
      _previewRequest++;
      _calculation = null;
      _input = {};
      _sheet = null;
      _historical = null;
      _resetEditors();
    }
  }

  void _feeRowsChanged() {
    if (!_replacingFees && _editable) _change(() {});
  }

  Map<String, dynamic> _freshInput() => {
    'goodsId': widget.detail.id,
    'name': widget.detail.name ?? '',
    'batchQty': '1',
    'exchangeRateToLocal': '1',
    'effectiveDate': DateTime.now().toIso8601String().split('T').first,
    'usageStrategy': 'ACTUAL_FIRST',
    'priceStrategy': 'APPROVED_PURCHASE',
    'lineOverrides': <Object>[],
    'fees': <Object>[],
    'priceColumns': <Object>[],
    'priceCells': <Object>[],
    'extraFields': <String, String>{},
  };
  Future<void> _boot() async {
    if (widget.detail.costMasked ||
        !ref.read(currentPermissionsProvider).contains(Perm.goodsCostView)) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      _input = _freshInput();
      final results = await Future.wait<Object>([
        _repository.list(widget.detail.id),
        ref
            .read(currencyRepositoryProvider)
            .dict()
            .catchError((_) => <CurrencyListItem>[]),
        _repository
            .templates(widget.detail.id, null)
            .catchError((_) => <Map<String, dynamic>>[]),
      ]);
      if (!mounted) return;
      _versions = results[0] as List<Map<String, dynamic>>;
      _currencies = results[1] as List<CurrencyListItem>;
      _templates = results[2] as List<Map<String, dynamic>>;
      final route = goRouterPageStateOrNull(context)?.uri;
      final resumesLocal =
          route?.path == '/basicinfo/goods/${widget.detail.id}' &&
          route?.queryParameters['draftId'] != null;
      if (resumesLocal) {
        // The selected local draft supplies its own sheet/version. A newer
        // confirmed default sheet must not disable the recovery lifecycle.
        _sheet = null;
      } else if (_versions.isNotEmpty) {
        final latest = await _repository.detail(
          costText(_versions.first['id'])!,
        );
        if (!mounted) return;
        _adopt(latest);
      } else {
        _input['currencyId'] = _currencies
            .where((c) => c.baseCurrency)
            .firstOrNull
            ?.id;
        await _preview();
      }
      if (!mounted) return;
      await initializeFormDraft();
      await _refreshLocalDrafts();
    } catch (e) {
      if (mounted) _error = _message(e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _message(Object e) => e is ApiException
      ? e.message
      : e is StateError
      ? e.message
      : _l.commonError;
  Map<String, dynamic> _currentInput() => {
    ..._input,
    'fees': _feeGrid.rows
        .where((r) => !r.generated)
        .map((r) => r.encode())
        .toList(),
  };
  void _resetEditors() {
    final old = _controllers.values.toList();
    _controllers.clear();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in old) {
        c.dispose();
      }
    });
    _replacingFees = true;
    try {
      _feeGrid.replaceAll(
        [
          ...costMaps(_input['fees']),
          ...?_calculation?.fees.where((f) => f['source'] == 'PRICE_COLUMN'),
        ].map((f) => GoodsCostFeeRow(f)),
      );
    } finally {
      _replacingFees = false;
    }
  }

  void _adopt(GoodsCostSheet sheet) {
    _debounce?.cancel();
    _previewRequest++;
    if (_sheet?.id != sheet.id) {
      _selectedPaths.clear();
      _collapsed.clear();
    }
    _sheet = sheet;
    _historical = null;
    _input = copyCostJson(sheet.input);
    _clientName = costText(costMap(_input['extraFields'])['serverClientName']);
    _calculation = sheet.calculation;
    _dirty = false;
    _inputRevision++;
    _calculatedRevision = _inputRevision;
    _confirmKey = null;
    _copyKey = null;
    _saveKey = const Uuid().v4();
    _error = null;
    _resetEditors();
    if (_input['clientId'] != null) unawaited(_loadClientContext());
  }

  void _change(VoidCallback edit) {
    if (!_editable) return;
    setState(() {
      edit();
      _dirty = true;
      _inputRevision++;
      _saveKey = const Uuid().v4();
      _confirmKey = null;
      _copyKey = null;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 550), _preview);
  }

  Future<void> _preview() async {
    if (!mounted ||
        widget.detail.costMasked ||
        _input.isEmpty ||
        _historical != null ||
        (_sheet != null && _sheet!.status != 'DRAFT')) {
      return;
    }
    final request = ++_previewRequest, revision = _inputRevision;
    final input = copyCostJson(_currentInput());
    setState(() {
      _calculating = true;
      _error = null;
    });
    try {
      final result = await _repository.preview(input);
      if (!mounted ||
          request != _previewRequest ||
          revision != _inputRevision) {
        return;
      }
      setState(() {
        final current = _currentInput();
        final merged = mergeResolvedCostInput(current, result.resolvedInput);
        if (jsonEncode(merged) != jsonEncode(current) ||
            (_sheet != null && result.digest != _sheet!.calculation.digest)) {
          _dirty = true;
        }
        _input = merged;
        _clientName =
            costText(costMap(_input['extraFields'])['serverClientName']) ??
            _clientName;
        _calculation = result;
        _syncRecommendedCells(result);
        _adoptTemplateSuggestions(result);
        _calculatedRevision = revision;
      });
    } catch (e) {
      if (mounted && request == _previewRequest && revision == _inputRevision) {
        setState(() => _error = _message(e));
      }
    } finally {
      if (mounted && request == _previewRequest) {
        setState(() => _calculating = false);
      }
    }
  }

  Future<T?> _action<T>(Future<T> Function() run) async {
    if (_busy) return null;
    FocusScope.of(context).unfocus();
    _debounce?.cancel();
    setState(() {
      _previewRequest++;
      _calculating = false;
      _busy = true;
      _error = null;
    });
    try {
      return await run();
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
      return null;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<GoodsCostSheet> _saveCurrent() async {
    final sheet = await _repository.save(
      _sheet?.id,
      copyCostJson(_currentInput()),
      idempotencyKey: _saveKey,
      expectedVersion: _sheet?.version,
    );
    if (!mounted) return sheet;
    setState(() => _adopt(sheet));
    await saveFormDraftNow();
    _versions = await _repository.list(widget.detail.id);
    widget.onSaved?.call();
    return sheet;
  }

  Future<void> _save() async {
    final saved = await _action(_saveCurrent);
    if (saved != null && mounted) context.appSuccess(_l.costSaved);
  }

  Future<void> _confirm() async {
    final ok = await UtenDialog.show(
      context,
      title: _l.costConfirm,
      content: Text(_l.costConfirmPrompt),
      confirmLabel: _l.commonConfirm,
      cancelLabel: _l.commonCancel,
    );
    if (ok != true || !mounted) return;
    await _action(() async {
      var sheet = _sheet;
      if (sheet == null || _dirty) sheet = await _saveCurrent();
      _confirmKey ??= const Uuid().v4();
      final confirmed = await _repository.confirm(
        sheet.id,
        sheet.version,
        _confirmKey!,
      );
      if (!mounted) return;
      setState(() => _adopt(confirmed));
      await completeFormDraft();
      _versions = await _repository.list(widget.detail.id);
      widget.onSaved?.call();
    });
  }

  Future<void> _new() async {
    if (_dirty) {
      context.appError(_l.costLeavePrompt);
      return;
    }
    await resetFormDraftAfterSubmission(
      prepare: () async {
        _sheet = null;
        _historical = null;
        _input = _freshInput();
        _input['currencyId'] = _currencies
            .where((c) => c.baseCurrency)
            .firstOrNull
            ?.id;
        _calculation = null;
        _inputRevision++;
        _saveKey = const Uuid().v4();
        _resetEditors();
      },
    );
    if (mounted) {
      setState(() => _tab = 0);
      await _preview();
    }
  }

  Future<void> _open(String id) async {
    if (_dirty) {
      context.appError(_l.costLeavePrompt);
      return;
    }
    await _action(() async {
      final sheet = await _repository.detail(id);
      if (!mounted) return;
      await resetFormDraftAfterSubmission(prepare: () async => _adopt(sheet));
      if (mounted) setState(() => _tab = 0);
    });
  }

  Future<void> _copy() async {
    final existing = _sheet;
    if (existing == null) return;
    await _action(() async {
      _copyKey ??= const Uuid().v4();
      final name = '${costText(_input['name']) ?? ''} · ${_l.costCopySuffix}';
      final copied = (_dirty || _historical != null)
          ? await _repository.save(null, {
              ..._currentInput(),
              'name': name,
            }, idempotencyKey: _copyKey!)
          : await _repository.copy(
              existing.id,
              existing.version,
              _copyKey!,
              name,
            );
      if (!mounted) return;
      await resetFormDraftAfterSubmission(prepare: () async => _adopt(copied));
      if (mounted) setState(() => _tab = 0);
      _versions = await _repository.list(widget.detail.id);
    });
  }

  Future<void> _refreshLocalDrafts() async {
    final store = ref.read(formDraftsProvider.notifier);
    await store.ready;
    if (!mounted) return;
    setState(
      () => _localDrafts = ref
          .read(formDraftsProvider)
          .where(
            (d) =>
                d.draftKind == 'goods_cost' &&
                d.data['goodsId'] == widget.detail.id,
          )
          .toList(),
    );
  }

  Future<void> _recover(FormDraft draft) async {
    if (_dirty) {
      context.appError(_l.costLeavePrompt);
      return;
    }
    await _action(() async {
      await resetFormDraftAfterSubmission(
        preserveCurrentDraft: true,
        prepare: () => restoreFormDraft(draft.data),
      );
      if (mounted) setState(() => _tab = 0);
    });
  }

  Future<UtenExportSelection?> _prepareDownload(String format) async {
    var section = _bodyTab == 1 ? 'FEES' : 'ALL';
    var selectedOnly = false;
    final ready = await _dialogWhenRemoved<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            format == 'xlsx' ? _l.costDownloadExcel : _l.costDownloadPdf,
          ),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenDropdownField(
                  label: _l.costSource,
                  value: section,
                  allowClear: false,
                  items: [
                    UtenDropdownItem(value: 'ALL', label: _l.costTotalLabel),
                    UtenDropdownItem(
                      value: 'MATERIAL',
                      label: _l.costStructure,
                    ),
                    UtenDropdownItem(value: 'FEES', label: _l.costFees),
                  ],
                  onChanged: (v) => update(() => section = v!),
                ),
                if (_selectedPaths.isNotEmpty)
                  CheckboxListTile(
                    title: Text(
                      '${_l.quoteTemplateDownloadSelected} (${_selectedPaths.length})',
                    ),
                    value: selectedOnly,
                    onChanged: (v) => update(() => selectedOnly = v == true),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: Text(_l.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: Text(_l.commonConfirm),
            ),
          ],
        ),
      ),
    );
    if (ready != true || !mounted) return null;
    GoodsCostSnapshot? snapshot = _historical;
    snapshot ??= await _action(() async {
      var sheet = _sheet;
      if (sheet == null || _dirty) sheet = await _saveCurrent();
      if (!sheet.canExport) throw StateError(_l.costNoPermission);
      return _repository.snapshot(sheet.id, sheet.version, const Uuid().v4());
    });
    if (snapshot == null) return null;
    return UtenExportSelection(
      extension: format,
      filename: 'cost_${_sheet?.number ?? snapshot.id}',
      bodyParams: {
        'sheetId': _sheet?.id,
        'snapshotId': snapshot.id,
        'format': format,
        'section': section,
        if (selectedOnly) 'paths': _selectedPaths.toList(),
      },
    );
  }

  String _status(Object? value) => switch (value) {
    'DRAFT' => _l.costDraft,
    'CONFIRMED' => _l.costConfirmed,
    'IN_REVIEW' => _l.costReview,
    'COMPLETE' || 'FINAL' => _l.costComplete,
    'ACTUAL' => _l.bomActualQty,
    'DESIGN' => _l.bomDesignQty,
    'MANUAL' => _l.costManual,
    'ROLLUP' => _l.costComplete,
    'INCOMPLETE' ||
    'INCOMPLETE_ROLLUP' ||
    'UNCONFIRMED' ||
    'NONE' => _l.costPending,
    'APPROVED_PURCHASE' ||
    'PURCHASE_ORDER' ||
    'PURCHASE_RECEIPT' => _l.costApprovedPrice,
    _ => costText(value) ?? '—',
  };
  String _money(Object? value) => financeMoneyText(costText(value));
  TextEditingController _controller(String key, String? initial) => _controllers
      .putIfAbsent(key, () => TextEditingController(text: initial ?? ''));
  Widget _oneLine(Object? text, {TextAlign? align}) {
    final child = Text(
      costText(text) ?? '—',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: align,
    );
    return align == TextAlign.right
        ? Align(alignment: Alignment.centerRight, child: child)
        : child;
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.detail.costMasked ||
        !ref.watch(currentPermissionsProvider).contains(Perm.goodsCostView)) {
      return Center(child: Text(_l.costNoPermission));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    return withFormDraft(
      Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final (index, label) in [
                  (0, _l.costEstimate),
                  (1, _l.costActual),
                  (2, _l.costVersions),
                ])
                  UtenButton(
                    key: ValueKey('cost-tab-$index'),
                    type: _tab == index
                        ? UtenButtonType.primary
                        : UtenButtonType.tonal,
                    onPressed: () => setState(() => _tab = index),
                    child: Text(label),
                  ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Semantics(
                liveRegion: true,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                    UtenButton(
                      type: UtenButtonType.tonal,
                      onPressed: _busy ? null : _preview,
                      child: Text(_l.commonRetry),
                    ),
                  ],
                ),
              ),
            ),
          if (_calculating || _busy) const LinearProgressIndicator(),
          Expanded(
            child: switch (_tab) {
              1 => GoodsCostActualPanel(goodsId: widget.detail.id),
              2 => _versionPane(),
              _ => _estimatePane(),
            },
          ),
        ],
      ),
    );
  }

  Widget _estimatePane() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 60),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        const SizedBox(height: 12),
        _summary(),
        const SizedBox(height: 12),
        if (_historical != null) Text(_l.costSnapshotReadOnly),
        if (_stale && _calculation != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(_l.costCalculationStale),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            UtenButton(
              type: _bodyTab == 0
                  ? UtenButtonType.primary
                  : UtenButtonType.tonal,
              onPressed: () => setState(() => _bodyTab = 0),
              child: Text(_l.costStructure),
            ),
            UtenButton(
              type: _bodyTab == 1
                  ? UtenButtonType.primary
                  : UtenButtonType.tonal,
              onPressed: () => setState(() => _bodyTab = 1),
              child: Text(_l.costFees),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_bodyTab == 0)
          SizedBox(height: _materialHeight, child: _materialTable())
        else
          _feeTable(),
        if (_calculation?.issues.isNotEmpty == true) ...[
          const SizedBox(height: 12),
          for (final issue in _calculation!.issues)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${issue['path'] ?? ''} ${issue['message'] ?? ''}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
        const SizedBox(height: 12),
        _actions(),
      ],
    ),
  );
  Widget _summary() {
    final totals = _calculation?.totals ?? const <String, dynamic>{};
    final currency =
        costText(_calculation?.json['currencyName']) ?? _l.costCurrency;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (label, key) in [
          (_l.costMaterial, 'material'),
          (_l.costProcess, 'process'),
          (_l.costManagement, 'management'),
          (_l.costKnownTotal, 'knownTotal'),
          (_l.costUnitCost, 'unitCost'),
        ])
          SizedBox(
            width: 212,
            child: UtenCard(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  const SizedBox(height: 8),
                  Text(
                    '$currency ${_money(totals[key])}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _actions() => Wrap(
    spacing: 8,
    runSpacing: 8,
    children: [
      if (_editable)
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _importWorkbook,
          child: Text(_l.costImport),
        ),
      if (_editable)
        UtenButton(
          key: const Key('cost-save'),
          onPressed: _save,
          child: Text(_l.costSaveDraft),
        ),
      if (_editable)
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _preview,
          child: Text(_l.costRecalculate),
        ),
      if (_sheet?.canConfirm == true && !_busy && _historical == null)
        UtenButton(
          key: const Key('cost-confirm'),
          onPressed: !_stale && _calculation?.complete == true
              ? _confirm
              : null,
          child: Text(_l.costConfirm),
        ),
      if (_sheet != null && _canCostEdit)
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _busy ? null : _copy,
          child: Text(_l.costCopy),
        ),
      if (_canCostEdit)
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _busy ? null : _new,
          child: Text(_l.costNew),
        ),
      if (_editable &&
          ref
              .watch(currentPermissionsProvider)
              .contains(Perm.goodsCostTemplate))
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _saveTemplate,
          child: Text(_l.costSaveTemplate),
        ),
      if (_sheet?.canExport == true)
        for (final format in ['xlsx', 'pdf'])
          UtenExportButton(
            endpoint: '${DioGoodsCostRepository.base}/export',
            report: '',
            queryParams: const {},
            requiredPermission: Perm.goodsCostExport,
            tableKey: _bodyTab == 0 ? _tableKey : 'master.goods.cost.fees',
            enabled: !_busy,
            label: format == 'xlsx' ? _l.costDownloadExcel : _l.costDownloadPdf,
            prepareExport: () => _prepareDownload(format),
          ),
      if (widget.canEdit)
        UtenButton(
          type: UtenButtonType.tonal,
          onPressed: _busy ? null : _lossPolicy,
          child: Text(_l.costLossPolicy),
        ),
    ],
  );
  Widget _versionPane() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 60),
    child: Column(
      children: [
        SizedBox(
          height: 450,
          child: MasterDataTableView<Map<String, dynamic>>(
            tableKey: 'master.goods.cost.versions',
            columns: [
              _readColumn('name', _l.costName, 220),
              _readColumn(
                'status',
                _l.costStatus,
                130,
                text: (r) => _status(r['status']),
              ),
              _readColumn('version', _l.costVersion, 90),
              _readColumn('batchQty', _l.costBatch, 120),
              _readColumn('knownTotal', _l.costKnownTotal, 150),
              _readColumn('updatedAt', _l.costUpdated, 190),
              MasterColumnDef(
                key: 'action',
                label: _l.costAction,
                width: 120,
                value: (_) => _l.costOpen,
                cellBuilder: (_, row) => UtenButton(
                  type: UtenButtonType.tonal,
                  onPressed: _busy ? null : () => _open(row['id'].toString()),
                  child: Text(_l.costOpen),
                ),
              ),
            ],
            items: _versions,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            emptyMessage: _l.costEmpty,
            toolbarLeadingActions: [
              UtenButton(
                type: UtenButtonType.tonal,
                onPressed: _busy
                    ? null
                    : () => _action(() async {
                        _versions = await _repository.list(widget.detail.id);
                        await _refreshLocalDrafts();
                      }),
                child: Text(_l.commonRefresh),
              ),
              if (_sheet != null)
                UtenButton(
                  type: UtenButtonType.tonal,
                  onPressed: _busy ? null : _compareVersions,
                  child: Text(_l.costCompare),
                ),
              if (_sheet != null)
                UtenButton(
                  type: UtenButtonType.tonal,
                  onPressed: _busy ? null : _showSnapshots,
                  child: Text(_l.costHistory),
                ),
            ],
          ),
        ),
        for (final draft in _localDrafts)
          ListTile(
            title: _oneLine(draft.title),
            subtitle: Text(draft.updatedAt.toIso8601String()),
            trailing: UtenButton(
              type: UtenButtonType.tonal,
              onPressed: _busy ? null : () => _recover(draft),
              child: Text(_l.costRecoverLocal),
            ),
          ),
      ],
    ),
  );
  MasterColumnDef<Map<String, dynamic>> _readColumn(
    String key,
    String label,
    double width, {
    String? Function(Map<String, dynamic>)? text,
    bool defaultVisible = true,
  }) => MasterColumnDef(
    key: key,
    label: label,
    width: width,
    defaultVisible: defaultVisible,
    value: text ?? (r) => costText(r[key]),
    cellBuilder: (_, row) => _oneLine(text?.call(row) ?? row[key]),
  );
  @override
  void dispose() {
    _debounce?.cancel();
    _previewRequest++;
    for (final c in _controllers.values) {
      c.dispose();
    }
    _feeGrid.dispose();
    _calculationSignal.dispose();
    super.dispose();
  }
}
