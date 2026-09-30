import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Keeps the last successful page mounted while a page-family request changes.
/// The scope excludes the page number and includes every query/session identity.
/// A different scope never receives rows from the previous query.
class RetainedAsyncPage<T> {
  Object? _scope;
  AsyncData<T>? _previous;

  /// A new auto-dispose family must stay observed until the rebuilt page starts
  /// watching it. Reading only `.future` can dispose it between these frames
  /// and issue the same page request twice.
  Future<void> waitFor(
    WidgetRef ref,
    AutoDisposeFutureProvider<T> provider,
    Future<T> Function() read,
  ) async {
    final subscription = ref.listenManual(provider, (_, _) {});
    try {
      // A failed family instance stays cached while the page watches it. Retry
      // must start a new request instead of re-awaiting its completed error.
      if (subscription.read().hasError) ref.invalidate(provider);
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
}
