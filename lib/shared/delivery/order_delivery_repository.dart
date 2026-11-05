import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/network/api_client.dart';
import 'order_delivery_plan.dart';

/// Authoritative delivery BOM. Unknown children remain missing, never an empty leaf.
class OrderDeliveryBomNode {
  OrderDeliveryBomNode.fromJson(Map<String, dynamic> json)
    : path = List<String>.unmodifiable(
        (json['path'] as List? ?? const []).map((value) => value.toString()),
      ),
      goodsId = json['goodsId']?.toString() ?? '',
      code = json['code']?.toString(),
      name = json['name']?.toString() ?? '未命名货品',
      unitName = json['unitName']?.toString(),
      qtyExact = json['qtyExact']?.toString(),
      consumptionBasis = json['consumptionBasis']?.toString(),
      basisOutputQtyExact = json['basisOutputQtyExact']?.toString(),
      materialRole = json['materialRole']?.toString(),
      childrenState = json['childrenState']?.toString() ?? 'MISSING',
      mandatoryAssembly = json['mandatoryAssembly'] == true,
      requiredOperations = List<String>.unmodifiable(
        (json['requiredOperations'] as List? ?? const []).map(
          (value) => value.toString(),
        ),
      ),
      children = List<OrderDeliveryBomNode>.unmodifiable([
        for (final child in json['children'] as List? ?? const [])
          if (child is Map)
            OrderDeliveryBomNode.fromJson(Map<String, dynamic>.from(child)),
      ]);
  final List<String> path;
  final String goodsId, name, childrenState;
  final String? code, unitName, qtyExact;
  final String? consumptionBasis, basisOutputQtyExact, materialRole;
  final bool mandatoryAssembly;
  final List<String> requiredOperations;
  final List<OrderDeliveryBomNode> children;
  String get key => OrderDeliveryPlan.pathKey(path);
  bool get hasChildren => childrenState != 'NONE';
  String? get cannotSplit => mandatoryAssembly
      ? '此组件必须保持组装'
      : childrenState == 'MISSING'
      ? '原始下级明细未提供，不能拆分'
      : childrenState == 'LOADED' && children.isEmpty
      ? '下级明细为空，不能拆分'
      : null;
}

class OrderDeliveryBom {
  OrderDeliveryBom.fromJson(Map<String, dynamic> json)
    : fingerprint = json['bomFingerprint']?.toString(),
      missing = json['missing'] == true,
      missingReason = json['missingReason']?.toString(),
      plan = OrderDeliveryPlan.read(json['deliveryPlan']),
      root = json['root'] is Map
          ? OrderDeliveryBomNode.fromJson(
              Map<String, dynamic>.from(json['root'] as Map),
            )
          : null;
  final String? fingerprint;
  final bool missing;
  final String? missingReason;
  final OrderDeliveryPlan? plan;
  final OrderDeliveryBomNode? root;
}

class OrderDeliveryRepository {
  const OrderDeliveryRepository(this.api);
  final ApiClient api;
  Future<OrderDeliveryBom> bom(String goodsId) async =>
      OrderDeliveryBom.fromJson(
        await api.get(
          '/sales/orders/delivery-bom',
          query: {'goodsId': goodsId},
        ),
      );
  Future<OrderDeliveryBom> frozenBom({
    required String orderId,
    required String itemId,
    String context = 'SALES',
  }) async => OrderDeliveryBom.fromJson(
    await api.get(
      '/sales/orders/${Uri.encodeComponent(orderId)}/items/${Uri.encodeComponent(itemId)}/delivery-bom',
      query: {'context': context},
    ),
  );
  Future<Map<String, dynamic>> preview({
    required String goodsId,
    required String quantity,
    required OrderDeliveryPlan plan,
    String? unitId,
    String? unitRate,
  }) => api.post(
    '/sales/orders/delivery-preview',
    body: {
      'goodsId': goodsId,
      'qty': quantity,
      'deliveryPlan': plan.toJson(),
      'unitId': ?unitId,
      'unitRate': ?unitRate,
    },
  );
  Future<OrderDeliveryBom> updateRule(
    String edgeId,
    Map<String, dynamic> body,
  ) async => OrderDeliveryBom.fromJson(
    await api.put(
      '/sales/orders/delivery-bom/rules/${Uri.encodeComponent(edgeId)}',
      body: body,
    ),
  );
}

final orderDeliveryRepositoryProvider = Provider<OrderDeliveryRepository>(
  (ref) => OrderDeliveryRepository(ref.watch(apiClientProvider)),
);
