import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/pricing/price_analysis_l10n.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../../../shared/pricing/price_analysis_repository.dart';
import '../models/master_facet.dart';
import 'master_data_table_view.dart';

/// Server-backed search over all authorized facet values, including values
/// beyond the bounded initial bucket list in a normal column menu.
class GoodsPriceFacetPicker extends ConsumerStatefulWidget {
  const GoodsPriceFacetPicker({
    super.key,
    required this.goodsId,
    required this.query,
  });
  final String goodsId;
  final Map<String, dynamic> query;
  @override
  ConsumerState<GoodsPriceFacetPicker> createState() =>
      _GoodsPriceFacetPickerState();
}

class _GoodsPriceFacetPickerState extends ConsumerState<GoodsPriceFacetPicker>
    with NativeReadViewScopeMixin<GoodsPriceFacetPicker> {
  String _column = 'sourceNo', _search = '';
  int _page = 1, _pages = 1;
  bool _loading = false;
  String? _error;
  List<MasterFacetBucket> _rows = [];
  bool get _allowed =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsView,
        Perm.goodsPriceAnalysisView,
      });
  String get _identity =>
      '${widget.goodsId}|${jsonEncode(widget.query)}|$_column|$_search';
  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (_, _) {
      invalidateNativeReadAccess();
      _clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(1));
  }

  void _clear() {
    if (mounted) {
      setState(() {
        _rows = [];
        _loading = false;
        _error = null;
        _page = 1;
        _pages = 1;
      });
    }
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => _load(1);
  Future<void> _load(int page) async {
    if (!mounted || !_allowed) return;
    final accepts = captureNativeRead(_identity, () => _identity);
    if (!accepts()) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final response = await ref
          .read(priceAnalysisRepositoryProvider)
          .historyFacets(widget.goodsId, {
            ...widget.query,
            'column': _column,
            'search': _search,
            'page': page,
            'size': 50,
          });
      if (!accepts() || !_allowed) return;
      acceptNativeRead();
      setState(() {
        _rows = priceMaps(
          response['buckets'],
        ).map(MasterFacetBucket.fromJson).toList();
        _page = (response['page'] as num?)?.toInt() ?? page;
        _pages = (response['totalPages'] as num?)?.toInt() ?? 1;
        _loading = false;
      });
    } catch (e) {
      if (!accepts()) return;
      setState(() {
        _loading = false;
        _rows = [];
        _error = e is ApiException
            ? e.message
            : priceText(context, 'UNAVAILABLE');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    return Stack(
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      priceText(context, 'allFilterValues'),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    tooltip: priceText(context, 'close'),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
              child: DropdownButtonFormField<String>(
                initialValue: _column,
                decoration: InputDecoration(
                  labelText: priceText(context, 'field'),
                ),
                items: [
                  for (final entry in const [
                    ('sourceNo', 'number'),
                    ('businessDate', 'date'),
                    ('partnerName', 'partner'),
                    ('unitPrice', 'price'),
                    ('quantity', 'qty'),
                    ('amount', 'amount'),
                    ('colorName', 'color'),
                    ('lifecycle', 'recordStatus'),
                  ])
                    DropdownMenuItem(
                      value: entry.$1,
                      child: Text(priceText(context, entry.$2)),
                    ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    _column = value;
                    invalidateNativeReadAccess();
                    _clear();
                    _load(1);
                  }
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: UtenSearchBar(
                hint: priceText(context, 'searchAllValues'),
                onInputChanged: (value) {
                  _search = value;
                  invalidateNativeReadAccess();
                  _clear();
                },
                onChanged: (_) => _load(1),
              ),
            ),
            Expanded(
              child: _error != null
                  ? UtenEmpty(
                      message: _error!,
                      isError: true,
                      actionLabel: priceText(context, 'retry'),
                      onAction: () => _load(1),
                    )
                  : MasterDataTableView<MasterFacetBucket>(
                      tableKey: 'goods.price-facet-values',
                      virtualized: true,
                      showFullscreenToggle: false,
                      showColumnChooser: false,
                      singleTapRows: true,
                      items: nativeReadAccessConfirmed && _allowed
                          ? _rows
                          : const [],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      rowKeyOf: (row) => row.value,
                      currentPage: _page,
                      totalPages: _pages,
                      onPageChange: _load,
                      paginationScope: _identity,
                      onRowTap: (row) {
                        if (nativeReadAccessConfirmed && _allowed) {
                          Navigator.pop(context, (_column, row));
                        }
                      },
                      columns: [
                        MasterColumnDef(
                          key: 'value',
                          label: priceText(context, 'value'),
                          width: 310,
                          aiSensitive: true,
                          value: (row) => row.display,
                        ),
                        MasterColumnDef(
                          key: 'count',
                          label: priceText(context, 'records'),
                          width: 95,
                          type: 'number',
                          value: (row) => row.count.toString(),
                        ),
                      ],
                    ),
            ),
          ],
        ),
        if (_loading)
          UtenBusyOverlay(title: priceText(context, 'loadingHistory')),
      ],
    );
  }
}
