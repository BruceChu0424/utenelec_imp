import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
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
  MasterFacetBucket? _picked;
  final _chromeKey = GlobalKey();
  final _bodyKey = GlobalKey();
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
        _picked = null;
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
      _picked = null;
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
    final picked = _picked;
    final identity = _identity;
    final owns = captureNativeOwnership();
    bool canSelect(MasterFacetBucket? row) =>
        row != null &&
        owns() &&
        identity == _identity &&
        nativeReadAccessConfirmed &&
        _allowed &&
        !_loading &&
        _rows.contains(row);
    return Stack(
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final footer = UtenPickerConfirmBar(
              selectedCount: picked == null ? 0 : 1,
              summary: Text(picked?.display ?? priceText(context, 'value')),
              confirmLabel: MaterialLocalizations.of(context).okButtonLabel,
              cancelLabel: MaterialLocalizations.of(context).cancelButtonLabel,
              confirmButtonKey: const Key('goods-price-facet-confirm'),
              confirmEnabled: canSelect(picked),
              onConfirm: () {
                if (!canSelect(picked) || !identical(picked, _picked)) return;
                Navigator.pop(context, (_column, picked!));
              },
            );
            final content = UtenCollapsingHeaderScrollView(
              // The shared outer scroll owns both the bounded table and the
              // footer; a second outer scroll can move a focused field or row
              // behind the other viewport on small, zoomed windows.
              compactBodyMinHeight:
                  320 + MediaQuery.textScalerOf(context).scale(140),
              collapsingHeader: KeyedSubtree(
                key: _chromeKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: UtenSpacing.s16,
                      ),
                      child: UtenDropdownField(
                        value: _column,
                        label: priceText(context, 'field'),
                        selectedMaxLines: null,
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
                            UtenDropdownItem(
                              value: entry.$1,
                              label: priceText(context, entry.$2),
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
                        initialValue: _search,
                        hint: priceText(context, 'searchAllValues'),
                        onInputChanged: (value) {
                          _search = value;
                          invalidateNativeReadAccess();
                          _clear();
                        },
                        onChanged: (_) => _load(1),
                      ),
                    ),
                  ],
                ),
              ),
              body: Column(
                children: [
                  Expanded(
                    child: KeyedSubtree(
                      key: _bodyKey,
                      child: _error != null
                          ? UtenEmpty(
                              message: _error!,
                              isError: true,
                              actionLabel: priceText(context, 'retry'),
                              onAction: () => _load(1),
                            )
                          : MasterDataTableView<MasterFacetBucket>(
                              tableKey: 'goods.price-facet-values',
                              primary: true,
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
                              isSelected: (row) => row.value == _picked?.value,
                              onRowTap: (row) {
                                if (!canSelect(row)) return;
                                setState(() => _picked = row);
                              },
                              columns: [
                                MasterColumnDef(
                                  key: 'value',
                                  label: priceText(context, 'value'),
                                  width: 310,
                                  aiSensitive: true,
                                  // Server-paged facet list: the funnel would
                                  // only cover the current page; the top search
                                  // bar queries all values.
                                  columnSearchEnabled: false,
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
                  ),
                  footer,
                ],
              ),
            );
            return content;
          },
        ),
        if (_loading)
          UtenBusyOverlay(title: priceText(context, 'loadingHistory')),
      ],
    );
  }
}
