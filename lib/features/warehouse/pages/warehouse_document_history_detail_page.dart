import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/warehouse_document_history.dart';
import '../repositories/warehouse_document_history_repository.dart';

/// Read-only physical detail for warehouse staff.
class WarehouseDocumentHistoryDetailPage extends ConsumerStatefulWidget {
  const WarehouseDocumentHistoryDetailPage({
    super.key,
    required this.type,
    required this.id,
  });

  final WarehouseDocumentHistoryType type;
  final String id;

  @override
  ConsumerState<WarehouseDocumentHistoryDetailPage> createState() =>
      _WarehouseDocumentHistoryDetailPageState();
}

class _WarehouseDocumentHistoryDetailPageState
    extends ConsumerState<WarehouseDocumentHistoryDetailPage> {
  WarehouseDocumentHistoryDetail? _detail;
  bool _loading = false;
  String? _error;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(warehouseDocumentHistoryRepositoryProvider(widget.type))
          .detail(widget.id);
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '${widget.type.documentLabel}详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: '${widget.type.documentLabel}详情',
        subtitle: '仓库实物视图',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: widget.type.listPath()),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: Key(
                'warehouse-history-detail-refresh-${widget.type.segment}',
              ),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && detail != null,
              onPressed: _loading ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && detail == null
            ? const UtenSkeletonList(itemCount: 6)
            : _error != null && detail == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : detail == null
            ? UtenEmpty.error(message: '记录不存在或您无权查看')
            : UtenContentContainer.wide(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _DetailPhysicalBanner(type: widget.type),
                    if (_error != null) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _factsCard(detail),
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      '实物明细 (${detail.items.length})',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    MasterDataTableView<WarehouseDocumentPhysicalItem>(
                      key: Key(
                        'warehouse-history-detail-table-${widget.type.segment}',
                      ),
                      embedded: true,
                      columns: _physicalColumns(detail.items),
                      items: detail.items,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      emptyMessage: '该记录暂无实物明细',
                    ),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _factsCard(WarehouseDocumentHistoryDetail detail) {
    final header = detail.header;
    final facts = <(String, String?)>[
      ('单据号', header.displayBillNo),
      ('业务日期', header.billDate),
      ('状态', header.statusLabel),
      if (header.inspectionStatus != null)
        ('质量状态', header.inspectionStatusLabel),
      ('往来单位', header.supplierName),
      ('仓库', header.warehouseName),
      ('来源单据', header.sourceDocNo),
      ('明细行', header.itemCount.toString()),
      ('制单人', detail.makerName),
      ('审核人', detail.approverName),
      ('交货人', detail.senderName),
      ('收货人', detail.receiverName),
      ('经办人', detail.workerName),
      ('制单时间', utenFmtIsoTime(detail.createdAt)),
      ('备注', detail.remark),
    ].where((fact) => _present(fact.$2)).toList(growable: false);
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '${widget.type.documentLabel}实物信息',
      child: Card(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: UtenRadius.lgAll,
          side: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = constraints.maxWidth >= 1080
                  ? 3
                  : constraints.maxWidth >= 640
                  ? 2
                  : 1;
              final gap = UtenSpacing.s12 * (columns - 1);
              final width = (constraints.maxWidth - gap) / columns;
              return Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s12,
                children: [
                  for (final fact in facts)
                    SizedBox(
                      width: width,
                      child: _FactTile(label: fact.$1, value: fact.$2!),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  List<MasterColumnDef<WarehouseDocumentPhysicalItem>> _physicalColumns(
    List<WarehouseDocumentPhysicalItem> items,
  ) {
    bool has(String? Function(WarehouseDocumentPhysicalItem) value) {
      return items.any((item) => _present(value(item)));
    }

    final columns = <MasterColumnDef<WarehouseDocumentPhysicalItem>>[
      MasterColumnDef(
        key: 'lineNumber',
        label: '行号',
        width: 64,
        type: 'number',
        value: (item) => item.lineNo?.toString() ?? '—',
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '货品编码',
        width: 126,
        value: (item) => item.goodsCode ?? '—',
      ),
      MasterColumnDef(
        key: 'goodsName',
        label: '货品名称',
        width: 220,
        value: (item) => item.goodsName ?? '—',
      ),
      if (has((item) => item.parentGoodsCode ?? item.parentGoodsName))
        MasterColumnDef(
          key: 'parentGoods',
          label: '父件',
          width: 180,
          value: (item) => [
            item.parentGoodsCode,
            item.parentGoodsName,
          ].where(_present).join(' · '),
        ),
      if (has((item) => item.stockPlace))
        MasterColumnDef(
          key: 'stockPlace',
          label: '当前建议库位',
          width: 126,
          value: (item) => item.stockPlace ?? '—',
        ),
      if (has((item) => item.colorName))
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 100,
          value: (item) => item.colorName ?? '—',
        ),
      if (has((item) => item.unitName))
        MasterColumnDef(
          key: 'unitName',
          label: '单位',
          width: 82,
          value: (item) => item.unitName ?? '—',
        ),
      MasterColumnDef(
        key: 'quantity',
        label: '数量',
        width: 100,
        type: 'number',
        value: (item) => item.qty ?? '—',
      ),
      if (has((item) => item.boxQty))
        MasterColumnDef(
          key: 'boxQuantity',
          label: '箱数',
          width: 90,
          type: 'number',
          value: (item) => item.boxQty ?? '—',
        ),
      if (has((item) => item.weight))
        MasterColumnDef(
          key: 'weight',
          label: '重量',
          width: 100,
          type: 'number',
          value: (item) => item.weight ?? '—',
        ),
      if (has((item) => item.returnedQty))
        MasterColumnDef(
          key: 'returnedQuantity',
          label: '已退数量',
          width: 108,
          type: 'number',
          value: (item) => item.returnedQty ?? '—',
        ),
      if (has((item) => item.wastedQty))
        MasterColumnDef(
          key: 'wastedQuantity',
          label: '损耗数量',
          width: 108,
          type: 'number',
          value: (item) => item.wastedQty ?? '—',
        ),
      if (has((item) => item.atSupplierQty))
        MasterColumnDef(
          key: 'atSupplierQuantity',
          label: '委外商在手',
          width: 118,
          type: 'number',
          value: (item) => item.atSupplierQty ?? '—',
        ),
      if (has((item) => item.consumedQty))
        MasterColumnDef(
          key: 'consumedQuantity',
          label: '已耗用',
          width: 100,
          type: 'number',
          value: (item) => item.consumedQty ?? '—',
        ),
      if (has((item) => item.supplierEndingQty))
        MasterColumnDef(
          key: 'supplierEndingQuantity',
          label: '委外商结余',
          width: 118,
          type: 'number',
          value: (item) => item.supplierEndingQty ?? '—',
        ),
      if (has((item) => item.endingQty))
        MasterColumnDef(
          key: 'endingQuantity',
          label: '期末数量',
          width: 108,
          type: 'number',
          value: (item) => item.endingQty ?? '—',
        ),
      if (has((item) => item.standardQty))
        MasterColumnDef(
          key: 'standardQuantity',
          label: '标准数量',
          width: 108,
          type: 'number',
          value: (item) => item.standardQty ?? '—',
        ),
      if (has((item) => item.wasteRate))
        MasterColumnDef(
          key: 'wasteRate',
          label: '损耗率',
          width: 96,
          type: 'number',
          value: (item) => item.wasteRate ?? '—',
        ),
      if (has((item) => item.inspectionStatus))
        MasterColumnDef(
          key: 'iqcStatus',
          label: '质量状态',
          width: 112,
          value: (item) => item.inspectionStatusLabel,
        ),
      if (has((item) => item.passedBaseQty))
        MasterColumnDef(
          key: 'iqcPassedBaseQuantity',
          label: '品质合格量',
          width: 118,
          type: 'number',
          value: (item) => item.passedBaseQty ?? '—',
        ),
      if (has((item) => item.stockedBaseQty))
        MasterColumnDef(
          key: 'iqcStockedBaseQuantity',
          label: '仓库已入库',
          width: 118,
          type: 'number',
          value: (item) => item.stockedBaseQty ?? '—',
        ),
      if (has((item) => item.pendingStockInBaseQty))
        MasterColumnDef(
          key: 'iqcPendingStockInBaseQuantity',
          label: '合格待入库',
          width: 118,
          type: 'number',
          value: (item) => item.pendingStockInBaseQty ?? '—',
        ),
      if (has((item) => item.failedBaseQty))
        MasterColumnDef(
          key: 'iqcFailedBaseQuantity',
          label: '不合格基础量',
          width: 126,
          type: 'number',
          value: (item) => item.failedBaseQty ?? '—',
        ),
      if (has((item) => item.sourceDocNo))
        MasterColumnDef(
          key: 'referenceDocumentNo',
          label: '来源单据',
          width: 170,
          value: (item) => item.sourceDocNo ?? '—',
        ),
      if (has((item) => item.cause))
        MasterColumnDef(
          key: 'reason',
          label: '原因',
          width: 180,
          value: (item) => item.cause ?? '—',
        ),
      if (has((item) => item.remark))
        MasterColumnDef(
          key: 'remark',
          label: '备注',
          width: 180,
          value: (item) => item.remark ?? '—',
        ),
    ];
    return columns;
  }
}

class _DetailPhysicalBanner extends StatelessWidget {
  const _DetailPhysicalBanner({required this.type});

  final WarehouseDocumentHistoryType type;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '仓库实物视图，不含商业信息，也不提供采购或委外业务操作。库位是当前建议值。',
      child: Container(
        key: Key('warehouse-history-detail-banner-${type.segment}'),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.45),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(type.icon, color: theme.colorScheme.primary),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Text(
                '仓库实物视图 · 仅显示数量、重量、当前建议库位、质量、来源与经办人员。'
                '库位来自当前货品主档，不是历史快照。'
                '本页不包含商业与财务信息，也不提供跨部门业务操作。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FactTile extends StatelessWidget {
  const _FactTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label：$value',
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

bool _present(String? value) => value?.trim().isNotEmpty == true;
