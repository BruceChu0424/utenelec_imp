// 客户收货地址簿行（V300；对应后端 ClientShipAddressDto）。
//
// 出货开单按客户学习收货地址+联系电话：保存出货/其它出货时后端 upsert 记忆，
// 下次开单按「最近使用优先」自动带出；用户改过的内容保存时再次学习更新。
// 删除地址需独立权限点 client_address:delete（前端只控制入口显隐，后端仍是授权边界）。

class ClientShipAddress {
  const ClientShipAddress({
    required this.id,
    required this.clientId,
    required this.address,
    this.linkPhone,
    this.usageCount = 0,
    this.lastUsedAt,
  });

  final String id;
  final String clientId;
  final String address;
  final String? linkPhone;
  final int usageCount;
  final String? lastUsedAt;

  factory ClientShipAddress.fromJson(Map<String, dynamic> json) =>
      ClientShipAddress(
        id: json['id']?.toString() ?? '',
        clientId: json['clientId']?.toString() ?? '',
        address: json['address']?.toString() ?? '',
        linkPhone: (json['linkPhone']?.toString().trim().isEmpty ?? true)
            ? null
            : json['linkPhone'].toString(),
        usageCount: (json['usageCount'] as num?)?.toInt() ?? 0,
        lastUsedAt: json['lastUsedAt']?.toString(),
      );
}
