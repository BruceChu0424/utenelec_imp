// 上游单据明细引入面板（销售编辑页"从上游引入"用）。
//
// 结构（2026-08-16 收敛）：面板状态机与外壳在共享组件
// [showUtenDocLinkPickerSheet]（components/layout/uten_doc_link_picker_sheet.dart），
// 本文件只保留销售领域差异：
//  - 上游类型推断（linkToOutItem→出货，linkToOrderItem→订货）；
//  - 剩余可引量口径（出货←订货 / 退货←出货/订货）；
//  - 单据表与明细表列定义（订货链有币种列、订单金额口径）；
//  - 结果映射：outItemId/orderItemId 按 cfg 与上游类型回填。
//
// 上游类型由 cfg 决定：
//  - linkToOutItem（退货链出货）：拉 shipments（已审）
//  - linkToOrderItem（出货/退货链订货）：拉 orders（已审）
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/layout/uten_doc_link_picker_sheet.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../config/sales_doc_config.dart';
import '../models/sales_doc.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_repository.dart';

/// 上游引入回填项：货品 + 本次数量 + 单价 + 上游明细 id（用于回写 orderItemId/outItemId）+
/// 可选颜色/单位。
class SalesLinkedItem {
  const SalesLinkedItem({
    required this.goodsId,
    required this.qty,
    this.price,
    this.orderItemId,
    this.outItemId,
    this.colorId,
    this.unitId,
    this.unitRate,
  });

  final String goodsId;
  final double qty;
  final double? price;
  final String? orderItemId;
  final String? outItemId;
  final String? colorId;
  final String? unitId;
  final double? unitRate;
}

/// 「从上游引入」的确认返回：所选明细 + 上游单据客户 id
///（编辑页表头未选客户时，据此外填表头客户并联动地址/电话）。
class SalesLinkPickResult {
  const SalesLinkPickResult({required this.items, this.clientId});

  final List<SalesLinkedItem> items;
  final String? clientId;
}

/// 决定引入源（订货 / 出货）。退货同时双挂时优先出货（outItemId 真骨干），
/// 订货 orderItemId 由编辑页"再引入一次订货"补全（v1 简化，逻辑沿用）。
SalesDocType _upstreamType(SalesDocConfig cfg) {
  if (cfg.linkToOutItem) return SalesDocType.shipment;
  if (cfg.linkToOrderItem) return SalesDocType.order;
  return SalesDocType.order;
}

String _upTypeLabel(SalesDocType t) {
  switch (t) {
    case SalesDocType.order:
      return '订货';
    case SalesDocType.shipment:
      return '出货';
    default:
      return '上游';
  }
}

/// 上游明细剩余可引量（也是"本次数量"默认值）：
/// 出货←订货 = 订货数 − 已发；退货←出货/订货 = 原单数 − 已退；其它 = 全额。
double _remainQty(SalesDocConfig cfg, SalesDocType upType, SalesDocItem it) {
  final q = it.qty ?? 0;
  if (upType == SalesDocType.order && cfg.type == SalesDocType.shipment) {
    return q - (it.shippedQty ?? 0);
  }
  if (cfg.type == SalesDocType.returnDoc) {
    return q - (it.returnedQty ?? 0);
  }
  return q;
}

/// 弹出"从上游引入"右滑入大面板；返回所选明细 + 上游客户（null 表示取消）。
/// [initialClientId]：编辑页表头已选客户时传入，面板客户筛选默认锁定该客户。
Future<SalesLinkPickResult?> showSalesDocLinkPicker(
  BuildContext context,
  WidgetRef ref,
  SalesDocConfig cfg, {
  String? initialClientId,
}) async {
  final upstream = _upstreamType(cfg);
  final docConfig =
      UtenDocLinkPickerConfig<
        SalesDocListItem,
        SalesDocItem,
        SalesMasterNameService
      >(
        step1Title: '从${_upTypeLabel(upstream)}引入',
        step1EmptyMessage:
            '暂无已审${_upTypeLabel(upstream)}单', // TODO(l10n): 补 arb
        partyNoun: '客户',
        allPartiesLabel: '全部客户', // TODO(l10n): 补 arb
        docIdOf: (d) => d.id,
        partyIdOf: (d) => d.clientId,
        watchNames: (ref) => ref.watch(salesMasterNameServiceProvider),
        partyEntries: (names) => names.clientEntries,
        partyName: (names, clientId) => names.client(clientId),
        initNames: (ref) async {
          ref.read(salesMasterNameServiceProvider).ensureLoaded();
        },
        loadGoodsNames: (ref, goodsIds) =>
            ref.read(salesMasterNameServiceProvider).loadGoodsNames(goodsIds),
        listDocs: (ref, page, keyword, clientId, sort, order) => ref
            .read(salesRepositoryProvider(upstream))
            .list(
              page: page,
              // 业务约束：只引入已审单（草稿/红冲不可引入）。
              filter: SalesDocFilter(
                keyword: keyword,
                clientId: clientId,
                status: kSalesStatusApproved,
              ),
              sort: sort,
              order: order,
            ),
        loadDetail: (ref, docId) async {
          final detail = await ref
              .read(salesRepositoryProvider(upstream))
              .detail(docId);
          return UtenDocLinkDetail<SalesDocItem>(
            partyId: detail.clientId,
            items: detail.items,
          );
        },
        itemFields: UtenDocLinkItemFields<SalesDocItem>(
          goodsId: (it) => it.goodsId,
          colorId: (it) => it.colorId,
          unitId: (it) => it.unitId,
          price: (it) => it.price,
          upstreamItemId: (it) => it.id,
          unitRate: (it) => it.unitRate,
        ),
        docColumns: (names) => _docColumns(names, upstream),
        goodsName: (names, goodsId) => names.goods(goodsId),
        colorName: (names, colorId) => names.color(colorId),
        unitName: (names, unitId) => names.unit(unitId),
        middleItemColumns: (names) => _middleItemColumns(upstream),
        remainQty: (it) => _remainQty(cfg, upstream, it),
        createBlankRow: () =>
            UtenDocLinkItemRow<SalesDocItem>(const SalesDocItem(id: null)),
      );

  final raw =
      await showUtenDocLinkPickerSheet<
        SalesDocListItem,
        SalesDocItem,
        SalesMasterNameService
      >(context, docConfig, initialPartyId: initialClientId);
  if (raw == null) return null;
  return SalesLinkPickResult(
    clientId: raw.partyId,
    items: raw.items
        .map(
          (d) => SalesLinkedItem(
            goodsId: d.goodsId,
            qty: d.qty,
            price: d.price,
            orderItemId: cfg.linkToOrderItem && upstream == SalesDocType.order
                ? d.upstreamItemId
                : null,
            outItemId: cfg.linkToOutItem && upstream == SalesDocType.shipment
                ? d.upstreamItemId
                : null,
            colorId: d.colorId,
            unitId: d.unitId,
            unitRate: d.unitRate,
          ),
        )
        .toList(),
  );
}

List<MasterColumnDef<SalesDocListItem>> _docColumns(
  SalesMasterNameService names,
  SalesDocType upstream,
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
    key: 'client',
    label: '客户',
    width: 200,
    value: (d) => names.client(d.clientId),
  ),
  if (upstream == SalesDocType.order)
    MasterColumnDef(
      key: 'currency',
      label: '币种',
      width: 100,
      value: (d) => names.currency(d.currencyId),
    ),
  MasterColumnDef(
    key: 'total',
    label: upstream == SalesDocType.order ? '订单金额' : '合计',
    width: 120,
    type: 'money',
    sortable: upstream != SalesDocType.order,
    value: (d) =>
        (upstream == SalesDocType.order ? d.totalOriginal : d.totalLocal)
            ?.toStringAsFixed(2),
  ),
  MasterColumnDef(
    key: 'status',
    label: '状态',
    width: 90,
    value: (d) => salesStatusLabel(d.status),
  ),
];

/// 明细中段领域列：上游数量 / 已发或已退（货品/颜色/单位与
/// 剩余/本次数量列由共享组件提供；销售链不展示单价）。
List<EditableGridColumn<UtenDocLinkItemRow<SalesDocItem>>> _middleItemColumns(
  SalesDocType upstream,
) => [
  EditableGridColumn<UtenDocLinkItemRow<SalesDocItem>>(
    key: 'qty',
    label: upstream == SalesDocType.order ? '订货数' : '出货数',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) => Text((row.item.qty ?? 0).toStringAsFixed(1)),
  ),
  EditableGridColumn<UtenDocLinkItemRow<SalesDocItem>>(
    key: 'shipped',
    label: upstream == SalesDocType.order ? '已发' : '已退',
    width: 90,
    numeric: true,
    cellBuilder: (context, row) => Text(
      (upstream == SalesDocType.order
              ? (row.item.shippedQty ?? 0)
              : (row.item.returnedQty ?? 0))
          .toStringAsFixed(1),
    ),
  ),
];
