import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/repositories/goods_repository.dart';
import '../../basic_data/widgets/goods_inline_edit.dart';
import '../../basic_data/widgets/master_inline_edit.dart';
import '../models/stock_query.dart';

/// Read the authoritative goods version only after entering edit mode. Stock
/// viewing itself continues to work without any goods permission or request.
final instantInventoryLocationSnapshotProvider = FutureProvider.autoDispose
    .family<GoodsDetail, String>((ref, id) {
      ref.watch(sensitiveReadBoundaryProvider);
      return ref.read(goodsRepositoryProvider).detail(id);
    }, retry: (_, _) => null);

bool instantInventoryLocationWritable(
  InstantInventoryRow row,
  GoodsDetail? detail,
) =>
    detail != null &&
    detail.id == row.goodsId &&
    detail.writable &&
    detail.version != null &&
    detail.stockPlace == row.stockPlace &&
    detail.owningWarehouseId == row.owningWarehouseId;

/// These columns edit goods location metadata. A stock row is a cross-warehouse
/// aggregate, so warehouse balances and all quantitative facts stay read-only.
/// Reuse the goods editors, including the UUID warehouse picker and its rules.
Map<String, MasterInlineField<InstantInventoryRow>>
instantInventoryLocationFields(BuildContext context, WidgetRef ref) {
  final goodsFields = goodsInlineFields(context, ref);
  GoodsListItem asGoods(InstantInventoryRow row) => GoodsListItem(
    id: row.goodsId!,
    stockPlace: row.stockPlace,
    owningWarehouseId: row.owningWarehouseId,
    owningWarehouseName: row.owningWarehouseName,
  );
  return {
    for (final key in const ['stockPlace', 'owningWarehouse'])
      key: MasterInlineField<InstantInventoryRow>(
        key: goodsFields[key]!.key,
        read: (row) => goodsFields[key]!.read(asGoods(row)),
        type: goodsFields[key]!.type,
        validate: goodsFields[key]!.validate,
        cellBuilder: goodsFields[key]!.cellBuilder == null
            ? null
            : (context, row, field) =>
                  goodsFields[key]!.cellBuilder!(context, asGoods(row), field),
      ),
  };
}
