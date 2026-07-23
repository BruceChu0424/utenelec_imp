// 库存 Provider（Phase 4）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/inventory.dart';
import '../repositories/mock_inventory_repository.dart';

final inventoryRepositoryProvider = Provider<MockInventoryRepository>((ref) {
  return MockInventoryRepository();
});

final inventorySearchProvider = StateProvider<String>((ref) => '');
final inventoryStatusFilterProvider =
    StateProvider<StockStatus?>((ref) => null);

final inventoryListProvider =
    FutureProvider.autoDispose<List<Material>>((ref) async {
  final search = ref.watch(inventorySearchProvider);
  final status = ref.watch(inventoryStatusFilterProvider);
  return ref.watch(inventoryRepositoryProvider).list(
        search: search,
        status: status,
      );
});

final movementTypeFilterProvider =
    StateProvider<MovementType?>((ref) => null);

final inventoryMovementListProvider =
    FutureProvider.autoDispose<List<InventoryMovement>>((ref) async {
  final type = ref.watch(movementTypeFilterProvider);
  return ref.watch(inventoryRepositoryProvider).movements(type: type);
});
