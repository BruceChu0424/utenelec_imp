import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/goods_node.dart' show GoodsListItem;
import '../../basic_data/widgets/uten_goods_picker.dart';

/// 采购手工明细共用销售同款多选选择器，保持原有采购物料分类范围。
typedef PurchaseGridGoodsPicker =
    Future<List<GoodsListItem>> Function(BuildContext context, WidgetRef ref);

final purchaseGridGoodsPickerProvider = Provider<PurchaseGridGoodsPicker>(
  (ref) =>
      (context, ref) => showUtenGoodsPickerMulti(
        context,
        ref,
        scope: UtenGoodsPickerScope.material,
      ),
);
