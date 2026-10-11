import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/warehouse_document_history_config.dart';
import '../models/warehouse_document_history.dart';
import '../repositories/warehouse_document_history_repository.dart';

/// 「数量 + 单位」内联 (2026-10-10 口径)：单位列已删除，数量直接带单位显示。
/// 本页数量是服务端精度原文（字符串），走 [formatQtyWithUnit] 拼单位时放宽到
/// 6 位小数、不丢服务端精度；空/非法数量保持「—」。
String _historyQtyWithUnit(String? text, String? unitName) {
  final value = num.tryParse(text ?? '');
  if (value == null) return '—';
  return formatQtyWithUnit(value, unitName, maxDecimals: 6);
}

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
            // 2026-09-11 折叠头+表内滚（对齐采购/货品资料页）：上滑先收头部
            // （错误提示/事实卡），明细标题吸顶后表格内部继续滚。
            : UtenContentContainer.wide(
                child: UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
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
                      ],
                    ),
                  ),
                  // body：明细表占满内滚（primary 拾取联动控制器）。
                  body: MasterDataTableView<WarehouseDocumentPhysicalItem>(
                    tableKey:
                        'features.warehouse.pages.warehouse_document_history_detail_page.WarehouseDocumentHistoryDetailPageState.build.1',
                    key: Key(
                      'warehouse-history-detail-table-${widget.type.segment}',
                    ),
                    primary: true,
                    columns: _physicalColumns(detail.items),
                    items: detail.items,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    emptyMessage: '该记录暂无实物明细',
                    bottomContentPadding: UtenSpacing.s16,
                  ),
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

    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final columns = <MasterColumnDef<WarehouseDocumentPhysicalItem>>[
      if (has((item) => item.inspectionStatus))
        MasterColumnDef(
          key: 'iqcStatus',
          label: '质量状态',
          width: 72,
          value: (item) => item.inspectionStatusLabel,
          // 质量状态整格底色（ADR-169）：不合格=红 / 检验完成=绿 / 待检=黄 /
          // 部分完成=橙 / 已撤销=灰；未关联/无需质检保持无色，判定共用 config。
          cellColor: (context, item) =>
              warehouseInspectionCellColor(item.inspectionStatus),
        ),
      MasterColumnDef(
        key: 'lineNumber',
        label: '行号',
        width: 64,
        type: 'number',
        value: (item) => item.lineNo?.toString() ?? '—',
      ),
      // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色的固定顺序。
      MasterColumnDef(
        key: 'goodsName',
        label: '货品名称',
        width: 200,
        value: (item) => item.goodsName ?? '—',
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 130,
        value: (item) => UtenGoodsAttributeCell.text(item.goodsCode),
        cellBuilder: (_, item) => UtenGoodsAttributeCell(item.goodsCode),
      ),
      if (has((item) => item.colorName))
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (item) => UtenGoodsAttributeCell.text(item.colorName),
          cellBuilder: (_, item) => UtenGoodsAttributeCell(item.colorName),
        ),
      // 父件也是一个货品，同样按「名称 / 编号 / 颜色」三列展开（2026-09-14）。
      // 父件颜色取 parentColorName（行色优先、父件主档色兜底）：委外发料/材料退
      // 的父件常按颜色分行，只有编号+名称仍会指错成品。
      if (has((item) => item.parentGoodsCode ?? item.parentGoodsName)) ...[
        MasterColumnDef(
          key: 'parentGoods',
          label: '父件名称',
          width: 200,
          value: (item) => item.parentGoodsName ?? item.parentGoodsCode ?? '—',
          cellBuilderHandlesSemantics: true,
          cellBuilder: (_, item) =>
              UtenGoodsIdentityCell(name: item.parentGoodsName),
        ),
        MasterColumnDef(
          key: 'parentGoodsCode',
          label: '父件编号',
          width: 130,
          value: (item) => UtenGoodsAttributeCell.text(item.parentGoodsCode),
          cellBuilder: (_, item) =>
              UtenGoodsAttributeCell(item.parentGoodsCode),
        ),
        MasterColumnDef(
          key: 'parentColorName',
          label: '父件颜色',
          width: 96,
          value: (item) => UtenGoodsAttributeCell.text(item.parentColorName),
          cellBuilder: (_, item) =>
              UtenGoodsAttributeCell(item.parentColorName),
        ),
      ],
      if (has((item) => item.stockPlace))
        MasterColumnDef(
          key: 'stockPlace',
          label: '当前建议库位',
          width: 126,
          value: (item) => item.stockPlace ?? '—',
        ),
      MasterColumnDef(
        key: 'quantity',
        label: '数量',
        width: 135,
        type: 'number',
        value: (item) => _historyQtyWithUnit(item.qty, item.unitName),
      ),
      // 重量紧跟数量 (ADR-135)：千克按用户显示单位换算并带单位；没称显示「未称」。
      if (items.any((item) => item.weightKg != null))
        MasterColumnDef(
          key: 'weight',
          label: '重量',
          width: 110,
          type: 'weight',
          value: (item) => formatWeightValue(item.weightKg, display: display),
        ),
      // 箱数是胶箱数量，单位是「箱」而非货品单位，保持纯数字不内联（2026-10-10）。
      if (has((item) => item.boxQty))
        MasterColumnDef(
          key: 'boxQuantity',
          label: '箱数',
          width: 90,
          type: 'number',
          value: (item) => item.boxQty ?? '—',
        ),
      if (has((item) => item.returnedQty))
        MasterColumnDef(
          key: 'returnedQuantity',
          label: '已退数量',
          width: 143,
          type: 'number',
          value: (item) => _historyQtyWithUnit(item.returnedQty, item.unitName),
        ),
      if (has((item) => item.wastedQty))
        MasterColumnDef(
          key: 'wastedQuantity',
          label: '损耗数量',
          width: 143,
          type: 'number',
          value: (item) => _historyQtyWithUnit(item.wastedQty, item.unitName),
        ),
      if (has((item) => item.atSupplierQty))
        MasterColumnDef(
          key: 'atSupplierQuantity',
          label: '委外商在手',
          width: 153,
          type: 'number',
          value: (item) =>
              _historyQtyWithUnit(item.atSupplierQty, item.unitName),
        ),
      if (has((item) => item.consumedQty))
        MasterColumnDef(
          key: 'consumedQuantity',
          label: '已耗用',
          width: 135,
          type: 'number',
          value: (item) => _historyQtyWithUnit(item.consumedQty, item.unitName),
        ),
      if (has((item) => item.supplierEndingQty))
        MasterColumnDef(
          key: 'supplierEndingQuantity',
          label: '委外商结余',
          width: 153,
          type: 'number',
          value: (item) =>
              _historyQtyWithUnit(item.supplierEndingQty, item.unitName),
        ),
      if (has((item) => item.endingQty))
        MasterColumnDef(
          key: 'endingQuantity',
          label: '期末数量',
          width: 143,
          type: 'number',
          value: (item) => _historyQtyWithUnit(item.endingQty, item.unitName),
        ),
      if (has((item) => item.standardQty))
        MasterColumnDef(
          key: 'standardQuantity',
          label: '标准数量',
          width: 143,
          type: 'number',
          value: (item) => _historyQtyWithUnit(item.standardQty, item.unitName),
        ),
      if (has((item) => item.wasteRate))
        MasterColumnDef(
          key: 'wasteRate',
          label: '损耗率',
          width: 96,
          type: 'number',
          value: (item) => item.wasteRate ?? '—',
        ),
      if (has((item) => item.passedBaseQty))
        MasterColumnDef(
          key: 'iqcPassedBaseQuantity',
          label: '品质合格量',
          width: 153,
          type: 'number',
          value: (item) =>
              _historyQtyWithUnit(item.passedBaseQty, item.unitName),
        ),
      if (has((item) => item.stockedBaseQty))
        MasterColumnDef(
          key: 'iqcStockedBaseQuantity',
          label: '仓库已入库',
          width: 153,
          type: 'number',
          value: (item) =>
              _historyQtyWithUnit(item.stockedBaseQty, item.unitName),
        ),
      if (has((item) => item.pendingStockInBaseQty))
        MasterColumnDef(
          key: 'iqcPendingStockInBaseQuantity',
          label: '合格待入库',
          width: 153,
          type: 'number',
          value: (item) =>
              _historyQtyWithUnit(item.pendingStockInBaseQty, item.unitName),
        ),
      if (has((item) => item.failedBaseQty))
        MasterColumnDef(
          key: 'iqcFailedBaseQuantity',
          label: '不合格基础量',
          width: 161,
          type: 'number',
          value: (item) =>
              _historyQtyWithUnit(item.failedBaseQty, item.unitName),
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
