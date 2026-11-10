import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';

import '../../core/network/authenticated_request_scope.dart';
import '../../core/network/api_exception.dart';
import '../../core/network/data_write_revision.dart';
import '../providers/export_context_epoch_provider.dart';
import '../providers/sensitive_read_boundary_provider.dart';

/// A pure provider read owns its transport until disposal/rebuild. Shared
/// consumers do not inherit the first caller's page/operation cancellation.
/// Identity/permission/query dependencies remain explicit at the owning
/// provider; [isCurrent] adds an existing manual-refresh generation if needed.
/// Never use this around commands or command/read reconciliation sequences.
Future<T> runSharedProviderRead<T>(
  Ref ref,
  FutureOr<T> Function() read, {
  bool Function()? isCurrent,
}) => AuthenticatedRequestScope.sharedRead(
  () => ref.mounted && (isCurrent?.call() ?? true),
  () => Future<T>.sync(read),
);

/// A one-shot bootstrap/refresh is also a real consumer. `read(.future)` alone
/// does not retain an autoDispose provider; hold exactly this awaited read,
/// without extending cache lifetime or replaying a command.
Future<T> readSharedProviderFuture<T>(
  ProviderContainer container,
  ProviderListenable<Future<T>> provider, {
  required ProviderListenable<Object?> boundary,
}) => _readHeldProviderFuture(provider, boundary, container.listen);

/// Widget-owned reads release demand on page disposal as well as completion.
/// Employee UI uses its sensitive boundary by default; other runtime/identity
/// families must supply their own boundary rather than borrowing staff scope.
Future<T> readSharedWidgetFuture<T>(
  WidgetRef ref,
  ProviderListenable<Future<T>> provider, {
  ProviderListenable<Object?>? boundary,
}) => _readHeldProviderFuture(
  provider,
  boundary ?? sensitiveReadBoundaryProvider,
  ref.listenManual,
);

typedef _Listen =
    ProviderSubscription<T> Function<T>(
      ProviderListenable<T> provider,
      void Function(T? previous, T next) listener,
    );

Future<T> _readHeldProviderFuture<T>(
  ProviderListenable<Future<T>> provider,
  ProviderListenable<Object?> boundary,
  _Listen listen,
) async {
  final retired = Completer<T>();
  ProviderSubscription<Future<T>>? subscription;
  Future<T>? original;
  Object? identity;
  var captured = false;
  void retire() {
    if (retired.isCompleted) return;
    retired.completeError(ApiException('REQUEST_STALE', '读取身份或条件已变化'));
    subscription?.close();
  }

  final boundarySubscription = listen<Object?>(boundary, (_, next) {
    if (captured && next != identity) retire();
  });
  identity = boundarySubscription.read();
  captured = true;
  try {
    subscription = listen<Future<T>>(provider, (_, next) {
      if (original != null && !identical(original, next)) retire();
    });
    original = subscription.read();
    return await Future.any([original, retired.future]);
  } finally {
    subscription?.close();
    boundarySubscription.close();
  }
}

/// A shared producer replaces caller intent with its own monotonic boundary,
/// including the interval before a dependency rebuild delivers onDispose.
bool Function() captureSharedReadProviderOwner(Ref ref) {
  final epoch = ref.watch(exportContextEpochProvider);
  final write = ref.watch(dataWriteRevisionProvider);
  return () =>
      ref.mounted &&
      epoch == ref.read(exportContextEpochProvider) &&
      write == ref.read(dataWriteRevisionProvider);
}
