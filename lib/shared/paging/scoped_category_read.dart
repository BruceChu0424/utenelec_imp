import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/authenticated_request_scope.dart';
import '../providers/export_context_epoch_provider.dart';
import 'paged_query_identity.dart';
import 'shared_read_provider_owner.dart';

/// Small authoritative category snapshots, keyed by the complete business scope.
/// No row-derived totals, parent-badge arithmetic, persistence, or business writes.
/// The owning provider retires pending reads and snapshots on every reader/write
/// boundary. Failures never poison a later retry.
class ScopedCategoryRead {
  ScopedCategoryRead({this.isOwnerCurrent});
  final bool Function()? isOwnerCurrent;
  final _entries = <(Type, PagedReadQueryKey), _CategoryReadEntry>{};
  bool _disposed = false;
  bool get _owned => !_disposed && (isOwnerCurrent?.call() ?? true);

  Future<T> read<T>({
    required Object query,
    required Future<T> Function() fetch,
    bool force = false,
    Duration maximumAge = const Duration(seconds: 15),
  }) {
    if (!_owned) return Future.error(StateError('Category reader retired'));
    final key = (T, PagedReadQueryKey(query));
    final previous = _entries[key];
    if (!force &&
        previous != null &&
        (!previous.complete || previous.age.elapsed < maximumAge)) {
      return previous.future as Future<T>;
    }
    if (_entries.length >= 64) _entries.remove(_entries.keys.first);
    final completion = Completer<T>();
    final entry = _CategoryReadEntry(completion.future);
    _entries[key] = entry;
    Future.sync(
      () => AuthenticatedRequestScope.sharedRead(() => _owned, fetch),
    ).then(
      (value) {
        entry.complete = true;
        entry.age.reset();
        if (!_owned) {
          completion.completeError(StateError('Category reader retired'));
        } else {
          completion.complete(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        if (identical(_entries[key], entry)) _entries.remove(key);
        completion.completeError(error, stack);
      },
    );
    return completion.future;
  }

  void dispose() {
    _disposed = true;
    _entries.clear();
  }
}

class _CategoryReadEntry {
  _CategoryReadEntry(this.future);
  final Future<Object?> future;
  final age = Stopwatch()..start();
  bool complete = false;
}

final scopedCategoryReadProvider = Provider<ScopedCategoryRead>((ref) {
  final ownerCurrent = captureSharedReadProviderOwner(ref);
  final reader = ScopedCategoryRead(isOwnerCurrent: ownerCurrent);
  ref.onDispose(reader.dispose);
  return reader;
}, dependencies: [exportContextEpochProvider]);
