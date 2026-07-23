// 分析 Provider（Phase 5）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/alert.dart';
import '../repositories/mock_alert_repository.dart';

final alertRepositoryProvider = Provider<MockAlertRepository>((ref) {
  return MockAlertRepository();
});

final alertStatusFilterProvider =
    StateProvider<AlertStatus?>((ref) => AlertStatus.pending);

final alertListProvider =
    FutureProvider.autoDispose<List<Alert>>((ref) async {
  final status = ref.watch(alertStatusFilterProvider);
  return ref.watch(alertRepositoryProvider).list(status: status);
});
