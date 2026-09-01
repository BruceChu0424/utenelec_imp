// 上游单据明细引入面板（采购编辑页"从上游引入"用）。
//
// 结构（2026-08-16 收敛）：面板状态机与外壳在共享组件
// [showUtenDocLinkPickerSheet]（components/layout/uten_doc_link_picker_sheet.dart），
// 本文件只保留采购领域差异：
//  - 上游类型推断（退货优先收货 → 订货 → 申请）；
//  - 剩余可引量口径（收货←订货 / 退货←收货/订货 / 订货←申请）；
//  - 单据表与明细表列定义；
//  - 结果类型 [PurchaseLinkPickResult] 映射。
//
// 上游类型由 cfg 决定：linkToReceiptItem→收货（退货优先收货），linkToOrderItem→订货，
// linkToRequestItem→申请。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_doc_link_picker_sheet.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/purchase_doc_config.dart';
import '../models/purchase_doc.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../repositories/purchase_repository.dart';

/// 上游引入回填项：货品 + 本次数量 + 单价 + 上游明细 id（用于回写 *ItemId）+
/// 可选颜色/单位。
class LinkedItem {
  const LinkedItem({
    required this.goodsId,
    required this.qty,
    this.maxQty,
    this.price,
    this.upstreamItemId,
    this.colorId,
    this.unitId,
    this.unitRate,
  });

  final String goodsId;
  final double qty;
  final double? maxQty;
  final double? price;
  final String? upstreamItemId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
}

/// 「从上游引入」的确认返回：所选明细 + 上游单据供应商 id（编辑页表头未选供应商时回填用）。
class PurchaseLinkPickResult {
  const PurchaseLinkPickResult({required this.items, this.supplierId});

  final List<LinkedItem> items;
  final String? supplierId;
}

/// 从 cfg 推断上游单据类型。退货同时可链收货/订货时优先收货。
PurchaseDocType _upstreamType(PurchaseDocConfig cfg) {
  if (cfg.linkToReceiptItem) return PurchaseDocType.receipt;
  if (cfg.linkToOrderItem) return PurchaseDocType.order;
  return PurchaseDocType.request;
}

String _upTypeLabel(PurchaseDocType t) {
  switch (t) {
    case PurchaseDocType.request:
      return '申请';
    case PurchaseDocType.order:
      return '订货';
    case PurchaseDocType.receipt:
      return '收货';
    case PurchaseDocType.returnDoc:
      return '退货';
  }
}

/// 上游明细剩余可引量（也是"本次数量"默认值）：
/// 收货←订货 = 订货数 − 已收 + 已退（退货回补后供应商仍欠交，与服务端权威口径一致）；
/// 退货←收货/订货 = 原单数 − 已退；订货←申请 = 申请数 − 已订；其它 = 全额。
double _remainQty(
  PurchaseDocConfig cfg,
  PurchaseDocType upType,
  PurchaseDocItem it,
) {
  final q = it.qty ?? 0;
  if (cfg.type == PurchaseDocType.returnDoc) {
    return q - (it.returnedQty ?? 0);
  }
  if (upType == PurchaseDocType.order && cfg.type == PurchaseDocType.receipt) {
    return q - (it.receivedQty ?? 0) + (it.returnedQty ?? 0);
  }
  if (upType == PurchaseDocType.request && cfg.type == PurchaseDocType.order) {
    return q - (it.orderedQty ?? 0);
  }
  return q;
}

/// 弹出"从上游引入"右滑入大面板；返回所选明细 + 上游供应商（null 表示用户取消）。
/// [initialSupplierId]：编辑页表头已选供应商时传入，面板供应商筛选默认锁定该供应商。
Future<PurchaseLinkPickResult?> showDocLinkPicker(
  BuildContext context,
  WidgetRef ref,
  PurchaseDocConfig cfg, {
  String? initialSupplierId,
}) async {
  final upstream = _upstreamType(cfg);
  final docConfig =
      UtenDocLinkPickerConfig<
        PurchaseDocListItem,
        PurchaseDocItem,
        MasterNameService
      >(
        step1Title: '从${_upTypeLabel(upstream)}引入',
        step1EmptyMessage:
            '暂无已审${_upTypeLabel(upstream)}单', // TODO(l10n): 补 arb
        partyNoun: '供应商',
        allPartiesLabel: '全部供应商', // TODO(l10n): 补 arb
        docIdOf: (d) => d.id,
        partyIdOf: (d) => d.supplierId,
        watchNames: (ref) => ref.watch(masterNameServiceProvider),
        partyEntries: (names) => names.supplierEntries,
        partyName: (names, supplierId) => names.supplier(supplierId),
        initNames: (ref) async {
          ref.read(masterNameServiceProvider).ensureLoaded();
        },
        loadGoodsNames: (ref, goodsIds) =>
            ref.read(masterNameServiceProvider).loadGoodsNames(goodsIds),
        listDocs: (ref, page, keyword, supplierId, sort, order) => ref
            .read(purchaseRepositoryProvider(upstream))
            .list(
              page: page,
              // 业务约束：只引入已审单（草稿/红冲不可引入）。
              filter: PurchaseDocFilter(
                keyword: keyword,
                supplierId: supplierId,
                status: kPurchaseStatusApproved,
              ),
              sort: sort,
              order: order,
            ),
        loadDetail: (ref, docId) async {
          final detail = await ref
              .read(purchaseRepositoryProvider(upstream))
              .detail(docId);
          return UtenDocLinkDetail<PurchaseDocItem>(
            partyId: detail.supplierId,
            items: detail.items,
          );
        },
        itemFields: UtenDocLinkItemFields<PurchaseDocItem>(
          goodsId: (it) => it.goodsId,
          colorId: (it) => it.colorId,
          unitId: (it) => it.unitId,
          price: (it) => it.price,
          upstreamItemId: (it) => it.id,
          unitRate: (it) => it.unitRate,
        ),
        docColumns: (names) => _docColumns(names),
        goodsName: (names, goodsId) => names.goods(goodsId),
        colorName: (names, colorId) => names.color(colorId),
        unitName: (names, unitId) => names.unit(unitId),
        middleItemColumns: (names) => _middleItemColumns(upstream),
        remainQty: (it) => _remainQty(cfg, upstream, it),
        createBlankRow: () => UtenDocLinkItemRow<PurchaseDocItem>(
          const PurchaseDocItem(id: null),
        ),
      );

  final raw =
      await showUtenDocLinkPickerSheet<
        PurchaseDocListItem,
        PurchaseDocItem,
        MasterNameService
      >(context, docConfig, initialPartyId: initialSupplierId);
  if (raw == null) return null;
  return PurchaseLinkPickResult(
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
            unitRate: d.unitRate,
          ),
        )
        .toList(),
  );
}

List<MasterColumnDef<PurchaseDocListItem>> _docColumns(
  MasterNameService names,
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
    label: '供应商',
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
    value: (d) => purchaseStatusLabel(d.status),
  ),
];

/// 明细中段领域列：单价 / 上游数量 / 已收或已退（货品/颜色/单位与
/// 剩余/本次数量列由共享组件提供）。
List<EditableGridColumn<UtenDocLinkItemRow<PurchaseDocItem>>>
_middleItemColumns(PurchaseDocType upstream) => [
  EditableGridColumn<UtenDocLinkItemRow<PurchaseDocItem>>(
    key: 'price',
    label: '单价',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) =>
        Text((row.item.price ?? 0).toStringAsFixed(2)),
  ),
  EditableGridColumn<UtenDocLinkItemRow<PurchaseDocItem>>(
    key: 'qty',
    label: '${_upTypeLabel(upstream)}数',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) => Text((row.item.qty ?? 0).toStringAsFixed(1)),
  ),
  EditableGridColumn<UtenDocLinkItemRow<PurchaseDocItem>>(
    key: 'doneQty',
    label: upstream == PurchaseDocType.order ? '已收' : '已退',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) => Text(
      (upstream == PurchaseDocType.order
              ? (row.item.receivedQty ?? 0)
              : (row.item.returnedQty ?? 0))
          .toStringAsFixed(1),
    ),
  ),
];
