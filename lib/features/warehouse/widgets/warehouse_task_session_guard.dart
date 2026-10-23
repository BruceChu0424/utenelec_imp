import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/authenticated_request_scope.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/providers/session_provider.dart';

/// A loaded physical task belongs to the identity and endpoint that read it.
/// Returning to equal values cannot revive an editor that crossed a boundary.
mixin WarehouseTaskSessionGuard<T extends ConsumerStatefulWidget>
    on ConsumerState<T> {
  SensitiveReadBoundary? _taskBoundary;
  ProviderSubscription<SensitiveReadBoundary>? _taskBoundarySubscription;
  bool _taskInvalidated = false;

  bool get warehouseTaskIsCurrent =>
      mounted &&
      !_taskInvalidated &&
      _taskBoundary?.identity != null &&
      _taskBoundary == ref.read(sensitiveReadBoundaryProvider);
  bool get warehouseTaskCanWrite =>
      warehouseTaskIsCurrent && _taskBoundary!.identity!.readOnly == false;

  void startWarehouseTaskGuard() {
    if (_taskBoundarySubscription != null) return;
    _taskBoundary = ref.read(sensitiveReadBoundaryProvider);
    _taskBoundarySubscription = ref.listenManual(
      sensitiveReadBoundaryProvider,
      (_, next) {
        if (next != _taskBoundary) invalidateWarehouseTask();
      },
    );
  }

  void onWarehouseTaskInvalidated();

  void invalidateWarehouseTask() {
    if (!mounted || _taskInvalidated) return;
    _taskInvalidated = true;
    onWarehouseTaskInvalidated();
  }

  Future<AuthenticatedRequestScope> captureWarehouseTaskScope() {
    startWarehouseTaskGuard();
    final session = ref.read(sessionProvider.notifier);
    final intent = session.requestIntentEpoch;
    return _taskBoundary!.api.captureRequestScope(
      isCurrent: () =>
          warehouseTaskIsCurrent &&
          identical(ref.read(sessionProvider.notifier), session) &&
          session.requestIntentEpoch == intent,
    );
  }

  @override
  void dispose() {
    _taskInvalidated = true;
    _taskBoundarySubscription?.close();
    super.dispose();
  }
}
