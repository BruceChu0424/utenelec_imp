// 空调 Provider（Phase 4）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/hvac_device.dart';
import '../repositories/mock_hvac_repository.dart';

final hvacRepositoryProvider = Provider<MockHvacRepository>((ref) {
  return MockHvacRepository();
});

final hvacBuildingProvider = StateProvider<String>((ref) => '全部');

final hvacListProvider = FutureProvider.autoDispose<List<HvacDevice>>((
  ref,
) async {
  final building = ref.watch(hvacBuildingProvider);
  return ref.watch(hvacRepositoryProvider).list(building: building);
});

final hvacDetailProvider = FutureProvider.autoDispose
    .family<HvacDevice?, String>((ref, id) async {
      return ref.watch(hvacRepositoryProvider).getById(id);
    });
