// 库存 Mock 仓库（Phase 4）

import '../models/inventory.dart';

class MockInventoryRepository {
  MockInventoryRepository();
  List<Material>? _materials;
  List<InventoryMovement>? _movements;

  Future<T> _delay<T>(T Function() cb) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    return cb();
  }

  Future<List<Material>> list({
    String? search,
    MaterialType? type,
    StockStatus? status,
  }) async {
    return _delay(() {
      var result = [..._ensureMaterials()];
      if (type != null) result = result.where((m) => m.type == type).toList();
      if (status != null) {
        result = result.where((m) => m.status == status).toList();
      }
      if (search != null && search.trim().isNotEmpty) {
        final q = search.trim().toLowerCase();
        result = result
            .where((m) =>
                m.code.toLowerCase().contains(q) ||
                m.name.toLowerCase().contains(q))
            .toList();
      }
      return result;
    });
  }

  Future<List<InventoryMovement>> movements({
    MovementType? type,
    String? materialName,
  }) async {
    return _delay(() {
      var result = [..._ensureMovements()];
      if (type != null) result = result.where((m) => m.type == type).toList();
      if (materialName != null) {
        result =
            result.where((m) => m.materialName == materialName).toList();
      }
      result.sort((a, b) => b.date.compareTo(a.date));
      return result;
    });
  }

  List<Material> _ensureMaterials() {
    if (_materials != null) return _materials!;
    _materials = [
      const Material(id: 'm1', code: 'M001', name: '钢板 A 型', type: MaterialType.raw,
          unit: '吨', warehouse: '1号库', quantity: 5.2, safetyStock: 3),
      const Material(id: 'm2', code: 'M002', name: '螺丝 B 型', type: MaterialType.raw,
          unit: '件', warehouse: '1号库', quantity: 120, safetyStock: 500),
      const Material(id: 'm3', code: 'M003', name: '铝合金板', type: MaterialType.raw,
          unit: '吨', warehouse: '1号库', quantity: 8.5, safetyStock: 5),
      const Material(id: 'm4', code: 'M004', name: '成品 X', type: MaterialType.finished,
          unit: '件', warehouse: '2号库', quantity: 0, safetyStock: 100),
      const Material(id: 'm5', code: 'M005', name: '成品 Y', type: MaterialType.finished,
          unit: '件', warehouse: '2号库', quantity: 320, safetyStock: 200),
      const Material(id: 'm6', code: 'M006', name: '包装纸箱', type: MaterialType.raw,
          unit: '个', warehouse: '1号库', quantity: 1500, safetyStock: 800),
      const Material(id: 'm7', code: 'M007', name: '电机 1.5kW', type: MaterialType.raw,
          unit: '台', warehouse: '2号库', quantity: 18, safetyStock: 20),
      const Material(id: 'm8', code: 'M008', name: '成品 Z', type: MaterialType.finished,
          unit: '件', warehouse: '2号库', quantity: 410, safetyStock: 150),
    ];
    return _materials!;
  }

  List<InventoryMovement> _ensureMovements() {
    if (_movements != null) return _movements!;
    final now = DateTime.now();
    DateTime d(int days) => now.subtract(Duration(days: days));
    _movements = [
      InventoryMovement(id: 'mv1', materialName: '钢板 A 型', type: MovementType.inbound,
          quantity: 5, warehouse: '1号库', operatorName: '王五', date: d(0), ref: 'PO-1023'),
      InventoryMovement(id: 'mv2', materialName: '螺丝 B 型', type: MovementType.outbound,
          quantity: 500, warehouse: '1号库', operatorName: '王五', date: d(1), ref: 'WO-1023'),
      InventoryMovement(id: 'mv3', materialName: '成品 X', type: MovementType.outbound,
          quantity: 200, warehouse: '2号库', operatorName: '刘六', date: d(2), ref: 'SO-0512'),
      InventoryMovement(id: 'mv4', materialName: '铝合金板', type: MovementType.inbound,
          quantity: 3, warehouse: '1号库', operatorName: '王五', date: d(3), ref: 'PO-1024'),
      InventoryMovement(id: 'mv5', materialName: '电机 1.5kW', type: MovementType.transfer,
          quantity: 5, warehouse: '2号库→1号库', operatorName: '刘六', date: d(4)),
      InventoryMovement(id: 'mv6', materialName: '包装纸箱', type: MovementType.inbound,
          quantity: 800, warehouse: '1号库', operatorName: '王五', date: d(5), ref: 'PO-1025'),
    ];
    return _movements!;
  }
}
