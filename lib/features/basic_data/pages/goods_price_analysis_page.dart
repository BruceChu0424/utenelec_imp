import '../widgets/goods_subcontract_supplier_table.dart';
import '../widgets/goods_price_facet_picker.dart';
import '../models/master_facet.dart';
import 'dart:convert';
import '../../../shared/models/paged_result.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../widgets/goods_price_observation_detail.dart';
import '../widgets/master_data_table_view.dart';
import '../../../components/buttons/uten_refresh_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../widgets/goods_price_history_chart.dart';
import '../widgets/goods_material_market_panel.dart';
import 'package:flutter/material.dart';
import 'package:uten_imp/components/inputs/uten_input_decoration.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../../shared/pricing/price_analysis_l10n.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../../../shared/pricing/price_analysis_repository.dart';
import '../../../shared/pricing/price_summary_value.dart';

class GoodsPriceAnalysisPage extends ConsumerStatefulWidget {
  const GoodsPriceAnalysisPage({super.key, required this.goodsId});
  final String goodsId;
  @override
  ConsumerState<GoodsPriceAnalysisPage> createState() =>
      _GoodsPriceAnalysisPageState();
}

class _GoodsPriceAnalysisPageState extends ConsumerState<GoodsPriceAnalysisPage>
    with NativeReadViewScopeMixin<GoodsPriceAnalysisPage> {
  String _kind = 'PURCHASE';
  int _days = 90;
  bool _advanced = false;
  PriceObservation? _selectedRow;
  int _contextRevision = 0;
  final _quantity = TextEditingController();
  final _margin = TextEditingController();
  final _filters = <String, String>{};
  final _options = <String, Map<String, String>>{};
  GoodsPriceAnalysis? _analysis;
  Map<String, dynamic>? _supplierResult;
  bool _supplierApplicable = false, _supplierLoading = false;
  int _supplierRevision = 0;
  String? _supplierError;
  String _subcontractView = 'prices';
  bool _loading = false;
  String? _error;
  PagedResult<PriceObservation>? _historyPage;
  bool _historyTableMode = false;
  final _tableFilters = <String, String?>{};
  final _selectedFacetBuckets = <String, MasterFacetBucket>{};
  String? _tableSort = 'businessDate';
  bool _tableAscending = false;
  String? _tableContext;
  String? _historyError;
  bool _historyLoading = false;
  int _historyRevision = 0;
  bool get _allowed =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsView,
        Perm.goodsPriceAnalysisView,
      });
  String get _identity => '${widget.goodsId}|$_kind|$_days|$_contextRevision';
  bool get _historyOnly =>
      _kind == 'SALES' &&
      !ref.read(isSuperAdminProvider) &&
      ref
          .read(currentPermissionsProvider)
          .contains(Perm.salesQuoteFinanceView) &&
      !ref.read(currentPermissionsProvider).containsAll({
        Perm.salesOrderView,
        Perm.salesOrderPriceView,
      });

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (_, _) {
      invalidateNativeReadAccess();
      _tableContext = null;
      _options.clear();
      _clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _load();
      });
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant GoodsPriceAnalysisPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.goodsId != oldWidget.goodsId) {
      _filters.clear();
      _options.clear();
      _clear();
      _load();
    }
  }

  @override
  void nativeReadOwnerChanged() {
    _tableContext = null;
    _options.clear();
    _filters.clear();
    _clear();
  }

  @override
  void nativeReadPermissionChanged() {
    _tableContext = null;
    _options.clear();
    _clear();
  }

  @override
  Future<void> nativeReadReload() => _load();
  void _clear() {
    if (!mounted) return;
    setState(() {
      _analysis = null;
      _supplierResult = null;
      _supplierApplicable = false;
      _supplierLoading = false;
      _supplierError = null;
      _supplierRevision++;
      _error = null;
      _loading = false;
      _selectedRow = null;
      _historyPage = null;
      _historyTableMode = false;
      if (_tableContext != _identity) {
        _tableFilters.clear();
        _selectedFacetBuckets.clear();
        _tableSort = 'businessDate';
        _tableAscending = false;
      }
      _tableContext = _identity;
      _historyError = null;
      _historyLoading = false;
      _historyRevision++;
    });
  }

  void _edited() {
    _contextRevision++;
    invalidateNativeReadAccess();
    _clear();
  }

  Future<void> _load() async {
    if (!mounted || !_allowed) return;
    final accepts = captureNativeRead(_identity, () => _identity);
    if (!accepts()) return;
    final restoreHistory = _historyTableMode;
    // A fresh native read supersedes every pending history cursor as well.
    // Otherwise a discarded history response could leave its spinner locked.
    _clear();
    if (_historyOnly) {
      setState(() {
        _analysis = null;
        _loading = true;
        _error = null;
      });
      try {
        final result = await ref
            .read(priceAnalysisRepositoryProvider)
            .historyTable(widget.goodsId, _tableParameters(1));
        if (!accepts() || !_allowed || !_historyOnly) return;
        acceptNativeRead();
        setState(() {
          _historyPage = result;
          _historyTableMode = true;

          _loading = false;
          _mergeChoices(result.items);
        });
      } catch (error) {
        if (!accepts() || !_allowed) return;
        setState(() {
          _loading = false;
          _error = error is ApiException
              ? error.message
              : priceText(context, 'UNAVAILABLE');
        });
      }
      return;
    }
    final quantity = financeExactDecimal(_quantity.text);
    final margin = financeExactDecimal(_margin.text);
    if ((_quantity.text.trim().isNotEmpty &&
            (quantity == null || (double.tryParse(quantity) ?? 0) <= 0)) ||
        (_kind == 'SALES' &&
            _margin.text.trim().isNotEmpty &&
            (margin == null ||
                (double.tryParse(margin) ?? -1) < 0 ||
                (double.tryParse(margin) ?? 100) >= 100))) {
      setState(() {
        _error = priceText(
          context,
          _quantity.text.trim().isNotEmpty &&
                  (quantity == null || (double.tryParse(quantity) ?? 0) <= 0)
              ? 'invalidQuantity'
              : 'invalidMargin',
        );
        _loading = false;
      });
      return;
    }
    setState(() {
      _analysis = null;
      _loading = true;
      _error = null;
      _selectedRow = null;
    });
    try {
      final result = await ref.read(priceAnalysisRepositoryProvider).analysis(
        widget.goodsId,
        {
          'kind': _kind,
          'days': _days,
          'quantity': ?quantity,
          ..._filters,
          if (_kind == 'SALES' && margin != null)
            'targetMarginRate': financeExactMultiplyTexts([margin, '0.01']),
        },
      );
      if (!accepts() || !_allowed) return;
      final supplierApplicable = _kind == 'SUBCONTRACT'
          ? await ref
                .read(priceAnalysisRepositoryProvider)
                .subcontractApplicable(widget.goodsId)
          : false;
      if (!accepts() || !_allowed) return;
      _mergeChoices(result.observations);
      acceptNativeRead();
      setState(() {
        _analysis = result;
        _supplierApplicable = supplierApplicable;
        _loading = false;
      });
      _primeContextChoices();
      if (restoreHistory) _loadHistoryTable(1);
      if (_supplierApplicable && _subcontractView == 'suppliers') {
        _loadSuppliers();
      }
    } catch (error) {
      if (!accepts() || !_allowed) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : priceText(context, 'UNAVAILABLE');
      });
    }
  }

  void _mergeChoices(List<PriceObservation> rows) {
    for (final row in rows) {
      for (final entry in [
        (_kind == 'SALES' ? 'clientId' : 'supplierId', 'partnerName'),
        ('currencyId', 'currencyName'),
        ('colorId', 'colorName'),
        ('taxRate', 'taxRate'),
      ]) {
        final id = row.text(entry.$1), label = row.text(entry.$2);
        if (id.isNotEmpty && label.isNotEmpty) {
          _options.putIfAbsent(entry.$1, () => {})[id] = label;
        }
      }
      final unit = row.text('unitId'), rate = row.text('unitRate');
      if (unit.isNotEmpty && row.text('unitName').isNotEmpty) {
        _options.putIfAbsent('unitId', () => {})['$unit|$rate'] =
            '${row.text('unitName')}${rate.isEmpty || priceNumber(rate) == '1' ? '' : ' ×${priceNumber(rate)}'}';
      }
    }
  }

  Future<void> _primeContextChoices() async {
    final owns = captureNativeOwnership();
    final identity = _identity;
    try {
      // History can discover a quoted box/unit or colour even when the current
      // basic unit has no comparable transactions. No UUID is shown as a label.
      final history = await ref.read(priceAnalysisRepositoryProvider).history(
        widget.goodsId,
        {'kind': _kind, 'pageSize': 50},
      );
      if (!mounted ||
          !owns() ||
          identity != _identity ||
          !_allowed ||
          !nativeReadAccessConfirmed) {
        return;
      }
      setState(() => _mergeChoices(history.observations));
    } catch (_) {
      /* The main evidence remains readable; history has its own retry. */
    }
  }

  String? _choiceValue(String key) => key == 'unitId' && _filters[key] != null
      ? '${_filters[key]}|${_filters['unitRate'] ?? ''}'
      : _filters[key];

  void _selectContext(String key, String? value) {
    if (key == 'unitId') {
      _filters.remove('unitRate');
      if (value != null) {
        final parts = value.split('|');
        _filters[key] = parts.first;
        if (parts.length == 2 && parts.last.isNotEmpty) {
          _filters['unitRate'] = parts.last;
        }
      } else {
        _filters.remove(key);
      }
    } else if (value == null) {
      _filters.remove(key);
    } else {
      _filters[key] = value;
    }
    _edited();
    _load();
  }

  Future<void> _loadSuppliers() async {
    if (!mounted ||
        !_allowed ||
        !nativeReadAccessConfirmed ||
        !_supplierApplicable) {
      return;
    }
    final owns = captureNativeOwnership();
    final identity = _identity;
    final revision = ++_supplierRevision;
    setState(() {
      _supplierLoading = true;
      _supplierResult = null;
      _supplierError = null;
    });
    try {
      final result = await ref
          .read(priceAnalysisRepositoryProvider)
          .subcontractSuppliers(widget.goodsId, {
            'days': _days,
            'supplierId': ?_filters['supplierId'],
          });
      if (!mounted ||
          !owns() ||
          !_allowed ||
          !nativeReadAccessConfirmed ||
          identity != _identity ||
          revision != _supplierRevision) {
        return;
      }
      setState(() {
        _supplierLoading = false;
        _supplierResult = result;
        _supplierApplicable = result['applicable'] == true;
        if (!_supplierApplicable) _subcontractView = 'prices';
      });
    } catch (e) {
      if (!mounted ||
          !owns() ||
          identity != _identity ||
          revision != _supplierRevision) {
        return;
      }
      setState(() {
        _supplierLoading = false;
        _supplierError = e is ApiException
            ? e.message
            : priceText(context, 'UNAVAILABLE');
      });
    }
  }

  Future<void> _openSupplier(Map<String, dynamic> group) async {
    if (!nativeReadAccessConfirmed || !_allowed) return;
    final owns = captureNativeOwnership();
    final source = await showUtenAdaptivePanel<Object?>(
      context: context,
      drawerWidth: 980,
      builder: (panelContext) => trackNativeReadDialog(
        panelContext,
        GoodsSubcontractSupplierDetail(
          goodsId: widget.goodsId,
          days: _days,
          group: group,
          onRefresh: () {
            Navigator.pop(panelContext);
            _load();
          },
        ),
        readOnly: true,
      ),
    );
    if (source is String && mounted && owns() && nativeReadAccessConfirmed) {
      final path = '/subcontract/orders/${Uri.encodeComponent(source)}';
      if (locationAllowedFor(
        ref.read(currentPermissionsProvider),
        ref.read(isSuperAdminProvider),
        path,
      )) {
        await context.push(path);
        if (mounted && owns()) _load();
      }
    }
  }

  Future<void> _open(PriceObservation row) async {
    if (!nativeReadAccessConfirmed || !_allowed) return;
    final owns = captureNativeOwnership();
    final source = await showUtenAdaptivePanel<Object?>(
      context: context,
      drawerWidth: 540,
      builder: (panelContext) => trackNativeReadDialog(
        panelContext,
        GoodsPriceObservationDetail(
          goodsId: widget.goodsId,
          kind: _kind,
          row: row,
          onReloadHistory: () {
            Navigator.pop(panelContext);
            _load();
          },
        ),
        readOnly: true,
      ),
    );
    if (source is PriceObservation &&
        mounted &&
        owns() &&
        nativeReadAccessConfirmed) {
      await _openSource(source);
    }
  }

  void _showBasis(GoodsPriceAnalysis data) {
    if (!nativeReadAccessConfirmed || !_allowed) return;
    showUtenAdaptivePanel<void>(
      context: context,
      drawerWidth: 500,
      widthFraction: UtenPanelWidth.form,
      builder: (panelContext) => trackNativeReadDialog(
        panelContext,
        _PriceBasisPanel(
          data: data,
          onClose: () => Navigator.pop(panelContext),
        ),
        readOnly: true,
      ),
    );
  }

  Future<void> _openSource(PriceObservation row) async {
    if (!nativeReadAccessConfirmed ||
        !_allowed ||
        row.data['canOpenSource'] != true) {
      return;
    }
    final id = row.text('sourceId');
    if (id.isEmpty) return;
    final path = switch (row.text('sourceType')) {
      'PURCHASE_ORDER' => '/purchase/orders/${Uri.encodeComponent(id)}',
      'SUBCONTRACT_ORDER' => '/subcontract/orders/${Uri.encodeComponent(id)}',
      'SALES_ORDER' => '/sales/orders/${Uri.encodeComponent(id)}',
      _ => null,
    };
    if (path == null ||
        !locationAllowedFor(
          ref.read(currentPermissionsProvider),
          ref.read(isSuperAdminProvider),
          path,
        )) {
      return;
    }
    final owns = captureNativeOwnership();
    await context.push(path);
    if (owns() && mounted) await _load();
  }

  Map<String, dynamic> _tableParameters(int page) => {
    'kind': _kind,
    ..._filters,
    'page': page,
    'size': 50,
    if (_tableSort != null) 'sort': _tableSort,
    'ascending': _tableAscending,
    'filters': jsonEncode(_tableFilters),
  };
  Future<void> _loadHistoryTable(int page) async {
    if (!mounted || !_allowed || !nativeReadAccessConfirmed) return;
    final owns = captureNativeOwnership();
    final identity = _identity;
    final revision = ++_historyRevision;
    setState(() {
      _historyTableMode = true;
      _historyLoading = true;
      _historyError = null;
      _selectedRow = null;
    });
    try {
      final result = await ref
          .read(priceAnalysisRepositoryProvider)
          .historyTable(widget.goodsId, _tableParameters(page));
      if (!mounted ||
          !owns() ||
          !_allowed ||
          identity != _identity ||
          revision != _historyRevision ||
          !nativeReadAccessConfirmed) {
        return;
      }
      setState(() {
        _historyPage = result;
        _historyLoading = false;
        _mergeChoices(result.items);
      });
    } catch (error) {
      if (!mounted ||
          !owns() ||
          identity != _identity ||
          revision != _historyRevision) {
        return;
      }
      setState(() {
        _historyLoading = false;
        _historyError = error is ApiException
            ? error.message
            : priceText(context, 'UNAVAILABLE');
      });
    }
  }

  Future<void> _pickFullFacet() async {
    if (!nativeReadAccessConfirmed || !_allowed) return;
    final owns = captureNativeOwnership();
    final result = await showUtenAdaptivePanel<Object?>(
      context: context,
      drawerWidth: 520,
      widthFraction: UtenPanelWidth.form,
      builder: (panelContext) => trackNativeReadDialog(
        panelContext,
        GoodsPriceFacetPicker(
          goodsId: widget.goodsId,
          query: _tableParameters(1),
        ),
        readOnly: true,
      ),
    );
    if (result is (String, MasterFacetBucket) &&
        mounted &&
        owns() &&
        nativeReadAccessConfirmed) {
      _selectedFacetBuckets[result.$1] = result.$2;
      _tableFilterChanged(result.$1, result.$2.value);
    }
  }

  Map<String, List<MasterFacetBucket>> _historyFacets() {
    final result = <String, List<MasterFacetBucket>>{
      for (final entry
          in (_historyPage?.facets ?? <String, List<MasterFacetBucket>>{})
              .entries)
        entry.key: [...entry.value],
    };
    for (final entry in _tableFilters.entries) {
      final value = entry.value;
      if (value == null || value == kMasterFilterNullValue) continue;
      final buckets = result.putIfAbsent(entry.key, () => []);
      if (!buckets.any((bucket) => bucket.value == value)) {
        final remembered = _selectedFacetBuckets[entry.key];
        buckets.add(
          MasterFacetBucket(
            value: value,
            label: remembered?.value == value
                ? remembered?.label
                : entry.key == 'lifecycle'
                ? priceText(context, value)
                : null,
            count: _historyPage?.total ?? 0,
          ),
        );
      }
    }
    return result;
  }

  void _tableFilterChanged(String key, String? value) {
    if (_tableFilters[key] == value ||
        (_tableFilters[key] == null && value?.isEmpty == true)) {
      return;
    }
    if (value == null || value.isEmpty) {
      _tableFilters.remove(key);
      _selectedFacetBuckets.remove(key);
    } else {
      _tableFilters[key] = value;
    }
    _historyPage = null;
    _loadHistoryTable(1);
  }

  void _tableSortChanged(String? column, bool ascending) {
    final equivalent =
        (_tableSort ?? 'businessDate') == (column ?? 'businessDate') &&
        (_tableSort == null ? false : _tableAscending) ==
            (column == null ? false : ascending);
    _tableSort = column;
    _tableAscending = column == null ? false : ascending;
    if (equivalent) {
      setState(() {});
      return;
    }
    _historyPage = null;
    _loadHistoryTable(1);
  }

  @override
  void dispose() {
    _quantity.dispose();
    _margin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final data = nativeReadAccessConfirmed && _allowed ? _analysis : null;
    final canShowRows = nativeReadAccessConfirmed && _allowed;
    final supplierMode =
        _kind == 'SUBCONTRACT' &&
        _supplierApplicable &&
        _subcontractView == 'suppliers';
    return Scaffold(
      appBar: UtenAppBar(
        title: priceText(context, 'title'),
        subtitle: data == null
            ? null
            : '${data.text('goodsCode')} · ${data.text('goodsName')}',
        leading: UtenBackButton(
          onPressed: () => backTo(
            context,
            defaultPath:
                '/basicinfo/goods/${Uri.encodeComponent(widget.goodsId)}',
          ),
        ),
        actions: [
          UtenRefreshButton(
            enabled: _allowed,
            busy: _loading,
            onRefresh: _load,
            tooltip: priceText(context, 'retry'),
          ),
        ],
      ),
      body: !_allowed
          ? UtenEmpty(message: priceText(context, 'denied'))
          : LayoutBuilder(
              builder: (context, box) {
                final compact = box.maxWidth < 720;
                final spacing = compact ? UtenSpacing.s12 : UtenSpacing.s24;
                return Stack(
                  children: [
                    UtenCollapsingHeaderScrollView(
                      collapsingHeader: Padding(
                        padding: EdgeInsets.all(spacing),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: UtenSpacing.s8,
                              runSpacing: UtenSpacing.s8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                UtenSegmentedFilter<String>(
                                  segments: [
                                    for (final kind in [
                                      'PURCHASE',
                                      'SUBCONTRACT',
                                      'SALES',
                                    ])
                                      UtenSegment(
                                        value: kind,
                                        label: priceText(context, kind),
                                      ),
                                  ],
                                  selected: _kind,
                                  onChanged: (kind) {
                                    if (_kind != kind) {
                                      _kind = kind;
                                      _subcontractView = 'prices';
                                      _filters.clear();
                                      _options.clear();
                                      _edited();
                                      _load();
                                    }
                                  },
                                ),
                                TextButton.icon(
                                  onPressed: () =>
                                      setState(() => _advanced = !_advanced),
                                  icon: Icon(
                                    _advanced ? Icons.expand_less : Icons.tune,
                                  ),
                                  label: Text(priceText(context, 'filter')),
                                ),
                              ],
                            ),
                            const SizedBox(height: UtenSpacing.s12),
                            _controls(context),
                            if (_kind == 'PURCHASE' &&
                                nativeReadAccessConfirmed) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              GoodsMaterialMarketPanel(
                                key: ValueKey('material-market-$_identity'),
                                goodsId: widget.goodsId,
                                contextIdentity: _identity,
                              ),
                            ],
                            if (_kind == 'SUBCONTRACT' &&
                                _supplierApplicable) ...[
                              const SizedBox(height: UtenSpacing.s12),
                              UtenSegmentedFilter<String>(
                                segments: [
                                  UtenSegment(
                                    value: 'prices',
                                    label: priceText(context, 'history'),
                                  ),
                                  UtenSegment(
                                    value: 'suppliers',
                                    label: priceText(
                                      context,
                                      'supplierLossTitle',
                                    ),
                                  ),
                                ],
                                selected: _subcontractView,
                                onChanged: (value) {
                                  setState(() => _subcontractView = value);
                                  if (value == 'suppliers' &&
                                      _supplierResult == null) {
                                    _loadSuppliers();
                                  }
                                },
                              ),
                            ],
                            if (data != null && !supplierMode) ...[
                              const SizedBox(height: UtenSpacing.s16),
                              _summary(data, box.maxWidth),
                              const SizedBox(height: UtenSpacing.s12),
                              Wrap(
                                spacing: UtenSpacing.s12,
                                runSpacing: UtenSpacing.s4,
                                crossAxisAlignment: WrapCrossAlignment.center,
                                children: [
                                  Text(
                                    '${priceText(context, data.text('status'))} · ${data.text('independentOrderCount')} ${priceText(context, 'orders')} · ${priceText(context, 'AS_RECORDED')}${data.context['taxRate'] == null ? '' : ' ${priceNumber(data.context['taxRate'])}%'}',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelMedium
                                        ?.copyWith(
                                          color: data.ready
                                              ? Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant
                                              : Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                        ),
                                  ),
                                  TextButton.icon(
                                    onPressed: () => _showBasis(data),
                                    icon: const Icon(
                                      Icons.info_outline,
                                      size: 16,
                                    ),
                                    label: Text(priceText(context, 'explain')),
                                  ),
                                ],
                              ),
                              _panel(
                                context,
                                title: priceText(context, 'trend'),
                                child: PriceHistoryChart(analysis: data),
                              ),
                              if (_kind == 'SALES') ...[
                                const SizedBox(height: UtenSpacing.s12),
                                _quote(data),
                              ],
                            ],
                            if (_historyOnly && canShowRows)
                              Padding(
                                padding: const EdgeInsets.only(
                                  top: UtenSpacing.s12,
                                ),
                                child: Text(
                                  priceText(context, 'quoteHistoryOnly'),
                                ),
                              ),
                          ],
                        ),
                      ),
                      body: Padding(
                        padding: EdgeInsets.fromLTRB(
                          spacing,
                          0,
                          spacing,
                          spacing,
                        ),
                        child: _error != null
                            ? UtenEmpty(
                                message: _error!,
                                isError: true,
                                actionLabel: priceText(context, 'retry'),
                                onAction: _load,
                              )
                            : canShowRows
                            ? supplierMode
                                  ? _supplierError != null
                                        ? UtenEmpty(
                                            message: _supplierError!,
                                            isError: true,
                                            actionLabel: priceText(
                                              context,
                                              'retry',
                                            ),
                                            onAction: _loadSuppliers,
                                          )
                                        : _supplierResult == null
                                        ? const SizedBox.shrink()
                                        : GoodsSubcontractSupplierTable(
                                            result: _supplierResult!,
                                            onOpen: _openSupplier,
                                          )
                                  : _history(data)
                            : _loading
                            ? const SizedBox.shrink()
                            : nativeReadAccessNotice(),
                      ),
                    ),
                    if (_loading || _historyLoading || _supplierLoading)
                      UtenBusyOverlay(
                        title: priceText(
                          context,
                          _historyLoading
                              ? 'loadingHistory'
                              : 'loadingAnalysis',
                        ),
                        semanticsKey: const Key('price-analysis-loading'),
                      ),
                  ],
                );
              },
            ),
    );
  }

  Widget _controls(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final style =
          Theme.of(context).textTheme.bodyMedium ??
          const TextStyle(fontSize: 14);
      final fontSize = style.fontSize ?? 14;
      final textFactor =
          MediaQuery.textScalerOf(context).scale(fontSize) / fontSize;
      final minimumWidth = 170 * textFactor;
      final optionWidth = box.maxWidth < minimumWidth * 2 + UtenSpacing.s12
          ? box.maxWidth
          : minimumWidth;
      return Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!_historyOnly)
            SizedBox(
              width: optionWidth,
              child: UtenDropdownField(
                key: const ValueKey('price-analysis-days'),
                label: priceText(context, 'days'),
                value: _days.toString(),
                selectedMaxLines: null,
                menuMatchContentWidth: true,
                allowClear: false,
                searchable: false,
                items: [
                  for (final days in [30, 90, 180, 365])
                    UtenDropdownItem(
                      value: days.toString(),
                      label: priceDaysText(context, days),
                    ),
                ],
                onChanged: (value) {
                  final days = int.tryParse(value ?? '');
                  if (days != null) {
                    _days = days;
                    _edited();
                    _load();
                  }
                },
              ),
            ),
          if (!_historyOnly &&
              !(_kind == 'SUBCONTRACT' && _subcontractView == 'suppliers'))
            SizedBox(
              width: optionWidth,
              child: TextField(
                key: const ValueKey('price-analysis-quantity'),
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: UtenInputDecoration(
                  InputDecoration(labelText: priceText(context, 'analysisQty')),
                ),
                onChanged: (_) => _edited(),
                onSubmitted: (_) => _load(),
              ),
            ),
          for (final entry in [
            (_kind == 'SALES' ? 'clientId' : 'supplierId', 'partner'),
            ('currencyId', 'currency'),
            ('unitId', 'unit'),
            ('colorId', 'color'),
            ('taxRate', 'tax'),
          ])
            if (_advanced &&
                (_subcontractView != 'suppliers' ||
                    _kind != 'SUBCONTRACT' ||
                    entry.$1 == 'supplierId') &&
                _options[entry.$1]?.isNotEmpty == true &&
                !(_kind == 'SALES' && entry.$1 == 'supplierId'))
              SizedBox(
                width: optionWidth,
                child: UtenDropdownField(
                  key: ValueKey('${entry.$1}-${_filters[entry.$1]}'),
                  value: _choiceValue(entry.$1),
                  label: priceText(context, entry.$2),
                  hintText: priceText(context, 'auto'),
                  selectedMaxLines: null,
                  menuMatchContentWidth: true,
                  allowClear: false,
                  items: [
                    UtenDropdownItem(label: priceText(context, 'auto')),
                    for (final option in _options[entry.$1]!.entries)
                      UtenDropdownItem(value: option.key, label: option.value),
                  ],
                  onChanged: (value) => _selectContext(entry.$1, value),
                ),
              ),
          if (_kind == 'SALES' && !_historyOnly)
            SizedBox(
              width: optionWidth,
              child: TextField(
                key: const ValueKey('price-analysis-margin'),
                controller: _margin,
                decoration: UtenInputDecoration(
                  InputDecoration(labelText: priceText(context, 'margin')),
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                onChanged: (_) => _edited(),
                onSubmitted: (_) => _load(),
              ),
            ),
          FilledButton.tonalIcon(
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.analytics_outlined),
            label: Text(priceText(context, 'apply')),
          ),
        ],
      );
    },
  );

  Widget _summary(GoodsPriceAnalysis data, double width) {
    final available = width - (width < 720 ? 24 : 48);
    final summaryFont =
        Theme.of(context).textTheme.headlineSmall?.fontSize ?? 20;
    final largeText =
        MediaQuery.textScalerOf(context).scale(summaryFont) > summaryFont * 1.2;
    final columns = width < 360 || largeText && width < 980
        ? 1
        : width < 980 || largeText
        ? 2
        : 4;
    final cardWidth = (available - UtenSpacing.s12 * (columns - 1)) / columns;
    final denomination =
        '${data.context['currencyName'] ?? ''} / ${data.context['unitName'] ?? ''}';
    final entries = [
      (
        'today',
        data.ready ? compactPriceStatistic(data.data['referencePrice']) : '—',
        data.ready ? priceNumber(data.data['referencePrice']) : '—',
      ),
      (
        'average',
        compactPriceStatistic(data.data['weightedAveragePrice']),
        priceNumber(data.data['weightedAveragePrice']),
      ),
      (
        'range',
        data.ready
            ? compactPriceRange(
                data.data['lowerReferencePrice'],
                data.data['upperReferencePrice'],
              )
            : '—',
        data.ready
            ? '${priceNumber(data.data['lowerReferencePrice'])} – ${priceNumber(data.data['upperReferencePrice'])}'
            : '—',
      ),
      (
        'latest',
        compactPriceStatistic(data.data['lastPrice']),
        priceNumber(data.data['lastPrice']),
      ),
    ];
    Widget value((String, String, String) entry) => PriceSummaryValue(
      key: ValueKey('price-summary-${entry.$1}'),
      compact: entry.$2,
      exact: entry.$3,
      suffix: denomination,
      semanticLabel:
          '${priceText(context, entry.$1)}: ${entry.$3} $denomination',
    );
    if (width < 720) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(
            color: Theme.of(context).colorScheme.outlineVariant,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            children: [
              for (final entry in entries)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                  child: largeText || width < 360
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(priceText(context, entry.$1)),
                            value(entry),
                          ],
                        )
                      : Row(
                          children: [
                            Expanded(
                              child: Text(
                                priceText(context, entry.$1),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                            Flexible(flex: 2, child: value(entry)),
                          ],
                        ),
                ),
            ],
          ),
        ),
      );
    }
    return Wrap(
      spacing: UtenSpacing.s12,
      runSpacing: UtenSpacing.s12,
      children: [
        for (final entry in entries)
          SizedBox(
            width: cardWidth,
            child: _panel(
              context,
              title: priceText(context, entry.$1),
              child: value(entry),
            ),
          ),
      ],
    );
  }

  Widget _quote(GoodsPriceAnalysis data) {
    final cost = data.cost;
    final complete = cost['fullCostComplete'] == true;
    return _panel(
      context,
      title: priceText(context, 'quote'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            complete
                ? '${priceText(context, 'cost')}: ${priceNumber(cost['unitCost'])} ${cost['currencyName'] ?? ''}/${cost['unitName'] ?? ''} · ${cost['sheetNo'] ?? ''}'
                : priceText(context, 'costIncomplete'),
          ),
          const SizedBox(height: UtenSpacing.s8),
          if (cost['batchQuantity'] != null)
            Text(
              '${priceText(context, 'costBatch')}: ${priceNumber(cost['batchQuantity'])} ${cost['unitName'] ?? ''}',
            ),
          if (complete)
            Text(
              '${priceText(context, 'quotePrice')}: ${priceNumber(cost['suggestedPrice'])} ${cost['currencyName'] ?? ''}/${cost['unitName'] ?? ''}',
              style: Theme.of(context).textTheme.titleLarge,
            ),
          Text(
            priceText(context, 'estimateBadge'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (priceStrings(cost['missingCostComponents']).isNotEmpty)
            Text(
              priceStrings(
                cost['missingCostComponents'],
              ).map((reason) => priceText(context, reason)).join(' · '),
            ),
        ],
      ),
    );
  }

  Widget _history(GoodsPriceAnalysis? data) {
    final rows = _historyTableMode
        ? _historyPage?.items ?? const <PriceObservation>[]
        : data?.observations ?? const <PriceObservation>[];
    MasterColumnDef<PriceObservation> column(
      String key,
      String label,
      double width, {
      bool numeric = false,
      String Function(PriceObservation)? text,
    }) => MasterColumnDef(
      key: key,
      label: priceText(context, label),
      width: width,
      type: numeric
          ? 'number'
          : key == 'businessDate'
          ? 'date'
          : 'text',
      sortable: !(_historyTableMode && key == 'comparable'),
      filterFromRows: !_historyTableMode,
      info:
          _historyPage is PriceHistoryTableResult &&
              (_historyPage! as PriceHistoryTableResult).hasMoreFacetValues(key)
          ? priceText(context, 'allValuesHint')
          : null,
      value: text ?? (row) => row.text(key),
      cellBuilder: numeric
          ? (cellContext, row) => Text(
              priceObservationValue(row, key),
              style: Theme.of(cellContext).textTheme.bodySmall?.copyWith(
                color: MasterDataTableCellScope.maybeOf(
                  cellContext,
                )?.foregroundColor,
              ),
            )
          : null,
      aiSensitive: numeric || key == 'partnerName',
      exactValueOf: numeric ? (row) => row.text(key) : null,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
          child: Text(
            priceText(context, 'history'),
            style: Theme.of(context).textTheme.titleSmall,
          ),
        ),
        Expanded(
          child: MasterDataTableView<PriceObservation>(
            key: const Key('goods-price-history-table'),
            tableKey:
                'goods.price-history.$_kind.${_historyTableMode ? 'history' : 'window'}',
            primary: true,
            virtualized: true,
            items: rows,
            facets: _historyTableMode ? _historyFacets() : const {},
            nullCounts: _historyTableMode
                ? _historyPage?.facetNullCounts ?? const {}
                : const {},
            filters: _tableFilters,
            onFilterChanged: _tableFilterChanged,
            currentPage: _historyPage?.page ?? 1,
            totalPages: _historyPage?.totalPages ?? 1,
            onPageChange: _historyTableMode ? _loadHistoryTable : null,
            sortColumn: _historyTableMode ? _tableSort : null,
            sortAscending: _tableAscending,
            onSortChange: _historyTableMode ? _tableSortChanged : null,
            rowKeyOf: (row) => row.identity,
            rowWidgetKeyOf: (row) => ValueKey('price-history-${row.identity}'),
            paginationScope:
                '$_identity|$_historyTableMode|${jsonEncode(_tableFilters)}|$_tableSort|$_tableAscending',
            onRowTap: _open,
            onSelectionChanged: (row) => setState(() => _selectedRow = row),
            onSelectionCleared: () => setState(() => _selectedRow = null),
            loadingMore: _historyLoading,
            error: _historyError,
            onRetry: _historyError == null
                ? null
                : () => _loadHistoryTable(_historyPage?.page ?? 1),
            emptyMessage: priceText(context, 'noData'),
            columns: [
              column('businessDate', 'date', 112),
              column('sourceNo', 'number', 150),
              column('partnerName', 'partner', 160),
              column('unitPrice', 'price', 145, numeric: true),
              column('quantity', 'qty', 120, numeric: true),
              column('amount', 'amount', 160, numeric: true),
              column('colorName', 'color', 85),
              column(
                'lifecycle',
                'recordStatus',
                165,
                text: (row) => priceText(
                  context,
                  row.text('lifecycle').isEmpty
                      ? 'ACTIVE'
                      : row.text('lifecycle'),
                ),
              ),
              column(
                'comparable',
                'basis',
                100,
                text: (row) => priceText(
                  context,
                  row.comparable ? 'comparable' : 'excluded',
                ),
              ),
            ],
            toolbarActions: [
              if (_historyTableMode)
                UtenButton(
                  icon: Icons.filter_alt_outlined,
                  onPressed: _historyLoading ? null : _pickFullFacet,
                  child: Text(priceText(context, 'allFilterValues')),
                ),
              UtenButton(
                icon: Icons.article_outlined,
                onPressed: _selectedRow == null
                    ? null
                    : () => _open(_selectedRow!),
                child: Text(priceText(context, 'priceDetail')),
              ),
              if (!_historyTableMode)
                UtenButton(
                  onPressed: _historyLoading
                      ? null
                      : () => _loadHistoryTable(1),
                  child: Text(priceText(context, 'allHistory')),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PriceBasisPanel extends StatefulWidget {
  const _PriceBasisPanel({required this.data, required this.onClose});
  final GoodsPriceAnalysis data;
  final VoidCallback onClose;
  @override
  State<_PriceBasisPanel> createState() => _PriceBasisPanelState();
}

class _PriceBasisPanelState extends State<_PriceBasisPanel> {
  final _scroll = ScrollController();
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    return Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: SingleChildScrollView(
        key: const ValueKey('price-basis-scroll'),
        controller: _scroll,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      priceText(context, 'explain'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    key: const ValueKey('price-basis-close'),
                    onPressed: widget.onClose,
                    tooltip: priceText(context, 'close'),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(data.text('explanation')),
                  const SizedBox(height: UtenSpacing.s16),
                  Text(
                    '${priceText(context, 'asOf')}: ${utenFmtIsoTime(data.text('dataAsOf'))}',
                  ),
                  Text(
                    '${priceText(context, 'samples')}: ${data.text('sampleCount')} / ${data.text('independentOrderCount')}',
                  ),
                  if (data.reasons.isNotEmpty)
                    Text(
                      data.reasons
                          .map((reason) => priceText(context, reason))
                          .toSet()
                          .join(' · '),
                      key: const ValueKey('price-basis-reasons'),
                    ),
                  if (data.cost.isNotEmpty) ...[
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      data.cost['explanation']?.toString() ??
                          priceText(context, 'quoteBasis'),
                      key: const ValueKey('price-basis-cost-explanation'),
                    ),
                    Text(priceText(context, 'estimateOnly')),
                  ],
                  const SizedBox(height: UtenSpacing.s16),
                  Text(
                    priceText(context, 'chartHint'),
                    key: const ValueKey('price-basis-chart-hint'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _panel(
  BuildContext context, {
  required String title,
  required Widget child,
}) => DecoratedBox(
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.surface,
    borderRadius: UtenRadius.lgAll,
    border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
  ),
  child: Padding(
    padding: const EdgeInsets.all(UtenSpacing.s16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: UtenSpacing.s12),
        child,
      ],
    ),
  ),
);
