import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart'
    show ProviderBase, ProviderException;

import '../../core/network/api_exception.dart';
import '../providers/export_context_epoch_provider.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

/// The same reader key also retires a table's retained pagination window.
int retainedReaderEpoch(WidgetRef ref) => ref.watch(exportContextEpochProvider);

/// Keeps the last successful page mounted while a page-family request changes.
/// The scope excludes the page number and includes every query/session identity.
/// A different scope never receives rows from the previous query.
class RetainedAsyncPage<T> {
  Object? _scope;
  AsyncData<T>? _previous;

  /// Read through the provider so a reader boundary can invalidate its source
  /// before a cached AsyncData is observed again. Merely adding an epoch to
  /// [resolve]'s scope cannot establish who produced that cached value.
  AsyncValue<T> resolveFor(
    WidgetRef ref,
    Object? scope,
    ProviderBase<AsyncValue<T>> source,
  ) {
    final epoch = ref.watch(exportContextEpochProvider);
    ref.listen<int>(exportContextEpochProvider, (previous, next) {
      if (previous == next) return;
      _scope = null;
      _previous = null;
      ref.invalidate(source);
    });
    return resolve((epoch, scope), ref.watch(source));
  }

  /// A new auto-dispose family must stay observed until the rebuilt page starts
  /// watching it. Reading only `.future` can dispose it between these frames
  /// and issue the same page request twice.
  Future<void> waitFor(
    WidgetRef ref,
    FutureProvider<T> provider,
    Future<T> Function() read,
  ) async {
    final subscription = ref.listenManual(provider, (_, _) {});
    try {
      // A failed family instance stays cached while the page watches it. Retry
      // must restart a settled error, but adopt a retry already in progress:
      // AsyncLoading may still retain that previous error.
      final state = subscription.read();
      if (state.hasError && !state.isLoading) ref.invalidate(provider);
      await read();
    } finally {
      WidgetsBinding.instance.addPostFrameCallback((_) => subscription.close());
      WidgetsBinding.instance.ensureVisualUpdate();
    }
  }

  AsyncValue<T> resolve(Object? scope, AsyncValue<T> value) {
    if (_scope != scope) {
      _scope = scope;
      _previous = null;
    }
    if (value.hasError && _retiresData(value.error!)) {
      _previous = null;
      return value.isLoading
          ? AsyncLoading<T>()
          : AsyncError<T>(value.error!, value.stackTrace ?? StackTrace.empty);
    }
    final previous = _previous;
    if (value.isLoading) {
      final loading = AsyncLoading<T>();
      return previous == null ? loading : loading.copyWithPrevious(previous);
    }
    if (value.hasError) {
      final error = AsyncError<T>(value.error!, value.stackTrace!);
      return previous == null ? error : error.copyWithPrevious(previous);
    }
    if (value.hasValue) _previous = AsyncData(value.requireValue);
    return value;
  }

  static bool _retiresData(Object error) {
    while (error is ProviderException) {
      error = error.exception;
    }
    return error is ApiException &&
        ({401, 403}.contains(error.httpStatus) ||
            const {
              'UNAUTHORIZED',
              'FORBIDDEN',
              'READ_SCOPE_CHANGED',
              'SESSION_CHANGED',
              'SESSION_STATE_UNAVAILABLE',
            }.contains(error.code));
  }
}
