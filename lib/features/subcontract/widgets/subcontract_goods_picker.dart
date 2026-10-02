import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';

typedef SubcontractGridGoodsPicker =
    Future<List<GoodsListItem>> Function(
      BuildContext context,
      WidgetRef ref,
      UtenGoodsPickerScope scope,
    );

final subcontractGridGoodsPickerProvider = Provider<SubcontractGridGoodsPicker>(
  (ref) =>
      (context, widgetRef, scope) =>
          showUtenGoodsPickerMulti(context, widgetRef, scope: scope),
);
