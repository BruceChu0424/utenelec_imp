import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/goods_node.dart' show GoodsListItem;
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/purchase_doc.dart';

/// 退货可涉及任意分类的来源收货；其它采购手工明细保留物料分类范围。
/// 目录可见性不替代服务端的来源收货、退货额度与库存校验。
UtenGoodsPickerScope purchaseGoodsPickerScope(PurchaseDocType type) =>
    switch (type) {
      PurchaseDocType.returnDoc => UtenGoodsPickerScope.all,
      PurchaseDocType.request ||
      PurchaseDocType.order ||
      PurchaseDocType.receipt => UtenGoodsPickerScope.material,
    };

typedef PurchaseGridGoodsPicker =
    Future<List<GoodsListItem>> Function(BuildContext context, WidgetRef ref);

final purchaseGridGoodsPickerProvider =
    Provider.family<PurchaseGridGoodsPicker, PurchaseDocType>(
      (ref, type) =>
          (context, ref) => showUtenGoodsPickerMulti(
            context,
            ref,
            scope: purchaseGoodsPickerScope(type),
          ),
    );
