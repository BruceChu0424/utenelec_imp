import 'package:flutter/material.dart';

import '../../../shared/presentation/workflow_field_guidance.dart';

/// The server resolves automatic arrivals only when the source is unambiguous.
enum WarehouseArrivalSource {
  automatic(null),
  normal('NORMAL'),
  replacementFirst('RETURN_REPLACEMENT');

  const WarehouseArrivalSource(this.apiValue);

  final String? apiValue;

  String label(BuildContext context) {
    final text = workflowFieldText(context);
    return switch (this) {
      automatic => text.warehouseArrivalSourceAutomatic,
      normal => text.warehouseArrivalSourceNormal,
      replacementFirst => text.warehouseArrivalSourceReplacement,
    };
  }
}

// 2026-10-10「到货来源」列删除：来源默认自动识别；仅当订单「正常待到货」与
// 「已退未补」并存时（服务端 409），登记页弹窗二选一后自动重提，枚举仍承载
// 该弹窗的取值与文案，原先挂在列上的下拉控件随之退役。
