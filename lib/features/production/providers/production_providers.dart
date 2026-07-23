// 生产 Provider（Phase 4）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../repositories/mock_production_repository.dart';

final productionRepositoryProvider = Provider<MockProductionRepository>((ref) {
  return MockProductionRepository();
});

final productionLineBoardProvider =
    FutureProvider.autoDispose((ref) async {
  return ref.watch(productionRepositoryProvider).lines();
});

final productionOutputListProvider =
    FutureProvider.autoDispose((ref) async {
  return ref.watch(productionRepositoryProvider).outputs();
});
