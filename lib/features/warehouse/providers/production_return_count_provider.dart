import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/stock_doc.dart';
import '../repositories/stock_doc_repository.dart';

/// Formal workshop return requests awaiting the original warehouse's receipt.
final warehouseProductionReturnPendingCountProvider =
    StateNotifierProvider<
      WarehouseProductionReturnCountNotifier,
      AsyncValue<int>
    >((ref) {
      final identity = ref.watch(
        sessionProvider.select(
          (session) => (
            session.status,
            session.user?.id,
            session.user?.employeeId,
            session.actor?.id,
            session.actor?.employeeId,
            session.impersonationReadOnly,
          ),
        ),
      );
      final allowed =
          ref.watch(currentPermissionsProvider).contains(Perm.stockDocView) &&
          identity.$1 == AuthStatus.authenticated;
      final repository = ref.watch(
        stockDocRepositoryProvider(StockDocType.wdraw),
      );
      final notifier = WarehouseProductionReturnCountNotifier(
        load: repository.pendingProductionReturnCount,
        allowed: allowed,
      )..start();
      ref.onDispose(notifier.stop);
      return notifier;
    });

/// Each account/actor scope owns its own state. A FutureProvider reload would
/// otherwise carry the previous actor's count in AsyncValue.valueOrNull.
class WarehouseProductionReturnCountNotifier
    extends StateNotifier<AsyncValue<int>> {
  WarehouseProductionReturnCountNotifier({
    required this._load,
    this.allowed = true,
  }) : super(allowed ? const AsyncLoading() : const AsyncData(0));
  final Future<int> Function() _load;
  final bool allowed;
  Timer? _timer;
  int _generation = 0;
  bool _stopped = false;

  void start() {
    if (!allowed || _stopped || _timer != null) return;
    unawaited(refresh());
    _timer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => unawaited(refresh()),
    );
  }

  void stop() {
    _stopped = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (!allowed || _stopped || !mounted) return;
    final generation = ++_generation;
    try {
      final count = await _load();
      if (!mounted || _stopped || generation != _generation) return;
      state = AsyncData(count);
    } catch (error, stack) {
      if (!mounted || _stopped || generation != _generation) return;
      if (!state.hasValue) state = AsyncError(error, stack);
    }
  }
}
