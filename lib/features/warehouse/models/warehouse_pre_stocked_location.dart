/// 先入库后质检(V596 / ADR-090)：待检明细行「已上架」的实际仓与库位。
///
/// 仓库在品质结论前把到货实物先落到记账叶仓与库位；品质部按此到储放区域检验，
/// 合格由系统按同一位置自动转正入库，不合格由仓库从库位取出登记退回。
/// 服务端契约 `ProcurementIqcPreStockInContracts.PreStockedLocation`；
/// null 表示该行走原流程(等品质放行后仓库确认入库)。
class WarehousePreStockedLocation {
  const WarehousePreStockedLocation({
    required this.warehouseId,
    this.warehouseName,
    this.place,
    this.stockedAt,
    this.stockedByName,
  });

  final String warehouseId;
  final String? warehouseName;
  final String? place;
  final String? stockedAt;
  final String? stockedByName;

  /// 「仓库 / 库位」一句话，给表格、横幅与通知共用。
  String get label {
    final warehouse = warehouseName?.trim().isNotEmpty == true
        ? warehouseName!.trim()
        : warehouseId;
    final spot = place?.trim();
    return spot == null || spot.isEmpty ? warehouse : '$warehouse / $spot';
  }

  static WarehousePreStockedLocation? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, dynamic>.from(raw);
    final warehouseId = json['warehouseId']?.toString().trim();
    if (warehouseId == null || warehouseId.isEmpty) return null;
    String? text(Object? value) {
      final result = value?.toString().trim();
      return result == null || result.isEmpty ? null : result;
    }

    return WarehousePreStockedLocation(
      warehouseId: warehouseId,
      warehouseName: text(json['warehouseName']),
      place: text(json['place']),
      stockedAt: text(json['stockedAt']),
      stockedByName: text(json['stockedByName']),
    );
  }
}
