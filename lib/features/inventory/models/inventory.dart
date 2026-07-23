// 库存 model（Phase 4）

enum MaterialType { raw, finished }
enum StockStatus { sufficient, low, out }
enum MovementType { inbound, outbound, transfer }

extension MaterialTypeX on MaterialType {
  String get label => switch (this) {
        MaterialType.raw => '原料',
        MaterialType.finished => '成品',
      };
}
extension MovementTypeX on MovementType {
  String get label => switch (this) {
        MovementType.inbound => '入库',
        MovementType.outbound => '出库',
        MovementType.transfer => '调拨',
      };
  String get sign => switch (this) {
        MovementType.inbound => '+',
        MovementType.outbound => '-',
        MovementType.transfer => '±',
      };
}

class Material {
  const Material({
    required this.id,
    required this.code,
    required this.name,
    required this.type,
    required this.unit,
    required this.warehouse,
    required this.quantity,
    required this.safetyStock,
  });

  final String id;
  final String code;
  final String name;
  final MaterialType type;
  final String unit;
  final String warehouse;
  final num quantity;
  final num safetyStock;

  StockStatus get status {
    if (quantity <= 0) return StockStatus.out;
    if (quantity < safetyStock) return StockStatus.low;
    return StockStatus.sufficient;
  }
}

class InventoryMovement {
  const InventoryMovement({
    required this.id,
    required this.materialName,
    required this.type,
    required this.quantity,
    required this.warehouse,
    required this.operatorName,
    required this.date,
    this.ref,
  });

  final String id;
  final String materialName;
  final MovementType type;
  final num quantity;
  final String warehouse;
  final String operatorName;
  final DateTime date;
  final String? ref; // 关联单据
}
