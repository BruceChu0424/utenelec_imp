import 'sales_doc.dart';
import '../../../shared/formatters/exact_decimal.dart';

/// Read-only navigation intent. Opening a prefilled page never creates a draft.
class SalesShipmentPrefill {
  SalesShipmentPrefill({
    required this.orderId,
    required Map<String, double> quantities,
    Map<String, String> exactQuantities = const {},
  }) : quantities = Map.unmodifiable(quantities),
       exactQuantities = Map.unmodifiable(exactQuantities);

  final String orderId;
  final Map<String, double> quantities;
  final Map<String, String> exactQuantities;

  factory SalesShipmentPrefill.parse(String orderId, String? rawItems) {
    if (orderId.trim().isEmpty || rawItems == null || rawItems.isEmpty) {
      throw const FormatException('请返回订单产品进度，重新选择本次发货产品');
    }
    final quantities = <String, double>{};
    final exactQuantities = <String, String>{};
    for (final item in rawItems.split(',')) {
      final parts = item.split(':');
      if (parts.length != 2 ||
          parts.first.isEmpty ||
          quantities.containsKey(parts.first) ||
          !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(parts.last)) {
        throw const FormatException('发货产品或数量不正确，请回到订单重新选择');
      }
      final quantity = double.tryParse(parts.last);
      if (quantity == null || !quantity.isFinite || quantity <= 0) {
        throw const FormatException('本次发货数量必须大于 0');
      }
      quantities[parts.first] = quantity;
      exactQuantities[parts.first] = parts.last;
    }
    return SalesShipmentPrefill(
      orderId: orderId.trim(),
      quantities: quantities,
      exactQuantities: exactQuantities,
    );
  }

  void validate(SalesDocDetail order, List<OrderPlanProgressLine> progress) {
    if (order.id != orderId ||
        !order.writable ||
        order.status != kSalesStatusApproved ||
        !order.financeConfirmed ||
        order.closed ||
        order.stopped) {
      throw const FormatException('该订单当前不能新建出货单，请返回订单刷新状态');
    }
    final sourceIds = order.items.map((item) => item.id).toSet();
    for (final entry in quantities.entries) {
      final line = progress
          .where((line) => line.orderItemId == entry.key)
          .firstOrNull;
      final requested = financeAmountUnits(
        exactQuantities[entry.key] ?? entry.value.toString(),
      );
      final available = financeAmountUnits(line?.availableShipmentQtyExact);
      if (!sourceIds.contains(entry.key) ||
          line == null ||
          requested == null ||
          available == null ||
          requested > available) {
        throw const FormatException('所选产品的可发或可建备货单数量已变化，请返回订单刷新后重新选择');
      }
    }
  }
}
