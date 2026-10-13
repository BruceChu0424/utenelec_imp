import 'master_data_table_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/pricing/price_analysis_l10n.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../../../shared/pricing/price_analysis_repository.dart';

String? priceObservationSourcePath(PriceObservation row) {
  if (row.data['canOpenSource'] != true || row.text('sourceId').isEmpty) {
    return null;
  }
  final id = Uri.encodeComponent(row.text('sourceId'));
  return switch (row.text('sourceType')) {
    'PURCHASE_ORDER' => '/purchase/orders/$id',
    'SUBCONTRACT_ORDER' => '/subcontract/orders/$id',
    'SALES_ORDER' => '/sales/orders/$id',
    _ => null,
  };
}

/// Opens immediately, but private values are rendered only after the server
/// rechecks this exact source/version/line and its expected revision.
class GoodsPriceObservationDetail extends ConsumerStatefulWidget {
  const GoodsPriceObservationDetail({
    super.key,
    required this.goodsId,
    required this.kind,
    required this.row,
    required this.onReloadHistory,
  });
  final String goodsId;
  final String kind;
  final PriceObservation row;
  final VoidCallback onReloadHistory;
  @override
  ConsumerState<GoodsPriceObservationDetail> createState() =>
      _GoodsPriceObservationDetailState();
}

class _GoodsPriceObservationDetailState
    extends ConsumerState<GoodsPriceObservationDetail>
    with NativeReadViewScopeMixin<GoodsPriceObservationDetail> {
  PriceObservationDetail? _detail;
  String? _error;
  bool _loading = false;
  bool _reloadRequired = false;
  final _chromeKey = GlobalKey();
  final _bodyKey = GlobalKey();
  bool get _allowed =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsView,
        Perm.goodsPriceAnalysisView,
      });
  String get _identity =>
      '${widget.goodsId}|${widget.kind}|${widget.row.identity}|${widget.row.text('sourceRevision')}';
  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    ref.listenManual(currentPermissionsProvider, (_, _) {
      invalidateNativeReadAccess();
      _clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _clear() {
    if (mounted) {
      setState(() {
        _detail = null;
        _loading = false;
        _error = null;
      });
    }
  }

  @override
  void nativeReadOwnerChanged() => _clear();
  @override
  void nativeReadPermissionChanged() => _clear();
  @override
  Future<void> nativeReadReload() => _load();
  Future<void> _load() async {
    if (!mounted || !_allowed) return;
    final accepts = captureNativeRead(_identity, () => _identity);
    if (!accepts()) return;
    setState(() {
      _loading = true;
      _detail = null;
      _error = null;
      _reloadRequired = false;
    });
    try {
      final result = await ref
          .read(priceAnalysisRepositoryProvider)
          .detail(widget.goodsId, widget.kind, widget.row);
      if (!accepts() || !_allowed) return;
      if (result.observation.identity != widget.row.identity ||
          result.observation.text('sourceRevision') !=
              widget.row.text('sourceRevision')) {
        setState(() {
          _loading = false;
          _error = priceText(context, 'detailChanged');
          _reloadRequired = true;
        });
        return;
      }
      acceptNativeRead();
      setState(() {
        _detail = result;
        _loading = false;
      });
    } catch (error) {
      if (!accepts() || !_allowed) return;
      setState(() {
        _loading = false;
        _error = error is ApiException
            ? error.message
            : priceText(context, 'UNAVAILABLE');
        _reloadRequired = true;
      });
    }
  }

  bool _canOpen(PriceObservation row) {
    final path = priceObservationSourcePath(row);
    return nativeReadAccessConfirmed &&
        _allowed &&
        path != null &&
        locationAllowedFor(
          ref.read(currentPermissionsProvider),
          ref.read(isSuperAdminProvider),
          path,
        );
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final detail = nativeReadAccessConfirmed && _allowed ? _detail : null;
    return Stack(
      children: [
        UtenCollapsingHeaderScrollView(
          compactBodyMinHeight: 320,
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
                          detail?.title.isNotEmpty == true
                              ? detail!.title
                              : priceText(context, 'priceDetail'),
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
                const Divider(height: 1),
                if (detail?.summary.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Text(detail!.summary),
                  ),
                if (detail?.reasons.isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Text(
                      detail!.reasons
                          .map((reason) => priceText(context, reason))
                          .toSet()
                          .join(' · '),
                    ),
                  ),
                if (detail != null && _canOpen(detail.observation))
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: FilledButton.tonalIcon(
                      onPressed: () {
                        if (_canOpen(detail.observation)) {
                          Navigator.pop(context, detail.observation);
                        }
                      },
                      icon: const Icon(Icons.open_in_new),
                      label: Text(priceText(context, 'openSource')),
                    ),
                  ),
              ],
            ),
          ),
          body: KeyedSubtree(
            key: _bodyKey,
            child: detail == null
                ? (_error != null
                      ? UtenEmpty(
                          message: _error!,
                          isError: true,
                          actionLabel: priceText(
                            context,
                            _reloadRequired ? 'reloadHistory' : 'retry',
                          ),
                          onAction: _reloadRequired
                              ? widget.onReloadHistory
                              : _load,
                        )
                      : _loading
                      ? const SizedBox.shrink()
                      : nativeReadAccessNotice())
                : Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s16,
                    ),
                    child: MasterDataTableView<Map<String, dynamic>>(
                      tableKey: 'goods.price-detail',
                      primary: true,
                      virtualized: true,
                      showFullscreenToggle: false,
                      items: [
                        for (final field in detail.fields)
                          if (!{
                            'unitName',
                            'currencyName',
                          }.contains(field['key']))
                            {
                              ...field,
                              if ({
                                'quantity',
                                'amount',
                                'unitPrice',
                              }.contains(field['key']))
                                'value': priceObservationValue(
                                  detail.observation,
                                  field['key'] as String,
                                ),
                            },
                      ],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      rowKeyOf: (row) => row['key']?.toString(),
                      paginationScope: widget.row.identity,
                      columns: [
                        MasterColumnDef(
                          key: 'label',
                          sortable: true,
                          filterFromRows: true,
                          label: priceText(context, 'field'),
                          width: 150,
                          value: (row) => row['label']?.toString() ?? '',
                        ),
                        MasterColumnDef(
                          key: 'value',
                          sortable: true,
                          filterFromRows: true,
                          label: priceText(context, 'value'),
                          width: 300,
                          aiSensitive: true,
                          value: (row) => row['value']?.toString() ?? '—',
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        if (_loading)
          UtenBusyOverlay(
            title: priceText(context, 'loadingDetail'),
            semanticsKey: const Key('price-detail-loading'),
          ),
      ],
    );
  }
}
