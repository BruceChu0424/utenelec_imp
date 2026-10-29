import 'package:uten_imp/components/buttons/uten_close_button.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/pricing/price_analysis_l10n.dart';
import '../../../shared/pricing/price_analysis_models.dart';
import '../../../shared/pricing/price_analysis_repository.dart';
import '../../../shared/pricing/price_summary_value.dart';
import 'master_data_table_view.dart';

String _text(Map<String, dynamic> row, String key) =>
    row[key]?.toString() ?? '';
String supplierGroupEvidence(Map<String, dynamic> group) {
  final lines =
      priceMaps(group['lines'])
          .map(
            (line) => [
              'orderId',
              'orderItemId',
              'sourceRevision',
            ].map((key) => _text(line, key)).join('|'),
          )
          .toList()
        ..sort();
  return jsonEncode([group['key'], lines]);
}

String _quantity(Map<String, dynamic> row, String key, String unit) =>
    '${priceNumber(row[key])}${unit.isEmpty ? '' : ' $unit'}';

class GoodsSubcontractSupplierTable extends StatelessWidget {
  const GoodsSubcontractSupplierTable({
    super.key,
    required this.result,
    required this.onOpen,
  });
  final Map<String, dynamic> result;
  final ValueChanged<Map<String, dynamic>> onOpen;
  @override
  Widget build(BuildContext context) {
    final groups = priceMaps(result['groups']);
    final plans =
        groups.map((group) => _text(group, 'materialBasisKey')).toSet().toList()
          ..sort();
    String planLabel(Map<String, dynamic> group) =>
        '${priceText(context, 'materialPlan')} ${plans.indexOf(_text(group, 'materialBasisKey')) + 1}';
    MasterColumnDef<Map<String, dynamic>> column(
      String key,
      String label,
      double width, {
      bool quantity = false,
      bool ratio = false,
    }) => MasterColumnDef(
      key: key,
      label: priceText(context, label),
      width: width,
      minimumWidthOf: (_) => 48,
      sortable: true,
      filterFromRows: true,
      type: quantity || ratio || key.endsWith('Count') ? 'number' : 'text',
      aiSensitive: quantity || ratio || key == 'supplierName',
      value: (row) => _text(row, key),
      measureValueOf: (row) => quantity
          ? _quantity(row, key, _text(row, 'unitName'))
          : ratio
          ? '${compactPriceStatistic(row[key])}%'
          : _text(row, key),
      exactValueOf: quantity || ratio || key.endsWith('Count')
          ? (row) => _text(row, key)
          : null,
      cellBuilder: quantity || ratio
          ? (cellContext, row) {
              final raw = priceNumber(row[key]);
              final exact = ratio
                  ? (raw == '—' ? raw : '$raw%')
                  : _quantity(row, key, _text(row, 'unitName'));
              return Tooltip(
                message: exact,
                child: Text(
                  ratio && raw != '—'
                      ? '${compactPriceStatistic(row[key])}%'
                      : exact,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(cellContext).textTheme.bodyMedium?.copyWith(
                    color: MasterDataTableCellScope.maybeOf(
                      cellContext,
                    )?.foregroundColor,
                  ),
                ),
              );
            }
          : null,
    );
    return MasterDataTableView<Map<String, dynamic>>(
      expensiveRowMounts: false,
      key: const Key('subcontract-supplier-table'),
      toolbarLeadingActions: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                priceText(context, 'supplierLossTitle'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if (result['status'] != 'READY')
                Text(
                  priceText(
                    context,
                    result['status']?.toString() ?? 'UNAVAILABLE',
                  ),
                ),
            ],
          ),
        ),
      ],
      tableKey: 'goods.subcontract-suppliers',
      primary: true,
      virtualized: true,
      items: groups,
      facets: const {},
      nullCounts: const {},
      filters: const {},
      onFilterChanged: (_, _) {},
      rowKeyOf: (row) => _text(row, 'key'),
      rowWidgetKeyOf: (row) => ValueKey('supplier-group-${row['key']}'),
      onRowTap: (group) => onOpen({...group, '_planLabel': planLabel(group)}),
      paginationScope: result['goodsId'],
      emptyMessage: priceText(
        context,
        result['status']?.toString() ?? 'noData',
      ),
      columns: [
        column('supplierName', 'supplier', 160),
        column('confirmedLossRatePct', 'confirmedLossRate', 150, ratio: true),
        column('settledSourceOrderCount', 'settledOrders', 110),
        column(
          'settledConfirmedLossQty',
          'confirmedLossQty',
          160,
          quantity: true,
        ),
        column('settledOrderQty', 'basisQty', 160, quantity: true),
        MasterColumnDef(
          key: 'features',
          label: priceText(context, 'supplierFeatures'),
          width: 190,
          sortable: true,
          filterFromRows: true,
          value: (row) =>
              '${planLabel(row)} · ${row['materialKindCount'] ?? 0} ${priceText(context, 'materialKinds')} · ${priceText(context, 'conversion')} ${priceNumber(row['unitRate'])}',
        ),
        column('pendingLineCount', 'pendingLines', 100),
        column('excludedLineCount', 'reviewLines', 100),
        column('colorName', 'color', 85),
        column('lastOrderDate', 'lastOrderDate', 130),
      ],
    );
  }
}

class GoodsSubcontractSupplierDetail extends ConsumerStatefulWidget {
  const GoodsSubcontractSupplierDetail({
    super.key,
    required this.goodsId,
    required this.days,
    required this.group,
    required this.onRefresh,
  });
  final String goodsId;
  final int days;
  final Map<String, dynamic> group;
  final VoidCallback onRefresh;
  @override
  ConsumerState<GoodsSubcontractSupplierDetail> createState() =>
      _SupplierDetailState();
}

class _SupplierDetailState extends ConsumerState<GoodsSubcontractSupplierDetail>
    with NativeReadViewScopeMixin<GoodsSubcontractSupplierDetail> {
  Map<String, dynamic>? _group;
  String? _error;
  bool _loading = false;
  String _summary = '';
  final _chromeKey = GlobalKey();
  final _bodyKey = GlobalKey();
  bool get _allowed =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).containsAll({
        Perm.goodsView,
        Perm.goodsPriceAnalysisView,
      });
  String get _identity =>
      '${widget.goodsId}|${widget.days}|${supplierGroupEvidence(widget.group)}';
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
        _group = null;
        _loading = false;
        _error = null;
        _summary = '';
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
      _group = null;
      _error = null;
    });
    try {
      final response = await ref
          .read(priceAnalysisRepositoryProvider)
          .subcontractSuppliers(widget.goodsId, {
            'days': widget.days,
            'supplierId': widget.group['supplierId'],
          });
      if (!accepts() || !_allowed) return;
      final group = priceMaps(
        response['groups'],
      ).where((row) => row['key'] == widget.group['key']).firstOrNull;
      if (response['applicable'] != true ||
          response['dataComplete'] != true ||
          group == null ||
          supplierGroupEvidence(group) != supplierGroupEvidence(widget.group)) {
        setState(() {
          _loading = false;
          _error = priceText(context, 'supplierChanged');
        });
        return;
      }
      acceptNativeRead();
      setState(() {
        _group = group;
        _summary = response['summary']?.toString() ?? '';
        _loading = false;
      });
    } catch (e) {
      if (!accepts()) return;
      setState(() {
        _loading = false;
        _error = e is ApiException
            ? e.message
            : priceText(context, 'UNAVAILABLE');
      });
    }
  }

  bool _canOpen(Map<String, dynamic> line) =>
      nativeReadAccessConfirmed &&
      _allowed &&
      line['canOpenSource'] == true &&
      _text(line, 'orderId').isNotEmpty &&
      locationAllowedFor(
        ref.read(currentPermissionsProvider),
        ref.read(isSuperAdminProvider),
        '/subcontract/orders/${Uri.encodeComponent(_text(line, 'orderId'))}',
      );
  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final group = nativeReadAccessConfirmed && _allowed ? _group : null;
    final unit = group == null ? '' : _text(group, 'unitName');
    MasterColumnDef<Map<String, dynamic>> col(
      String key,
      String label,
      double width, {
      bool qty = false,
    }) => MasterColumnDef(
      key: key,
      label: priceText(context, label),
      width: width,
      minimumWidthOf: (_) => 48,
      sortable: true,
      filterFromRows: true,
      type: qty ? 'number' : 'text',
      value: (row) => _text(row, key),
      measureValueOf: (row) =>
          qty ? _quantity(row, key, unit) : _text(row, key),
      exactValueOf: qty ? (row) => _text(row, key) : null,
      aiSensitive: qty,
      cellBuilder: qty
          ? (cellContext, row) => Tooltip(
              message: _quantity(row, key, unit),
              child: Text(
                _quantity(row, key, unit),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(cellContext).textTheme.bodyMedium?.copyWith(
                  color: MasterDataTableCellScope.maybeOf(
                    cellContext,
                  )?.foregroundColor,
                ),
              ),
            )
          : null,
    );
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
                          group == null
                              ? priceText(context, 'supplierLossTitle')
                              : '${_text(group, 'supplierName')} · ${_text(widget.group, '_planLabel')}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      UtenCloseButton(
                        onPressed: () => Navigator.pop(context),
                        tooltip: priceText(context, 'close'),
                      ),
                    ],
                  ),
                ),
                if (group != null)
                  ExpansionTile(
                    title: Text(priceText(context, 'lossBasis')),
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(UtenSpacing.s16),
                        child: Text(_summary),
                      ),
                    ],
                  ),
              ],
            ),
          ),
          body: KeyedSubtree(
            key: _bodyKey,
            child: _error != null
                ? UtenEmpty(
                    message: _error!,
                    isError: true,
                    actionLabel: priceText(context, 'reloadHistory'),
                    onAction: widget.onRefresh,
                  )
                : group == null
                ? const SizedBox.shrink()
                : MasterDataTableView<Map<String, dynamic>>(
                    expensiveRowMounts: false,
                    tableKey: 'goods.subcontract-supplier-detail',
                    primary: true,
                    virtualized: true,
                    items: priceMaps(group['lines']),
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    rowKeyOf: (row) =>
                        '${row['orderId']}|${row['orderItemId']}',
                    columns: [
                      col('orderNo', 'number', 145),
                      col('orderDate', 'date', 115),
                      col('orderedQty', 'basisQty', 155, qty: true),
                      col(
                        'qualifiedStockedNetQty',
                        'qualifiedNetQty',
                        170,
                        qty: true,
                      ),
                      col(
                        'confirmedLossQty',
                        'confirmedLossQty',
                        155,
                        qty: true,
                      ),
                      col(
                        'issuedEquivalentQty',
                        'issuedEquivalentQty',
                        160,
                        qty: true,
                      ),
                      col('receivedQty', 'receivedQty', 160, qty: true),
                      col('returnedQty', 'returnedQty', 155, qty: true),
                      col(
                        'legacyConfirmedLossQty',
                        'legacyLossQty',
                        160,
                        qty: true,
                      ),
                      MasterColumnDef(
                        key: 'status',
                        label: priceText(context, 'recordStatus'),
                        width: 100,
                        sortable: true,
                        filterFromRows: true,
                        value: (row) =>
                            priceText(context, _text(row, 'status')),
                      ),
                      MasterColumnDef(
                        key: 'reason',
                        label: priceText(context, 'basis'),
                        width: 250,
                        sortable: true,
                        filterFromRows: true,
                        value: (row) => priceStrings(
                          row['reasonCodes'],
                        ).map((code) => priceText(context, code)).join(' · '),
                      ),
                      MasterColumnDef(
                        key: 'action',
                        label: priceText(context, 'openSource'),
                        width: 105,
                        minimumWidthOf: (_) => 48,
                        value: (_) => '',
                        cellBuilder: (_, row) => _canOpen(row)
                            ? Align(
                                alignment: Alignment.centerLeft,
                                child: UtenTableCellAction(
                                  label: priceText(context, 'openSource'),
                                  onPressed: () {
                                    if (_canOpen(row)) {
                                      Navigator.pop(
                                        context,
                                        _text(row, 'orderId'),
                                      );
                                    }
                                  },
                                ),
                              )
                            : const Text('—'),
                      ),
                    ],
                  ),
          ),
        ),
        if (_loading)
          UtenBusyOverlay(
            showDoNotLeaveHint: false,
            title: priceText(context, 'loadingDetail'),
          ),
      ],
    );
  }
}
