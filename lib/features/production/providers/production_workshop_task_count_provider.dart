import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../repositories/production_execution_workbench_repository.dart';

const _pollInterval = Duration(seconds: 60);

final productionWorkshopTaskCountProvider =
    StateNotifierProvider<ProductionWorkshopTaskCountNotifier, int>((ref) {
      final notifier = ProductionWorkshopTaskCountNotifier(ref)..start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

class ProductionWorkshopTaskCountNotifier extends StateNotifier<int> {
  ProductionWorkshopTaskCountNotifier(this.ref) : super(0);

  final Ref ref;
  Timer? _timer;

  void start() {
    refresh();
    _timer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    final allowed =
        ref
            .read(currentPermissionsProvider)
            .contains(Perm.productionExecutionView) ||
        ref.read(isSuperAdminProvider);
    if (!allowed) {
      state = 0;
      return;
    }
    try {
      state = await ref
          .read(productionExecutionWorkbenchRepositoryProvider)
          .workshopTaskCount();
    } catch (_) {
      // Keep the last confirmed value during transient network failures.
    }
  }
}
