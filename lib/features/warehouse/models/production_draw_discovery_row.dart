import 'package:flutter/material.dart';

import '../../../shared/models/production_material_discovery.dart';

/// A reviewed request line, kept separate from inventory documents until commit.
class ProductionDrawDiscoveryRow {
  ProductionDrawDiscoveryRow({
    required this.request,
    required this.index,
    required Map<String, dynamic> initial,
  }) : values = Map<String, dynamic>.from(initial),
       quantity = TextEditingController(text: initial['qty']?.toString() ?? '');

  final ProductionMaterialDiscoveryDetail request;
  final int index;
  final Map<String, dynamic> values;
  final TextEditingController quantity;

  String get id => '${request.requestId}:$index';
  String label(String field) {
    final value = (values[field] as String?)?.trim();
    return value == null || value.isEmpty ? '—' : value;
  }

  String? get quantityError {
    final input = quantity.text.trim();
    final amount = double.tryParse(input);
    if (input.isEmpty) return '请填写本次领料数量';
    if (amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(input)) {
      return '数量须大于 0，最多 4 位小数';
    }
    return null;
  }

  String? get warehouseError =>
      (values['warehouseId'] as String?)?.trim().isNotEmpty != true
      ? '请选择实际发料仓'
      : null;
  String? get validationError {
    if ((values['goodsId'] as String?)?.trim().isNotEmpty != true ||
        (values['unitId'] as String?)?.trim().isNotEmpty != true) {
      return '材料或基本单位缺失，请返回核对';
    }
    return quantityError ?? warehouseError;
  }

  Map<String, dynamic> toJson() => {
    'goodsId': values['goodsId'],
    'colorId': values['colorId'],
    'unitId': values['unitId'],
    'warehouseId': values['warehouseId'],
    'qty': quantity.text.trim(),
  };

  String get productionDescription =>
      '${request.productName} · ${request.productCode}\n${request.plannedQty} ${request.productUnitName} · ${request.segmentCode}';

  void dispose() => quantity.dispose();
}
