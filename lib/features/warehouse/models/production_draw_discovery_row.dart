import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../shared/models/production_material_discovery.dart';
import 'outbound_weight_entry.dart';

/// A reviewed request line, kept separate from inventory documents until commit.
class ProductionDrawDiscoveryRow {
  ProductionDrawDiscoveryRow({
    required this.request,
    required this.index,
    required Map<String, dynamic> initial,
  }) : values = Map<String, dynamic>.from(initial),
       quantity = UtenAutofillTextController(
         text: initial['qty']?.toString() ?? '',
         autofilled: false,
       ) {
    // 材料申请按基本单位领料 (unitId 即基本单位), 本次重量按领料数量核对偏差。
    weight = OutboundWeightEntry(
      goodsId: values['goodsId'] as String?,
      colorId: values['colorId'] as String?,
      warehouseIdOf: () => values['warehouseId'] as String?,
      qtyOf: () => double.tryParse(quantity.text.trim()),
      qtyController: quantity,
      unitRate: 1,
    );
  }

  final ProductionMaterialDiscoveryDetail request;
  final int index;
  final Map<String, dynamic> values;

  /// 本次领料数量 (空着时可按称重推算, 黄框预填)。
  final UtenAutofillTextController quantity;

  /// 本次重量 (ADR-135 §3.6): 随批量出库请求的 discoveries[].weights 发出。
  late final OutboundWeightEntry weight;

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
    if (weight.weight.hasError) return '本次重量看不懂，请改成如 12.5 或 850g';
    return quantityError ?? warehouseError;
  }

  Map<String, dynamic> toJson() => {
    'goodsId': values['goodsId'],
    'colorId': values['colorId'],
    'unitId': values['unitId'],
    'warehouseId': values['warehouseId'],
    'qty': quantity.text.trim(),
  };

  /// 本行称了重量时的 IssueWeight (按 货品+颜色+实际发料仓 对到服务端建好的领料明细);
  /// 没称为 null。
  Map<String, dynamic>? weightJson() {
    final kg = weight.kg;
    if (kg == null) return null;
    return {
      'goodsId': values['goodsId'],
      'colorId': values['colorId'],
      'warehouseId': values['warehouseId'],
      'weightKg': kg,
      'qtyFromWeight': weight.qtyFromWeight,
    };
  }

  String get productionDescription =>
      '${request.productName} · ${request.productCode}\n${request.plannedQty} ${request.productUnitName} · ${request.segmentCode}';

  void dispose() {
    weight.dispose();
    quantity.dispose();
  }
}
