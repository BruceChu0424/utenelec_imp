import '../widgets/goods_price_history_chart.dart';
import 'package:flutter/material.dart';
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
  int _shown = 25;
  int _contextRevision = 0;
  final _quantity = TextEditingController();
  final _margin = TextEditingController();
  final _filters = <String, String>{};
  final _options = <String, Map<String, String>>{};
  GoodsPriceAnalysis? _analysis;
  bool _loading = false;
  String? _error;
  List<PriceObservation>? _allHistory;
  String? _historyCursor;
  String? _historyError;
  bool _historyMore = false;
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
    _options.clear();
    _filters.clear();
    _clear();
  }

  @override
  void nativeReadPermissionChanged() {
    _options.clear();
    _clear();
  }

  @override
  Future<void> nativeReadReload() => _load();
  void _clear() {
    if (!mounted) return;
    setState(() {
      _analysis = null;
      _error = null;
      _loading = false;
      _shown = 25;
      _allHistory = null;
      _historyCursor = null;
      _historyError = null;
      _historyMore = false;
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
        final result = await ref.read(priceAnalysisRepositoryProvider).history(
          widget.goodsId,
          {'kind': 'SALES', ..._filters, 'pageSize': 50},
        );
        if (!accepts() || !_allowed || !_historyOnly) return;
        acceptNativeRead();
        setState(() {
          _allHistory = result.observations;
          _historyCursor = result.nextCursor;
          _historyMore = result.hasMore;
          _shown = result.observations.length;
          _loading = false;
          _mergeChoices(result.observations);
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
      _shown = 25;
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
      _mergeChoices(result.observations);
      acceptNativeRead();
      setState(() {
        _analysis = result;
        _loading = false;
      });
      _primeContextChoices();
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

  Future<void> _open(PriceObservation row) async {
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

  Future<void> _loadHistory({bool reset = false}) async {
    if (!_allowed || !nativeReadAccessConfirmed || _historyLoading) return;
    final owns = captureNativeOwnership();
    final identity = _identity;
    final revision = ++_historyRevision;
    setState(() {
      _historyLoading = true;
      _historyError = null;
      if (reset) {
        _allHistory = [];
        _historyCursor = null;
        _historyMore = false;
      }
    });
    try {
      final result = await ref.read(priceAnalysisRepositoryProvider).history(
        widget.goodsId,
        {'kind': _kind, ..._filters, 'pageSize': 50, 'cursor': ?_historyCursor},
      );
      if (!mounted ||
          !owns() ||
          !_allowed ||
          identity != _identity ||
          revision != _historyRevision ||
          !nativeReadAccessConfirmed) {
        return;
      }
      setState(() {
        _mergeChoices(result.observations);
        _allHistory = [...?_allHistory, ...result.observations];
        _historyCursor = result.nextCursor;
        _historyMore = result.hasMore;
        _historyLoading = false;
        _shown = _allHistory!.length;
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
          IconButton(
            onPressed: _loading || !_allowed ? null : _load,
            tooltip: priceText(context, 'retry'),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: !_allowed
          ? UtenEmpty(message: priceText(context, 'denied'))
          : LayoutBuilder(
              builder: (context, constraints) {
                final narrow = constraints.maxWidth < 720;
                return SingleChildScrollView(
                  padding: EdgeInsets.all(
                    narrow ? UtenSpacing.s12 : UtenSpacing.s24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: UtenSpacing.s8,
                        runSpacing: UtenSpacing.s8,
                        children: [
                          for (final kind in [
                            'PURCHASE',
                            'SUBCONTRACT',
                            'SALES',
                          ])
                            ChoiceChip(
                              label: Text(priceText(context, kind)),
                              selected: _kind == kind,
                              onSelected: (selected) {
                                if (selected && _kind != kind) {
                                  _kind = kind;
                                  _filters.clear();
                                  _options.clear();
                                  _edited();
                                  _load();
                                }
                              },
                            ),
                        ],
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                      _controls(context),
                      const SizedBox(height: UtenSpacing.s16),
                      if (_loading) const LinearProgressIndicator(),
                      if (_error != null)
                        UtenEmpty(
                          message: _error!,
                          isError: true,
                          actionLabel: priceText(context, 'retry'),
                          onAction: _load,
                        ),
                      if (!_loading &&
                          _error == null &&
                          data == null &&
                          !(_historyOnly && nativeReadAccessConfirmed))
                        nativeReadAccessNotice(),
                      if (_historyOnly && nativeReadAccessConfirmed) ...[
                        Text(priceText(context, 'quoteHistoryOnly')),
                        const SizedBox(height: UtenSpacing.s16),
                        _panel(
                          context,
                          title: priceText(context, 'history'),
                          child: _history(
                            null,
                            narrow || constraints.maxWidth < 1050,
                          ),
                        ),
                      ],
                      if (data != null) ...[
                        _summary(data, constraints.maxWidth),
                        const SizedBox(height: UtenSpacing.s16),
                        _panel(
                          context,
                          title: priceText(context, 'trend'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                '${data.context['currencyName'] ?? ''} / ${data.context['unitName'] ?? ''}',
                                style: Theme.of(context).textTheme.labelLarge,
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                              PriceHistoryChart(analysis: data),
                              const SizedBox(height: UtenSpacing.s8),
                              Text(
                                priceText(
                                  context,
                                  data.ready ? 'chartHint' : 'chartHintSparse',
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: UtenSpacing.s16),
                        _panel(
                          context,
                          title: priceText(context, 'explain'),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                data.text('explanation').isEmpty
                                    ? priceText(context, data.text('status'))
                                    : data.text('explanation'),
                              ),
                              const SizedBox(height: UtenSpacing.s8),
                              Text(
                                '${priceText(context, 'asOf')}: ${utenFmtIsoTime(data.text('dataAsOf'))} · ${priceText(context, 'samples')}: ${data.text('sampleCount')} / ${data.text('independentOrderCount')}',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              if (data.reasons.isNotEmpty)
                                Text(
                                  data.reasons
                                      .map(
                                        (reason) => priceText(context, reason),
                                      )
                                      .join(' · '),
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                        if (_kind == 'SALES') ...[
                          const SizedBox(height: UtenSpacing.s16),
                          _quote(data),
                        ],
                        const SizedBox(height: UtenSpacing.s16),
                        _panel(
                          context,
                          title: priceText(context, 'history'),
                          child: _history(
                            data,
                            narrow || constraints.maxWidth < 1050,
                          ),
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
    );
  }

  Widget _controls(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final optionWidth = box.maxWidth < 400
          ? (box.maxWidth - UtenSpacing.s12) / 2
          : 170.0;
      return Wrap(
        spacing: UtenSpacing.s12,
        runSpacing: UtenSpacing.s12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          if (!_historyOnly)
            SizedBox(
              width: 150,
              child: DropdownButtonFormField<int>(
                initialValue: _days,
                decoration: InputDecoration(
                  labelText: priceText(context, 'days'),
                ),
                items: [
                  for (final days in [30, 90, 180, 365])
                    DropdownMenuItem(
                      value: days,
                      child: Text(priceDaysText(context, days)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _days = value;
                    _edited();
                    _load();
                  }
                },
              ),
            ),
          if (!_historyOnly)
            SizedBox(
              width: 150,
              child: TextField(
                controller: _quantity,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: priceText(context, 'analysisQty'),
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
            if (_options[entry.$1]?.isNotEmpty == true &&
                !(_kind == 'SALES' && entry.$1 == 'supplierId'))
              SizedBox(
                width: optionWidth,
                child: DropdownButtonFormField<String>(
                  key: ValueKey('${entry.$1}-${_filters[entry.$1]}'),
                  initialValue: _choiceValue(entry.$1),
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: priceText(context, entry.$2),
                  ),
                  items: [
                    DropdownMenuItem<String>(
                      child: Text(priceText(context, 'auto')),
                    ),
                    for (final option in _options[entry.$1]!.entries)
                      DropdownMenuItem(
                        value: option.key,
                        child: Text(
                          option.value,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (value) => _selectContext(entry.$1, value),
                ),
              ),
          if (_kind == 'SALES' && !_historyOnly)
            SizedBox(
              width: 180,
              child: TextField(
                controller: _margin,
                decoration: InputDecoration(
                  labelText: priceText(context, 'margin'),
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
    final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.2;
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            for (final entry in entries)
              SizedBox(
                width: cardWidth,
                child: _panel(
                  context,
                  title: priceText(context, entry.$1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      PriceSummaryValue(
                        key: ValueKey('price-summary-${entry.$1}'),
                        compact: entry.$2,
                        exact: entry.$3,
                        semanticLabel:
                            '${priceText(context, entry.$1)}: ${entry.$3} $denomination',
                      ),
                      Text(
                        denomination,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '${priceText(context, data.text('status'))} · ${priceText(context, data.context['taxMode']?.toString() ?? '')} · ${priceText(context, data.context['priceBasis']?.toString() ?? '')}',
          style: Theme.of(context).textTheme.labelMedium,
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
          if (cost['actualFullCostComplete'] != true)
            Text(priceText(context, 'estimateOnly')),
          Text(
            cost['explanation']?.toString() ?? priceText(context, 'quoteBasis'),
          ),
          if (priceStrings(cost['missingCostComponents']).isNotEmpty)
            Text(
              priceStrings(
                cost['missingCostComponents'],
              ).map((reason) => priceText(context, reason)).join(' · '),
            ),
          Text(
            priceText(context, 'quoteBasis'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _history(GoodsPriceAnalysis? data, bool narrow) {
    final all = _allHistory ?? data?.observations ?? [];
    final rows = all.take(_shown).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                priceText(
                  context,
                  _allHistory == null ? 'windowHistory' : 'allHistoryHint',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            if (_allHistory == null)
              TextButton(
                onPressed: _historyLoading
                    ? null
                    : () => _loadHistory(reset: true),
                child: Text(priceText(context, 'allHistory')),
              ),
          ],
        ),
        if (_historyLoading) const LinearProgressIndicator(),
        if (_historyError != null)
          Text(
            _historyError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (rows.isEmpty && !_historyLoading)
          Text(priceText(context, 'noData')),
        if (narrow) ...[
          for (final row in rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '${row.text('sourceNo')} · ${priceNumber(row.price)} ${row.text('currencyName')}/${row.text('unitName')}',
              ),
              subtitle: Text(
                '${row.text('businessDate')} · ${row.text('partnerName')}${row.text('lifecycle').isEmpty ? '' : ' · ${priceText(context, row.text('lifecycle'))}'}\n${priceText(context, 'qty')}: ${priceNumber(row.data['quantity'])} · ${priceText(context, row.comparable ? 'comparable' : 'excluded')}',
              ),
              trailing: row.data['canOpenSource'] == true
                  ? const Icon(Icons.chevron_right)
                  : null,
              onTap: row.data['canOpenSource'] == true
                  ? () => _open(row)
                  : null,
            ),
        ] else
          DataTable(
            columnSpacing: UtenSpacing.s16,
            horizontalMargin: 0,
            columns: [
              for (final key in [
                'date',
                'number',
                'partner',
                'qty',
                'price',
                'amount',
                'basis',
              ])
                DataColumn(label: Text(priceText(context, key))),
            ],
            rows: [
              for (final row in rows)
                DataRow(
                  cells: [
                    DataCell(
                      Tooltip(
                        message: row.text('recordedAt'),
                        child: Text(
                          [
                            row.text('businessDate'),
                            if (row.text('lifecycle').isNotEmpty)
                              priceText(context, row.text('lifecycle')),
                          ].join('\n'),
                        ),
                      ),
                    ),
                    DataCell(
                      Text(row.text('sourceNo')),
                      onTap: row.data['canOpenSource'] == true
                          ? () => _open(row)
                          : null,
                    ),
                    DataCell(
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          row.text('partnerName'),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    DataCell(Text(priceNumber(row.data['quantity']))),
                    DataCell(
                      Text(
                        '${priceNumber(row.price)} ${row.text('currencyName')}/${row.text('unitName')}',
                      ),
                    ),
                    DataCell(Text(priceNumber(row.data['amount']))),
                    DataCell(
                      Tooltip(
                        message: priceStrings(
                          row.data['reasonCodes'],
                        ).join(' · '),
                        child: Text(
                          priceText(
                            context,
                            row.comparable ? 'comparable' : 'excluded',
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
            ],
          ),
        if (all.length > rows.length)
          TextButton(
            onPressed: () => setState(() => _shown += 25),
            child: Text(
              '${priceText(context, 'more')} (${all.length - rows.length})',
            ),
          ),
        if ((_historyMore || _historyError != null) && _allHistory != null)
          TextButton(
            onPressed: _historyLoading ? null : _loadHistory,
            child: Text(
              priceText(context, _historyError == null ? 'more' : 'retry'),
            ),
          ),
      ],
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
