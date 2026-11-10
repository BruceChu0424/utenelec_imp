import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/subcontract_doc.dart';

/// 人工选货范围只控制目录浏览，不代替上游来源、库存及退货额度校验。
/// 委外退货可涉及任意分类的历史回厂货品，不能套用成品目录排除规则。
/// 穷举类型，新增单据必须明确其范围，避免默认分支静默隐藏分类。
UtenGoodsPickerScope subcontractGoodsPickerScope(SubcontractDocType type) =>
    switch (type) {
      SubcontractDocType.returnDoc => UtenGoodsPickerScope.all,
      SubcontractDocType.materialIssue ||
      SubcontractDocType.materialReturn ||
      SubcontractDocType.waste => UtenGoodsPickerScope.material,
      SubcontractDocType.inquiry ||
      SubcontractDocType.application ||
      SubcontractDocType.order ||
      SubcontractDocType.receipt => UtenGoodsPickerScope.sellable,
    };

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
