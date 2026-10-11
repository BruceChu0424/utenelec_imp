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
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/auth/cost_workbench_capability.dart';
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
import 'goods_cost_production_evidence.dart';
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
  static const _tableKey = 'master.goods.cost.items.simple';
  final _controllers = <String, TextEditingController>{};
  final _collapsed = <String>{};
  final _selectedPaths = <String>{};
  final _adjustingPaths = <String>{};
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
  String? _automaticResumeId;
  String? _actualExecutionScope;
  bool _busy = false, _loading = true, _calculating = false, _dirty = false;
  bool _replacingFees = false;
  bool _showSettings = false,
      _showAdvancedSettings = false,
      _settingsLoaded = false,
      _settingsLoading = false,
      _onlyPending = false;
  Future<void>? _previewInFlight;
  int? _previewRevision;
  int _tab = 0, _bodyTab = 0, _inputRevision = 0, _previewRequest = 0;
  int _templateRequest = 0;
  int? _calculatedRevision;
  Timer? _debounce;
  String _saveKey = const Uuid().v4();
  String? _confirmKey;
  String? _copyKey;
  final _feeGrid = UtenEditableGridController<GoodsCostFeeRow>();
  final _feeScroll = ScrollController();
  final _materialOuterScroll = ScrollController();
  final _feePinned = ValueNotifier<bool>(false);
  bool _materialFullscreen = false;
  Completer<void>? _fullscreenClosed;
  GoodsCostRepository get _repository => ref.read(goodsCostRepositoryProvider);
  AppLocalizations get _l => AppLocalizations.of(context);
  CostWorkbenchCapability get _capability =>
      ref.read(costWorkbenchCapabilityProvider);
  bool get _canCostEdit => _capability.canCreate;
  bool get _canSaveDraft =>
      _capability.canEditSheet(
        serverAllowed: _sheet == null || _sheet!.canEdit,
      ) &&
      _historical == null;
  bool get _editable => _canSaveDraft && !_busy;
  bool get _stale => _calculatedRevision != _inputRevision;
  bool get _canDownload => _capability.canExportSheet(
    serverAllowed: _sheet == null ? _capability.canCreate : _sheet!.canExport,
  );
  @override
  String? get formDraftResumeId => _automaticResumeId;
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
        !_capability.canRead ||
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
    if (widget.detail.costMasked || !_capability.canRead) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      _input = _freshInput();
      final versions = await _repository.list(widget.detail.id);
      if (!mounted) return;
      _versions = versions;
      await _refreshLocalDrafts();
      if (!mounted) return;
      final route = goRouterPageStateOrNull(context)?.uri;
      final resumesLocal =
          route?.path == '/basicinfo/goods/${widget.detail.id}' &&
          route?.queryParameters['draftId'] != null;
      if (!resumesLocal && _localDrafts.isNotEmpty) {
        _automaticResumeId = _localDrafts.first.id;
      }
      if (resumesLocal || _automaticResumeId != null) {
        // The selected local draft supplies its own sheet/version. A newer
        // confirmed default sheet must not disable the recovery lifecycle.
        _sheet = null;
      } else if (_versions.isNotEmpty) {
        final latest = await _repository.detail(
          costText(_versions.first['id'])!,
        );
        if (!mounted) return;
        _adopt(latest);
        if (latest.status == 'DRAFT') await _preview();
      } else {
        await _bootstrap();
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

  Future<void> _bootstrap() async {
    final calculation = await _repository.bootstrap(widget.detail.id);
    if (!mounted) return;
    final input = calculation.resolvedInput;
    if (input == null || input['goodsId'] != widget.detail.id) {
      throw StateError(_l.commonError);
    }
    setState(() {
      _sheet = null;
      _historical = null;
      _input = copyCostJson(input);
      _calculation = calculation;
      _inputRevision++;
      _calculatedRevision = _inputRevision;
      _dirty = false;
      _error = null;
      _clientName = costText(costMap(input['extraFields'])['serverClientName']);
      _saveKey = const Uuid().v4();
      _resetEditors();
    });
  }

  Future<void> _loadSettings() async {
    if (_settingsLoaded || _settingsLoading) return;
    final clientId = costText(_input['clientId']);
    final templateRequest = ++_templateRequest;
    setState(() => _settingsLoading = true);
    try {
      final result = await Future.wait<Object>([
        ref.read(currencyRepositoryProvider).dict(),
        _repository.templates(widget.detail.id, clientId),
      ]);
      if (!mounted) return;
      setState(() {
        _currencies = result[0] as List<CurrencyListItem>;
        if (templateRequest == _templateRequest &&
            clientId == costText(_input['clientId'])) {
          _templates = result[1] as List<Map<String, dynamic>>;
        }
        _settingsLoaded = true;
      });
    } catch (e) {
      if (mounted) setState(() => _error = _message(e));
    } finally {
      if (mounted) setState(() => _settingsLoading = false);
    }
  }

  void _toggleSettings() {
    final scroll = _bodyTab == 0 ? _materialOuterScroll : _feeScroll;
    final headerCollapsed = scroll.hasClients && scroll.offset > 0;
    setState(() => _showSettings = headerCollapsed || !_showSettings);
    if (_showSettings) unawaited(_loadSettings());
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
      _adjustingPaths.clear();
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
      _calculationSignal.value++;
      _saveKey = const Uuid().v4();
      _confirmKey = null;
      _copyKey = null;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 550), _preview);
  }

  Future<void> _preview() {
    _previewRevision = _inputRevision;
    final future = _calculatePreview();
    _previewInFlight = future;
    return future;
  }

  Future<void> _calculatePreview() async {
    if (!mounted ||
        widget.detail.costMasked ||
        !_capability.canRead ||
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
      _calculatedRevision = null;
      _calculationSignal.value++;
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

  Future<T?> _action<T>(
    Future<T> Function() run, {
    bool preservePreview = false,
  }) async {
    if (_busy) return null;
    FocusScope.of(context).unfocus();
    _debounce?.cancel();
    setState(() {
      if (!preservePreview) {
        _previewRequest++;
        _calculating = false;
      }
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
    if (!_capability.canEditSheet(
          serverAllowed: _sheet == null || _sheet!.canEdit,
        ) ||
        _historical != null) {
      throw StateError(_l.costNoPermission);
    }
    if (_stale) {
      if (_previewRevision == _inputRevision) await _previewInFlight;
      if (_stale) await _preview();
      if (_stale) throw StateError(_error ?? _l.costCalculationStale);
    }
    if (!mounted) throw StateError('Cost workbench is no longer mounted');
    if (!_capability.canEditSheet(
          serverAllowed: _sheet == null || _sheet!.canEdit,
        ) ||
        _historical != null) {
      throw StateError(_l.costNoPermission);
    }
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
    final saved = await _action(_saveCurrent, preservePreview: true);
    if (saved != null && mounted) context.appSuccess(_l.costSaved);
  }

  Future<void> _confirm() async {
    if (_stale ||
        _calculation?.complete != true ||
        _historical != null ||
        !_capability.canConfirmSheet(
          serverAllowed: _sheet?.canConfirm == true,
        )) {
      return;
    }
    final ok = await UtenDialog.show(
      context,
      title: _l.costConfirm,
      content: Text(_l.costConfirmPrompt),
      confirmLabel: _l.commonConfirm,
      cancelLabel: _l.commonCancel,
    );
    if (ok != true ||
        !mounted ||
        _stale ||
        _calculation?.complete != true ||
        _historical != null ||
        !_capability.canConfirmSheet(
          serverAllowed: _sheet?.canConfirm == true,
        )) {
      return;
    }
    await _action(() async {
      var sheet = _sheet;
      if (sheet == null || _dirty) sheet = await _saveCurrent();
      if (!_capability.canConfirmSheet(serverAllowed: sheet.canConfirm) ||
          !sheet.calculation.complete) {
        throw StateError(_l.costNoPermission);
      }
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
    if (!_capability.canCreate) return;
    if (_dirty) {
      context.appError(_l.costLeavePrompt);
      return;
    }
    await resetFormDraftAfterSubmission(
      prepare: () async {
        await _bootstrap();
      },
    );
    if (mounted) {
      setState(() => _tab = 0);
    }
  }

  Future<void> _open(String id) async {
    await _leaveMaterialFullscreen();
    if (!mounted) return;
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
    if (existing == null || !_capability.canCreate) return;
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
    await _leaveMaterialFullscreen();
    if (!mounted) return;
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

  Future<UtenExportSelection?> _prepareDownload(String? initialFormat) async {
    if (!_canDownload) return null;
    var format = initialFormat ?? 'xlsx';
    var advanced = false;
    var section = _bodyTab == 1 ? 'FEES' : 'ALL';
    var selectedOnly = false;
    final ready = await _dialogWhenRemoved<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(_l.costDownload),
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenDropdownField(
                  label: _l.costDownloadFormat,
                  value: format,
                  allowClear: false,
                  items: const [
                    UtenDropdownItem(value: 'xlsx', label: 'Excel'),
                    UtenDropdownItem(value: 'pdf', label: 'PDF'),
                  ],
                  onChanged: (v) => update(() => format = v!),
                ),
                TextButton(
                  onPressed: () => update(() => advanced = !advanced),
                  child: Text(_l.costAdvancedOptions),
                ),
                if (advanced) ...[
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
    if (ready != true || !mounted || !_canDownload) {
      return null;
    }
    GoodsCostSnapshot? snapshot = _historical;
    snapshot ??= await _action(() async {
      var sheet = _sheet;
      if (sheet == null || _dirty) sheet = await _saveCurrent();
      if (!_capability.canExportSheet(serverAllowed: sheet.canExport)) {
        throw StateError(_l.costNoPermission);
      }
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
    'KNOWN' => _l.costPriceAvailable,
    'MISSING' || 'MISSING_PRICE' => _l.costMissingPriceInput,
    'AUTO' => _l.costAutoPrice,
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
  Widget _oneLine(Object? text) =>
      Text(costText(text) ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.detail.costMasked ||
        !ref.watch(costWorkbenchCapabilityProvider).canRead) {
      return Center(child: Text(_l.costNoPermission));
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    return withFormDraft(
      Column(
        children: [
          if (_tab != 0)
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: Row(
                children: [
                  UtenButton(
                    key: const Key('cost-return-table'),
                    type: UtenButtonType.tonal,
                    onPressed: () => setState(() => _tab = 0),
                    child: Text(_l.costReturnToTable),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _tab == 1 ? _l.costActualEvidence : _l.costSavedHistory,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
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
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
              1 => GoodsCostActualPanel(
                key: ValueKey(_actualExecutionScope),
                goodsId: widget.detail.id,
                executionSegmentId: _actualExecutionScope,
              ),
              2 => _versionPane(),
              _ => _estimatePane(),
            },
          ),
        ],
      ),
    );
  }

  Widget _estimatePane() {
    if (_bodyTab == 1) {
      return Stack(
        children: [
          Positioned.fill(
            child: UtenGridPageScrollbar(
              pinned: _feePinned,
              controller: _feeScroll,
              child: ListView(
                controller: _feeScroll,
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s12,
                  0,
                  UtenSpacing.s12,
                  UtenFloatingActionGroup.scrollClearance,
                ),
                children: [_header(), _feeTable()],
              ),
            ),
          ),
          if (_canSaveDraft)
            PositionedDirectional(
              end: UtenSpacing.s16,
              bottom: UtenSpacing.s16,
              child: UtenFloatingActionGroup(children: _saveActions()),
            ),
        ],
      );
    }
    return UtenCollapsingHeaderScrollView(
      key: const Key('cost-collapsing-scroll'),
      controller: _materialOuterScroll,
      collapsingHeader: Padding(
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        child: _header(),
      ),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        child: _materialTable(),
      ),
    );
  }

  List<Map<String, dynamic>> get _pendingIssues =>
      _calculation?.issues ?? const [];
  String _currentMoney(Object? value) => _stale ? '…' : _money(value);
  Widget _costSummary() => UtenTotalsSummaryBar(
    entries: [
      UtenTotalEntry(
        _calculation?.complete == true
            ? _l.costTotalLabel
            : _l.costKnownPartial,
        '${costText(_calculation?.json['currencyName']) ?? ''} ${_currentMoney(_calculation?.totals['knownTotal'])}',
      ),
      UtenTotalEntry(
        _l.costUnitCost,
        _currentMoney(_calculation?.totals['unitCost']),
      ),
      UtenTotalEntry(
        _l.costStatus,
        _stale
            ? _l.costCalculationStale
            : _status(_calculation?.totals['valueState']),
      ),
    ],
  );
  List<Widget> _saveActions() => [
    if (_canSaveDraft)
      UtenButton(
        key: const Key('cost-save'),
        type: UtenButtonType.danger,
        size: UtenButtonSize.large,
        icon: Icons.save_outlined,
        isLoading: _busy,
        onPressed: _busy ? null : _save,
        child: Text(_l.costSaveDraft),
      ),
  ];
  List<Widget> _tableActions() => [
    if (_editable)
      UtenButton(
        key: const Key('cost-add-column'),
        height: UtenTableToolbar.controlHeight,
        onPressed: _addPriceColumn,
        child: Text(_l.costAddPriceColumn),
      ),
    UtenButton(
      key: const Key('cost-settings-toggle'),
      height: UtenTableToolbar.controlHeight,
      onPressed: () async {
        await _leaveMaterialFullscreen();
        if (mounted) {
          _toggleSettings();
          _revealCostHeader();
        }
      },
      child: Text(_l.costCalculationSettings),
    ),
    if (_canDownload)
      UtenExportButton(
        key: const Key('cost-download'),
        endpoint: '${DioGoodsCostRepository.base}/export',
        report: '',
        queryParams: const {},
        requiredPermission: CostWorkbenchCapability.exportPermission,
        height: UtenTableToolbar.controlHeight,
        icon: null,
        type: UtenButtonType.primary,
        tableKey: _bodyTab == 0 ? _tableKey : 'master.goods.cost.fees',
        enabled: !_busy,
        label: _l.costDownload,
        prepareExport: () => _prepareDownload(null),
      ),
    if (_pendingIssues.isNotEmpty)
      UtenButton(
        key: const Key('cost-pending-filter'),
        height: UtenTableToolbar.controlHeight,
        onPressed: () => setState(() => _onlyPending = !_onlyPending),
        child: Text(_onlyPending ? _l.costAllMaterials : _l.costOnlyPending),
      ),
    UtenButton(
      key: const Key('cost-more'),
      height: UtenTableToolbar.controlHeight,
      onPressed: _busy
          ? null
          : () async {
              await _leaveMaterialFullscreen();
              if (mounted) await _moreActions();
            },
      child: Text(_l.costMoreActions),
    ),
  ];
  Future<void> _leaveMaterialFullscreen() async {
    if (_fullscreenClosed != null) {
      await _fullscreenClosed!.future;
      return;
    }
    if (!_materialFullscreen) return;
    final closed = _fullscreenClosed ??= Completer<void>();
    Navigator.of(context, rootNavigator: true).pop();
    await closed.future;
  }

  void _revealCostHeader() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scroll = _bodyTab == 0 ? _materialOuterScroll : _feeScroll;
      if (scroll.hasClients) {
        scroll.animateTo(0, duration: UtenAnim.fast, curve: Curves.easeOut);
      }
    });
  }

  Future<void> _moreActions() async {
    final actions = <(String, Future<void> Function())>[
      (
        _l.costActualEvidence,
        () async {
          setState(() {
            _actualExecutionScope = null;
            _tab = 1;
          });
        },
      ),
      (
        _l.costSavedHistory,
        () async {
          setState(() => _tab = 2);
        },
      ),
      (
        _bodyTab == 0 ? _l.costFees : _l.costStructure,
        () async {
          setState(() => _bodyTab = _bodyTab == 0 ? 1 : 0);
        },
      ),
      if (_editable) (_l.costRefreshSources, _preview),
      if (_capability.canConfirmSheet(
            serverAllowed: _sheet?.canConfirm == true,
          ) &&
          _historical == null &&
          !_stale &&
          _calculation?.complete == true)
        (_l.costConfirm, _confirm),
      if (_sheet != null && _canCostEdit) (_l.costCopy, _copy),
      if (_canCostEdit) (_l.costNew, _new),
      if (_editable && _capability.canManageTemplates)
        (_l.costSaveTemplate, _saveTemplate),
      if (_editable) (_l.costImport, _importWorkbook),
      if (widget.canEdit) (_l.costLossPolicy, _lossPolicy),
      if (_sheet != null) (_l.costCompare, _compareVersions),
      if (_sheet != null) (_l.costHistory, _showSnapshots),
    ];
    final selected = await _dialogWhenRemoved<int>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costMoreActions),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < actions.length; i++)
                  ListTile(
                    title: Text(actions[i].$1),
                    onTap: () => Navigator.pop(dialog, i),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonCancel),
          ),
        ],
      ),
    );
    if (selected != null && mounted) await actions[selected].$2();
  }

  Future<void> _showCalculationIssues() async {
    final rows = [
      for (final issue in _pendingIssues)
        {
          ...issue,
          'goodsName':
              _costLinesByPath[issue['path']]?['goodsName'] ??
              _l.costTotalLabel,
          'goodsCode': _costLinesByPath[issue['path']]?['goodsCode'],
        },
    ];
    final selected = await _dialogWhenRemoved<Map<String, dynamic>>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(_l.costNeedsReviewCount(rows.length)),
        content: SizedBox(
          width: 1000,
          height: MediaQuery.sizeOf(context).height * .6,
          child: MasterDataTableView<Map<String, dynamic>>(
            tableKey: 'master.goods.cost.pending',
            columns: [
              _readColumn('goodsName', _l.costGoodsName, 220),
              _readColumn('goodsCode', _l.costGoodsCode, 120),
              MasterColumnDef(
                key: 'message',
                label: _l.costPendingItems,
                width: 460,
                value: (r) => costText(r['message']),
                cellBuilder: (_, r) => Tooltip(
                  message: costText(r['message']) ?? '',
                  child: _oneLine(r['message']),
                ),
              ),
              MasterColumnDef(
                key: 'adjust',
                label: _l.costAdjustment,
                width: 130,
                value: (_) => _l.costAdjustment,
                cellBuilder: (_, r) => UtenTableCellAction(
                  label: _l.costAdjustment,
                  onPressed: () => Navigator.pop(dialog, r),
                ),
              ),
            ],
            items: rows,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(_l.commonBack),
          ),
        ],
      ),
    );
    if (selected != null && mounted) {
      setState(() {
        _bodyTab = 0;
        _onlyPending = true;
        _adjustingPaths.add(selected['path'].toString());
      });
    }
  }

  Widget _versionPane() => UtenCollapsingHeaderScrollView(
    collapsingHeader: _localDrafts.isEmpty
        ? null
        : Column(
            children: [
              for (final draft in _localDrafts)
                ListTile(
                  title: _oneLine(draft.title),
                  subtitle: _oneLine(draft.updatedAt.toIso8601String()),
                  trailing: UtenButton(
                    onPressed: _busy ? null : () => _recover(draft),
                    child: Text(_l.costRecoverLocal),
                  ),
                ),
            ],
          ),
    body: Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
      child: MasterDataTableView<Map<String, dynamic>>(
        tableKey: 'master.goods.cost.versions',
        primary: true,
        onFullscreenChanged: (value) {
          _materialFullscreen = value;
          if (!value) {
            _fullscreenClosed?.complete();
            _fullscreenClosed = null;
          }
        },
        columns: [
          _readColumn(
            'status',
            _l.costStatus,
            72,
            text: (r) => _status(r['status']),
          ),
          _readColumn('name', _l.costName, 220),
          for (final (key, label, width) in [
            ('version', _l.costVersion, 90.0),
            ('batchQty', _l.costBatch, 120.0),
            ('knownTotal', _l.costKnownTotal, 150.0),
          ])
            MasterColumnDef(
              key: key,
              label: label,
              width: width,
              type: key == 'knownTotal' ? 'money' : 'number',
              aiSensitive: key == 'knownTotal',
              value: (r) => costText(r[key]),
              exactValueOf: (r) => costText(r[key]),
              cellBuilder: (_, r) => _oneLine(r[key]),
            ),
          _readColumn('updatedAt', _l.costUpdated, 190),
          MasterColumnDef(
            key: 'action',
            label: _l.costAction,
            width: 120,
            value: (_) => _l.costOpen,
            cellBuilder: (_, row) => UtenTableCellAction(
              label: _l.costOpen,
              onPressed: _busy ? null : () => _open(row['id'].toString()),
            ),
          ),
        ],
        items: _versions,
        rowKeyOf: (r) => r['id'].toString(),
        rowMenuBuilder: (row) => [
          UtenMenuItem(
            label: _l.costOpen,
            onTap: () => _open(row['id'].toString()),
            enabled: !_busy,
          ),
        ],
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        emptyMessage: _l.costEmpty,
        toolbarLeadingActions: [
          if (_sheet != null)
            UtenButton(
              height: UtenTableToolbar.controlHeight,
              onPressed: _busy ? null : _compareVersions,
              child: Text(_l.costCompare),
            ),
          if (_sheet != null)
            UtenButton(
              height: UtenTableToolbar.controlHeight,
              onPressed: _busy ? null : _showSnapshots,
              child: Text(_l.costHistory),
            ),
        ],
        toolbarActions: [
          UtenButton(
            height: UtenTableToolbar.controlHeight,
            onPressed: _busy
                ? null
                : () => _action(() async {
                    _versions = await _repository.list(widget.detail.id);
                    await _refreshLocalDrafts();
                  }),
            child: Text(_l.commonRefresh),
          ),
        ],
      ),
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
    _feeScroll.dispose();
    _materialOuterScroll.dispose();
    _feePinned.dispose();
    _calculationSignal.dispose();
    super.dispose();
  }
}
