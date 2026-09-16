import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/stock_doc.dart';

/// 单张领料和批量出库共用的逐物料明细，来源始终随所属单据展示。
class ProductionDrawDetailRow {
  const ProductionDrawDetailRow(this.document, this.item);

  final StockDocDetail document;
  final StockDocItem item;
}

/// 一行待出库行的校验结果（页面提交前逐行核对）。
String? drawIssueQtyError(ProductionDrawDetailRow row, String input) {
  final value = double.tryParse(input.trim());
  if (value == null || !value.isFinite) return '请输入有效数量';
  if (value < 0) return '数量不能为负';
  if (value == 0) return '出库数量需大于 0';
  if (value > row.item.remainingQty + 1e-9) {
    return '不能超过待出库 ${row.item.remainingQty}';
  }
  return null;
}

class ProductionDrawDetailTable extends StatelessWidget {
  const ProductionDrawDetailTable({
    super.key,
    required this.documents,
    required this.names,
    required this.permissions,
    this.superAdmin = false,
    this.primary = false,
    this.issueQtyControllers,
    this.lineRemarkControllers,
    this.issueSaving = false,
  });

  final List<StockDocDetail> documents;
  final MasterNameService names;
  final Set<String> permissions;
  final bool superAdmin;
  final bool primary;

  /// 2026-09-12 用户口径「数量在表格里改，出库只弹总结」：单张详情页传入
  /// 逐行「本次出库」数量与「行备注」控制器（键=item.id，页面持有随路由销毁）；
  /// null = 只读（批量出库视图等）。控制器由页面在 _load 后重建。
  final Map<String, TextEditingController>? issueQtyControllers;
  final Map<String, TextEditingController>? lineRemarkControllers;

  /// 出库提交中：输入格禁用（只读防抖动）。
  final bool issueSaving;

  @override
  Widget build(
    BuildContext context,
  ) => MasterDataTableView<ProductionDrawDetailRow>(
    key: const Key('production-draw-detail-table'),
    primary: primary,
    bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    columns: [
      MasterColumnDef(
        key: 'billNo',
        label: '领料单号',
        width: 160,
        value: (row) => row.document.billNo ?? '—',
      ),
      // 2026-09-14 全站列序统一（ADR-081 §4.1）：名称 → 编号 → 颜色。
      MasterColumnDef(
        key: 'goods',
        label: '货品名称',
        width: 200,
        value: (row) => names.goods(row.item.goodsId),
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '编号',
        width: 120,
        value: (row) => names.goodsInfo(row.item.goodsId)?.code ?? '—',
      ),
      // 颜色列原来排在库位号之后（第 8 列），仓库拣货要横滚才看得到：同名不同色
      // 在本系统很常见，编号/名称/颜色必须在前几列同屏可见，故上移紧跟货品名称。
      // 已有独立颜色列，货品列就不再重复带颜色。
      MasterColumnDef(
        key: 'color',
        label: '颜色',
        width: 90,
        value: (row) => names.color(row.item.colorId),
      ),
      MasterColumnDef(
        key: 'warehouse',
        label: '仓库',
        width: 160,
        value: (row) => names.warehouse(row.document.warehouseId),
      ),
      MasterColumnDef(
        key: 'department',
        label: '领料车间',
        width: 150,
        value: (row) => names.department(row.document.departmentId),
      ),
      MasterColumnDef(
        key: 'worker',
        label: '领料负责人',
        width: 140,
        value: (row) => names.employee(row.document.workerId),
      ),
      MasterColumnDef(
        key: 'place',
        label: '库位号',
        width: 100,
        value: (row) => row.item.place?.trim().isNotEmpty == true
            ? row.item.place!
            : names.goodsInfo(row.item.goodsId)?.stockPlace ?? '—',
      ),
      MasterColumnDef(
        key: 'unit',
        label: '单位',
        width: 70,
        value: (row) => names.unit(row.item.unitId),
      ),
      MasterColumnDef(
        key: 'qty',
        label: '应领数量',
        width: 105,
        type: 'number',
        value: (row) => _quantity(row.item.qty ?? 0),
      ),
      MasterColumnDef(
        key: 'requestedQty',
        label: '已申请领料',
        width: 105,
        type: 'number',
        value: (row) => _quantity(row.item.requestedQty ?? row.item.qty ?? 0),
      ),
      MasterColumnDef(
        key: 'issuedQty',
        label: '已出库',
        width: 105,
        type: 'number',
        value: (row) => _quantity(row.item.issuedQty ?? 0),
      ),
      MasterColumnDef(
        key: 'remainingQty',
        label: '待出库',
        width: 105,
        type: 'number',
        value: (row) => _quantity(row.item.remainingQty),
      ),
      // 2026-09-12：本次出库数量与行备注在表格内编辑（默认=待出库），
      // 出库按钮只弹总结确认——弹窗里不再改数字、不再传附件。
      if (issueQtyControllers != null)
        MasterColumnDef(
          key: 'issueQty',
          label: '本次出库',
          width: 120,
          value: (row) => issueQtyControllers![row.item.id]?.text ?? '',
          cellBuilder: (context, row) {
            final controller = issueQtyControllers![row.item.id];
            if (controller == null) return const Text('—');
            return Semantics(
              textField: true,
              label: '${names.goods(row.item.goodsId)} 本次出库数量',
              child: TextField(
                key: ValueKey('draw-issue-qty-${row.item.id}'),
                controller: controller,
                enabled: !issueSaving && row.item.remainingQty > 0,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                textAlign: TextAlign.right,
                decoration: const InputDecoration(isDense: true),
              ),
            );
          },
        ),
      if (lineRemarkControllers != null)
        MasterColumnDef(
          key: 'lineRemark',
          label: '行备注',
          width: 160,
          value: (row) => lineRemarkControllers![row.item.id]?.text ?? '',
          cellBuilder: (context, row) {
            final controller = lineRemarkControllers![row.item.id];
            if (controller == null) return const Text('—');
            return Semantics(
              textField: true,
              label: '${names.goods(row.item.goodsId)} 行备注',
              child: TextField(
                key: ValueKey('draw-issue-remark-${row.item.id}'),
                controller: controller,
                enabled: !issueSaving && row.item.remainingQty > 0,
                maxLength: 60,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '选填',
                  counterText: '',
                ),
              ),
            );
          },
        ),
      MasterColumnDef(
        key: 'issueStatus',
        label: '出库进度',
        width: 120,
        value: (row) => drawIssueStatusLabel(row.document.issueStatus),
      ),
      MasterColumnDef(
        key: 'planNo',
        label: '生产计划',
        width: 170,
        value: (row) => row.document.planNo ?? '—',
        cellBuilder: (context, row) => _sourceLink(
          context,
          row.document.planNo,
          row.document.sourcePlanId == null
              ? null
              : RoutePath.productionPlanDetail(row.document.sourcePlanId!),
        ),
      ),
      MasterColumnDef(
        key: 'sourceDocNo',
        label: '来源',
        width: 170,
        value: (row) => row.item.sourceDocNo ?? row.document.sourceDocNo ?? '—',
        cellBuilder: (context, row) => _sourceLink(
          context,
          row.item.sourceDocNo ?? row.document.sourceDocNo,
          row.document.sourceDailyReportId == null
              ? null
              : '/production/daily-reports/${row.document.sourceDailyReportId}',
        ),
      ),
      MasterColumnDef(
        key: 'series',
        label: '系列',
        width: 90,
        value: (row) => names.goodsInfo(row.item.goodsId)?.series ?? '—',
      ),
      MasterColumnDef(
        key: 'weight',
        label: '实际重量',
        width: 105,
        type: 'number',
        value: (row) =>
            row.item.weight == null ? '—' : _quantity(row.item.weight!),
      ),
      MasterColumnDef(
        key: 'remark',
        label: '备注',
        width: 200,
        value: (row) => row.item.remark ?? row.document.remark ?? '—',
      ),
    ],
    items: [
      for (final document in documents)
        for (final item in document.items)
          ProductionDrawDetailRow(document, item),
    ],
    emptyMessage: '暂无领料明细',
  );

  Widget _sourceLink(BuildContext context, String? number, String? path) {
    final label = number?.isNotEmpty == true ? number! : '—';
    if (path == null ||
        number?.isNotEmpty != true ||
        !locationAllowedFor(permissions, superAdmin, path)) {
      return Text(label);
    }
    return TextButton(
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.zero,
      ),
      onPressed: () => context.push(path),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }

  static String _quantity(double value) => value
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}
