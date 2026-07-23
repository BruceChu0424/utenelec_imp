// 检测 Provider（Phase 4）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/lab_test.dart';
import '../repositories/mock_lab_repository.dart';

final labRepositoryProvider = Provider<MockLabRepository>((ref) {
  return MockLabRepository();
});

enum LabFilter { all, qualified, unqualified }

final labFilterProvider = StateProvider<LabFilter>((ref) => LabFilter.all);
final labSearchProvider = StateProvider<String>((ref) => '');

final labListProvider =
    FutureProvider.autoDispose<List<LabTest>>((ref) async {
  final filter = ref.watch(labFilterProvider);
  final search = ref.watch(labSearchProvider);
  final bool? q = switch (filter) {
    LabFilter.all => null,
    LabFilter.qualified => true,
    LabFilter.unqualified => false,
  };
  return ref.watch(labRepositoryProvider).list(search: search, qualified: q);
});

final labDetailProvider =
    FutureProvider.autoDispose.family<LabTest?, String>((ref, id) async {
  return ref.watch(labRepositoryProvider).getById(id);
});
