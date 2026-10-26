import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import '../providers/export_context_epoch_provider.dart';
import 'paged_query_identity.dart';
import 'scoped_paged_read.dart';

/// Confirmed access failures wait for the user's retry or a new reader owner.
/// Other failures retain Riverpod's ordinary retry policy.
Duration? pagedReadProviderRetry(int retryCount, Object error) =>
    pagedReadAccessDenied(error)
    ? null
    : ProviderContainer.defaultRetry(retryCount, error);

/// A query-family provider owns this lease across page-provider replacements.
/// Cache, request coalescing and look-ahead stay in [ScopedPagedRead].
class ScopedPagedReadProviderLease<R> {
  ScopedPagedReadProviderLease(Ref ref, {required Object query})
    : _ref = ref,
      _epoch = ref.watch(exportContextEpochProvider),
      _query = freezePagedReadQuery(query) {
    ref.onDispose(() {
      _disposed = true;
      _reader.dispose();
    });
  }

  final Ref _ref;
  final int _epoch;
  final Object? _query;
  final _reader = ScopedPagedRead<R>();
  BuildContext? _view;
  Object Function()? _currentQuery;
  ({Object token, int page})? _intent;
  bool _disposed = false;
  Object? _readFailure;

  void bindView(
    BuildContext context, {
    required Object Function() currentQuery,
  }) {
    _view = context;
    _currentQuery = currentQuery;
  }

  bool get _current =>
      !_disposed &&
      _epoch == _ref.read(exportContextEpochProvider) &&
      (_currentQuery == null || samePagedReadQuery(_query, _currentQuery!()));

  /// Only this explicit navigation may reuse a previously read page. The
  /// finally also clears an intent when Riverpod already had a completed future
  /// and did not execute its page-provider body again. Ordinary invalidation,
  /// writes and retries therefore retain their fresh-read contract.
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
  }) {
    final failure = _readFailure;
    if (failure != null) return Future.error(failure);
    final useCache = _intent?.page == page;
    if (useCache) _intent = null;
    return _reader.read(
      page,
      scope: [_epoch, _query],
      fetchPage: fetchPage,
      useCache: useCache,
      isCurrent: () => _current,
      canPrefetch: () {
        final view = _view;
        return _current &&
            view != null &&
            view.mounted &&
            TickerMode.valuesOf(view).enabled &&
            (ModalRoute.of(view)?.isCurrent ?? true);
      },
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
    );
  }

  void invalidate() {
    _intent = null;
    _readFailure = null;
    _reader.invalidate();
  }
}
