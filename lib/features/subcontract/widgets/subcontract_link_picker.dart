// 委外上游单据明细引入面板（编辑页"从上游引入"用）。
//
// 结构（2026-08-16 收敛）：面板状态机与外壳在共享组件
// [showUtenDocLinkPickerSheet]（components/layout/uten_doc_link_picker_sheet.dart），
// 本文件只保留委外领域差异：
//  - 发料审核未启用时的防御门禁（历史兼容说明对话框）；
//  - 4 个上游方向推断（见 upstreamTypeOf）；
//  - 剩余可引量口径（进仓←订货 / 发料←订货 / 退货←进仓/订货 / 材料退·损耗←发料）；
//  - 单据表与明细表列定义。
//
// 委外 8 单据链路更复杂（4 个上游方向，见 upstreamTypeOf）：
//   订货 → 申请；进仓 → 订货；退货 → 进仓优先/订货；
//   新增发料在冻结 BOM 快照与子件台账落地前禁止从订货引入；
//   材料退 → 发料优先/订货；损耗 → 发料。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_doc_link_picker_sheet.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/subcontract_doc_config.dart';
import '../models/subcontract_doc.dart';
import '../providers/subcontract_providers.dart';
import '../repositories/subcontract_repository.dart';
import '../../../shared/providers/master_name_provider.dart' as mn;

/// 上游引入回填项：货品 + 本次数量 + 单价(可空) + 上游明细 id + 颜色/单位。
/// [upstreamItemId] 由编辑页按 cfg 映射为对应 *ItemId 字段。
class LinkedItem {
  const LinkedItem({
    required this.goodsId,
    required this.qty,
    this.maxQty,
    this.price,
    this.upstreamItemId,
    this.colorId,
    this.unitId,
  });
  final String goodsId;
  final double qty;
  final double? maxQty;
  final double? price;
  final String? upstreamItemId;
  final String? colorId;
  final String? unitId;
}

/// 「从上游引入」的确认返回：所选明细 + 上游单据委外商 id（编辑页表头未选委外商时回填用）。
class SubcontractLinkPickResult {
  const SubcontractLinkPickResult({required this.items, this.supplierId});

  final List<LinkedItem> items;
  final String? supplierId;
}

/// 由 cfg 推断上游单据类型。退货/材料退双链时优先进仓/发料（更接近源头）。
SubcontractDocType upstreamTypeOf(SubcontractDocConfig cfg) {
  if (cfg.linkToReceiptItem) return SubcontractDocType.receipt;
  if (cfg.linkToMaterialIssueItem) return SubcontractDocType.materialIssue;
  if (cfg.linkToOrderItem) return SubcontractDocType.order;
  return SubcontractDocType.application;
}

String _upstreamLabel(SubcontractDocType t) {
  switch (t) {
    case SubcontractDocType.application:
      return '委外申请单';
    case SubcontractDocType.order:
      return '委外订货单';
    case SubcontractDocType.receipt:
      return '委外进仓单';
    case SubcontractDocType.materialIssue:
      return '委外发料单';
    default:
      return '上游单据';
  }
}

/// 上游明细剩余可引量（也是"本次数量"默认值）：
/// 进仓←订货 = 订货数 − 已收 + 已退（退回供应商后仍欠交）；
/// 发料←订货 = 未回厂产量（订货数 − 已回厂 + 成品退回），按父件口径给可发料上限；
/// 退货←进仓/订货 = 原单数 − 已退；材料退/损耗←发料 = 发出数 − 已退 − 已损耗；
/// 其它（订货←申请）= 全额。
double _remainQty(
  SubcontractDocConfig cfg,
  SubcontractDocType upstream,
  SubcontractDocItem it,
) {
  final q = it.qty ?? 0;
  switch (upstream) {
    case SubcontractDocType.order:
      if (cfg.type == SubcontractDocType.receipt) {
        return q - (it.receivedQty ?? 0);
      }
      if (cfg.type == SubcontractDocType.materialIssue) {
        // 可发料产量上限 = 未回厂量（订货 − 已回厂 + 成品退回）；材料行再由 BOM 单耗推导。
        return q - (it.receivedQty ?? 0) + (it.returnedQty ?? 0);
      }
      return q - (it.returnedQty ?? 0);
    case SubcontractDocType.receipt:
      return q - (it.returnedQty ?? 0);
    case SubcontractDocType.materialIssue:
      // 材料退/损耗←发料：默认量 = 供应商处结存（发出−回厂已消费−已退−已损耗，
      // V304 口径；已消费部分不可能再退/再损耗）。老数据无结存字段时回落旧口径。
      return it.supplierEnding ??
          (q - (it.returnedQty ?? 0) - (it.wastedQty ?? 0));
    default:
      return q;
  }
}

/// 弹出"从上游引入"右滑入大面板。null=取消；返回所选明细 + 上游委外商。
/// [initialSupplierId]：编辑页表头已选委外商时传入，面板委外商筛选默认锁定该委外商。
Future<SubcontractLinkPickResult?> showSubcontractLinkPicker(
  BuildContext context,
  WidgetRef ref,
  SubcontractDocConfig cfg, {
  String? initialSupplierId,
}) async {
  if (cfg.type == SubcontractDocType.materialIssue && !cfg.approvalEnabled) {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.lock_outline_rounded),
        title: const Text('新增发料审核暂不可用'),
        content: Text(
          '${cfg.approvalBlockedReason}\n\n'
          '$kSubcontractMaterialIssueHistoricalCompatibilityNote',
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
    return null;
  }

  final upstream = upstreamTypeOf(cfg);
  final docConfig =
      UtenDocLinkPickerConfig<
        SubcontractDocListItem,
        SubcontractDocItem,
        mn.MasterNameService
      >(
        step1Title: '从${_upstreamLabel(upstream)}引入',
        step1EmptyMessage:
            '暂无已审的${_upstreamLabel(upstream)}', // TODO(l10n): 补 arb
        partyNoun: '委外商',
        allPartiesLabel: '全部委外商', // TODO(l10n): 补 arb
        docIdOf: (d) => d.id,
        partyIdOf: (d) => d.supplierId,
        watchNames: (ref) => ref.watch(mn.masterNameServiceProvider),
        partyEntries: (names) => names.supplierEntries,
        partyName: (names, supplierId) => names.supplier(supplierId),
        initNames: (ref) async {
          ref.read(mn.masterNameServiceProvider).ensureLoaded();
        },
        loadGoodsNames: (ref, goodsIds) =>
            ref.read(mn.masterNameServiceProvider).loadGoodsNames(goodsIds),
        listDocs: (ref, page, keyword, supplierId, sort, order) => ref
            .read(subcontractRepositoryProvider(upstream))
            .list(
              page: page,
              // 拉已审单据（草稿单据的明细不该被引入）。
              filter: SubcontractDocFilter(
                keyword: keyword,
                supplierId: supplierId,
                status: kSubcontractStatusApproved,
              ),
              sort: sort,
              order: order,
            ),
        loadDetail: (ref, docId) async {
          final detail = await ref
              .read(subcontractRepositoryProvider(upstream))
              .detail(docId);
          return UtenDocLinkDetail<SubcontractDocItem>(
            partyId: detail.supplierId,
            items: detail.items,
          );
        },
        itemFields: UtenDocLinkItemFields<SubcontractDocItem>(
          goodsId: (it) => it.goodsId,
          colorId: (it) => it.colorId,
          unitId: (it) => it.unitId,
          price: (it) => it.price,
          upstreamItemId: (it) => it.id,
        ),
        docColumns: (names) => _docColumns(names),
        goodsName: (names, goodsId) => names.goods(goodsId),
        colorName: (names, colorId) => names.color(colorId),
        unitName: (names, unitId) => names.unit(unitId),
        middleItemColumns: (names) => _middleItemColumns(),
        remainQty: (it) => _remainQty(cfg, upstream, it),
        createBlankRow: () => UtenDocLinkItemRow<SubcontractDocItem>(
          const SubcontractDocItem(id: null),
        ),
      );

  final raw =
      await showUtenDocLinkPickerSheet<
        SubcontractDocListItem,
        SubcontractDocItem,
        mn.MasterNameService
      >(context, docConfig, initialPartyId: initialSupplierId);
  if (raw == null) return null;
  return SubcontractLinkPickResult(
    supplierId: raw.partyId,
    items: raw.items
        .map(
          (d) => LinkedItem(
            goodsId: d.goodsId,
            qty: d.qty,
            maxQty: d.maxQty,
            price: d.price,
            upstreamItemId: d.upstreamItemId,
            colorId: d.colorId,
            unitId: d.unitId,
          ),
        )
        .toList(),
  );
}

List<MasterColumnDef<SubcontractDocListItem>> _docColumns(
  mn.MasterNameService names,
) => [
  MasterColumnDef(
    key: 'billNo',
    label: '单据号',
    width: 140,
    value: (d) => d.billNo,
  ),
  MasterColumnDef(
    key: 'billDate',
    label: '日期',
    width: 110,
    type: 'date',
    sortable: true,
    value: (d) => (d.billDate ?? '').substring(0, 10),
  ),
  MasterColumnDef(
    key: 'supplier',
    label: '委外商',
    width: 200,
    value: (d) => names.supplier(d.supplierId),
  ),
  MasterColumnDef(
    key: 'total',
    label: '合计',
    width: 120,
    type: 'money',
    sortable: true,
    value: (d) => d.totalLocal?.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 90,
    value: (d) => subcontractStatusLabel(d.status),
  ),
];

/// 明细中段领域列：单价 / 上游数量（货品/颜色/单位与剩余/本次数量列由共享组件提供；
/// 委外链的已收/已退不设独立列，差异都体现在剩余量的口径里）。
List<EditableGridColumn<UtenDocLinkItemRow<SubcontractDocItem>>>
_middleItemColumns() => [
  EditableGridColumn<UtenDocLinkItemRow<SubcontractDocItem>>(
    key: 'price',
    label: '单价',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) =>
        Text((row.item.price ?? 0).toStringAsFixed(2)),
  ),
  EditableGridColumn<UtenDocLinkItemRow<SubcontractDocItem>>(
    key: 'qty',
    label: '上游数量',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) => Text((row.item.qty ?? 0).toStringAsFixed(1)),
  ),
];
