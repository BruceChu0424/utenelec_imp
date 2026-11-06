import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../../core/network/api_provider_retry.dart';
import '../models/paged_result.dart';
import '../providers/export_context_epoch_provider.dart';
import 'paged_query_identity.dart';
import 'scoped_paged_read.dart';
import 'read_view_activity.dart';

/// Complete reads publish a terminal failure. ApiClient keeps the original
/// bounded transport retry; explicit refresh/recovery owns the next full read.
Duration? pagedReadProviderRetry(int retryCount, Object error) =>
    apiProviderRetry(retryCount, error);

/// A query-family provider owns its complete result and cancellation lease.
/// Shared read ownership and request coalescing stay in [ScopedPagedRead].
class ScopedPagedReadProviderLease<R> {
  ScopedPagedReadProviderLease(Ref ref, {required Object query})
    : _ref = ref,
      _epoch = ref.watch(exportContextEpochProvider),
      _query = freezePagedReadQuery(query) {
    ref.onDispose(() {
      _disposed = true;
      _reader.dispose();
      _activity.dispose();
    });
  }

  final Ref _ref;
  final int _epoch;
  final Object? _query;
  final _reader = ScopedPagedRead<R>();
  late final _activity = ReadViewActivity(onResume: _resume);
  ({Object token, int page})? _intent;
  bool _disposed = false;
  Object? _readFailure;

  void bindView(
    BuildContext context, {
    required Object Function() currentQuery,
  }) {
    _activity.bindView(
      context,
      isCurrent: () => samePagedReadQuery(_query, currentQuery()),
    );
  }

  void _resume() {
    if (_current && _readFailure == null) _ref.notifyListeners();
  }

  VoidCallback retainBackground() => _activity.retainBackground();

  bool get _current =>
      !_disposed && _epoch == _ref.read(exportContextEpochProvider);

  /// Compatibility callbacks may reuse only the same complete result.
  /// Ordinary invalidation, writes and retries retain their fresh-read contract.
  Future<T> paginate<T>(int page, Future<T> Function() navigate) async {
    final intent = (token: Object(), page: page);
    _intent = intent;
    try {
      return await navigate();
    } finally {
      if (identical(_intent?.token, intent.token)) _intent = null;
    }
  }

  Future<PagedResult<R>> read(
    int page, {
    required Future<PagedResult<R>> Function(int) fetchPage,
    Future<PagedResult<R>> Function(int page, int size)? fetchPageSized,
    Object? Function(R row)? idOf,
  }) {
    final failure = _readFailure;
    if (failure != null) return Future.error(failure);
    final useCache = _intent?.page == page;
    if (useCache) _intent = null;
    return _activity.runRead(
      () => _current,
      () => _reader.read(
        page,
        scope: [_epoch, _query],
        fetchPage: fetchPage,
        fetchPageSized: fetchPageSized,
        idOf: idOf,
        useCache: useCache,
        isCurrent: () => _current,
        onPrefetchError: (error) {
          if (!_current ||
              error is! ApiException ||
              !({401, 403}.contains(error.httpStatus) ||
                  const {
                    'UNAUTHORIZED',
                    'FORBIDDEN',
                    'READ_SCOPE_CHANGED',
                  }.contains(error.code))) {
            return;
          }
          _readFailure = error;
          // Re-evaluate subscribed page providers into the confirmed access
          // error. Do not perform another GET or keep accepted private rows.
          _ref.notifyListeners();
        },
      ),
    );
  }

  void invalidate() {
    _intent = null;
    _readFailure = null;
    _reader.invalidate();
  }
}
