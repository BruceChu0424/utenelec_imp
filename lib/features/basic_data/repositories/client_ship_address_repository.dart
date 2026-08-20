// 客户收货地址簿仓库（V300 出货开单学习能力）。
//
// 端点 /api/master/clients/{id}/ship-addresses：
//  - GET    → 地址簿（后端按最近使用降序，第一行即默认带出候选）
//  - POST   → 新增地址（与既有地址规范化重复时后端等价于点选既有行）
//  - DELETE → 删除（软删；需 client_address:delete，无权限后端 403）
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/client_ship_address.dart';

abstract interface class ClientShipAddressRepository {
  /// 某客户地址簿（最近使用优先）。
  Future<List<ClientShipAddress>> list(String clientId);

  /// 手工新增（地址弹窗「新增地址」）；返回落库行（含既有行命中情形）。
  Future<ClientShipAddress> add(
    String clientId, {
    required String address,
    String? linkPhone,
  });

  /// 删除地址（软删；client_address:delete）。
  Future<void> delete(String clientId, String addressId);
}

class DioClientShipAddressRepository implements ClientShipAddressRepository {
  const DioClientShipAddressRepository(this.api);

  final ApiClient api;

  String _base(String clientId) =>
      '${ApiEndpoints.client(clientId)}/ship-addresses';

  @override
  Future<List<ClientShipAddress>> list(String clientId) async {
    final json = await api.getList(_base(clientId));
    return json.map(ClientShipAddress.fromJson).toList(growable: false);
  }

  @override
  Future<ClientShipAddress> add(
    String clientId, {
    required String address,
    String? linkPhone,
  }) async {
    final json = await api.post(
      _base(clientId),
      body: <String, dynamic>{
        'address': address.trim(),
        if (linkPhone != null && linkPhone.trim().isNotEmpty)
          'linkPhone': linkPhone.trim(),
      },
    );
    return ClientShipAddress.fromJson(json);
  }

  @override
  Future<void> delete(String clientId, String addressId) async {
    await api.delete('${_base(clientId)}/$addressId');
  }
}

final clientShipAddressRepositoryProvider =
    Provider<ClientShipAddressRepository>(
      (ref) => DioClientShipAddressRepository(ref.watch(apiClientProvider)),
    );
